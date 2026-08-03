import 'package:espflash_flutter/esp/chip_detect.dart';
import 'package:espflash_flutter/esp/connection.dart';
import 'package:espflash_flutter/esp/errors.dart';
import 'package:espflash_flutter/esp/protocol.dart';
import 'package:espflash_flutter/esp/targets/esp32c3.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_transport.dart';

void main() {
  late FakeRomTransport transport;
  late EspConnection connection;

  setUp(() {
    transport = FakeRomTransport();
    connection = EspConnection(
      transport,
      defaultTimeout: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    await connection.close();
  });

  group('READ_REG magic loop (primary)', () {
    for (final magic in Esp32C3.detectMagics) {
      test('magic 0x${magic.toRadixString(16)} detects ESP32-C3',
          () async {
        transport.registers[Esp32C3.chipDetectMagicRegister] = magic;
        final chip = await detectChip(connection);
        expect(chip, isA<Esp32C3>());
        expect(chip.chipId, 5);
        // Magic path must not need GET_SECURITY_INFO.
        expect(
          transport.requestsFor(EspCommand.getSecurityInfo),
          isEmpty,
        );
        expect(
          transport
              .requestsFor(EspCommand.readReg)
              .single
              .data,
          u32le(0x40001000),
        );
      });
    }

    test('known foreign magic is refused by name', () async {
      transport.registers[Esp32C3.chipDetectMagicRegister] = 0x09;
      await expectLater(
        () => detectChip(connection),
        throwsA(
          isA<EspUnsupportedChipError>().having(
            (e) => e.message,
            'message',
            allOf(contains('ESP32-S3'), contains('not an ESP32-C3')),
          ),
        ),
      );
    });

    test('unknown magic is refused with its value', () async {
      transport.registers[Esp32C3.chipDetectMagicRegister] = 0xDEADBEEF;
      await expectLater(
        () => detectChip(connection),
        throwsA(
          isA<EspUnsupportedChipError>().having(
            (e) => e.message,
            'message',
            contains('deadbeef'),
          ),
        ),
      );
    });
  });

  group('GET_SECURITY_INFO fallback', () {
    setUp(() {
      // Make the magic read fail so the fallback path runs.
      transport.romErrorFor[EspCommand.readReg] = 0x01;
    });

    test('chip id 5 detects ESP32-C3', () async {
      transport.securityChipId = 5;
      final chip = await detectChip(connection);
      expect(chip, isA<Esp32C3>());
      expect(
        transport.requestsFor(EspCommand.getSecurityInfo),
        hasLength(1),
      );
    });

    test('any other chip id is refused', () async {
      transport.securityChipId = 6;
      await expectLater(
        () => detectChip(connection),
        throwsA(
          isA<EspUnsupportedChipError>().having(
            (e) => e.message,
            'message',
            contains('chip ID 6'),
          ),
        ),
      );
    });

    test('flash encryption is refused', () async {
      transport.securityChipId = 5;
      transport.securityCryptCnt = 1;
      await expectLater(
        () => detectChip(connection),
        throwsA(
          isA<EspUnsupportedChipError>().having(
            (e) => e.message,
            'message',
            contains('encryption'),
          ),
        ),
      );
    });

    test('secure download mode is refused even for a C3', () async {
      transport.securityChipId = 5;
      transport.securityFlags = securityFlagSecureDownloadEnable;
      await expectLater(
        () => detectChip(connection),
        throwsA(
          isA<EspUnsupportedChipError>().having(
            (e) => e.message,
            'message',
            contains('Secure download'),
          ),
        ),
      );
    });
  });

  test('both paths failing ends in EspUnsupportedChipError', () async {
    transport.romErrorFor[EspCommand.readReg] = 0x01;
    transport.romErrorFor[EspCommand.getSecurityInfo] = 0x01;
    await expectLater(
      () => detectChip(connection),
      throwsA(isA<EspUnsupportedChipError>()),
    );
  });
}
