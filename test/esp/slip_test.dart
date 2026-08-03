import 'dart:typed_data';

import 'package:espflash_flutter/esp/slip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SlipCodec.encode', () {
    test('wraps the packet in END markers', () {
      expect(
        SlipCodec.encode([0x01, 0x02, 0x03]),
        [0xC0, 0x01, 0x02, 0x03, 0xC0],
      );
    });

    test('escapes END as ESC ESC_END', () {
      expect(SlipCodec.encode([0xC0]), [0xC0, 0xDB, 0xDC, 0xC0]);
    });

    test('escapes ESC as ESC ESC_ESC', () {
      expect(SlipCodec.encode([0xDB]), [0xC0, 0xDB, 0xDD, 0xC0]);
    });

    test('escapes every special byte, including adjacent ones', () {
      expect(
        SlipCodec.encode([0xC0, 0xDB, 0xDB, 0xDC, 0xC0]),
        [
          0xC0, //
          0xDB, 0xDC, // C0
          0xDB, 0xDD, // DB
          0xDB, 0xDD, // DB
          0xDC, // plain byte, NOT escaped
          0xDB, 0xDC, // C0
          0xC0,
        ],
      );
    });

    test('empty payload produces two adjacent END markers', () {
      expect(SlipCodec.encode(const []), [0xC0, 0xC0]);
    });

    test('escapes special bytes anywhere, header positions included',
        () {
      // A real packet has the 8-byte protocol header inside the SLIP
      // body; a checksum byte of 0xC0 must be escaped like any other.
      final frame = SlipCodec.encode([0x00, 0x08, 0xC0, 0xDB]);
      expect(frame, [0xC0, 0x00, 0x08, 0xDB, 0xDC, 0xDB, 0xDD, 0xC0]);
    });
  });

  group('SlipCodec.decode', () {
    test('reverses encode for plain payloads', () {
      final payload = List<int>.generate(256, (i) => i);
      final frame = SlipCodec.encode(payload);
      expect(
        SlipCodec.decode(frame.sublist(1, frame.length - 1)),
        payload,
      );
    });

    test('reverses payloads full of special bytes', () {
      const payload = [0xC0, 0xDB, 0xDB, 0xDC, 0x00, 0xFF, 0xC0];
      final frame = SlipCodec.encode(payload);
      expect(
        SlipCodec.decode(frame.sublist(1, frame.length - 1)),
        payload,
      );
    });

    test('rejects an invalid escape sequence', () {
      expect(
        () => SlipCodec.decode([0xDB, 0x00]),
        throwsFormatException,
      );
    });

    test('rejects a truncated trailing escape', () {
      expect(() => SlipCodec.decode([0x01, 0xDB]), throwsFormatException);
    });
  });

  group('SlipStream', () {
    test('emits a packet fed in one chunk', () {
      final stream = SlipStream();
      final packets = stream.addBytes(SlipCodec.encode([1, 2, 3]));
      expect(packets, [
        [1, 2, 3],
      ]);
      expect(stream.hasPartialPacket, isFalse);
    });

    test('emits several packets carried in one chunk', () {
      final stream = SlipStream();
      final bytes = <int>[
        ...SlipCodec.encode([1]),
        ...SlipCodec.encode([2]),
        ...SlipCodec.encode([3]),
      ];
      final packets = stream.addBytes(bytes);
      expect(packets, [
        [1],
        [2],
        [3],
      ]);
    });

    test('reassembles a frame split across chunks', () {
      final stream = SlipStream();
      final frame = SlipCodec.encode([0x11, 0x22, 0x33, 0x44]);
      expect(stream.addBytes(frame.sublist(0, 3)), isEmpty);
      expect(stream.hasPartialPacket, isTrue);
      expect(stream.addBytes(frame.sublist(3)), [
        [0x11, 0x22, 0x33, 0x44],
      ]);
    });

    test('survives a split right after ESC', () {
      final stream = SlipStream();
      final frame = SlipCodec.encode([0xC0]); // C0 DB DC C0
      expect(frame, [0xC0, 0xDB, 0xDC, 0xC0]);
      expect(stream.addBytes(frame.sublist(0, 2)), isEmpty); // C0 DB
      expect(stream.addBytes(frame.sublist(2)), [
        [0xC0],
      ]);
    });

    test('survives a split inside a two-byte escape', () {
      final stream = SlipStream();
      final frame = SlipCodec.encode([0xDB]); // C0 DB DD C0
      expect(stream.addBytes([frame[0], frame[1]]), isEmpty);
      expect(stream.addBytes([frame[2]]), isEmpty);
      expect(stream.addBytes([frame[3]]), [
        [0xDB],
      ]);
    });

    test('drops inter-frame garbage like the ROM boot log', () {
      final stream = SlipStream();
      final noise = 'boot:0x01 (download)\r\n'.codeUnits;
      final packets = stream.addBytes([
        ...noise,
        ...SlipCodec.encode([9]),
      ]);
      expect(packets, [
        [9],
      ]);
    });

    test('discards empty frames', () {
      final stream = SlipStream();
      expect(stream.addBytes([0xC0, 0xC0, 0xC0]), isEmpty);
      expect(stream.hasPartialPacket, isFalse);
    });

    test('roundtrips a big binary payload byte-for-byte', () {
      final payload = List<int>.generate(4096, (i) => (i * 7) & 0xFF);
      final stream = SlipStream();
      // Feed it in awkward 13-byte chunks.
      final frame = SlipCodec.encode(payload);
      final received = <Uint8List>[];
      for (var i = 0; i < frame.length; i += 13) {
        received.addAll(
          stream.addBytes(
            frame.sublist(i, (i + 13).clamp(0, frame.length)),
          ),
        );
      }
      expect(received, hasLength(1));
      expect(received.single, payload);
    });

    test('throws on an invalid escape mid-stream', () {
      final stream = SlipStream();
      expect(
        () => stream.addBytes([0xC0, 0xDB, 0x00, 0xC0]),
        throwsFormatException,
      );
    });

    test('reset() discards a partial frame', () {
      final stream = SlipStream();
      stream.addBytes([0xC0, 0x01, 0x02]);
      stream.reset();
      expect(stream.hasPartialPacket, isFalse);
      expect(stream.addBytes(SlipCodec.encode([7])), [
        [7],
      ]);
    });
  });
}
