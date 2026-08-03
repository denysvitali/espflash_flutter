/// Device/permission lifecycle events emitted by the Android USB layer on
/// the `espflash_flutter/usb/events` EventChannel.
library;

/// One lifecycle event: a device was attached/detached or a permission
/// request was granted/denied.
sealed class UsbEvent {
  const UsbEvent({
    required this.deviceId,
    required this.vendorId,
    required this.productId,
  });

  /// Parses the map shape emitted by the Kotlin `UsbSerialManager`.
  ///
  /// Throws [FormatException] for unknown or malformed events so a
  /// platform-side contract drift fails loudly instead of dropping
  /// silently into the UI state machine.
  factory UsbEvent.fromMap(Map<Object?, Object?> map) {
    final deviceId = map['deviceId'] as String;
    final vendorId = map['vendorId'] as int;
    final productId = map['productId'] as int;
    switch (map['type']) {
      case 'attached':
        return UsbDeviceAttached(
          deviceId: deviceId,
          vendorId: vendorId,
          productId: productId,
        );
      case 'detached':
        return UsbDeviceDetached(
          deviceId: deviceId,
          vendorId: vendorId,
          productId: productId,
        );
      case 'permissionGranted':
        return UsbPermissionGranted(
          deviceId: deviceId,
          vendorId: vendorId,
          productId: productId,
        );
      case 'permissionDenied':
        return UsbPermissionDenied(
          deviceId: deviceId,
          vendorId: vendorId,
          productId: productId,
        );
      default:
        throw FormatException('Unknown USB event type: ${map['type']}');
    }
  }

  /// Platform identifier (Android `UsbDevice.getDeviceName`).
  final String deviceId;

  final int vendorId;

  final int productId;

  @override
  bool operator ==(Object other) =>
      other is UsbEvent &&
      other.runtimeType == runtimeType &&
      other.deviceId == deviceId &&
      other.vendorId == vendorId &&
      other.productId == productId;

  @override
  int get hashCode => Object.hash(runtimeType, deviceId, vendorId, productId);
}

/// A USB device was plugged in, or the app was launched by the
/// USB_DEVICE_ATTACHED intent.
final class UsbDeviceAttached extends UsbEvent {
  const UsbDeviceAttached({
    required super.deviceId,
    required super.vendorId,
    required super.productId,
  });

  @override
  String toString() => 'UsbDeviceAttached($deviceId)';
}

/// A USB device was unplugged (or re-enumerated, which shows up as
/// detached followed by attached).
final class UsbDeviceDetached extends UsbEvent {
  const UsbDeviceDetached({
    required super.deviceId,
    required super.vendorId,
    required super.productId,
  });

  @override
  String toString() => 'UsbDeviceDetached($deviceId)';
}

/// The user granted USB permission for the device.
final class UsbPermissionGranted extends UsbEvent {
  const UsbPermissionGranted({
    required super.deviceId,
    required super.vendorId,
    required super.productId,
  });

  @override
  String toString() => 'UsbPermissionGranted($deviceId)';
}

/// The user denied (or dismissed) the USB permission dialog.
final class UsbPermissionDenied extends UsbEvent {
  const UsbPermissionDenied({
    required super.deviceId,
    required super.vendorId,
    required super.productId,
  });

  @override
  String toString() => 'UsbPermissionDenied($deviceId)';
}
