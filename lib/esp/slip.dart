/// SLIP framing (RFC 1055 subset) used by the ESP ROM bootloader.
///
/// Every packet on the wire is framed as `END <body> END` where the
/// body has `END` and `ESC` bytes escaped. The codec is byte-level
/// agnostic about packet contents: the 8-byte protocol header is part
/// of the escaped body, exactly like esptool-js `slipWriter` and the
/// ROM's own SLIP writer do it.
library;

import 'dart:typed_data';

/// SLIP byte constants plus stateless encode/decode helpers.
abstract final class SlipCodec {
  /// Frame delimiter. Marks both start and end of a packet.
  static const int end = 0xC0;

  /// Escape prefix for special bytes inside a frame body.
  static const int esc = 0xDB;

  /// Escaped form of [end] inside a frame body.
  static const int escEnd = 0xDC;

  /// Escaped form of [esc] inside a frame body.
  static const int escEsc = 0xDD;

  /// SLIP-encode [packet] (header + payload already assembled by the
  /// caller): wraps it in [end] markers and escapes [end]/[esc] bytes.
  static Uint8List encode(List<int> packet) {
    final out = BytesBuilder(copy: false)..addByte(end);
    for (final byte in packet) {
      if (byte == end) {
        out
          ..addByte(esc)
          ..addByte(escEnd);
      } else if (byte == esc) {
        out
          ..addByte(esc)
          ..addByte(escEsc);
      } else {
        out.addByte(byte);
      }
    }
    return (out..addByte(end)).toBytes();
  }

  /// Decode one frame [body]: the bytes between the two [end]
  /// markers, with escape sequences reverted.
  ///
  /// Throws [FormatException] on a byte following [esc] that is not
  /// [escEnd] or [escEsc].
  static Uint8List decode(List<int> body) {
    final out = BytesBuilder(copy: false);
    var escaping = false;
    for (final byte in body) {
      if (escaping) {
        switch (byte) {
          case escEnd:
            out.addByte(end);
          case escEsc:
            out.addByte(esc);
          default:
            throw FormatException(
              'Invalid SLIP escape sequence: 0xDB 0x'
              '${byte.toRadixString(16)}',
            );
        }
        escaping = false;
      } else if (byte == esc) {
        escaping = true;
      } else {
        out.addByte(byte);
      }
    }
    if (escaping) {
      throw FormatException('Truncated SLIP escape at end of frame');
    }
    return out.toBytes();
  }
}

/// Incremental SLIP parser.
///
/// Feed arbitrary chunks from the transport via [addBytes]; complete
/// decoded packets are returned as they become available. Survives
/// chunk splits anywhere, including mid-escape (`0xDB` as the last
/// byte of a chunk) and carries several packets in a single chunk.
final class SlipStream {
  final BytesBuilder _body = BytesBuilder(copy: false);
  bool _inPacket = false;

  /// True while an incomplete frame body is buffered.
  bool get hasPartialPacket => _inPacket && _body.length > 0;

  /// Feed [chunk] and return every complete decoded packet that the
  /// chunk finished. Empty frames (two adjacent [SlipCodec.end]
  /// markers) are discarded; bytes outside any frame (e.g. the ROM
  /// boot log) are silently dropped. Invalid escape sequences throw
  /// [FormatException] from [SlipCodec.decode].
  List<Uint8List> addBytes(List<int> chunk) {
    final packets = <Uint8List>[];
    for (final byte in chunk) {
      if (!_inPacket) {
        // Wait for the start-of-frame marker; drop inter-frame noise.
        if (byte == SlipCodec.end) {
          _inPacket = true;
        }
        continue;
      }
      if (byte == SlipCodec.end) {
        final body = _body.toBytes();
        _body.clear();
        if (body.isNotEmpty) {
          packets.add(SlipCodec.decode(body));
        }
        // This END doubles as the start marker of the next frame.
        _inPacket = true;
        continue;
      }
      _body.addByte(byte);
    }
    return packets;
  }

  /// Drop any partially received frame.
  void reset() {
    _body.clear();
    _inPacket = false;
  }
}
