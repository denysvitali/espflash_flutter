/// Platform-channel names shared between Dart and the Kotlin side.
///
/// Kotlin must use the exact same strings; they are the contract between
/// `MainActivity`/`UsbSerialManager` and `AndroidUsbTransport`.
library;

abstract final class UsbChannels {
  /// Method channel: listDevices, hasPermission, requestPermission,
  /// open, close, write, setBaud, setDtr, setRts.
  static const String methods = 'espflash_flutter/usb';

  /// Event channel: device/permission lifecycle events.
  static const String events = 'espflash_flutter/usb/events';

  /// Event channel: raw serial byte chunks (List<int>).
  static const String data = 'espflash_flutter/usb/data';
}
