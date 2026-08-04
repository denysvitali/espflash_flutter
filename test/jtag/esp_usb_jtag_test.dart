import 'dart:typed_data';

import 'package:espflash_flutter/jtag/esp_usb_jtag.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records writes; serves programmed IN bytes.
final class FakeWire implements JtagWire {
  final List<int> written = <int>[];
  final List<Uint8List> inQueue = <Uint8List>[];

  @override
  Future<void> write(Uint8List bytes) async {
    written.addAll(bytes);
  }

  @override
  Future<Uint8List> read(int maxLen, Duration timeout) async {
    if (inQueue.isEmpty) {
      return Uint8List(0);
    }
    return inQueue.removeAt(0);
  }
}

void main() {
  group('EspUsbJtag nibble packing', () {
    test('single clock nibble goes to the high nibble, flush pads low', () async {
      final wire = FakeWire();
      final jtag = EspUsbJtag(wire);
      // tms=1, tdi=1, cap=0 → 0b011 = 0x3; flush → 0x3A.
      await jtag.shiftBit(true, true, false);
      await jtag.flush();
      expect(wire.written, [0x3A]);
    });

    test('two commands share one byte', () async {
      final wire = FakeWire();
      final jtag = EspUsbJtag(wire);
      // clock cap=1,tms=0,tdi=1 → 0b101 = 0x5; then tms=1,tdi=0 → 0x2.
      await jtag.shiftBit(false, true, true);
      await jtag.shiftBit(true, false, false);
      wire.inQueue.add(Uint8List.fromList([0x00])); // 1 capture bit
      await jtag.flush();
      // nibbles [5,2] = 0x52; flush nibble padded by fill: 0xAA.
      expect(wire.written, [0x52, 0xAA]);
    });

    test('repeat coalescing: N identical clocks → command + repeat nibbles',
        () async {
      final wire = FakeWire();
      final jtag = EspUsbJtag(wire);
      // 5 identical clocks (tms=1,tdi=0) = command 0x2 with 4 extra reps:
      // reps shifted 2 bits at a time: 4&3=0 → 0xC, then 1 → 0xD.
      for (var i = 0; i < 5; i++) {
        await jtag.shiftBit(true, false, false);
      }
      await jtag.flush();
      // nibbles: 2, C, D, A → bytes 0x2C 0xDA
      expect(wire.written, [0x2C, 0xDA]);
    });

    test('captured bits arrive LSB-first and stop at the pending count',
        () async {
      final wire = FakeWire();
      final jtag = EspUsbJtag(wire);
      for (var i = 0; i < 3; i++) {
        await jtag.shiftBit(false, false, true);
      }
      // 0bxxx10110 → bits 0,1,2 = false,true,true; rest is device padding.
      wire.inQueue.add(Uint8List.fromList([0xF6]));
      final bits = await jtag.readCapturedBits();
      expect(bits, [false, true, true]);
    });

    test('read timeout raises JtagProtocolError', () async {
      final wire = FakeWire();
      final jtag = EspUsbJtag(wire);
      await jtag.shiftBit(false, false, true);
      expect(jtag.readCapturedBits(), throwsA(isA<JtagProtocolError>()));
    });
  });

  group('JtagTap scan sequences', () {
    test('tapReset: 5× tms=1 then tms=0', () async {
      final wire = FakeWire();
      final tap = JtagTap(EspUsbJtag(wire));
      await tap.tapReset();
      // 5× clock(tms=1,tdi=1)=0x3 coalesced: reps=4 → repeat nibbles
      // 0xC (4&3=0) then 0xD (1); then clock(0,0,0)=0x0; flush + pad.
      // nibbles [3,C,D,0,A(+A)] → bytes 0x3C 0xD0 0xAA.
      expect(wire.written, [0x3C, 0xD0, 0xAA]);
    });

    test('writeRegister shifts IR then DR, captures DR bits', () async {
      final wire = FakeWire();
      final tap = JtagTap(EspUsbJtag(wire), idleCycles: 0);
      // IR=0x10 (5 bits), DR=32 zero bits (read dtmcs).
      wire.inQueue.add(Uint8List.fromList([0x01, 0x02, 0x03, 0x04]));
      final captured = await tap.writeRegister(0x10, 5, bitsOf(0, 32));
      expect(captured, hasLength(32));
      expect(bitsToInt(captured), 0x04030201);
    });
  });

  group('bits helpers', () {
    test('round trip', () {
      expect(bitsToInt(bitsOf(0xDEADBEEF, 32)), 0xDEADBEEF);
      expect(bitsOf(5, 4), [true, false, true, false]);
    });
  });
}
