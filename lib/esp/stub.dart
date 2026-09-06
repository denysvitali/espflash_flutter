/// ESP32-C3 RAM flasher upload. The asset is supplied by the application so
/// this layer remains independent of Flutter and can use scripted transports.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'connection.dart';
import 'errors.dart';
import 'protocol.dart';
import 'targets/chip_target.dart';

final class StubImage {
  StubImage.fromJson(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    entry = json['entry'] as int;
    textStart = json['text_start'] as int;
    dataStart = json['data_start'] as int;
    text = base64Decode(json['text'] as String);
    data = base64Decode(json['data'] as String);
    if (text.isEmpty || entry < textStart || entry >= textStart + text.length) {
      throw const FormatException('Invalid stub entry or empty text');
    }
  }

  late final int entry;
  late final int textStart;
  late final int dataStart;
  late final Uint8List text;
  late final Uint8List data;
}

final class StubLoader {
  const StubLoader(this.connection, this.target);

  final EspConnection connection;
  final ChipTarget target;

  Future<void> load(
    StubImage image, {
    Future<bool> Function()? isCancelled,
  }) async {
    if (target.chipId != 5) {
      throw const EspUnsupportedChipError('Stub supports only ESP32-C3');
    }
    if (connection.stubRunning) return;
    Future<void> checkCancelled() async {
      if (isCancelled != null && await isCancelled()) {
        throw const EspCancelledError();
      }
    }

    final blockSize = target.ramBlockSize;
    for (final (offset, bytes) in [
      (image.textStart, image.text),
      (image.dataStart, image.data),
    ]) {
      await checkCancelled();
      if (bytes.isEmpty) continue;
      final blocks = (bytes.length + blockSize - 1) ~/ blockSize;
      await connection.command(
        EspCommand.memBegin,
        data: [
          ...u32le(bytes.length),
          ...u32le(blocks),
          ...u32le(blockSize),
          ...u32le(offset),
        ],
      );
      for (var seq = 0; seq < blocks; seq++) {
        await checkCancelled();
        final block = bytes.sublist(
          seq * blockSize,
          math.min((seq + 1) * blockSize, bytes.length),
        );
        await connection.command(
          EspCommand.memData,
          data: [
            ...u32le(block.length),
            ...u32le(seq),
            ...u32le(0),
            ...u32le(0),
            ...block,
          ],
          checksum: espChecksum(block),
        );
      }
    }
    await checkCancelled();
    await connection.command(
      EspCommand.memEnd,
      data: [...u32le(0), ...u32le(image.entry)],
    );
    await connection.waitForStub();
  }
}
