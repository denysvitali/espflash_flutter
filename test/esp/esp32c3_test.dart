import 'package:espflash_flutter/esp/connection.dart';
import 'package:espflash_flutter/esp/protocol.dart';
import 'package:espflash_flutter/esp/targets/esp32c3.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_transport.dart';

void main() {
  const chip = Esp32C3();

  group('constants', () {
    test('chip identity', () {
      expect(chip.chipName, 'ESP32-C3');
      expect(chip.chipId, 5);
      expect(chip.chipDetectMagicReg, 0x40001000);
      expect(chip.chipDetectMagics, [
        0x6921506F,
        0x1B31506F,
        0x4881606F,
        0x4361606F,
      ]);
    });

    test('flash geometry', () {
      expect(chip.flashWriteSize, 0x400);
      expect(chip.stubFlashWriteSize, 0x4000);
      expect(chip.flashSectorSize, 0x1000);
      expect(chip.ramBlockSize, 0x1800);
      expect(chip.bootloaderOffset, 0);
    });

    test('RTC_CNTL register map', () {
      expect(Esp32C3.rtcCntlWdtConfig0Reg, 0x60008090);
      expect(Esp32C3.rtcCntlWdtConfig1Reg, 0x60008094);
      expect(Esp32C3.rtcCntlWdtWprotectReg, 0x600080A8);
      expect(Esp32C3.rtcCntlWdtWKey, 0x50D83AA1);
      expect(Esp32C3.rtcCntlSwdConfReg, 0x600080AC);
      expect(Esp32C3.rtcCntlSwdAutoFeedEn, 0x80000000);
      expect(Esp32C3.rtcCntlSwdWprotectReg, 0x600080B0);
      expect(Esp32C3.rtcCntlSwdWKey, 0x8F1D312A);
    });
  });

  group('register sequences', () {
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

    List<(int address, int value)> writeRegSequence() {
      return transport
          .requestsFor(EspCommand.writeReg)
          .map(
            (request) => (
              readU32le(request.data),
              readU32le(request.data, 4),
            ),
          )
          .toList();
    }

    test('disableWatchdogs: unlock WDT, off, lock, autofeed SWD',
        () async {
      await chip.disableWatchdogs(connection);
      expect(writeRegSequence(), [
        (0x600080A8, 0x50D83AA1), // unlock RTC WDT
        (0x60008090, 0x00000000), // WDTCONFIG0 = 0 (off)
        (0x600080A8, 0x00000000), // lock RTC WDT
        (0x600080B0, 0x8F1D312A), // unlock SWD
        (0x600080AC, 0x80000000), // SWD auto-feed enable
        (0x600080B0, 0x00000000), // lock SWD
      ]);
      // Every WRITE_REG carries mask 0xFFFFFFFF and delay 0.
      for (final request in transport.requestsFor(EspCommand.writeReg)) {
        expect(readU32le(request.data, 8), 0xFFFFFFFF);
        expect(readU32le(request.data, 12), 0);
      }
    });

    test('rtcWdtReset: arm the watchdog for a ~2 s reset', () async {
      await chip.rtcWdtReset(connection);
      expect(writeRegSequence(), [
        (0x600080A8, 0x50D83AA1), // unlock
        (0x60008094, 2000), // WDTCONFIG1: 2000 ms
        // WDTCONFIG0: enable | stage config | pause | reset
        (0x60008090, (1 << 31) | (5 << 28) | (1 << 8) | 2),
        (0x600080A8, 0x00000000), // lock
      ]);
    });
  });
}
