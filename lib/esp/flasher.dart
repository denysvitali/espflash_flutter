/// Flash orchestration: SPI attach/params, per-part erase + block
/// writes, MD5 verification, reboot.
///
/// ROM-only sequence (no stub), mirroring esptool `write_flash` and
/// IMPLEMENTATION_PLAN.md section 3: FLASH_END is deliberately NOT
/// sent to the ROM, since it would make the bootloader exit and run
/// user code before we reboot on our own terms.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'connection.dart';
import 'errors.dart';
import 'protocol.dart';
import 'reset.dart';
import 'targets/chip_target.dart';

/// One firmware part to write at [offset].
final class FirmwarePart {
  FirmwarePart({required this.offset, required List<int> bytes, this.name})
      : bytes = Uint8List.fromList(bytes);

  /// Flash address the part is written to.
  final int offset;

  /// Raw part content (unpadded).
  final Uint8List bytes;

  /// Display name (file name), for logging/UI.
  final String? name;
}

/// Progress callback: `(partIndex, bytesWritten, totalBytes)`,
/// fired once before the first block and once after every block.
typedef FlashProgressCallback = void Function(
  int partIndex,
  int written,
  int total,
);

/// Cancellation probe; returning true aborts with
/// [EspCancelledError].
typedef CancelCheck = Future<bool> Function();

final class EspFlasher {
  EspFlasher(
    this.connection,
    this.target, {
    this.flashBeginTimeoutFloor = const Duration(seconds: 30),
    this.flashBeginTimeoutPerMb = const Duration(seconds: 40),
    this.blockTimeout = const Duration(seconds: 3),
    this.blockAttempts = 3,
    this.md5TimeoutFloor = const Duration(seconds: 3),
    this.md5TimeoutPerMb = const Duration(seconds: 8),
  });

  /// Flash size assumed for SPI_SET_PARAMS and full-chip erase.
  static const int assumedFlashSize = 0x400000;

  final EspConnection connection;
  final ChipTarget target;

  /// FLASH_BEGIN timeout floor: the ROM erases up-front and can sit
  /// silent for a long time.
  final Duration flashBeginTimeoutFloor;

  /// FLASH_BEGIN timeout scaled by erase size (40 s per MB).
  final Duration flashBeginTimeoutPerMb;

  /// Per-block FLASH_DATA timeout (ROM writes before ACKing).
  final Duration blockTimeout;

  /// Attempts per FLASH_DATA block before giving up.
  final int blockAttempts;

  /// SPI_FLASH_MD5 timeout floor.
  final Duration md5TimeoutFloor;

  /// SPI_FLASH_MD5 timeout scaled by region size (8 s per MB).
  final Duration md5TimeoutPerMb;

  /// Flash [parts] (sorted by offset internally), verify each one
  /// via SPI_FLASH_MD5, then reboot the chip.
  ///
  /// When [eraseFirst] is set, the whole 4 MB is erased up front.
  /// [isCancelled] is polled between blocks; a `true` answer raises
  /// [EspCancelledError].
  Future<void> flash(
    List<FirmwarePart> parts, {
    FlashProgressCallback? onProgress,
    bool eraseFirst = false,
    CancelCheck? isCancelled,
  }) async {
    if (parts.isEmpty) {
      throw ArgumentError.value(parts, 'parts', 'must not be empty');
    }
    final sorted = [...parts]
      ..sort((a, b) => a.offset.compareTo(b.offset));

    await spiAttach();
    await spiSetParams();
    if (eraseFirst) {
      await eraseFlash();
    }
    for (var index = 0; index < sorted.length; index++) {
      await _throwIfCancelled(isCancelled);
      await _writePart(index, sorted[index], onProgress, isCancelled);
    }
    for (final part in sorted) {
      await _verifyPart(part);
    }
    await reboot();
  }

  /// Erase the full assumed flash: FLASH_BEGIN with zero blocks
  /// (ROM erase-only). Takes roughly a minute per MB.
  Future<void> eraseFlash() async {
    await _flashBegin(size: assumedFlashSize, offset: 0, numBlocks: 0);
  }

  /// Reboot into user code: RTC watchdog reset over USB-Serial-JTAG
  /// (DTR/RTS never reach the chip there), hard reset via RTS
  /// otherwise.
  Future<void> reboot() async {
    if (connection.transport.isUsbJtag) {
      await target.rtcWdtReset(connection);
    } else {
      await const HardReset().reset(connection.transport);
    }
  }

  /// SPI_ATTACH: enable the SPI flash pins (`<u32 0><u32 0>`).
  Future<void> spiAttach() async {
    final data = (BytesBuilder(copy: false)
          ..add(u32le(0))
          ..add(u32le(0)))
        .toBytes();
    await connection.command(
      EspCommand.spiAttach,
      data: data,
      description: 'attach SPI flash',
    );
  }

  /// SPI_SET_PARAMS: tell the ROM the "flashchip" geometry we assume
  /// (`id, total size, block, sector, page, status mask`).
  Future<void> spiSetParams() async {
    final data = (BytesBuilder(copy: false)
          ..add(u32le(0))
          ..add(u32le(assumedFlashSize))
          ..add(u32le(0x10000))
          ..add(u32le(0x1000))
          ..add(u32le(0x100))
          ..add(u32le(0xFFFF)))
        .toBytes();
    await connection.command(
      EspCommand.spiSetParams,
      data: data,
      description: 'set SPI flash parameters',
    );
  }

  /// FLASH_BEGIN: size, block count, block size, offset, encrypted
  /// flag. The ROM performs the erase here, before ACKing, hence the
  /// size-scaled timeout.
  Future<void> _flashBegin({
    required int size,
    required int offset,
    required int numBlocks,
  }) async {
    final data = (BytesBuilder(copy: false)
          ..add(u32le(size))
          ..add(u32le(numBlocks))
          ..add(u32le(target.flashWriteSize))
          ..add(u32le(offset))
          ..add(u32le(0)))
        .toBytes();
    await connection.command(
      EspCommand.flashBegin,
      data: data,
      timeout: _scaledTimeout(
        flashBeginTimeoutPerMb,
        flashBeginTimeoutFloor,
        size,
      ),
      description: 'enter flash download mode (erases the region)',
    );
  }

  Future<void> _writePart(
    int partIndex,
    FirmwarePart part,
    FlashProgressCallback? onProgress,
    CancelCheck? isCancelled,
  ) async {
    final total = part.bytes.length;
    final blockSize = target.flashWriteSize;
    final numBlocks = (total + blockSize - 1) ~/ blockSize;
    await _flashBegin(size: total, offset: part.offset, numBlocks: numBlocks);
    onProgress?.call(partIndex, 0, total);
    var written = 0;
    var sequence = 0;
    while (written < total) {
      await _throwIfCancelled(isCancelled);
      final end = math.min(written + blockSize, total);
      final block = _prepareBlock(part.bytes, written, end, blockSize);
      await _flashBlock(block, sequence);
      written = end;
      sequence++;
      onProgress?.call(partIndex, written, total);
    }
  }

  /// Slice `[start, end)` of [bytes]; when it is the final, short
  /// block, pad it to a 4-byte boundary with 0xFF (the erased flash
  /// value). The prefix `len` and the checksum both cover the
  /// transmitted, padded block, as the ROM verifies them; for parts
  /// whose size is a multiple of 4 (every real firmware image) this
  /// equals the checksum over the unpadded data.
  Uint8List _prepareBlock(
    Uint8List bytes,
    int start,
    int end,
    int blockSize,
  ) {
    var block = bytes.sublist(start, end);
    final padding = (4 - block.length % 4) % 4;
    if (padding != 0) {
      block = Uint8List.fromList([
        ...block,
        ...List<int>.filled(padding, 0xFF),
      ]);
    }
    assert(block.length <= blockSize);
    return block;
  }

  Future<void> _flashBlock(Uint8List block, int sequence) async {
    final data = (BytesBuilder(copy: false)
          ..add(u32le(block.length))
          ..add(u32le(sequence))
          ..add(u32le(0))
          ..add(u32le(0))
          ..add(block))
        .toBytes();
    for (var attempt = 1; attempt <= blockAttempts; attempt++) {
      try {
        await connection.command(
          EspCommand.flashData,
          data: data,
          checksum: espChecksum(block),
          timeout: blockTimeout,
          description: 'write flash block $sequence',
        );
        return;
      } on EspError {
        if (attempt == blockAttempts) {
          rethrow;
        }
      }
    }
  }

  /// SPI_FLASH_MD5 over the part region; the ROM answers with 32
  /// ASCII hex chars which must match the MD5 of the part bytes.
  Future<void> _verifyPart(FirmwarePart part) async {
    final data = (BytesBuilder(copy: false)
          ..add(u32le(part.offset))
          ..add(u32le(part.bytes.length))
          ..add(u32le(0))
          ..add(u32le(0)))
        .toBytes();
    final response = await connection.command(
      EspCommand.spiFlashMd5,
      data: data,
      timeout: _scaledTimeout(
        md5TimeoutPerMb,
        md5TimeoutFloor,
        part.bytes.length,
      ),
      description: 'calculate flash MD5',
    );
    final body = response.body;
    if (body.length < 32) {
      throw EspVerifyError(
        'MD5 response too short (${body.length} bytes)',
      );
    }
    final flashMd5 =
        String.fromCharCodes(body.sublist(0, 32)).toLowerCase();
    final expectedMd5 = md5.convert(part.bytes).toString();
    if (flashMd5 != expectedMd5) {
      throw EspVerifyError(
        'MD5 mismatch at offset 0x'
        '${part.offset.toRadixString(16)}: flash reports $flashMd5, '
        'expected $expectedMd5',
      );
    }
  }

  /// `max(floor, perMb * sizeInMb)` scaled timeouts, as esptool's
  /// `timeout_per_mb`.
  Duration _scaledTimeout(Duration perMb, Duration floor, int size) {
    final scaled = perMb * (size / 1000000);
    return scaled > floor ? scaled : floor;
  }

  Future<void> _throwIfCancelled(CancelCheck? isCancelled) async {
    if (isCancelled != null && await isCancelled()) {
      throw const EspCancelledError();
    }
  }
}
