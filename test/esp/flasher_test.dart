import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:espflash_flutter/esp/connection.dart';
import 'package:espflash_flutter/esp/errors.dart';
import 'package:espflash_flutter/esp/flasher.dart';
import 'package:espflash_flutter/esp/protocol.dart';
import 'package:espflash_flutter/esp/targets/esp32c3.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_transport.dart';

Uint8List fixture(int seed, int length) {
  return Uint8List.fromList(
    List<int>.generate(length, (i) => (seed + i * 7) & 0xFF),
  );
}

typedef ProgressTick = (int part, int written, int total);

void main() {
  late FakeRomTransport transport;
  late EspConnection connection;
  late EspFlasher flasher;

  // Part A: 2305 bytes -> blocks of 1024/1024/257 (last padded to 260).
  final partA = FirmwarePart(offset: 0x0, bytes: fixture(1, 0x901));
  // Part B: exactly two full blocks.
  final partB = FirmwarePart(offset: 0x10000, bytes: fixture(2, 0x800));

  String md5Of(FirmwarePart part) => md5.convert(part.bytes).toString();

  setUp(() {
    transport = FakeRomTransport();
    transport.md5Provider = (address, size) {
      if (address == partA.offset && size == partA.bytes.length) {
        return md5Of(partA);
      }
      if (address == partB.offset && size == partB.bytes.length) {
        return md5Of(partB);
      }
      return '0' * 32;
    };
    connection = EspConnection(
      transport,
      defaultTimeout: const Duration(milliseconds: 200),
    );
    flasher = EspFlasher(
      connection,
      const Esp32C3(),
      blockTimeout: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    await connection.close();
  });

  List<RomRequest> requestsOf(int opcode) =>
      transport.requestsFor(opcode);

  test(
      'full two-part flash: ATTACH, SET_PARAMS, BEGIN/DATA layout, '
      'MD5, reboot', () async {
    final ticks = <ProgressTick>[];
    await flasher.flash(
      [partA, partB],
      onProgress: (part, written, total) =>
          ticks.add((part, written, total)),
    );

    // --- command order ---
    final opcodes = transport.requests.map((r) => r.opcode).toList();
    expect(opcodes, [
      EspCommand.spiAttach,
      EspCommand.spiSetParams,
      EspCommand.flashBegin, // part A
      EspCommand.flashData,
      EspCommand.flashData,
      EspCommand.flashData,
      EspCommand.flashBegin, // part B
      EspCommand.flashData,
      EspCommand.flashData,
      EspCommand.spiFlashMd5, // verify A
      EspCommand.spiFlashMd5, // verify B
      EspCommand.writeReg, // rtcWdtReset: 4 writes
      EspCommand.writeReg,
      EspCommand.writeReg,
      EspCommand.writeReg,
    ]);

    // --- SPI_ATTACH: <u32 0><u32 0> ---
    expect(requestsOf(EspCommand.spiAttach).single.data,
        [0, 0, 0, 0, 0, 0, 0, 0]);

    // --- SPI_SET_PARAMS: 0, 4MB, block, sector, page, status mask ---
    expect(requestsOf(EspCommand.spiSetParams).single.words, [
      0,
      0x400000,
      0x10000,
      0x1000,
      0x100,
      0xFFFF,
    ]);

    // --- FLASH_BEGIN: size, num_blocks, block_size, offset, 0 ---
    final begins = requestsOf(EspCommand.flashBegin);
    expect(begins[0].words, [0x901, 3, 0x400, 0x0, 0]);
    expect(begins[1].words, [0x800, 2, 0x400, 0x10000, 0]);

    // --- FLASH_DATA blocks ---
    final dataRequests = requestsOf(EspCommand.flashData);
    expect(dataRequests, hasLength(5));
    // Prefixes: <len, seq, 0, 0>.
    expect(dataRequests[0].words.sublist(0, 4), [0x400, 0, 0, 0]);
    expect(dataRequests[1].words.sublist(0, 4), [0x400, 1, 0, 0]);
    expect(dataRequests[2].words.sublist(0, 4), [0x104, 2, 0, 0]);
    expect(dataRequests[3].words.sublist(0, 4), [0x400, 0, 0, 0]);
    expect(dataRequests[4].words.sublist(0, 4), [0x400, 1, 0, 0]);

    // Block content: part A sliced, last block padded with 0xFF.
    final blockA0 = dataRequests[0].data.sublist(16);
    expect(blockA0, partA.bytes.sublist(0, 0x400));
    final blockA2 = dataRequests[2].data.sublist(16);
    expect(blockA2.sublist(0, 0x101), partA.bytes.sublist(0x800));
    expect(blockA2.sublist(0x101), [0xFF, 0xFF, 0xFF]);
    // Part B needs no padding.
    expect(dataRequests[3].data.sublist(16),
        partB.bytes.sublist(0, 0x400));

    // Header checksum = XOR over the transmitted block (seed 0xEF).
    for (final request in dataRequests) {
      expect(request.checksum, espChecksum(request.data.sublist(16)));
    }
    // With 4-aligned data the transmitted checksum equals the one
    // over the unpadded data (part B is block-aligned).
    expect(dataRequests[3].checksum,
        espChecksum(partB.bytes.sublist(0, 0x400)));

    // --- No FLASH_END is ever sent to the ROM ---
    expect(requestsOf(EspCommand.flashEnd), isEmpty);

    // --- SPI_FLASH_MD5: <addr, size, 0, 0> per part ---
    final md5Requests = requestsOf(EspCommand.spiFlashMd5);
    expect(md5Requests[0].words, [0x0, 0x901, 0, 0]);
    expect(md5Requests[1].words, [0x10000, 0x800, 0, 0]);

    // --- progress: initial tick + one tick per block ---
    expect(ticks, [
      (0, 0, 0x901),
      (0, 0x400, 0x901),
      (0, 0x800, 0x901),
      (0, 0x901, 0x901),
      (1, 0, 0x800),
      (1, 0x400, 0x800),
      (1, 0x800, 0x800),
    ]);

    // --- reboot over USB-JTAG: RTC WDT reset writes ---
    final rebootWrites = requestsOf(EspCommand.writeReg)
        .map((r) => (readU32le(r.data), readU32le(r.data, 4)))
        .toList();
    expect(rebootWrites, [
      (0x600080A8, 0x50D83AA1),
      (0x60008094, 2000),
      (0x60008090, (1 << 31) | (5 << 28) | (1 << 8) | 2),
      (0x600080A8, 0),
    ]);
  });

  test('MD5 mismatch throws EspVerifyError before reboot', () async {
    transport.md5Provider = (address, size) => 'f' * 32;
    await expectLater(
      () => flasher.flash([partB]),
      throwsA(
        isA<EspVerifyError>()
            .having((e) => e.message, 'message', contains('MD5'))
            .having((e) => e.message, 'message', contains('0x10000')),
      ),
    );
    expect(requestsOf(EspCommand.writeReg), isEmpty);
  });

  test('MD5 comparison is case-insensitive', () async {
    transport.md5Provider = (address, size) =>
        md5Of(partB).toUpperCase();
    await flasher.flash([partB]);
    expect(requestsOf(EspCommand.spiFlashMd5), hasLength(1));
  });

  test('eraseFirst sends FLASH_BEGIN with num_blocks = 0 over 4MB',
      () async {
    await flasher.flash([partB], eraseFirst: true);
    final begins = requestsOf(EspCommand.flashBegin);
    expect(begins, hasLength(2));
    // Erase: size 4MB, zero blocks, block size, offset 0, no crypt.
    expect(begins.first.words, [0x400000, 0, 0x400, 0, 0]);
    // Then the actual part.
    expect(begins.last.words, [0x800, 2, 0x400, 0x10000, 0]);
  });

  test('eraseFlash alone is one zero-block FLASH_BEGIN', () async {
    await flasher.eraseFlash();
    expect(
      requestsOf(EspCommand.flashBegin).single.words,
      [0x400000, 0, 0x400, 0, 0],
    );
    expect(requestsOf(EspCommand.flashData), isEmpty);
  });

  test('cancel between blocks throws EspCancelledError', () async {
    var cancelCalls = 0;
    await expectLater(
      () => flasher.flash(
        [partA],
        isCancelled: () async {
          cancelCalls++;
          // Let part start + block 0 through, stop before block 1.
          return cancelCalls >= 3;
        },
      ),
      throwsA(isA<EspCancelledError>()),
    );
    expect(requestsOf(EspCommand.flashData), hasLength(1));
    expect(requestsOf(EspCommand.spiFlashMd5), isEmpty);
    expect(requestsOf(EspCommand.writeReg), isEmpty);
  });

  test('cancel before anything is written', () async {
    await expectLater(
      () => flasher.flash(
        [partA],
        isCancelled: () async => true,
      ),
      throwsA(isA<EspCancelledError>()),
    );
    expect(requestsOf(EspCommand.flashBegin), isEmpty);
    expect(requestsOf(EspCommand.flashData), isEmpty);
  });

  test('FLASH_DATA is retried on ROM error and succeeds', () async {
    final small = FirmwarePart(offset: 0, bytes: fixture(3, 0x10));
    transport.md5Provider = (address, size) =>
        md5.convert(small.bytes).toString();
    transport.flashDataFailures = 2;
    await flasher.flash([small]);
    expect(requestsOf(EspCommand.flashData), hasLength(3));
  });

  test('FLASH_DATA gives up after blockAttempts failures', () async {
    final small = FirmwarePart(offset: 0, bytes: fixture(3, 0x10));
    transport.flashDataFailures = 99;
    await expectLater(
      () => flasher.flash([small]),
      throwsA(
        isA<EspRomError>().having((e) => e.code, 'code', 0x0108),
      ),
    );
    expect(requestsOf(EspCommand.flashData), hasLength(3));
  });

  test('parts are flashed sorted by offset', () async {
    await flasher.flash([partB, partA]); // passed out of order
    final begins = requestsOf(EspCommand.flashBegin);
    expect(begins[0].words[3], 0x0); // part A first
    expect(begins[1].words[3], 0x10000);
  });

  test('bridge chip reboots via RTS hard reset', () async {
    final bridge = FakeRomTransport(vendorId: 0x10C4, productId: 0xEA60);
    bridge.md5Provider = (address, size) => md5Of(partB);
    final bridgeConnection = EspConnection(
      bridge,
      defaultTimeout: const Duration(milliseconds: 200),
    );
    final bridgeFlasher = EspFlasher(bridgeConnection, const Esp32C3());
    await bridgeFlasher.flash([partB]);
    await bridgeConnection.close();
    expect(bridge.requestsFor(EspCommand.writeReg), isEmpty);
    expect(bridge.lineEvents, [
      ('rts', true),
      ('rts', false),
    ]);
  });

  test('empty part list is rejected', () async {
    await expectLater(
      () => flasher.flash(const []),
      throwsArgumentError,
    );
  });

  test('single-byte part pads to 4 bytes with 0xFF', () async {
    final tiny = FirmwarePart(offset: 0, bytes: [0xAB]);
    transport.md5Provider = (address, size) =>
        md5.convert(tiny.bytes).toString();
    await flasher.flash([tiny]);
    final begin = requestsOf(EspCommand.flashBegin).single;
    expect(begin.words, [1, 1, 0x400, 0, 0]);
    final block = requestsOf(EspCommand.flashData).single;
    expect(block.words.sublist(0, 4), [4, 0, 0, 0]);
    expect(block.data.sublist(16), [0xAB, 0xFF, 0xFF, 0xFF]);
    expect(block.checksum, espChecksum([0xAB, 0xFF, 0xFF, 0xFF]));
  });
}
