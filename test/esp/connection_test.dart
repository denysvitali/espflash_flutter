import 'dart:typed_data';

import 'package:espflash_flutter/esp/connection.dart';
import 'package:espflash_flutter/esp/errors.dart';
import 'package:espflash_flutter/esp/protocol.dart';
import 'package:espflash_flutter/esp/reset.dart';
import 'package:espflash_flutter/esp/slip.dart';
import 'package:espflash_flutter/esp/transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_transport.dart';

Uint8List _syncResponseFrame({int value = 0x0BAD0001}) {
  final packet = [
    0x01, // response
    EspCommand.sync,
    0x04, 0x00, // payload size
    value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF,
    (value >> 24) & 0xFF, //
    0, 0, 0, 0, // ROM status: ok
  ];
  return SlipCodec.encode(packet);
}

Uint8List _responseFrame(int opcode, {int value = 0, List<int>? data}) {
  final payload = data ?? const [0, 0, 0, 0];
  final packet = (BytesBuilder(copy: false)
        ..addByte(0x01)
        ..addByte(opcode)
        ..add(u16le(payload.length))
        ..add(u32le(value))
        ..add(payload))
      .toBytes();
  return SlipCodec.encode(packet);
}

/// Decoded host request for assertions.
final class _Request {
  _Request(this.opcode, this.checksum, this.data);

  final int opcode;
  final int checksum;
  final Uint8List data;
}

_Request _decodeRequest(Uint8List frame) {
  final packet = SlipStream().addBytes(frame).single;
  expect(packet[0], 0x00, reason: 'request direction');
  return _Request(
    packet[1],
    readU32le(packet, 4),
    Uint8List.fromList(packet.sublist(8)),
  );
}

void main() {
  late FakeTransport transport;
  late EspConnection connection;

  setUp(() {
    transport = FakeTransport();
    connection = EspConnection(
      transport,
      syncTries: 2,
      connectAttempts: 2,
      syncTimeout: const Duration(milliseconds: 20),
      defaultTimeout: const Duration(milliseconds: 50),
    );
  });

  tearDown(() async {
    await connection.close();
  });

  group('sync', () {
    test('sends the 36-byte payload once and drains 8 responses',
        () async {
      for (var i = 0; i < 8; i++) {
        transport.feed(_syncResponseFrame());
      }
      await connection.sync();
      expect(transport.writes, hasLength(1));
      final request = _decodeRequest(transport.writes.single);
      expect(request.opcode, EspCommand.sync);
      expect(request.data, syncPayload);
      expect(request.data, hasLength(36));
      expect(request.data.sublist(0, 4), [0x07, 0x07, 0x12, 0x20]);
      expect(request.data.sublist(4), List<int>.filled(32, 0x55));
      expect(connection.syncStubDetected, isFalse);
    });

    test('value == 0 in every response means a stub is running',
        () async {
      for (var i = 0; i < 8; i++) {
        transport.feed(_syncResponseFrame(value: 0));
      }
      await connection.sync();
      expect(connection.syncStubDetected, isTrue);
    });

    test('a single non-zero response keeps it a ROM', () async {
      transport.feed(_syncResponseFrame(value: 1));
      for (var i = 0; i < 7; i++) {
        transport.feed(_syncResponseFrame(value: 0));
      }
      await connection.sync();
      expect(connection.syncStubDetected, isFalse);
    });

    test('throws EspTimeoutError when nothing comes back', () async {
      await expectLater(
        () => connection.sync(),
        throwsA(isA<EspTimeoutError>()),
      );
    });
  });

  group('connect', () {
    test('runs the reset strategy before the sync tries', () async {
      final events = <String>[];
      final recording = _EventTransport(transport, events);
      final conn = EspConnection(
        recording,
        syncTries: 2,
        connectAttempts: 2,
        syncTimeout: const Duration(milliseconds: 20),
      );
      // Like the ROM: answer a SYNC frame with 8 responses. Each
      // sync try flushes its input first, so feeding early would be
      // dropped (correctly) by connect().
      transport.onWrite = (frame) {
        for (final packet in SlipStream().addBytes(frame)) {
          if (packet.length > 1 && packet[1] == EspCommand.sync) {
            for (var i = 0; i < 8; i++) {
              transport.feed(_syncResponseFrame());
            }
          }
        }
      };
      await conn.connect(resetStrategy: HardReset(sleep: (d) async {
        events.add('sleep');
      }));
      await conn.close();
      // Reset (RTS pulse) must precede the first SYNC write.
      final firstWrite = events.indexOf('write');
      final firstRts = events.indexOf('rts');
      expect(firstRts, isNonNegative);
      expect(firstWrite, greaterThan(firstRts));
    });

    test('retries tries x attempts, resetting before each attempt',
        () async {
      // ClassicReset asserts RTS once per run -> count resets.
      EspSyncError? caught;
      try {
        await connection.connect(
          resetStrategy: ClassicReset(sleep: (d) async {}),
        );
      } on EspSyncError catch (error) {
        caught = error;
      }
      expect(caught, isNotNull);
      // 2 attempts x 2 tries = 4 SYNC frames written.
      expect(transport.writes, hasLength(4));
      for (final frame in transport.writes) {
        expect(_decodeRequest(frame).opcode, EspCommand.sync);
      }
      // One reset per attempt.
      final rtsPulses = transport.lineEvents
          .where((e) => e.$1 == 'rts' && e.$2)
          .length;
      expect(rtsPulses, 2);
      expect(caught.toString(), contains('Failed to sync'));
    });

    test('succeeds on the second attempt', () async {
      var syncRequests = 0;
      final decoder = SlipStream();
      transport.onWrite = (frame) {
        for (final packet in decoder.addBytes(frame)) {
          if (packet.length > 1 && packet[1] == EspCommand.sync) {
            syncRequests++;
            // Stay silent for attempt 1 (2 tries); answer attempt 2.
            if (syncRequests > 2) {
              for (var i = 0; i < 8; i++) {
                transport.feed(_syncResponseFrame());
              }
            }
          }
        }
      };
      await connection.connect(
        resetStrategy: ClassicReset(sleep: (d) async {}),
      );
      expect(syncRequests, 3); // 2 silent tries + 1 answered
      expect(transport.writes, hasLength(3));
    });
  });

  group('command', () {
    test('skips responses for other opcodes', () async {
      transport.feed(_responseFrame(EspCommand.readReg, value: 1));
      transport.feed(_responseFrame(EspCommand.writeReg, value: 2));
      final response = await connection.command(EspCommand.writeReg);
      expect(response.opcode, EspCommand.writeReg);
      expect(response.value, 2);
    });

    test('times out with EspTimeoutError when no reply arrives',
        () async {
      await expectLater(
        () => connection.command(EspCommand.spiAttach),
        throwsA(isA<EspTimeoutError>()),
      );
    });

    test('ignores unparseable frames and keeps waiting', () async {
      transport.feed(SlipCodec.encode([0x01])); // too short
      transport.feed(_responseFrame(EspCommand.writeReg));
      final response = await connection.command(EspCommand.writeReg);
      expect(response.opcode, EspCommand.writeReg);
    });

    test('survives framing noise then answers the next command',
        () async {
      // Invalid escape mid-noise must not kill the connection.
      transport.feed([0xC0, 0xDB, 0x00, 0xC0]);
      transport.feed('boot:0x01 noise\r\n'.codeUnits);
      transport.feed(_responseFrame(EspCommand.readReg, value: 7));
      expect(await connection.readReg(0x1000), 7);
    });

    test('reassembles a response split across two chunks', () async {
      final frame = _responseFrame(EspCommand.readReg, value: 0x1234);
      transport.feed(frame.sublist(0, 5));
      transport.feed(frame.sublist(5));
      final response = await connection.command(EspCommand.readReg);
      expect(response.value, 0x1234);
    });

    test('raises EspRomError on a failing ROM status', () async {
      transport.feed(
        _responseFrame(EspCommand.flashData, data: [1, 0x07, 0, 0]),
      );
      await expectLater(
        () => connection.command(EspCommand.flashData),
        throwsA(
          isA<EspRomError>().having((e) => e.code, 'code', 0x0107),
        ),
      );
    });

    test('checkRomStatus: false returns the raw response', () async {
      transport.feed(
        _responseFrame(EspCommand.flashData, data: [1, 0x08, 0, 0]),
      );
      final response = await connection.command(
        EspCommand.flashData,
        checkRomStatus: false,
      );
      expect(response.hasRomError, isTrue);
      expect(response.romStatus, (1, 0x08));
    });

    test('throws EspDeviceLostError when the transport closes',
        () async {
      final pending = connection.command(EspCommand.readReg);
      await transport.close();
      await expectLater(
        () => pending,
        throwsA(isA<EspDeviceLostError>()),
      );
    });
  });

  group('register helpers', () {
    test('readReg sends <u32 addr> and returns the header value',
        () async {
      transport.feed(
        _responseFrame(EspCommand.readReg, value: 0x6921506F),
      );
      final value = await connection.readReg(0x40001000);
      expect(value, 0x6921506F);
      final request = _decodeRequest(transport.writes.single);
      expect(request.opcode, EspCommand.readReg);
      expect(request.data, u32le(0x40001000));
      expect(request.checksum, 0);
    });

    test('writeReg sends <addr, value, mask, delay> little-endian',
        () async {
      transport.feed(_responseFrame(EspCommand.writeReg));
      await connection.writeReg(
        0x600080A8,
        0x50D83AA1,
        mask: 0xFFFFFFFF,
        delayUs: 0,
      );
      final request = _decodeRequest(transport.writes.single);
      expect(request.opcode, EspCommand.writeReg);
      expect(request.data, [
        ...u32le(0x600080A8),
        ...u32le(0x50D83AA1),
        ...u32le(0xFFFFFFFF),
        ...u32le(0),
      ]);
      expect(request.checksum, 0);
    });

    test('readReg after sync sees no stale sync responses', () async {
      // Fully answered sync leaves the queue drained.
      for (var i = 0; i < 8; i++) {
        transport.feed(_syncResponseFrame());
      }
      await connection.sync();
      transport.feed(
        _responseFrame(EspCommand.readReg, value: 0x42),
      );
      expect(await connection.readReg(0x1000), 0x42);
    });
  });
}

/// Wraps a transport and records coarse event kinds for ordering
/// assertions.
final class _EventTransport implements EspTransport {
  _EventTransport(this.inner, this.events);

  final FakeTransport inner;
  final List<String> events;

  @override
  Future<void> write(List<int> data) {
    events.add('write');
    return inner.write(data);
  }

  @override
  Stream<List<int>> get chunks => inner.chunks;

  @override
  Future<void> setBaud(int baud) => inner.setBaud(baud);

  @override
  Future<void> setDtr(bool value) async {
    events.add('dtr');
  }

  @override
  Future<void> setRts(bool value) async {
    events.add('rts');
  }

  @override
  int? get vendorId => inner.vendorId;

  @override
  int? get productId => inner.productId;

  @override
  bool get isUsbJtag => inner.isUsbJtag;

  @override
  Future<void> close() => inner.close();
}
