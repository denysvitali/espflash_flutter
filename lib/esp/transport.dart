/// Transport abstraction between the ESP ROM protocol and the physical
/// serial link.
///
/// Everything above this interface (SLIP framing, commands, flash
/// sequencing) is pure Dart and unit-testable with a fake transport.
/// The production implementation is [AndroidUsbTransport] in
/// `lib/usb/android_usb_transport.dart`, backed by a Kotlin platform
/// channel around mik3y/usb-serial-for-android.
library;

abstract interface class EspTransport {
  /// Raw write to the serial port. Must not SLIP-encode; the caller
  /// frames data before writing.
  Future<void> write(List<int> data);

  /// Raw byte chunks arriving from the port, in order. The stream is a
  /// broadcast stream safe to listen to once (the connection layer owns
  /// the single subscription via [chunks]).
  Stream<List<int>> get chunks;

  /// Change the baud rate. No-op on USB-Serial-JTAG (CDC-ACM ignores
  /// baud); on UART bridges the transport must reconfigure itself after
  /// telling the chip to switch.
  Future<void> setBaud(int baud);

  Future<void> setDtr(bool value);

  Future<void> setRts(bool value);

  /// USB vendor ID of the attached device, if known.
  int? get vendorId;

  /// USB product ID of the attached device, if known.
  int? get productId;

  /// True when the device is Espressif's native USB-Serial-JTAG
  /// peripheral (303A:1001) rather than an external UART bridge.
  bool get isUsbJtag;

  Future<void> close();
}
