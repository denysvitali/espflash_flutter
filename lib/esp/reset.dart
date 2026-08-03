/// Reset strategies that put the chip into the ROM bootloader using
/// the DTR/RTS control lines.
///
/// Sequences mirror IMPLEMENTATION_PLAN.md section 3 (derived from
/// esp-pylib `serial_reset.py`). Sleep is injectable so tests can
/// record the exact timing without waiting.
library;

import 'transport.dart';

/// Signature for the delay between line transitions.
typedef SleepFn = Future<void> Function(Duration duration);

/// Real-clock sleep used outside tests.
Future<void> defaultSleep(Duration duration) =>
    Future<void>.delayed(duration);

/// Base class for all reset strategies.
sealed class ResetStrategy {
  const ResetStrategy({SleepFn? sleep}) : _sleep = sleep;

  final SleepFn? _sleep;

  /// Delay function; [defaultSleep] unless injected.
  SleepFn get sleep => _sleep ?? defaultSleep;

  /// Run the reset sequence against [transport].
  Future<void> reset(EspTransport transport);
}

/// Classic bootloader entry for boards with an auto-reset circuit
/// (UART bridges): `D0 R1 W100 D1 R0 W50 D0`.
final class ClassicReset extends ResetStrategy {
  const ClassicReset({
    this.resetDelay = const Duration(milliseconds: 50),
    super.sleep,
  });

  /// Delay between releasing reset and sampling IO0.
  final Duration resetDelay;

  @override
  Future<void> reset(EspTransport transport) async {
    await transport.setDtr(false); // IO0 = HIGH
    await transport.setRts(true); // EN = LOW, chip in reset
    await sleep(const Duration(milliseconds: 100));
    await transport.setDtr(true); // IO0 = LOW (bootloader)
    await transport.setRts(false); // EN = HIGH, chip out of reset
    await sleep(resetDelay);
    await transport.setDtr(false); // IO0 = HIGH again
  }
}

/// Reset sequence for chips connected through their native
/// USB-Serial-JTAG peripheral, as specced in the implementation plan.
final class UsbJtagReset extends ResetStrategy {
  const UsbJtagReset({super.sleep});

  @override
  Future<void> reset(EspTransport transport) async {
    await transport.setRts(true);
    await transport.setDtr(true);
    await sleep(const Duration(milliseconds: 100));
    await transport.setDtr(false);
    await transport.setRts(true);
    await sleep(const Duration(milliseconds: 100));
    await transport.setRts(false);
    await transport.setDtr(true);
    await transport.setRts(false);
    await sleep(const Duration(milliseconds: 100));
    await transport.setDtr(false); // DTR false -> true
    await transport.setDtr(true);
    await transport.setRts(false); // RTS false -> true
    await transport.setRts(true);
  }
}

/// Pulse EN via RTS to restart the chip (post-flash reboot on
/// bridge-connected boards): hold RTS low for 100 ms.
final class HardReset extends ResetStrategy {
  const HardReset({super.sleep});

  @override
  Future<void> reset(EspTransport transport) async {
    await transport.setRts(true); // EN = LOW
    await sleep(const Duration(milliseconds: 100));
    await transport.setRts(false); // EN = HIGH, chip restarts
  }
}
