/// RZCOBS (Reverse Zero-Compressing COBS) codec.
///
/// defmt's default wire encoding. Encoded frames contain no `0x00` bytes,
/// so `0x00` acts as the on-the-wire frame delimiter. Decoding walks the
/// frame backwards; each code byte describes the up-to-7 bytes before it:
///
/// - `0x01..=0x7f`: bitmap; bits are consumed MSB→LSB, one per byte:
///   set → literal `0x00`, clear → next byte from the (reversed) input.
/// - `0x80..=0xfe`: one zero byte followed by `(code & 0x7f) + 7` literals.
/// - `0xff`: run of 134 literal bytes.
///
/// The encoder pads a final partial group with set bits, so decoding can
/// append phantom trailing zeros. Consumers that know their payload
/// length (defmt does, from the format string) read only the prefix.
///
/// Direct port of the `rzcobs` crate (Dirbaio/rzcobs, v0.1.2).
library;

import 'dart:typed_data';

/// Decode one rzcobs frame (without the trailing `0x00` delimiter).
/// May return phantom trailing zeros (see file docs). Throws
/// [FormatException] on malformed input.
Uint8List rzcobsDecode(List<int> frame) {
  final out = <int>[];
  var i = frame.length;
  int next() {
    if (i <= 0) {
      throw const FormatException('malformed rzcobs frame');
    }
    return frame[--i];
  }

  while (i > 0) {
    final code = next();
    if (code == 0) {
      throw const FormatException('rzcobs frame contains 0x00');
    } else if (code <= 0x7f) {
      for (var bit = 0; bit < 7; bit++) {
        if (code & (1 << (6 - bit)) == 0) {
          out.add(next());
        } else {
          out.add(0);
        }
      }
    } else if (code == 0xff) {
      for (var n = 0; n < 134; n++) {
        out.add(next());
      }
    } else {
      out.add(0);
      final literals = (code & 0x7f) + 7;
      for (var n = 0; n < literals; n++) {
        out.add(next());
      }
    }
  }
  return Uint8List.fromList(out.reversed.toList());
}

/// Encode [data] as an rzcobs frame (no trailing delimiter is added;
/// callers append `0x00` to frame it on the wire).
///
/// Streaming port of the crate's `Encoder`: one byte of state.
Uint8List rzcobsEncode(List<int> data) {
  final out = <int>[];
  var run = 0;
  var zeros = 0;

  void flushPartial() {
    if (run == 0) {
      return;
    }
    if (run <= 6) {
      out.add((zeros | (0xFF << run)) & 0x7F);
    } else {
      out.add((run - 7) | 0x80);
    }
    run = 0;
    zeros = 0;
  }

  for (final byte in data) {
    if (run < 7) {
      if (byte == 0) {
        zeros |= 1 << run;
      } else {
        out.add(byte);
      }
      run++;
      if (run == 7 && zeros != 0) {
        out.add(zeros);
        run = 0;
        zeros = 0;
      }
    } else if (byte == 0) {
      out.add((run - 7) | 0x80);
      run = 0;
      zeros = 0;
    } else {
      out.add(byte);
      run++;
      if (run == 134) {
        out.add(0xFF);
        run = 0;
        zeros = 0;
      }
    }
  }
  flushPartial();
  return Uint8List.fromList(out);
}
