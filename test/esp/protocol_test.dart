import 'package:espflash_flutter/esp/connection.dart' show syncPayload;
import 'package:espflash_flutter/esp/errors.dart';
import 'package:espflash_flutter/esp/protocol.dart';
import 'package:espflash_flutter/esp/slip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('opcode constants', () {
    test('match the ROM protocol', () {
      expect(EspCommand.flashBegin, 0x02);
      expect(EspCommand.flashData, 0x03);
      expect(EspCommand.flashEnd, 0x04);
      expect(EspCommand.memBegin, 0x05);
      expect(EspCommand.memEnd, 0x06);
      expect(EspCommand.memData, 0x07);
      expect(EspCommand.sync, 0x08);
      expect(EspCommand.writeReg, 0x09);
      expect(EspCommand.readReg, 0x0A);
      expect(EspCommand.spiSetParams, 0x0B);
      expect(EspCommand.spiAttach, 0x0D);
      expect(EspCommand.changeBaud, 0x0F);
      expect(EspCommand.flashDeflBegin, 0x10);
      expect(EspCommand.flashDeflData, 0x11);
      expect(EspCommand.flashDeflEnd, 0x12);
      expect(EspCommand.spiFlashMd5, 0x13);
      expect(EspCommand.getSecurityInfo, 0x14);
    });
  });

  group('checksum', () {
    test('empty payload returns the seed 0xEF', () {
      expect(espChecksum(const []), 0xEF);
    });

    test('XORs the payload bytes over the seed', () {
      expect(espChecksum([0xEF]), 0x00);
      expect(espChecksum([0x01, 0x02]), 0xEF ^ 0x01 ^ 0x02);
      expect(espChecksum([0xFF, 0xFF]), 0xEF); // even 0xFF count
      expect(espChecksum([0xFF]), 0xEF ^ 0xFF); // odd 0xFF count
    });

    test('accepts a custom seed', () {
      expect(espChecksum([0x0F], 0x00), 0x0F);
      expect(espChecksum(const [], 0x42), 0x42);
    });
  });

  group('byte helpers', () {
    test('u32le/u16le encode little-endian', () {
      expect(u32le(0x11223344), [0x44, 0x33, 0x22, 0x11]);
      expect(u32le(0), [0, 0, 0, 0]);
      expect(u32le(0xFFFFFFFF), [0xFF, 0xFF, 0xFF, 0xFF]);
      expect(u16le(0x24), [0x24, 0x00]);
      expect(u16le(0xBEEF), [0xEF, 0xBE]);
    });

    test('readU32le/readU16le decode little-endian', () {
      expect(readU32le([0x44, 0x33, 0x22, 0x11]), 0x11223344);
      expect(readU32le([0, 0, 0, 0x80]), 0x80000000);
      expect(readU16le([0xEF, 0xBE]), 0xBEEF);
      expect(readU32le([0xAA, 0x44, 0x33, 0x22, 0x11], 1), 0x11223344);
    });
  });

  group('EspRequest', () {
    test('golden SYNC frame bytes', () {
      // C0 00 08 24 00 00 00 00 00 07 07 12 20 + 32x55 + C0
      final frame = EspRequest(EspCommand.sync, syncPayload).toFrame();
      expect(frame, [
        0xC0, // frame start
        0x00, // direction: request
        0x08, // opcode: SYNC
        0x24, 0x00, // payload size 36, little-endian
        0x00, 0x00, 0x00, 0x00, // checksum 0
        0x07, 0x07, 0x12, 0x20, // sync magic
        ...List<int>.filled(32, 0x55),
        0xC0, // frame end
      ]);
      expect(frame, hasLength(46));
    });

    test('header is little-endian <BBHI>', () {
      final packet = EspRequest(
        0x2A,
        List<int>.generate(0x0102, (i) => i & 0xFF),
        0x11223344,
      ).toPacket();
      expect(packet.sublist(0, 8), [
        0x00, // direction
        0x2A, // opcode
        0x02, 0x01, // size 0x0102 LE
        0x44, 0x33, 0x22, 0x11, // checksum LE
      ]);
      expect(packet.length, 8 + 0x0102);
    });

    test('request direction is always 0x00', () {
      expect(EspRequest(EspCommand.readReg).toPacket()[0], 0x00);
    });

    test('SLIP escaping covers header bytes too', () {
      // Checksum 0x00C000DB forces C0/DB into the header area.
      final frame = EspRequest(0x03, const [1, 2, 3], 0x00C000DB)
          .toFrame();
      // No raw C0/DB except the framing and escape prefixes.
      expect(frame.first, 0xC0);
      expect(frame.last, 0xC0);
      final inner = frame.sublist(1, frame.length - 1);
      expect(inner.contains(0xC0), isFalse);
      // Decode roundtrip returns the exact unframed packet.
      expect(
        SlipCodec.decode(inner),
        EspRequest(0x03, const [1, 2, 3], 0x00C000DB).toPacket(),
      );
    });
  });

  group('EspResponse', () {
    test('parses direction, opcode, LE value and payload', () {
      final packet = [
        0x01, // direction: response
        0x0A, // opcode: READ_REG
        0x04, 0x00, // payload size 4
        0x6F, 0x50, 0x21, 0x69, // value 0x6921506F LE
        0x00, 0x00, 0x00, 0x00, // ROM status: ok
      ];
      final response = EspResponse.tryParse(packet);
      expect(response, isNotNull);
      expect(response!.opcode, EspCommand.readReg);
      expect(response.value, 0x6921506F);
      expect(response.data, [0, 0, 0, 0]);
      expect(response.hasRomError, isFalse);
    });

    test('rejects request-direction and short packets', () {
      expect(EspResponse.tryParse([0x00, 0x08, 0, 0, 0, 0, 0, 0]),
          isNull);
      expect(EspResponse.tryParse([0x01, 0x08, 0]), isNull);
      expect(EspResponse.tryParse(const []), isNull);
    });

    test('reads ROM status from the LAST 4 payload bytes', () {
      // MD5-style: 32-byte result body, then [1, 7, 0, 0] status.
      final payload = [
        ...List<int>.filled(32, 0x30),
        1, 7, 0, 0,
      ];
      final response = EspResponse.tryParse([
        0x01, 0x13, // response, SPI_FLASH_MD5
        36, 0, // size
        0, 0, 0, 0, // value
        ...payload,
      ])!;
      expect(response.hasRomError, isTrue);
      expect(response.romStatus, (1, 7));
      expect(response.body, List<int>.filled(32, 0x30));
    });

    test('status-only payloads report ok', () {
      final response = EspResponse.tryParse([
        0x01, 0x09, 4, 0, 0, 0, 0, 0, // WRITE_REG
        0, 0, 0, 0,
      ])!;
      expect(response.hasRomError, isFalse);
      expect(response.body, isEmpty);
    });

    test('two-byte stub-style status payloads are understood', () {
      final response = EspResponse.tryParse([
        0x01, 0x03, 2, 0, 0, 0, 0, 0, //
        1, 8,
      ])!;
      expect(response.romStatus, (1, 8));
      expect(response.hasRomError, isTrue);
    });

    test('throwIfRomError raises EspRomError with the combined code',
        () {
      final response = EspResponse.tryParse([
        0x01, 0x03, 4, 0, 0, 0, 0, 0, //
        1, 7, 0, 0,
      ])!;
      expect(
        () => response.throwIfRomError('write block'),
        throwsA(
          isA<EspRomError>()
              .having((e) => e.code, 'code', 0x0107)
              .having((e) => e.message, 'message',
                  contains('Checksum error')),
        ),
      );
    });

    test('throwIfRomError is silent on success', () {
      final response = EspResponse.tryParse([
        0x01, 0x03, 4, 0, 0, 0, 0, 0, //
        0, 0, 0, 0,
      ])!;
      response.throwIfRomError('write block'); // must not throw
    });
  });

  group('RomError / romErrorText', () {
    test('every ROM error code maps to a message', () {
      const codes = [
        0x01, // invalid parameter
        0x05, // invalid message
        0x07, // checksum
        0x08, // flash write
        0x09, // flash read
        0x0A, // flash read length
        0x0B, // deflate
        0x0C, // deflate adler32
        0x0D, // deflate parameter
        0x0E, // invalid RAM binary size
        0x0F, // invalid RAM binary address
      ];
      for (final code in codes) {
        expect(romErrorText(code), isNot(contains('Unknown')),
            reason: 'code 0x${code.toRadixString(16)}');
        // The esptool-style combined word maps to the same text.
        expect(romErrorText(0x100 | code), romErrorText(code));
      }
      expect(romErrorText(0x99), contains('Unknown'));
    });

    test('RomError combines status and code like esptool', () {
      const error = RomError(1, 0x07);
      expect(error.combined, 0x0107);
      expect(error.message, 'Checksum error');
      expect(error.toString(), contains('RomError'));
    });
  });
}
