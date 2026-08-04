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
const int _dmiDmstatus = 0x11;

/// `dmcontrol` bits.
const int _dmactive = 1 << 0;
const int _ndmreset = 1 << 1;

/// RISC-V DTM access: init, DMI read/write, SBA memory IO.
final class RiscvDtm {
  RiscvDtm(this._tap);

  final DmiTransport _tap;

  int _abits = 0;
  bool _initialized = false;
  bool _attached = false;

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

  /// Take the debug module out of reset and confirm it can do 32-bit
  /// System Bus Access.
  ///
  /// This must run after [init] and before any other debug-module
  /// register is touched. While `dmcontrol.dmactive` is 0 the whole DM
  /// is held at its reset values (debug spec 0.13.2 §3.12.2): writes to
  /// `sbcs`/`sbaddress0` are discarded and `sbdata0` reads back 0 — so
  /// memory reads silently return zeros. DTMCS lives in the JTAG TAP,
  /// not the DM, which is why the transport looks healthy either way.
  Future<void> attach() async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 500));
    while (true) {
      await dmiWrite(_dmiDmcontrol, _dmactive);
      if (await dmiRead(_dmiDmcontrol) & _dmactive != 0) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const RiscvDebugError(
          'debug module stays in reset (dmactive reads back 0)',
        );
      }
    }
    final dmstatus = await dmiRead(_dmiDmstatus);
    if (dmstatus & 0xF == 0) {
      throw RiscvDebugError(
        'debug module not responding (dmstatus=0x${dmstatus.toRadixString(16)})',
      );
    }
    final sbcs = await dmiRead(_dmiSbcs);
    final sbversion = (sbcs >> 29) & 0x7;
    final sbasize = (sbcs >> 5) & 0x7F;
    final has32 = sbcs & (1 << 2) != 0;
    if (sbversion != 1 || sbasize == 0 || !has32) {
      throw RiscvDebugError(
        'no 32-bit system bus access on this chip '
        '(sbcs=0x${sbcs.toRadixString(16)})',
      );
    }
    _attached = true;
    diagnostics = 'dmstatus=0x${dmstatus.toRadixString(16)} '
        'sbcs=0x${sbcs.toRadixString(16)} idle=${_tap.idleCycles}';
  }

  /// Debug-module identity captured by [attach]; shown when RTT
  /// discovery fails so one report pins down the failing layer.
  String diagnostics = '';

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

  // sbcs (debug spec 0.13.2 §3.12.18):
  //   sbversion[31:29] sbbusyerror[22] sbbusy[21] sbreadonaddr[20]
  //   sbaccess[19:17] sbautoincrement[16] sbreadondata[15] sberror[14:12]
  //   sbasize[11:5] sbaccess128[4] 64[3] 32[2] 16[1] 8[0]
  static const int _sbBusyError = 1 << 22; // W1C
  static const int _sbBusy = 1 << 21;
  static const int _sbReadOnAddr = 1 << 20;
  static const int _sbAccess32 = 2 << 17;
  static const int _sbAutoIncrement = 1 << 16;
  static const int _sbReadOnData = 1 << 15;

  /// Single word: writing sbaddress0 is the only bus access.
  static const int _sbcsSingleRead32 =
      _sbBusyError | _sbAccess32 | _sbReadOnAddr;

  /// Block: each sbdata0 read returns word i and prefetches word i+1.
  static const int _sbcsBlockRead32 = _sbBusyError |
      _sbAccess32 |
      _sbReadOnAddr |
      _sbAutoIncrement |
      _sbReadOnData;

  /// Autoread off — used before the final read of a block so the DM
  /// does not fetch one word past the end.
  static const int _sbcsAutoreadOff = _sbBusyError | _sbAccess32;

  static const int _sbcsWrite32 =
      _sbBusyError | _sbAccess32 | _sbAutoIncrement;

  /// Flash-mapped windows are served by the cache, not the system bus;
  /// probe-rs routes them elsewhere. RTT lives in DRAM, so refuse these
  /// rather than return plausible garbage.
  void _checkAddress(int address) {
    if (!_attached) {
      throw const RiscvDebugError('debug module not attached');
    }
    if (address & 3 != 0) {
      throw RiscvDebugError(
        'system bus access is word-aligned, got '
        '0x${address.toRadixString(16)}',
      );
    }
    final isFlashMapped = (address >= 0x3C000000 && address < 0x3C800000) ||
        (address >= 0x42000000 && address < 0x42800000);
    if (isFlashMapped) {
      throw RiscvDebugError(
        '0x${address.toRadixString(16)} is flash-mapped; the system bus '
        'cannot read it reliably',
      );
    }
  }

  /// Read one 32-bit word at [address].
  Future<int> readMem32(int address) async {
    _checkAddress(address);
    await _waitNotBusy();
    await dmiWrite(_dmiSbcs, _sbcsSingleRead32);
    await dmiWrite(_dmiSbaddress0, address); // triggers the read
    final value = await dmiRead(_dmiSbdata0);
    await _checkSbError();
    return value;
  }

  /// Read [wordCount] consecutive 32-bit words starting at [address].
  Future<Uint32List> readMemBlock(int address, int wordCount) async {
    if (wordCount <= 0) {
      return Uint32List(0);
    }
    if (wordCount == 1) {
      return Uint32List.fromList(<int>[await readMem32(address)]);
    }
    _checkAddress(address);
    await _waitNotBusy();
    await dmiWrite(_dmiSbcs, _sbcsBlockRead32);
    await dmiWrite(_dmiSbaddress0, address); // fetches word 0
    final out = Uint32List(wordCount);
    for (var i = 0; i < wordCount - 1; i++) {
      out[i] = await dmiRead(_dmiSbdata0); // word i, prefetches i+1
    }
    // Disable autoread before the last read, or the DM fetches one word
    // past the block and can latch sberror at a region boundary.
    await _waitNotBusy();
    await dmiWrite(_dmiSbcs, _sbcsAutoreadOff);
    out[wordCount - 1] = await dmiRead(_dmiSbdata0);
    await _checkSbError();
    return out;
  }

  /// Write one 32-bit word at [address].
  Future<void> writeMem32(int address, int value) async {
    _checkAddress(address);
    await _waitNotBusy();
    await dmiWrite(_dmiSbcs, _sbcsWrite32);
    await dmiWrite(_dmiSbaddress0, address);
    await dmiWrite(_dmiSbdata0, value); // triggers the write
    await _checkSbError();
  }

  /// sbcs must not be written while a bus access is in flight; doing so
  /// sets sbbusyerror and wedges further accesses.
  Future<void> _waitNotBusy() async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 500));
    while (true) {
      final sbcs = await dmiRead(_dmiSbcs);
      if (sbcs & _sbBusy == 0) {
        if (sbcs & _sbBusyError != 0) {
          await dmiWrite(_dmiSbcs, _sbBusyError); // W1C
        }
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const RiscvDebugError('system bus stayed busy');
      }
    }
  }

  Future<void> _checkSbError() async {
    final sbcs = await dmiRead(_dmiSbcs);
    final error = (sbcs >> 12) & 0x7;
    final busyError = sbcs & _sbBusyError != 0;
    if (error != 0 || busyError) {
      // Both sberror and sbbusyerror are write-1-to-clear.
      await dmiWrite(_dmiSbcs, (error << 12) | (busyError ? _sbBusyError : 0));
      throw RiscvDebugError(
        'system bus access error '
        '${error != 0 ? 'sberror=$error' : 'sbbusyerror'}',
      );
    }
  }
}
