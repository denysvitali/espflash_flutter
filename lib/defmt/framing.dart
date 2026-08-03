/// Stream framing for esp-println's defmt logger.
///
/// esp-println writes a non-UTF-8 marker `FF 00` before every defmt
/// frame; the rzcobs payload follows, terminated by `0x00` (rzcobs data
/// never contains `0x00`). Anything outside `FF 00 … 00` is ordinary
/// serial output and is passed through as raw bytes.
///
/// Direct port of espflash's `FrameDelimiter`
/// (espflash/src/cli/monitor/parser/esp_defmt.rs).
library;

import 'dart:typed_data';

/// One extracted piece of the serial stream.
sealed class FrameChunk {
  const FrameChunk();
}

/// A complete defmt frame (rzcobs-encoded, without the delimiter).
final class DefmtFrameChunk extends FrameChunk {
  const DefmtFrameChunk(this.bytes);

  final Uint8List bytes;
}

/// Raw, non-defmt serial bytes.
final class RawChunk extends FrameChunk {
  const RawChunk(this.bytes);

  final Uint8List bytes;
}

/// Incremental frame splitter. Feed serial chunks; completed frames and
/// raw runs are returned from [feed].
final class FrameDelimiter {
  final List<int> _buffer = <int>[];
  bool _inFrame = false;

  /// defmt frames are small (typically <1 KB); a "frame" larger than
  /// this means we latched onto a spurious `FF 00` — flush as raw and
  /// resync instead of buffering forever.
  static const int maxFrameBytes = 8192;

  static const List<int> _frameStart = [0xFF, 0x00];

  /// Feed [bytes]; returns all chunks that completed during this call.
  List<FrameChunk> feed(List<int> bytes) {
    _buffer.addAll(bytes);
    final out = <FrameChunk>[];

    while (true) {
      if (_inFrame && _buffer.length > maxFrameBytes) {
        out.add(RawChunk(Uint8List.fromList(_buffer)));
        _buffer.clear();
        _inFrame = false;
        continue;
      }
      final found = _search(_buffer, _inFrame);
      if (found == null) {
        break;
      }
      final (frame, consumed) = found;
      if (_inFrame) {
        out.add(DefmtFrameChunk(Uint8List.fromList(frame)));
      } else if (frame.isNotEmpty) {
        out.add(RawChunk(Uint8List.fromList(frame)));
      }
      _inFrame = !_inFrame;
      _buffer.removeRange(0, consumed);
    }

    if (!_inFrame) {
      // A trailing 0xFF may be the first half of a frame start; hold it
      // back until the next byte disambiguates.
      var consume = _buffer.length;
      if (_buffer.isNotEmpty && _buffer.last == 0xFF) {
        consume--;
      }
      if (consume > 0) {
        out.add(RawChunk(Uint8List.fromList(_buffer.sublist(0, consume))));
        _buffer.removeRange(0, consume);
      }
    }
    return out;
  }

  /// Mirrors espflash's `search`: when looking for a frame start, find
  /// `FF 00`; when inside a frame, skip leading zeros then find the next
  /// `00` terminator. Returns (bytes before the needle, bytes consumed).
  (List<int>, int)? _search(List<int> haystack, bool lookForEnd) {
    final needle = lookForEnd ? const [0x00] : _frameStart;
    var start = 0;
    if (lookForEnd) {
      start = haystack.indexWhere((b) => b != 0);
      if (start == -1) {
        return null;
      }
    }
    outer:
    for (var i = start; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          continue outer;
        }
      }
      return (haystack.sublist(start, i), i + needle.length);
    }
    return null;
  }
}
