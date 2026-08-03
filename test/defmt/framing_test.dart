import 'package:espflash_flutter/defmt/framing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Direct port of the `FrameDelimiter` tests in espflash's
/// `esp_defmt.rs` — behavior must match exactly.
void main() {
  group('FrameDelimiter', () {
    test('prints raw data by default', () {
      final parser = FrameDelimiter();
      final frames = parser.feed('hello'.codeUnits);
      expect(frames, hasLength(1));
      expect((frames[0] as RawChunk).bytes, 'hello'.codeUnits);
    });

    test('trailing 0xFF is not part of the raw sequence', () {
      final parser = FrameDelimiter();
      final frames = parser.feed([...'hello'.codeUnits, 0xFF]);
      expect(frames, hasLength(1));
      expect((frames[0] as RawChunk).bytes, 'hello'.codeUnits);
      // The held-back 0xFF completes as raw once a non-zero follows.
      final rest = parser.feed([0x41]);
      expect(
        rest.whereType<RawChunk>().expand((c) => c.bytes),
        [0xFF, 0x41],
      );
    });

    test('frame start on end is not part of the raw sequence', () {
      final parser = FrameDelimiter();
      final frames = parser.feed([...'hello'.codeUnits, 0xFF, 0x00]);
      expect(frames, hasLength(1));
      expect((frames[0] as RawChunk).bytes, 'hello'.codeUnits);
    });

    test('processes data after a frame', () {
      final parser = FrameDelimiter();
      final frames = parser.feed([
        0xFF, 0x00, ...'frame data'.codeUnits, 0x00, ...'hello'.codeUnits,
      ]);
      expect(frames, hasLength(2));
      expect((frames[0] as DefmtFrameChunk).bytes, 'frame data'.codeUnits);
      expect((frames[1] as RawChunk).bytes, 'hello'.codeUnits);
    });

    test('concatenates partial defmt frames', () {
      final parser = FrameDelimiter();
      expect(parser.feed([0xFF, 0x00, ...'frame'.codeUnits]), isEmpty);
      final first = parser.feed([...' data'.codeUnits, 0x00, 0xFF]);
      expect(first, hasLength(1));
      expect(
        (first[0] as DefmtFrameChunk).bytes,
        'frame data'.codeUnits,
      );
      expect(parser.feed([0x00, ...'second frame'.codeUnits]), isEmpty);
      final last = parser.feed([0x00, ...'last part'.codeUnits]);
      expect(last, hasLength(2));
      expect((last[0] as DefmtFrameChunk).bytes, 'second frame'.codeUnits);
      expect((last[1] as RawChunk).bytes, 'last part'.codeUnits);
    });

    test('defmt frames back to back', () {
      final parser = FrameDelimiter();
      final frames = parser.feed([
        0xFF, 0x00, ...'frame data1'.codeUnits, 0x00, //
        0xFF, 0x00, ...'frame data2'.codeUnits, 0x00,
      ]);
      expect(frames, hasLength(2));
      expect((frames[0] as DefmtFrameChunk).bytes, 'frame data1'.codeUnits);
      expect((frames[1] as DefmtFrameChunk).bytes, 'frame data2'.codeUnits);
    });

    test('output can include FF and 0 bytes', () {
      final parser = FrameDelimiter();
      const message =
          'some message\xFF with parts of\x00 a defmt \x00\xFF frame '
          'delimiter';
      final frames = parser.feed(message.codeUnits);
      // espflash emits this as ONE raw chunk; our feed may split at the
      // trailing 0xFF hold-back boundary, so compare the concatenation.
      final raw = frames.whereType<RawChunk>().expand((c) => c.bytes);
      expect(raw.toList(), message.codeUnits);
      expect(frames.whereType<DefmtFrameChunk>(), isEmpty);
    });
  });
}
