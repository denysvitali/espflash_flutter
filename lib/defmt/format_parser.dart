/// Parser for defmt format strings, following the grammar of the
/// `defmt-parser` crate:
///
/// ```text
/// param := '{' [ argument ] [ '=' argtype ] [ ':' format_spec ] '}'
/// argument := integer
/// format_spec := [ zero_pad ] type
/// ```
///
/// Literals escape braces as `{{` and `}}`. Unknown display hints are
/// kept as [DisplayHintUnknown] (forwards-compatible) instead of failing.
library;

/// Argument type of a `{=...}` parameter.
sealed class ParamType {
  const ParamType();
}

final class TypeBool extends ParamType {
  const TypeBool();
}

final class TypeChar extends ParamType {
  const TypeChar();
}

/// Unsigned integer of [bits] width (8..128, or 0 for `usize`).
final class TypeUint extends ParamType {
  const TypeUint(this.bits);

  final int bits;
}

/// Signed integer of [bits] width (8..128, or 0 for `isize`).
final class TypeInt extends ParamType {
  const TypeInt(this.bits);

  final int bits;
}

final class TypeF32 extends ParamType {
  const TypeF32();
}

final class TypeF64 extends ParamType {
  const TypeF64();
}

/// Length-prefixed UTF-8 string (`{=str}`).
final class TypeStr extends ParamType {
  const TypeStr();
}

/// Interned string reference (`{=istr}`), u16 table index.
final class TypeIStr extends ParamType {
  const TypeIStr();
}

/// Nested `defmt::Format` value (`{}` / `{=?}`).
final class TypeFormat extends ParamType {
  const TypeFormat();
}

/// Slice of `Format` values (`{=[?]}`).
final class TypeFormatSlice extends ParamType {
  const TypeFormatSlice();
}

/// Byte slice (`{=[u8]}`).
final class TypeU8Slice extends ParamType {
  const TypeU8Slice();
}

/// Fixed-length byte array (`{=[u8; N]}`).
final class TypeU8Array extends ParamType {
  const TypeU8Array(this.length);

  final int length;
}

/// Fixed-length array of `Format` values (`{=[?; N]}`).
final class TypeFormatArray extends ParamType {
  const TypeFormatArray(this.length);

  final int length;
}

/// Bitfield (`{=0..8}`), half-open bit range into the enclosing integer.
final class TypeBitField extends ParamType {
  const TypeBitField(this.start, this.end);

  final int start;
  final int end;
}

/// UTF-8 stream terminated by 0xFF (internal: `Display2Format` / `Debug2Format`).
final class TypeDisplay extends ParamType {
  const TypeDisplay();
}

final class TypeDebug extends ParamType {
  const TypeDebug();
}

/// Display hints after the `:`.
sealed class DisplayHint {
  const DisplayHint();
}

final class HintHex extends DisplayHint {
  const HintHex({required this.uppercase});

  final bool uppercase;
}

final class HintBinary extends DisplayHint {
  const HintBinary();
}

final class HintOctal extends DisplayHint {
  const HintOctal();
}

/// `:a` — byte string, rendered `b"..."` with escapes.
final class HintAscii extends DisplayHint {
  const HintAscii();
}

/// `:us` / `:ms` — value is a duration in micro/milliseconds.
final class HintSeconds extends DisplayHint {
  const HintSeconds({required this.precisionDigits});

  /// 6 for `:us`, 3 for `:ms`.
  final int precisionDigits;
}

/// `:time` — value is microseconds, rendered `HH:MM:SS.ffffff`.
final class HintTime extends DisplayHint {
  const HintTime();
}

/// Unknown hint, kept for forwards compatibility.
final class DisplayHintUnknown extends DisplayHint {
  const DisplayHintUnknown(this.raw);

  final String raw;
}

/// One fragment of a parsed format string.
sealed class Fragment {
  const Fragment();
}

final class LiteralFragment extends Fragment {
  const LiteralFragment(this.text);

  final String text;
}

final class ParamFragment extends Fragment {
  const ParamFragment({
    required this.index,
    required this.type,
    this.hint,
    this.zeroPad = 0,
  });

  final int index;
  final ParamType type;
  final DisplayHint? hint;
  final int zeroPad;
}

/// Parse a defmt format string into fragments.
///
/// Throws [FormatException] on malformed input. Indices are validated to
/// be dense (0..n-1 with no gaps), matching defmt-parser.
List<Fragment> parseFormat(String format) {
  final fragments = <Fragment>[];
  final literal = StringBuffer();
  var i = 0;
  var nextAutoIndex = 0;
  final seenIndices = <int>{};

  void flushLiteral() {
    if (literal.isNotEmpty) {
      fragments.add(LiteralFragment(literal.toString()));
      literal.clear();
    }
  }

  while (i < format.length) {
    final char = format[i];
    if (char == '{') {
      if (i + 1 < format.length && format[i + 1] == '{') {
        literal.write('{');
        i += 2;
        continue;
      }
      flushLiteral();
      final close = format.indexOf('}', i);
      if (close == -1) {
        throw FormatException('unmatched open bracket in "$format"');
      }
      final param = _parseParam(format.substring(i + 1, close), nextAutoIndex);
      nextAutoIndex = param.index + 1;
      if (!seenIndices.add(param.index)) {
        // Re-using an index is allowed by defmt only with an identical
        // type; the decoder re-reads the value once per index, so keep
        // the first occurrence's type.
      }
      fragments.add(param);
      i = close + 1;
    } else if (char == '}') {
      if (i + 1 < format.length && format[i + 1] == '}') {
        literal.write('}');
        i += 2;
      } else {
        throw FormatException('unmatched close bracket in "$format"');
      }
    } else {
      literal.write(char);
      i++;
    }
  }
  flushLiteral();

  // Indices must be dense: 0..max with no gaps.
  if (seenIndices.isNotEmpty) {
    final max = seenIndices.reduce((a, b) => a > b ? a : b);
    for (var n = 0; n <= max; n++) {
      if (!seenIndices.contains(n)) {
        throw FormatException('unused argument index $n in "$format"');
      }
    }
  }
  return fragments;
}

ParamFragment _parseParam(String body, int autoIndex) {
  var rest = body.trim();
  var index = autoIndex;

  // Optional explicit argument index.
  final indexMatch = RegExp(r'^\d+').firstMatch(rest);
  if (indexMatch != null) {
    index = int.parse(indexMatch.group(0)!);
    rest = rest.substring(indexMatch.end);
  }

  ParamType type = const TypeFormat();
  DisplayHint? hint;
  var zeroPad = 0;

  // Split type part and display-hint part at the first ':' — but a ':'
  // inside a bitfield range or array length is impossible, so a plain
  // split is safe.
  final colon = rest.indexOf(':');
  var typePart = rest;
  String? hintPart;
  if (colon != -1) {
    typePart = rest.substring(0, colon);
    hintPart = rest.substring(colon + 1);
    if (hintPart.isEmpty) {
      throw const FormatException('malformed format string: empty hint');
    }
  }

  if (typePart.startsWith('=')) {
    type = _parseType(typePart.substring(1).trim());
  } else if (typePart.trim().isNotEmpty) {
    throw FormatException('unexpected content in "{$body}"');
  }

  if (hintPart != null) {
    final zeroMatch = RegExp(r'^0(\d+)').firstMatch(hintPart);
    if (zeroMatch != null) {
      zeroPad = int.parse(zeroMatch.group(1)!);
      hintPart = hintPart.substring(zeroMatch.end);
    }
    hint = _parseHint(hintPart);
  }

  return ParamFragment(index: index, type: type, hint: hint, zeroPad: zeroPad);
}

ParamType _parseType(String spec) {
  const uints = <String, int>{
    'u8': 8, 'u16': 16, 'u32': 32, 'u64': 64, 'u128': 128, 'usize': 0,
  };
  const ints = <String, int>{
    'i8': 8, 'i16': 16, 'i32': 32, 'i64': 64, 'i128': 128, 'isize': 0,
  };
  final uintBits = uints[spec];
  if (uintBits != null) {
    return TypeUint(uintBits);
  }
  final intBits = ints[spec];
  if (intBits != null) {
    return TypeInt(intBits);
  }
  switch (spec) {
    case 'bool':
      return const TypeBool();
    case 'char':
      return const TypeChar();
    case 'f32':
      return const TypeF32();
    case 'f64':
      return const TypeF64();
    case 'str':
      return const TypeStr();
    case 'istr':
      return const TypeIStr();
    case '?':
      return const TypeFormat();
    case '[?]':
      return const TypeFormatSlice();
    case '[u8]':
      return const TypeU8Slice();
    case 'display':
      return const TypeDisplay();
    case 'debug':
      return const TypeDebug();
  }
  // Arrays: `[u8; N]` / `[?; N]` (spaces before the length allowed).
  final arrayMatch = RegExp(r'^\[(u8|\?);\s*(\d+)\]$').firstMatch(spec);
  if (arrayMatch != null) {
    final length = int.parse(arrayMatch.group(2)!);
    return arrayMatch.group(1) == 'u8'
        ? TypeU8Array(length)
        : TypeFormatArray(length);
  }
  // Bitfield: `start..end`, half-open, within 0..128.
  final bitfieldMatch = RegExp(r'^(\d+)\.\.(\d+)$').firstMatch(spec);
  if (bitfieldMatch != null) {
    final start = int.parse(bitfieldMatch.group(1)!);
    final end = int.parse(bitfieldMatch.group(2)!);
    if (end <= start || start >= 128 || end > 128) {
      throw FormatException('invalid bitfield range $start..$end');
    }
    return TypeBitField(start, end);
  }
  throw FormatException('invalid type specifier "$spec"');
}

DisplayHint _parseHint(String hint) => switch (hint) {
  'x' => const HintHex(uppercase: false),
  'X' => const HintHex(uppercase: true),
  'b' => const HintBinary(),
  'o' => const HintOctal(),
  'a' => const HintAscii(),
  'us' => const HintSeconds(precisionDigits: 6),
  'ms' => const HintSeconds(precisionDigits: 3),
  'time' => const HintTime(),
  _ => DisplayHintUnknown(hint),
};
