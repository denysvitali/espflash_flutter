/// ESP ROM bootloader wire protocol: request/response framing and
/// opcode constants.
///
/// Request packet (little-endian header `<BBHI>`):
///
/// ```text
/// u8 direction  = 0x00
/// u8 opcode
/// u16 payload size
/// u32 checksum (XOR of payload bytes, seeded 0xEF; 0 for most cmds)
/// ```
///
/// Response packet: same header layout, but direction = 0x01 and the
/// u32 header field is the response *value* (register contents for
/// READ_REG, non-zero handshake value for SYNC). ROM responses end
/// their payload with 4 status bytes `[status, error, rsvd, rsvd]`;
/// `status != 0` means failure and `error` carries the ROM error
/// code. Mirrors esptool `struct.pack('<BBHI', ...)` / esptool-js
/// `command()`.
library;

import 'dart:typed_data';

import 'errors.dart';
import 'slip.dart';

/// ROM bootloader command opcodes.
abstract final class EspCommand {
  static const int flashBegin = 0x02;
  static const int flashData = 0x03;
  static const int flashEnd = 0x04;
  static const int memBegin = 0x05;
  static const int memEnd = 0x06;
  static const int memData = 0x07;
  static const int sync = 0x08;
  static const int writeReg = 0x09;
  static const int readReg = 0x0A;
  static const int spiSetParams = 0x0B;
  static const int spiAttach = 0x0D;
  static const int changeBaud = 0x0F;
  static const int flashDeflBegin = 0x10;
  static const int flashDeflData = 0x11;
  static const int flashDeflEnd = 0x12;
  static const int spiFlashMd5 = 0x13;
  static const int getSecurityInfo = 0x14;
}

/// Seed value for the ESP ROM payload checksum.
const int espChecksumSeed = 0xEF;

/// XOR checksum of [data] seeded with [seed] (default 0xEF), as the
/// ROM verifies it for FLASH_DATA/MEM_DATA payloads.
int espChecksum(List<int> data, [int seed = espChecksumSeed]) {
  var checksum = seed;
  for (final byte in data) {
    checksum ^= byte & 0xFF;
  }
  return checksum & 0xFF;
}

/// Encode [value] as 4 little-endian bytes.
Uint8List u32le(int value) {
  return Uint8List.fromList([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);
}

/// Encode [value] as 2 little-endian bytes.
Uint8List u16le(int value) {
  return Uint8List.fromList([value & 0xFF, (value >> 8) & 0xFF]);
}

/// Decode a little-endian u32 from [bytes] at [offset].
int readU32le(List<int> bytes, [int offset = 0]) {
  return (bytes[offset] & 0xFF) |
      ((bytes[offset + 1] & 0xFF) << 8) |
      ((bytes[offset + 2] & 0xFF) << 16) |
      ((bytes[offset + 3] & 0xFF) << 24);
}

/// Decode a little-endian u16 from [bytes] at [offset].
int readU16le(List<int> bytes, [int offset = 0]) {
  return (bytes[offset] & 0xFF) | ((bytes[offset + 1] & 0xFF) << 8);
}

/// Text for ROM (and stub) error codes.
///
/// The ROM reports two trailing status bytes; esptool combines them
/// big-endian into one word (`0x100 | code`). Both the combined word
/// (e.g. `0x107`) and the bare low byte (e.g. `0x07`) are accepted.
String romErrorText(int code) {
  const texts = <int, String>{
    0x00: 'Success',
    0x01: 'Invalid parameter',
    0x05: 'Invalid message',
    0x07: 'Checksum error',
    0x08: 'Flash write error',
    0x09: 'Flash read error',
    0x0A: 'Flash read length error',
    0x0B: 'Deflate failed',
    0x0C: 'Deflate Adler32 error',
    0x0D: 'Deflate parameter error',
    0x0E: 'Invalid RAM binary size',
    0x0F: 'Invalid RAM binary address',
    0x64: 'Invalid parameter (stub)',
    0x65: 'Invalid format (stub)',
    0x66: 'Description too long (stub)',
    0x67: 'Bad encoding description (stub)',
    0x69: 'Insufficient storage (stub)',
  };
  final bare = code & 0xFF;
  return texts[bare] ?? 'Unknown ROM error (code $code)';
}

/// Status bytes reported by the ROM for a failed command.
///
/// [status] is the first of the trailing status bytes (non-zero on
/// failure); [code] is the ROM error reason byte that follows it.
final class RomError {
  const RomError(this.status, this.code);

  final int status;
  final int code;

  /// esptool-style combined error word, e.g. `0x107` for a checksum
  /// failure (`status` 0x01, `code` 0x07).
  int get combined => ((status & 0xFF) << 8) | (code & 0xFF);

  String get message => romErrorText(code);

  @override
  String toString() =>
      'RomError(status: $status, code: $code, message: $message)';
}

/// A request heading for the ROM bootloader.
final class EspRequest {
  EspRequest(this.opcode, [List<int> data = const [], this.checksum = 0])
      : data = Uint8List.fromList(data);

  /// Direction byte for host-to-chip packets.
  static const int direction = 0x00;

  static const int headerSize = 8;

  final int opcode;
  final Uint8List data;
  final int checksum;

  /// The unframed packet: 8-byte little-endian header + payload.
  /// SLIP escaping is applied later, by [toFrame], to this whole
  /// packet (header included), matching esptool / esptool-js.
  Uint8List toPacket() {
    return (BytesBuilder(copy: false)
          ..addByte(direction)
          ..addByte(opcode & 0xFF)
          ..add(u16le(data.length))
          ..add(u32le(checksum))
          ..add(data))
        .toBytes();
  }

  /// The packet wrapped in a SLIP frame, ready for the wire.
  Uint8List toFrame() => SlipCodec.encode(toPacket());
}

/// A parsed response packet from the ROM bootloader.
final class EspResponse {
  EspResponse({
    required this.opcode,
    required this.value,
    required this.data,
  });

  /// Direction byte for chip-to-host packets.
  static const int direction = 0x01;

  /// Number of trailing status bytes the ROM appends to the payload
  /// (`[status, error, rsvd, rsvd]`).
  static const int romStatusSize = 4;

  final int opcode;

  /// The u32 header value (register contents for READ_REG, non-zero
  /// handshake value for SYNC; a stub answers SYNC with 0).
  final int value;

  /// Payload after the 8-byte header.
  final Uint8List data;

  /// Parse a decoded SLIP packet. Returns null when [packet] is too
  /// short for a header or is not a response (`direction != 0x01`).
  static EspResponse? tryParse(List<int> packet) {
    if (packet.length < EspRequest.headerSize) {
      return null;
    }
    if (packet[0] != direction) {
      return null;
    }
    return EspResponse(
      opcode: packet[1] & 0xFF,
      value: readU32le(packet, 4),
      data: Uint8List.fromList(packet.sublist(EspRequest.headerSize)),
    );
  }

  /// The trailing ROM status bytes: `[status, error]` plus reserved
  /// bytes. The ROM pads them to [romStatusSize] bytes at the end of
  /// the payload; shorter payloads (stub responses) carry just two.
  (int status, int code) get romStatus {
    if (data.length >= romStatusSize) {
      return (
        data[data.length - romStatusSize] & 0xFF,
        data[data.length - romStatusSize + 1] & 0xFF,
      );
    }
    if (data.length >= 2) {
      return (data[0] & 0xFF, data[1] & 0xFF);
    }
    return (0, 0);
  }

  /// True when the ROM status bytes signal a failure.
  bool get hasRomError => romStatus.$1 != 0;

  /// Payload minus the trailing ROM status bytes: the actual result
  /// data (e.g. the 32 ASCII hex chars of SPI_FLASH_MD5).
  Uint8List get body {
    if (data.length <= romStatusSize) {
      return Uint8List(0);
    }
    return Uint8List.fromList(data.sublist(0, data.length - romStatusSize));
  }

  /// Throw [EspRomError] when the ROM reported a failure for the
  /// command described by [opDescription].
  void throwIfRomError(String opDescription) {
    if (!hasRomError) {
      return;
    }
    final (status, code) = romStatus;
    final error = RomError(status, code);
    throw EspRomError(
      error.combined,
      'Failed to $opDescription (result 0x'
      '${error.combined.toRadixString(16)}: ${error.message})',
    );
  }
}
