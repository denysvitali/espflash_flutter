/// defmt frame decoder: turns one deframed, rzcobs-decoded byte buffer
/// into a rendered log line, using the interned-string table from the ELF.
///
/// Wire order per frame (defmt wire format v4):
/// `[u16 LE index] [timestamp args…] [message args…]`.
///
/// Integers are little-endian; lengths are u32 LE; format/istr indices
/// are u16 LE. u64/u128 values are carried as [BigInt].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'format_parser.dart';
import 'table.dart';

/// Thrown when a byte stream cannot be decoded against the table.
final class DefmtDecodeException implements Exception {
  const DefmtDecodeException(this.message);

  final String message;

  @override
  String toString() => 'defmt decode error: $message';
}

/// A decoded, rendered log frame.
final class DecodedFrame {
  const DecodedFrame({
    required this.index,
    required this.level,
    required this.timestamp,
    required this.text,
  });

  final int index;
  final DefmtLevel? level;

  /// Rendered timestamp, null when the firmware has no `defmt::timestamp`.
  final String? timestamp;

  /// Rendered message.
  final String text;
}

// ---------------------------------------------------------------------------
// Decoded argument tree
// ---------------------------------------------------------------------------

sealed class Arg {
  const Arg();
}

final class BoolArg extends Arg {
  const BoolArg(this.value);

  final bool value;
}

/// Integer argument. [value] is already sign-extended for signed types;
/// [bits] is the declared width (0 = usize/isize, treated as 32).
final class IntArg extends Arg {
  const IntArg(this.value, {required this.bits, required this.signed});

  final BigInt value;
  final int bits;
  final bool signed;
}

/// Raw bitfield read; [rangeStart]/[rangeEnd] is the covering range that
/// was read from the stream. Individual `{=a..b}` params isolate their
/// sub-range at render time.
final class BitFieldArg extends Arg {
  const BitFieldArg(this.raw, this.rangeStart, this.rangeEnd);

  final BigInt raw;
  final int rangeStart;
  final int rangeEnd;
}

final class FloatArg extends Arg {
  const FloatArg(this.value);

  final double value;
}

final class StrArg extends Arg {
  const StrArg(this.value);

  final String value;
}

final class CharArg extends Arg {
  const CharArg(this.value);

  final String value;
}

final class BytesArg extends Arg {
  const BytesArg(this.value);

  final Uint8List value;
}

/// Nested `Format` value: its own format string + decoded args.
final class FormatArg extends Arg {
  const FormatArg(this.format, this.args);

  final String format;
  final List<Arg> args;
}

/// `{=[?]}` / `{=[?; N]}`: every element shares one format string.
final class FormatSliceArg extends Arg {
  const FormatSliceArg(this.elements);

  final List<FormatArg> elements;
}

/// Zero-terminated sequence of nested formats.
final class FormatSeqArg extends Arg {
  const FormatSeqArg(this.elements);

  final List<FormatArg> elements;
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

final class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int _pos = 0;

  int get remaining => bytes.length - _pos;

  int u8() {
    if (_pos >= bytes.length) {
      throw const DefmtDecodeException('unexpected end of frame');
    }
    return bytes[_pos++];
  }

  Uint8List take(int count) {
    if (count < 0 || remaining < count) {
      throw const DefmtDecodeException('unexpected end of frame');
    }
    final out = Uint8List.sublistView(bytes, _pos, _pos + count);
    _pos += count;
    return out;
  }

  int u16() => _le(take(2));
  int u32() => _le(take(4));

  BigInt uint(int byteCount) {
    final raw = take(byteCount);
    var value = BigInt.zero;
    for (var i = raw.length - 1; i >= 0; i--) {
      value = (value << 8) | BigInt.from(raw[i]);
    }
    return value;
  }

  BigInt sint(int byteCount) {
    final unsigned = uint(byteCount);
    final bits = byteCount * 8;
    if (unsigned >= (BigInt.one << (bits - 1))) {
      return unsigned - (BigInt.one << bits);
    }
    return unsigned;
  }

  static int _le(Uint8List raw) {
    var value = 0;
    for (var i = raw.length - 1; i >= 0; i--) {
      value = (value << 8) | raw[i];
    }
    return value;
  }
}

/// Decodes whole frames against a [DefmtTable].
final class DefmtFrameDecoder {
  DefmtFrameDecoder(this.table);

  final DefmtTable table;

  /// Cache: format string → parsed fragments.
  final Map<String, List<Fragment>> _parseCache = {};

  List<Fragment> _fragments(String format) =>
      _parseCache.putIfAbsent(format, () => parseFormat(format));

/// Decode one frame. [bytes] must start at the u16 frame index.
  DecodedFrame decode(Uint8List bytes) {
    final reader = _Reader(bytes);
    final index = reader.u16();

    String? timestamp;
    final tsEntry = table.timestamp;
    if (tsEntry != null) {
      final ts = _decodeFormat(tsEntry.format, reader);
      timestamp = renderFormat(ts.format, ts.args);
    }

    final entry = table.lookup(index);
    if (entry == null) {
      throw DefmtDecodeException('unknown defmt index $index');
    }
    final message = _decodeFormat(entry.format, reader);
    return DecodedFrame(
      index: index,
      level: entry.level,
      timestamp: timestamp,
      text: renderFormat(message.format, message.args),
    );
  }

  /// Decode the arguments of [format] from [reader]. Handles `|`-separated
  /// enum variants (discriminant first, smallest fitting width); the
  /// returned [_DecodedFormat.format] is the selected variant.
  _DecodedFormat _decodeFormat(String format, _Reader reader) {
    var effective = format;
    if (effective.contains('|')) {
      final variants = effective.split('|');
      final discriminant = _readDiscriminant(reader, variants.length);
      if (discriminant >= variants.length) {
        throw DefmtDecodeException(
          'enum discriminant $discriminant out of range '
          '(${variants.length} variants)',
        );
      }
      effective = variants[discriminant];
    }

    final fragments = _fragments(effective);
    final params = fragments.whereType<ParamFragment>().toList();

    // One read per argument index; same-index bitfields merge into a
    // single covering-range read.
    final byIndex = <int, List<ParamFragment>>{};
    for (final param in params) {
      byIndex.putIfAbsent(param.index, () => []).add(param);
    }
    final args = <int, Arg>{};
    final sortedIndices = byIndex.keys.toList()..sort();
    for (final index in sortedIndices) {
      final group = byIndex[index]!;
      final first = group.first;
      if (group.every((p) => p.type is TypeBitField)) {
        var start = 128, end = 0;
        for (final p in group) {
          final t = p.type as TypeBitField;
          if (t.start < start) start = t.start;
          if (t.end > end) end = t.end;
        }
        args[index] = _readBitField(reader, start, end);
      } else {
        args[index] = _readArg(reader, first.type);
      }
    }
    final maxIndex = sortedIndices.isEmpty ? -1 : sortedIndices.last;
    return _DecodedFormat(effective, [
      for (var i = 0; i <= maxIndex; i++)
        args[i] ?? (throw const DefmtDecodeException('missing argument')),
    ]);
  }

  int _readDiscriminant(_Reader reader, int variantCount) {
    if (variantCount <= 0x100) return reader.u8();
    if (variantCount <= 0x10000) return reader.u16();
    return reader.u32();
  }

  Arg _readBitField(_Reader reader, int start, int end) {
    final lowestByte = start ~/ 8;
    final highestByte = (end - 1) ~/ 8;
    final byteCount = highestByte - lowestByte + 1;
    var raw = reader.uint(byteCount);
    raw = raw << (lowestByte * 8);
    return BitFieldArg(raw, start, end);
  }

  Arg _readArg(_Reader reader, ParamType type) {
    switch (type) {
      case TypeBool():
        final v = reader.u8();
        if (v > 1) {
          throw const DefmtDecodeException('malformed bool');
        }
        return BoolArg(v == 1);
      case TypeUint(:final bits):
        final bytes = bits == 0 ? 4 : bits ~/ 8;
        return IntArg(reader.uint(bytes), bits: bits, signed: false);
      case TypeInt(:final bits):
        final bytes = bits == 0 ? 4 : bits ~/ 8;
        return IntArg(reader.sint(bytes), bits: bits, signed: true);
      case TypeF32():
        final raw = reader.take(4);
        return FloatArg(
          ByteData.sublistView(raw).getFloat32(0, Endian.little),
        );
      case TypeF64():
        final raw = reader.take(8);
        return FloatArg(
          ByteData.sublistView(raw).getFloat64(0, Endian.little),
        );
      case TypeChar():
        final code = reader.u32();
        if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
          throw const DefmtDecodeException('invalid char');
        }
        return CharArg(String.fromCharCode(code));
      case TypeStr():
        final length = reader.u32();
        return StrArg(utf8.decode(reader.take(length), allowMalformed: true));
      case TypeIStr():
        final index = reader.u16();
        final entry = table.lookup(index);
        if (entry == null) {
          throw DefmtDecodeException('unknown istr index $index');
        }
        return StrArg(entry.format);
      case TypeU8Slice():
        final length = reader.u32();
        return BytesArg(reader.take(length));
      case TypeU8Array(:final length):
        return BytesArg(reader.take(length));
      case TypeDisplay():
      case TypeDebug():
        // Unprefixed UTF-8 stream terminated by 0xFF.
        final out = <int>[];
        while (true) {
          final b = reader.u8();
          if (b == 0xFF) break;
          out.add(b);
        }
        return StrArg(utf8.decode(out, allowMalformed: true));
      case TypeFormat():
        return _readNestedFormat(reader);
      case TypeFormatSlice():
        final count = reader.u32();
        return _readFormatSlice(reader, count);
      case TypeFormatArray(:final length):
        return _readFormatSlice(reader, length);
      case TypeBitField():
        // Bitfields are merged per index before _readArg is called.
        throw StateError('unmerged bitfield');
    }
  }

  FormatArg _readNestedFormat(_Reader reader) {
    final index = reader.u16();
    final entry = table.lookup(index);
    if (entry == null) {
      throw DefmtDecodeException('unknown format index $index');
    }
    final decoded = _decodeFormat(entry.format, reader);
    return FormatArg(decoded.format, decoded.args);
  }

  FormatSliceArg _readFormatSlice(_Reader reader, int count) {
    final index = reader.u16();
    final entry = table.lookup(index);
    if (entry == null) {
      throw DefmtDecodeException('unknown format index $index');
    }
    final isEnum = entry.format.contains('|');
    final variants = isEnum ? entry.format.split('|') : null;
    final elements = <FormatArg>[];
    for (var i = 0; i < count; i++) {
      var format = entry.format;
      if (variants != null) {
        final d = _readDiscriminant(reader, variants.length);
        if (d >= variants.length) {
          throw DefmtDecodeException('enum discriminant $d out of range');
        }
        format = variants[d];
      }
      final decoded = _decodeFormat(format, reader);
      elements.add(FormatArg(decoded.format, decoded.args));
    }
    return FormatSliceArg(elements);
  }
}

/// A format string plus its decoded arguments (enum variant resolved).
final class _DecodedFormat {
  const _DecodedFormat(this.format, this.args);

  final String format;
  final List<Arg> args;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Render [format] with decoded [args] (index-aligned) to a string.
String renderFormat(String format, List<Arg> args) {
  final out = StringBuffer();
  List<Fragment> fragments;
  try {
    fragments = parseFormat(format);
  } on FormatException {
    return '<bad format: $format>';
  }
  for (final fragment in fragments) {
    switch (fragment) {
      case LiteralFragment(:final text):
        out.write(text);
      case ParamFragment(:final index, :final hint, :final zeroPad):
        if (index >= args.length) {
          out.write('<missing arg $index>');
        } else {
          out.write(_renderArg(args[index], fragment, hint, zeroPad));
        }
    }
  }
  return out.toString();
}

String _renderArg(
  Arg arg,
  ParamFragment param,
  DisplayHint? hint,
  int zeroPad,
) {
  switch (arg) {
    case BoolArg(:final value):
      return '$value';
    case CharArg(:final value):
      return value;
    case FloatArg(:final value):
      return '$value';
    case StrArg(:final value):
      return value;
    case IntArg():
      return _renderInt(arg, hint, zeroPad);
    case BitFieldArg():
      final type = param.type;
      if (type is! TypeBitField) {
        return arg.raw.toString();
      }
      final width = type.end - type.start;
      final mask = (BigInt.one << width) - BigInt.one;
      final value = (arg.raw >> type.start) & mask;
      return _renderInt(
        IntArg(value, bits: width, signed: false),
        hint,
        zeroPad,
      );
    case BytesArg(:final value):
      return _renderBytes(value, hint);
    case FormatArg(:final format, :final args):
      return renderFormat(format, args);
    case FormatSliceArg(:final elements):
      final rendered = elements.map((e) => renderFormat(e.format, e.args));
      return '[${rendered.join(', ')}]';
    case FormatSeqArg(:final elements):
      return elements.map((e) => renderFormat(e.format, e.args)).join();
  }
}

String _renderInt(IntArg arg, DisplayHint? hint, int zeroPad) {
  var value = arg.value;
  if (hint is HintHex || hint is HintBinary || hint is HintOctal) {
    if (arg.signed && value.isNegative) {
      final bits = arg.bits == 0 ? 32 : arg.bits;
      value = value + (BigInt.one << bits);
    }
    final radix = hint is HintHex
        ? 16
        : hint is HintBinary
        ? 2
        : 8;
    var text = value.toRadixString(radix);
    if (hint is HintHex && hint.uppercase) {
      text = text.toUpperCase();
    }
    return text.padLeft(zeroPad, '0');
  }
  if (hint is HintSeconds) {
    final scale = BigInt.from(10).pow(hint.precisionDigits);
    final seconds = value ~/ scale;
    final fraction = (value % scale)
        .toString()
        .padLeft(hint.precisionDigits, '0');
    return '$seconds.$fraction';
  }
  if (hint is HintTime) {
    // Value is microseconds → [d days ]HH:MM:SS.ffffff
    var micros = value.toInt();
    final days = micros ~/ (24 * 3600 * 1000000);
    micros %= 24 * 3600 * 1000000;
    final hours = micros ~/ (3600 * 1000000);
    micros %= 3600 * 1000000;
    final minutes = micros ~/ (60 * 1000000);
    micros %= 60 * 1000000;
    final seconds = micros ~/ 1000000;
    final frac = (micros % 1000000).toString().padLeft(6, '0');
    final hh = hours.toString().padLeft(2, '0');
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return '${days > 0 ? '${days}d ' : ''}$hh:$mm:$ss.$frac';
  }
  return value.toString();
}

String _renderBytes(Uint8List bytes, DisplayHint? hint) {
  if (hint is HintAscii) {
    final out = StringBuffer('b"');
    for (final b in bytes) {
      switch (b) {
        case 0x09:
          out.write(r'\t');
        case 0x0a:
          out.write(r'\n');
        case 0x0d:
          out.write(r'\r');
        case 0x22:
          out.write(r'\"');
        case 0x5c:
          out.write(r'\\');
        default:
          if (b >= 0x20 && b < 0x7f) {
            out.writeCharCode(b);
          } else {
            out.write('\\x${b.toRadixString(16).padLeft(2, '0')}');
          }
      }
    }
    out.write('"');
    return out.toString();
  }
  if (hint is HintHex) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(', ');
    return '[$hex]';
  }
  return '[${bytes.join(', ')}]';
}
