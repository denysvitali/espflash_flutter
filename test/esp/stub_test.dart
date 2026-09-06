import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:espflash_flutter/esp/connection.dart';
import 'package:espflash_flutter/esp/errors.dart';
import 'package:espflash_flutter/esp/flasher.dart';
import 'package:espflash_flutter/esp/protocol.dart';
import 'package:espflash_flutter/esp/slip.dart';
import 'package:espflash_flutter/esp/stub.dart';
import 'package:espflash_flutter/esp/targets/esp32c3.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_transport.dart';

void main() {
  late FakeRomTransport transport;
  late EspConnection connection;
  const target = Esp32C3();
  setUp(() {
    transport = FakeRomTransport()..startStubOnMemEnd = true;
    connection = EspConnection(
      transport,
      defaultTimeout: const Duration(milliseconds: 30),
    );
  });
  tearDown(() async {
    await connection.close();
    await transport.close();
  });
  StubImage stub() => StubImage.fromJson(
    jsonEncode({
      'entry': 0x40380000,
      'text_start': 0x40380000,
      'data_start': 0x3fc90000,
      'text': base64Encode(List.generate(0x1801, (i) => i & 255)),
      'data': base64Encode([0xc0, 0xdb, 3]),
    }),
  );

  test(
    'uploads segments, resets sequence, then consumes queued OHAI',
    () async {
      final image = stub();
      await StubLoader(connection, target).load(image);
      expect(connection.stubRunning, isTrue);
      expect(transport.requestsFor(EspCommand.memBegin).map((r) => r.words), [
        [0x1801, 2, 0x1800, image.textStart],
        [3, 1, 0x1800, image.dataStart],
      ]);
      final blocks = transport.requestsFor(EspCommand.memData);
      expect(blocks.map((r) => r.words.take(4).toList()), [
        [0x1800, 0, 0, 0],
        [1, 1, 0, 0],
        [3, 0, 0, 0],
      ]);
      for (final block in blocks) {
        expect(block.checksum, espChecksum(block.data.sublist(16)));
      }
      expect(transport.requestsFor(EspCommand.memEnd).single.words, [
        0,
        image.entry,
      ]);
      await connection.readReg(0); // Two-byte status is now required.
    },
  );

  test('vendored asset parses and uploads completely', () async {
    final image = StubImage.fromJson(
      File('assets/stubs/esp32c3.json').readAsStringSync(),
    );
    await StubLoader(connection, target).load(image);
    final uploaded = transport
        .requestsFor(EspCommand.memData)
        .expand((r) => r.data.skip(16))
        .toList();
    expect(uploaded, [...image.text, ...image.data]);
  });

  test('split greeting and serial noise are handled', () async {
    transport.feed(SlipCodec.encode([1, 2, 3]));
    final waiting = connection.waitForStub();
    transport.feed([0xc0, 0x4f, 0x48]);
    transport.feed([0x41, 0x49, 0xc0]);
    await waiting;
    expect(connection.stubRunning, isTrue);
  });

  test('missing greeting never enables stub mode', () async {
    await expectLater(
      connection.waitForStub(timeout: const Duration(milliseconds: 5)),
      throwsA(isA<EspTimeoutError>()),
    );
    expect(connection.stubRunning, isFalse);
  });

  test('RAM upload failure does not execute stub', () async {
    transport.romErrorFor[EspCommand.memData] = 7;
    await expectLater(
      StubLoader(connection, target).load(stub()),
      throwsA(isA<EspRomError>()),
    );
    expect(transport.requestsFor(EspCommand.memEnd), isEmpty);
    expect(connection.stubRunning, isFalse);
  });

  test('cancel during upload stops before execution', () async {
    await expectLater(
      StubLoader(connection, target).load(
        stub(),
        isCancelled: () async =>
            transport.requestsFor(EspCommand.memData).isNotEmpty,
      ),
      throwsA(isA<EspCancelledError>()),
    );
    expect(transport.requestsFor(EspCommand.memEnd), isEmpty);
  });

  test(
    'compressed multi-part flash roundtrips payload with binary MD5',
    () async {
      await StubLoader(connection, target).load(stub());
      final random = Random(17);
      final parts = [
        FirmwarePart(
          offset: 0,
          bytes: List.generate(40001, (_) => random.nextInt(256)),
        ),
        FirmwarePart(offset: 0x10000, bytes: List.filled(100000, 0xff)),
      ];
      transport.md5Provider = (offset, size) => md5
          .convert(parts.firstWhere((p) => p.offset == offset).bytes)
          .toString();
      final ticks = <(int, int, int)>[];
      await EspFlasher(connection, target).flash(
        parts.reversed.toList(),
        eraseFirst: true,
        onProgress: (i, w, t) => ticks.add((i, w, t)),
      );
      expect(transport.requestsFor(EspCommand.eraseFlash), hasLength(1));
      expect(transport.requestsFor(EspCommand.flashBegin), isEmpty);
      expect(transport.requestsFor(EspCommand.flashData), isEmpty);
      expect(transport.requestsFor(EspCommand.spiAttach), isEmpty);
      var partIndex = -1;
      final compressed = <int>[];
      var seq = 0;
      for (final request in transport.requests) {
        if (request.opcode == EspCommand.flashDeflBegin) {
          partIndex++;
          seq = 0;
          compressed.clear();
          expect(request.words, [
            parts[partIndex].bytes.length,
            (ZLibEncoder().encode(parts[partIndex].bytes).length + 0x3fff) ~/
                0x4000,
            0x4000,
            parts[partIndex].offset,
          ]);
        } else if (request.opcode == EspCommand.flashDeflData) {
          final data = request.data.sublist(16);
          expect(request.words.take(4), [data.length, seq++, 0, 0]);
          expect(data.length, lessThanOrEqualTo(0x4000));
          expect(request.checksum, espChecksum(data));
          compressed.addAll(data);
        } else if (request.opcode == EspCommand.flashDeflEnd) {
          expect(request.words, [1]); // Keep stub alive for MD5 and next part.
          expect(ZLibDecoder().decodeBytes(compressed), parts[partIndex].bytes);
        }
      }
      expect(transport.requestsFor(EspCommand.flashDeflData), hasLength(4));
      expect(ticks.last, (1, 100000, 100000));
      final ops = transport.requests.map((r) => r.opcode).toList();
      expect(
        ops.lastIndexOf(EspCommand.flashDeflEnd),
        lessThan(ops.indexOf(EspCommand.spiFlashMd5)),
      );
    },
  );

  test('compressed error is not replayed and prevents verify/reboot', () async {
    connection.stubRunning = transport.stubMode = true;
    transport.romErrorFor[EspCommand.flashDeflData] = 0x0b;
    await expectLater(
      EspFlasher(
        connection,
        target,
      ).flash([FirmwarePart(offset: 0, bytes: List.filled(3000, 1))]),
      throwsA(isA<EspRomError>()),
    );
    expect(transport.requestsFor(EspCommand.flashDeflData), hasLength(1));
    expect(transport.requestsFor(EspCommand.spiFlashMd5), isEmpty);
    expect(transport.requestsFor(EspCommand.writeReg), isEmpty);
  });

  test('compressed timeout aborts without replaying the block', () async {
    connection.stubRunning = transport.stubMode = true;
    transport.silentOpcodes.add(EspCommand.flashDeflData);
    final flasher = EspFlasher(
      connection,
      target,
      flashBeginTimeoutFloor: const Duration(milliseconds: 5),
      flashBeginTimeoutPerMb: Duration.zero,
    );
    await expectLater(
      flasher.flash([FirmwarePart(offset: 0, bytes: List.filled(32, 0xff))]),
      throwsA(isA<EspTimeoutError>()),
    );
    expect(transport.requestsFor(EspCommand.flashDeflData), hasLength(1));
    expect(transport.requestsFor(EspCommand.flashDeflEnd), isEmpty);
  });

  test('cancel after compressed block prevents finish and verify', () async {
    connection.stubRunning = transport.stubMode = true;
    await expectLater(
      EspFlasher(connection, target).flash(
        [FirmwarePart(offset: 0, bytes: List.filled(100000, 0xff))],
        isCancelled: () async =>
            transport.requestsFor(EspCommand.flashDeflData).isNotEmpty,
      ),
      throwsA(isA<EspCancelledError>()),
    );
    expect(transport.requestsFor(EspCommand.flashDeflEnd), isEmpty);
    expect(transport.requestsFor(EspCommand.spiFlashMd5), isEmpty);
  });

  test('binary MD5 mismatch prevents reboot', () async {
    connection.stubRunning = transport.stubMode = true;
    await expectLater(
      EspFlasher(connection, target).flash([
        FirmwarePart(offset: 0, bytes: [1, 2, 3]),
      ]),
      throwsA(isA<EspVerifyError>()),
    );
    expect(transport.requestsFor(EspCommand.writeReg), isEmpty);
  });

  test('stub response status does not consume digest bytes', () {
    final payload = [...List.filled(16, 0xab), 1, 0x0b];
    final response = EspResponse.tryParse([
      1,
      EspCommand.spiFlashMd5,
      ...u16le(payload.length),
      ...u32le(0),
      ...payload,
    ], statusSize: 2)!;
    expect(response.body, List.filled(16, 0xab));
    expect(response.romStatus, (1, 0x0b));
    expect(
      () => response.throwIfRomError('verify'),
      throwsA(isA<EspRomError>()),
    );
  });

  test('bridge baud command includes old baud; USB JTAG skips it', () async {
    await connection.changeBaud(460800);
    expect(transport.requests, isEmpty);
    final bridge = FakeRomTransport(vendorId: 0x10c4, productId: 0xea60)
      ..stubMode = true;
    final conn = EspConnection(bridge)..stubRunning = true;
    try {
      await conn.changeBaud(460800);
      expect(bridge.requests.single.words, [460800, 115200]);
      expect(bridge.baudRates, [460800]);
    } finally {
      await conn.close();
      await bridge.close();
    }
  });
}
