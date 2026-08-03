/// Chip-specific constants and ROM operations.
///
/// v1 ships only [Esp32C3]; the interface exists so v2 targets slot
/// in without touching the flasher.
library;

import '../connection.dart';

/// Everything the flasher needs to know about one ESP chip type.
abstract interface class ChipTarget {
  String get chipName;

  /// Chip ID as reported by GET_SECURITY_INFO (ESP32-C3: 5).
  int get chipId;

  /// Values found at [chipDetectMagicReg] on this chip's ROMs.
  List<int> get chipDetectMagics;

  /// Register holding the chip detect magic value.
  int get chipDetectMagicReg;

  /// Block size the ROM accepts per FLASH_DATA (0x400 without stub).
  int get flashWriteSize;

  /// Block size once a flasher stub is running (v2).
  int get stubFlashWriteSize;

  int get flashSectorSize;

  /// Max RAM upload block for MEM_DATA (v2 stub loader).
  int get ramBlockSize;

  int get bootloaderOffset;

  /// Disable the watchdogs that can reset the board mid-flash when
  /// talking over USB-Serial-JTAG.
  Future<void> disableWatchdogs(EspConnection connection);

  /// Reset the chip via the RTC watchdog; the reliable post-flash
  /// reboot when talking over USB-Serial-JTAG.
  Future<void> rtcWdtReset(EspConnection connection);
}
