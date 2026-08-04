/// ESP32-C3/S3 built-in USB JTAG: the nibble-packed command protocol and
/// JTAG TAP scan helpers.
///
/// Direct port of probe-rs' `espusbjtag` protocol handler
/// (probe-rs-espressif/src/espusbjtag/protocol.rs), simplified to
/// synchronous transfers (no OUT-endpoint pipelining).
///
/// Wire format: every command is one nibble, packed high-nibble-first.
/// - Clock: `(cap<<2)|(tms<<1)|tdi` — one TCK cycle; captures TDO if cap.
/// - Reset: `8|srst`
/// - Flush: `0xA` — pads the byte and forces the device to complete the
///   current capture byte.
/// - Repeat(r): `0xC + (r & 3)` — repeats the previous command; the
///   repetition count is shifted in two bits at a time.
///
/// Captured bits return LSB-first on the bulk IN endpoint. The device
/// holds at most (64+4)*8 = 544 capture bits; exceeding that stalls the
/// command stream until the host reads.
library;

import 'dart:typed_data';

/// Transport the probe talks over (USB bulk OUT/IN in production).
abstract interface class JtagWire {
  Future<void> write(Uint8List bytes);

  /// Returns up to [maxLen] bytes; empty on timeout.
  Future<Uint8List> read(int maxLen, Duration timeout);
}

final class JtagProtocolError implements Exception {
  const JtagProtocolError(this.message);

  final String message;

  @override
  String toString() => 'JTAG protocol error: $message';
}

/// ESP USB JTAG command stream encoder/decoder.
final class EspUsbJtag {
  EspUsbJtag(this._wire);

  final JtagWire _wire;

  static const int _maxRepetitions = 1023; // 10-bit device repeat counter
  static const int _maxInFlightCaptureBits = (64 + 4) * 8;
  static const int _inEpBufferSize = 64;

  final List<int> _out = <int>[];
  bool _halfUsed = false;
  int _pendingInBits = 0;
  int _queuedCommand = -1;
  int _queuedReps = 0;

  final List<bool> _response = <bool>[];

  static int _clock({
    required bool tms,
    required bool tdi,
    required bool cap,
  }) =>
      (cap ? 4 : 0) | (tms ? 2 : 0) | (tdi ? 1 : 0);

  /// One TCK cycle with the given TMS/TDI; capture TDO when [cap].
  Future<void> shiftBit(bool tms, bool tdi, bool cap) async {
    if (cap && _pendingInBits >= _maxInFlightCaptureBits) {
      await _finalizeQueued();
      await _sendBuffer();
      await _receiveUntilDrained();
    }
    final command = _clock(tms: tms, tdi: tdi, cap: cap);
    if (_queuedCommand == command && _queuedReps < _maxRepetitions) {
      _queuedReps++;
      return;
    }
    await _finalizeQueued();
    _queuedCommand = command;
    _queuedReps = 0;
  }

  /// Assert/deassert SRST.
  Future<void> setReset(bool srst) async {
    await _finalizeQueued();
    _addRaw(8 | (srst ? 1 : 0));
    await flush();
  }

  Future<void> _finalizeQueued() async {
    if (_queuedCommand == -1) {
      return;
    }
    final command = _queuedCommand;
    final reps = _queuedReps;
    _queuedCommand = -1;
    _queuedReps = 0;

    final captures = command & 4 != 0;
    final newBits = reps + 1;
    if (captures && _pendingInBits + newBits > _maxInFlightCaptureBits) {
      await _sendBuffer();
      await _receiveUntilDrained();
    }
    _addRaw(command);
    var remaining = reps;
    while (remaining > 0) {
      _addRaw(0xC + (remaining & 3));
      remaining >>= 2;
    }
    if (captures) {
      _pendingInBits += newBits;
    }
  }

  void _addRaw(int nibble) {
    if (_halfUsed) {
      _out[_out.length - 1] |= nibble;
      _halfUsed = false;
    } else {
      _out.add(nibble << 4);
      _halfUsed = true;
    }
  }

  Future<void> _sendBuffer() async {
    if (_halfUsed) {
      // A fill nibble completes the byte; it also forces the device to
      // flush its capture byte, adding padding bits we must drain.
      _addRaw(0xA);
    }
    if (_out.isNotEmpty) {
      await _wire.write(Uint8List.fromList(_out));
      _out.clear();
    }
  }

  Future<void> _receiveUntilDrained() async {
    var emptyReads = 0;
    while (_pendingInBits > 0) {
      final want = (_pendingInBits + 7) ~/ 8;
      final chunk = await _wire.read(
        want < _inEpBufferSize ? want : _inEpBufferSize,
        const Duration(milliseconds: 500),
      );
      if (chunk.isEmpty) {
        // The device answers only once it has executed the queued
        // commands; a few short reads while it catches up are normal.
        if (++emptyReads > 8) {
          throw JtagProtocolError(
            'timeout reading capture data ($_pendingInBits bits pending)',
          );
        }
        continue;
      }
      emptyReads = 0;
      final bitsHere =
          _pendingInBits < chunk.length * 8 ? _pendingInBits : chunk.length * 8;
      for (var i = 0; i < bitsHere; i++) {
        _response.add(chunk[i >> 3] & (1 << (i & 7)) != 0);
      }
      _pendingInBits -= bitsHere;
    }
  }

  /// Send pending commands and drain captured bits.
  Future<void> flush() async {
    await _finalizeQueued();
    if (_out.isEmpty && _pendingInBits == 0) {
      return;
    }
    _addRaw(0xA); // Flush
    await _sendBuffer();
    await _receiveUntilDrained();
  }

  /// Flush and return all bits captured since the last call.
  Future<List<bool>> readCapturedBits() async {
    await flush();
    final out = List<bool>.of(_response);
    _response.clear();
    return out;
  }
}

/// JTAG TAP navigation helpers on top of [EspUsbJtag]. All scans start
/// and end in Run-Test/Idle.
final class JtagTap {
  JtagTap(this._jtag, {this.idleCycles = 1});

  final EspUsbJtag _jtag;

  /// Extra TCK cycles spent in Run-Test/Idle after each scan (from
  /// dtmcs.idle, bumped on busy responses).
  int idleCycles;

  /// Test-Logic-Reset (≥5 TMS=1 clocks), then to Run-Test/Idle.
  Future<void> tapReset() async {
    for (var i = 0; i < 5; i++) {
      await _jtag.shiftBit(true, true, false);
    }
    await _jtag.shiftBit(false, false, false);
    await _jtag.flush();
  }

  /// Shift [width] bits of [value] (LSB first) into IR.
  Future<void> shiftIr(int value, int width) async {
    // RTI → Select-DR → Select-IR → Capture-IR → Shift-IR
    await _jtag.shiftBit(true, false, false);
    await _jtag.shiftBit(true, false, false);
    await _jtag.shiftBit(false, false, false);
    await _jtag.shiftBit(false, false, false);
    for (var i = 0; i < width; i++) {
      final last = i == width - 1;
      await _jtag.shiftBit(last, value & (1 << i) != 0, false);
    }
    // Exit1-IR → Update-IR → RTI
    await _jtag.shiftBit(true, false, false);
    await _jtag.shiftBit(false, false, false);
    await _idle();
  }

  /// Shift [bits] (LSB first) into DR; returns captured TDO bits.
  Future<List<bool>> shiftDr(List<bool> bits) async {
    // RTI → Select-DR → Capture-DR → Shift-DR
    await _jtag.shiftBit(true, false, false);
    await _jtag.shiftBit(false, false, false);
    await _jtag.shiftBit(false, false, false);
    for (var i = 0; i < bits.length; i++) {
      final last = i == bits.length - 1;
      await _jtag.shiftBit(last, bits[i], true);
    }
    // Exit1-DR → Update-DR → RTI
    await _jtag.shiftBit(true, false, false);
    await _jtag.shiftBit(false, false, false);
    await _idle();
    final captured = await _jtag.readCapturedBits();
    return captured.sublist(0, bits.length);
  }

  /// IR then DR in one USB round trip; returns captured DR bits.
  Future<List<bool>> writeRegister(
    int ir,
    int irWidth,
    List<bool> drBits,
  ) async {
    // IR: RTI → Shift-IR
    await _jtag.shiftBit(true, false, false);
    await _jtag.shiftBit(true, false, false);
    await _jtag.shiftBit(false, false, false);
    await _jtag.shiftBit(false, false, false);
    for (var i = 0; i < irWidth; i++) {
      final last = i == irWidth - 1;
      await _jtag.shiftBit(last, ir & (1 << i) != 0, false);
    }
    // Exit1-IR → Update-IR → RTI → Select-DR → Capture-DR → Shift-DR
    await _jtag.shiftBit(true, false, false);
    await _jtag.shiftBit(false, false, false);
    await _jtag.shiftBit(true, false, false);
    await _jtag.shiftBit(false, false, false);
    await _jtag.shiftBit(false, false, false);
    for (var i = 0; i < drBits.length; i++) {
      final last = i == drBits.length - 1;
      await _jtag.shiftBit(last, drBits[i], true);
    }
    await _jtag.shiftBit(true, false, false);
    await _jtag.shiftBit(false, false, false);
    await _idle();
    final captured = await _jtag.readCapturedBits();
    return captured.sublist(0, drBits.length);
  }

  Future<void> _idle() async {
    for (var i = 0; i < idleCycles; i++) {
      await _jtag.shiftBit(false, false, false);
    }
  }
}

/// int → LSB-first bit list.
List<bool> bitsOf(int value, int width) => [
  for (var i = 0; i < width; i++) value & (1 << i) != 0,
];

/// LSB-first bit list → int.
int bitsToInt(List<bool> bits) {
  var value = 0;
  for (var i = bits.length - 1; i >= 0; i--) {
    value = (value << 1) | (bits[i] ? 1 : 0);
  }
  return value;
}
