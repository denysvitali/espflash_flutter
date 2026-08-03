/// Chip detection: verify we are talking to an ESP32-C3 ROM before
/// flashing anything.
///
/// Primary path is GET_SECURITY_INFO: it identifies the chip and is
/// also the security gate (flash encryption / secure download are
/// refused in v1). When the command is unsupported, the READ_REG
/// chip-detect magic loop is the fallback.
library;

import 'connection.dart';
import 'errors.dart';
import 'protocol.dart';
import 'targets/chip_target.dart';
import 'targets/esp32c3.dart';

/// GET_SECURITY_INFO flag: secure download mode enabled.
const int securityFlagSecureDownloadEnable = 1 << 2;

/// Magic values of chips we can name in the refusal message.
const Map<int, String> knownChipMagics = {
  0x00F01D83: 'ESP32',
  0x0C21E06F: 'ESP32-C2',
  0x6F51306F: 'ESP32-C2',
  0x7C41A06F: 'ESP32-C2',
  0x2CE0806F: 'ESP32-C6',
  0x2421606F: 'ESP32-C61',
  0x33F0206F: 'ESP32-C61',
  0x4F81606F: 'ESP32-C61',
  0x1101406F: 'ESP32-C5',
  0x63E1406F: 'ESP32-C5',
  0x5FD1406F: 'ESP32-C5',
  0xD7B73E80: 'ESP32-H2',
  0x97E30068: 'ESP32-H2',
  0x00000009: 'ESP32-S3',
  0x000007C6: 'ESP32-S2',
  0xFFF0C101: 'ESP8266',
};

/// Detect the connected chip; returns the [Esp32C3] target or throws
/// [EspUnsupportedChipError] for anything else (including encrypted
/// or secure-boot chips, which v1 refuses to flash).
Future<ChipTarget> detectChip(EspConnection connection) async {
  // Primary: GET_SECURITY_INFO chip ID — also the security gate.
  final bySecurityInfo = await _detectBySecurityInfo(connection);
  if (bySecurityInfo != null) {
    return bySecurityInfo;
  }
  // Fallback: READ_REG magic loop at the chip detect register.
  return _detectByMagic(connection);
}

Future<ChipTarget> _detectByMagic(EspConnection connection) async {
  final int magic;
  try {
    magic = await connection.readReg(Esp32C3.chipDetectMagicRegister);
  } on EspError catch (error) {
    throw EspUnsupportedChipError(
      'Unable to detect chip type: $error',
    );
  }
  if (Esp32C3.detectMagics.contains(magic)) {
    return const Esp32C3();
  }
  final known = knownChipMagics[magic];
  if (known != null) {
    throw EspUnsupportedChipError(
      'This chip is $known, not an ESP32-C3. '
      'Only ESP32-C3 is supported.',
    );
  }
  throw EspUnsupportedChipError(
    'Unsupported chip (magic value 0x'
    '${magic.toRadixString(16).padLeft(8, '0')}). '
    'Only ESP32-C3 is supported.',
  );
}

/// Returns null when GET_SECURITY_INFO is unsupported on this ROM
/// (caller falls back to the magic loop). Security refusals and
/// foreign chip IDs throw — they never fall back.
Future<ChipTarget?> _detectBySecurityInfo(EspConnection connection) async {
  final EspResponse response;
  try {
    response = await connection.command(
      EspCommand.getSecurityInfo,
      description: 'get security info',
    );
  } on EspError {
    // Command unsupported or failed; try the magic fallback.
    return null;
  }
  final body = response.body;
  if (body.length < 16) {
    throw const EspUnsupportedChipError(
      'Unable to detect chip type: truncated security info payload',
    );
  }
  // Payload: [u32 flags][u8 flash_crypt_cnt][7x u8 key purposes]
  //          [u32 chip_id @ 12][u32 api_version]
  final flags = readU32le(body);
  final flashCryptCnt = body[4] & 0xFF;
  final chipId = readU32le(body, 12);
  if (flashCryptCnt != 0) {
    throw const EspUnsupportedChipError(
      'Flash encryption is enabled on this chip; refusing to flash.',
    );
  }
  if (flags & securityFlagSecureDownloadEnable != 0) {
    throw const EspUnsupportedChipError(
      'Secure download mode is enabled on this chip; '
      'refusing to flash.',
    );
  }
  if (chipId == Esp32C3.id) {
    return const Esp32C3();
  }
  throw EspUnsupportedChipError(
    'Unsupported chip (chip ID $chipId). Only ESP32-C3 is supported.',
  );
}
