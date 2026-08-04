/// RISC-V debug support over JTAG: DTMCS/DMI register access (debug spec
/// v0.13) and System Bus Access memory reads/writes without halting the
/// CPU. Ported from probe-rs' `jtag_dtm.rs` + the SBA register map.
library;

import 'dart:typed_data';

import 'esp_usb_jtag.dart';

final class RiscvDebugError implements Exception {
  const RiscvDebugError(this.message);

  final String message;

  @override
  String toString() => 'RISC-V debug error: $message';
}

/// JTAG IR values (5-bit IR on ESP32-C3).
const int _irIdcode = 0x01;
const int _irDtmcs = 0x10;
const int _irDmi = 0x11;
const int _irWidth = 5;

/// DMI register addresses.
const int _dmiSbdata0 = 0x3C;
const int _dmiSbaddress0 = 0x39;
const int _dmiSbcs = 0x38;
const int _dmiDmcontrol = 0x10;

/// `dmcontrol` bits.
const int _dmactive = 1 << 0;
const int _ndmreset = 1 << 1;

/// RISC-V DTM access: init, DMI read/write, SBA memory IO.
final class RiscvDtm {
  RiscvDtm(this._tap);

  final JtagTap _tap;

  int _abits = 0;
  bool _initialized = false;

  /// TAP reset + DTMCS: validates the transport, learns `abits` and the
  /// idle-cycle hint.
  Future<int> init() async {
    await _tap.tapReset();
    final captured =
        await _tap.writeRegister(_irDtmcs, _irWidth, bitsOf(0, 32));
    final dtmcs = bitsToInt(captured);
    if (dtmcs == 0) {
      throw const RiscvDebugError('no RISC-V target (dtmcs reads 0)');
    }
    final version = dtmcs & 0xF;
    if (version != 1) {
      throw RiscvDebugError('unsupported DTM version $version');
    }
    _abits = (dtmcs >> 4) & 0x3F;
    _tap.idleCycles = (dtmcs >> 12) & 0x7;
    _initialized = true;
    return dtmcs;
  }

  /// JTAG IDCODE of the TAP.
  Future<int> readIdcode() async {
    await _tap.tapReset();
    final captured =
        await _tap.writeRegister(_irIdcode, _irWidth, bitsOf(0, 32));
    return bitsToInt(captured);
  }

  /// One DMI scan; returns the data field of the *previous* operation's
  /// response. op: 0 = nop, 1 = read, 2 = write.
  Future<int> _dmiScan(int op, int address, int value) async {
    if (!_initialized) {
      throw const RiscvDebugError('dtm not initialized');
    }
    final width = _abits + 34;
    // value = (address << 34) | (data << 2) | op, shifted LSB first.
    final bits = <bool>[
      for (var i = 0; i < 2; i++) op & (1 << i) != 0,
      for (var i = 0; i < 32; i++) value & (1 << i) != 0,
      for (var i = 0; i < _abits; i++) address & (1 << i) != 0,
    ];
    assert(bits.length == width);
    final captured = await _tap.writeRegister(_irDmi, _irWidth, bits);
    final response = bitsToInt(captured);
    final status = response & 0x3;
    switch (status) {
      case 0:
        return (response >> 2) & 0xFFFFFFFF;
      case 2:
        throw const RiscvDebugError('DMI operation failed');
      case 3:
        // Busy: clear the sticky state, add an idle cycle, retry upstream.
        throw const RiscvDebugError('DMI busy');
      default:
        throw const RiscvDebugError('reserved DMI status');
    }
  }

  /// DMI scan with busy recovery (dmireset + extra idle cycles, ≤2 s).
  Future<int> _dmiScanRetry(int op, int address, int value) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (true) {
      try {
        return await _dmiScan(op, address, value);
      } on RiscvDebugError catch (error) {
        if (error.message != 'DMI busy') {
          rethrow;
        }
        await _clearBusy();
        _tap.idleCycles++;
        if (DateTime.now().isAfter(deadline)) {
          throw const RiscvDebugError('DMI busy timeout');
        }
      }
    }
  }

  Future<void> _clearBusy() async {
    // dtmcs.dmireset = bit 16.
    await _tap.writeRegister(_irDtmcs, _irWidth, bitsOf(1 << 16, 32));
  }

  /// DMI register read (read op, then a nop scan to collect the result).
  Future<int> dmiRead(int address) async {
    await _dmiScanRetry(1, address, 0);
    return _dmiScanRetry(0, 0, 0);
  }

  /// DMI register write.
  Future<void> dmiWrite(int address, int value) async {
    await _dmiScanRetry(2, address, value);
  }

  /// Reset the whole system through the debug module (`ndmreset`) and
  /// let the CPU run again. Unlike the ROM-bootloader dance this works
  /// while user firmware runs, and leaves the chip executing firmware.
  Future<void> resetSystem() async {
    await dmiWrite(_dmiDmcontrol, _dmactive);
    await dmiWrite(_dmiDmcontrol, _dmactive | _ndmreset);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await dmiWrite(_dmiDmcontrol, _dmactive);
  }

  // ---------------------------------------------------------------------
  // System Bus Access
  // ---------------------------------------------------------------------

  // sbcs fields: sbaccess[19:17] (2 = 32-bit), sbreadonaddr[20],
  // sbautoincrement[16], sbreadondata[15], sberror[14:12], sbbusy[21].
  static const int _sbcsRead32 =
      (2 << 17) | (1 << 20) | (1 << 16) | (1 << 15);
  static const int _sbcsWrite32 = (2 << 17) | (1 << 16);

  /// Read one 32-bit word at [address].
  Future<int> readMem32(int address) async {
    await dmiWrite(_dmiSbcs, _sbcsRead32);
    await dmiWrite(_dmiSbaddress0, address);
    final value = await dmiRead(_dmiSbdata0);
    await _checkSbError();
    return value;
  }

  /// Read [wordCount] consecutive 32-bit words starting at [address].
  Future<Uint32List> readMemBlock(int address, int wordCount) async {
    if (wordCount <= 0) {
      return Uint32List(0);
    }
    await dmiWrite(_dmiSbcs, _sbcsRead32);
    await dmiWrite(_dmiSbaddress0, address);
    final out = Uint32List(wordCount);
    for (var i = 0; i < wordCount; i++) {
      out[i] = await dmiRead(_dmiSbdata0);
    }
    await _checkSbError();
    return out;
  }

  /// Write one 32-bit word at [address].
  Future<void> writeMem32(int address, int value) async {
    await dmiWrite(_dmiSbcs, _sbcsWrite32);
    await dmiWrite(_dmiSbaddress0, address);
    await dmiWrite(_dmiSbdata0, value);
    await _checkSbError();
  }

  Future<void> _checkSbError() async {
    final sbcs = await dmiRead(_dmiSbcs);
    final error = (sbcs >> 12) & 0x7;
    if (error != 0) {
      // Clear by writing 1s to sberror.
      await dmiWrite(_dmiSbcs, error << 12);
      throw RiscvDebugError('system bus access error $error');
    }
  }
}
