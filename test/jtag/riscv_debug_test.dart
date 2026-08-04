import 'dart:typed_data';

import 'package:espflash_flutter/jtag/esp_usb_jtag.dart';
import 'package:espflash_flutter/jtag/riscv_debug.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake RISC-V debug module reachable over the JTAG TAP.
///
/// Models the parts of the spec that actually bit us: while
/// `dmcontrol.dmactive` is 0 every other DM register reads 0 and writes
/// to them are discarded; System Bus Access reads memory on an
/// sbaddress0 write (sbreadonaddr) and prefetches the next word on each
/// sbdata0 read (sbreadondata + autoincrement).
final class FakeDebugModule implements DmiTransport {
  FakeDebugModule({this.memory = const <int, int>{}, this.stuckInReset = false});

  final Map<int, int> memory;

  /// Models a module whose dmactive bit never sticks.
  final bool stuckInReset;

  bool dmactive = false;
  int sbcs = (1 << 29) | (32 << 5) | (1 << 2); // sbversion=1, sbasize=32, 32-bit
  int sbaddress = 0;
  int sbdata = 0;

  /// Every DMI operation, as (op, address, value).
  final List<(int, int, int)> ops = <(int, int, int)>[];

  @override
  int idleCycles = 0;

  int _pendingResult = 0;

  @override
  Future<void> tapReset() async {}

  @override
  Future<List<bool>> writeRegister(int ir, int irWidth, List<bool> drBits) async {
    if (ir == 0x10) {
      // dtmcs: version 1, abits 7, idle 1.
      return bitsOf((1 << 12) | (7 << 4) | 1, 32);
    }
    if (ir != 0x11) {
      return bitsOf(0, drBits.length);
    }
    final value = _dmiValue(drBits);
    final op = value.$1;
    final address = value.$2;
    final data = value.$3;
    ops.add((op, address, data));

    final previous = _pendingResult;
    switch (op) {
      case 1: // read
        _pendingResult = _read(address);
      case 2: // write
        _write(address, data);
        _pendingResult = 0;
      default: // nop: returns the previous operation's result
        break;
    }
    // Response carries the *previous* operation's data, status ok.
    return bitsOf(previous << 2, drBits.length);
  }

  int _read(int address) {
    if (address == 0x10) {
      return dmactive ? 1 : 0;
    }
    if (!dmactive) {
      return 0; // DM held in reset
    }
    switch (address) {
      case 0x11: // dmstatus: version 2 (0.13)
        return 0x00430c82;
      case 0x38:
        return sbcs;
      case 0x39:
        return sbaddress;
      case 0x3C:
        final value = sbdata;
        if (sbcs & (1 << 15) != 0) {
          // sbreadondata: read at the current address, then advance —
          // the address already points at the next word because the
          // previous access incremented it.
          sbdata = memory[sbaddress] ?? 0;
          if (sbcs & (1 << 16) != 0) {
            sbaddress += 4;
          }
        }
        return value;
      default:
        return 0;
    }
  }

  void _write(int address, int data) {
    if (address == 0x10) {
      dmactive = !stuckInReset && data & 1 != 0;
      return;
    }
    if (!dmactive) {
      return; // discarded while the DM is in reset
    }
    switch (address) {
      case 0x38:
        // Keep the read-only capability bits; adopt the control bits.
        sbcs = (sbcs & 0xE00007FF) | (data & 0x001FF000);
      case 0x39:
        sbaddress = data;
        if (sbcs & (1 << 20) != 0) {
          // sbreadonaddr: the write triggers a bus read.
          sbdata = memory[sbaddress] ?? 0;
          if (sbcs & (1 << 16) != 0) {
            sbaddress += 4;
          }
        }
      case 0x3C:
        memory[sbaddress] = data;
        if (sbcs & (1 << 16) != 0) {
          sbaddress += 4;
        }
    }
  }

  /// Decode (op, address, data) from an LSB-first DMI scan.
  (int, int, int) _dmiValue(List<bool> bits) {
    final op = bitsToInt(bits.sublist(0, 2));
    final data = bitsToInt(bits.sublist(2, 34));
    final address = bitsToInt(bits.sublist(34));
    return (op, address, data);
  }
}

void main() {
  group('RiscvDtm.attach', () {
    test('writes dmcontrol.dmactive before touching other DM registers',
        () async {
      final dm = FakeDebugModule();
      final dtm = RiscvDtm(dm);
      await dtm.init();
      await dtm.attach();

      expect(dm.dmactive, isTrue);
      // The first DM write must be dmcontrol; anything earlier would be
      // discarded by a module still in reset.
      final firstWrite = dm.ops.firstWhere((o) => o.$1 == 2);
      expect(firstWrite.$2, 0x10, reason: 'first DM write must be dmcontrol');
      expect(firstWrite.$3 & 1, 1, reason: 'dmactive must be set');
    });

    test('fails clearly when the module never leaves reset', () async {
      final dm = FakeDebugModule(stuckInReset: true);
      final dtm = RiscvDtm(dm);
      await dtm.init();
      expect(
        dtm.attach(),
        throwsA(
          isA<RiscvDebugError>().having(
            (e) => e.message,
            'message',
            contains('stays in reset'),
          ),
        ),
      );
    });

    test('rejects a chip without 32-bit system bus access', () async {
      final dm = FakeDebugModule()..sbcs = 0; // sbversion 0, no sbaccess32
      final dtm = RiscvDtm(dm);
      await dtm.init();
      expect(
        dtm.attach(),
        throwsA(
          isA<RiscvDebugError>().having(
            (e) => e.message,
            'message',
            contains('system bus access'),
          ),
        ),
      );
    });
  });

  group('memory access', () {
    late FakeDebugModule dm;
    late RiscvDtm dtm;

    setUp(() async {
      dm = FakeDebugModule(
        memory: <int, int>{
          0x3FC80000: 0x11111111,
          0x3FC80004: 0x22222222,
          0x3FC80008: 0x33333333,
          0x3FC8000C: 0x44444444,
        },
      );
      dtm = RiscvDtm(dm);
      await dtm.init();
      await dtm.attach();
    });

    test('single word read returns the addressed word', () async {
      expect(await dtm.readMem32(0x3FC80004), 0x22222222);
    });

    test('block read returns consecutive words, not shifted by one',
        () async {
      final words = await dtm.readMemBlock(0x3FC80000, 4);
      expect(words, <int>[0x11111111, 0x22222222, 0x33333333, 0x44444444]);
    });

    test('block read disables autoread before the final word', () async {
      dm.ops.clear();
      await dtm.readMemBlock(0x3FC80000, 3);
      // Last sbcs write before the final sbdata0 read must clear
      // sbreadondata (bit 15), so the DM does not fetch past the block.
      final sbcsWrites =
          dm.ops.where((o) => o.$1 == 2 && o.$2 == 0x38).toList();
      expect(sbcsWrites.last.$3 & (1 << 15), 0);
    });

    test('write then read round-trips', () async {
      await dtm.writeMem32(0x3FC80008, 0xDEADBEEF);
      expect(await dtm.readMem32(0x3FC80008), 0xDEADBEEF);
    });

    test('unaligned and flash-mapped addresses are refused', () async {
      expect(dtm.readMem32(0x3FC80001), throwsA(isA<RiscvDebugError>()));
      expect(dtm.readMem32(0x42000000), throwsA(isA<RiscvDebugError>()));
    });

    test('memory access before attach is refused', () async {
      final fresh = RiscvDtm(FakeDebugModule());
      await fresh.init();
      expect(fresh.readMem32(0x3FC80000), throwsA(isA<RiscvDebugError>()));
    });
  });
}
