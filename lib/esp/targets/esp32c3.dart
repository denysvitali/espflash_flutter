/// ESP32-C3 ROM target: constants and watchdog handling.
///
/// Mirrors esptool `ESP32C3ROM` / esptool-js `ESP32C3ROM`; register
/// sequences follow IMPLEMENTATION_PLAN.md section 3.
library;

import '../connection.dart';
import 'chip_target.dart';

final class Esp32C3 implements ChipTarget {
  const Esp32C3();

  static const String name = 'ESP32-C3';

  /// Chip ID inside the GET_SECURITY_INFO payload.
  static const int id = 5;

  /// Register holding the chip detect magic value.
  static const int chipDetectMagicRegister = 0x40001000;

  /// Magic values reported by the various ESP32-C3 ROM revisions.
  static const List<int> detectMagics = [
    0x6921506F,
    0x1B31506F,
    0x4881606F,
    0x4361606F,
  ];

  /// ROM FLASH_DATA block size.
  static const int romFlashWriteSize = 0x400;

  /// Flasher stub FLASH_DATA block size (v2).
  static const int stubFlashWriteBlockSize = 0x4000;

  static const int sectorSize = 0x1000;

  /// MEM_DATA block size for RAM uploads (v2).
  static const int ramBlock = 0x1800;

  static const int rtcCntlBase = 0x60008000;

  /// RTC WDT configuration registers.
  static const int rtcCntlWdtConfig0Reg = rtcCntlBase + 0x0090;
  static const int rtcCntlWdtConfig1Reg = rtcCntlBase + 0x0094;

  /// RTC WDT write-protect register (unlock with [rtcCntlWdtWKey]).
  static const int rtcCntlWdtWprotectReg = rtcCntlBase + 0x00A8;
  static const int rtcCntlWdtWKey = 0x50D83AA1;

  /// Super-watchdog (SWD) registers.
  static const int rtcCntlSwdConfReg = rtcCntlBase + 0x00AC;
  static const int rtcCntlSwdAutoFeedEn = 1 << 31;
  static const int rtcCntlSwdWprotectReg = rtcCntlBase + 0x00B0;
  static const int rtcCntlSwdWKey = 0x8F1D312A;

  @override
  String get chipName => name;

  @override
  int get chipId => id;

  @override
  List<int> get chipDetectMagics => detectMagics;

  @override
  int get chipDetectMagicReg => chipDetectMagicRegister;

  @override
  int get flashWriteSize => romFlashWriteSize;

  @override
  int get stubFlashWriteSize => stubFlashWriteBlockSize;

  @override
  int get flashSectorSize => sectorSize;

  @override
  int get ramBlockSize => ramBlock;

  @override
  int get bootloaderOffset => 0;

  /// Disable the RTC WDT and auto-feed the SWD. Required over
  /// USB-Serial-JTAG, where neither watchdog is held in check and
  /// they reset the board mid-flash.
  @override
  Future<void> disableWatchdogs(EspConnection connection) async {
    // Unlock the RTC WDT and turn it off.
    await connection.writeReg(rtcCntlWdtWprotectReg, rtcCntlWdtWKey);
    await connection.writeReg(rtcCntlWdtConfig0Reg, 0);
    await connection.writeReg(rtcCntlWdtWprotectReg, 0);
    // Unlock the SWD and let it feed itself.
    await connection.writeReg(rtcCntlSwdWprotectReg, rtcCntlSwdWKey);
    await connection.writeReg(rtcCntlSwdConfReg, rtcCntlSwdAutoFeedEn);
    await connection.writeReg(rtcCntlSwdWprotectReg, 0);
  }

  /// Arm the RTC watchdog so it resets the chip ~2 s after the last
  /// write. The reliable post-flash reboot over USB-Serial-JTAG,
  /// where toggling DTR/RTS does not reach the chip.
  @override
  Future<void> rtcWdtReset(EspConnection connection) async {
    await connection.writeReg(rtcCntlWdtWprotectReg, rtcCntlWdtWKey);
    await connection.writeReg(rtcCntlWdtConfig1Reg, 2000);
    await connection.writeReg(
      rtcCntlWdtConfig0Reg,
      (1 << 31) | (5 << 28) | (1 << 8) | 2,
    );
    await connection.writeReg(rtcCntlWdtWprotectReg, 0);
  }
}
