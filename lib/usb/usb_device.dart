/// Immutable description of one USB serial device exposed by the Android
/// USB host stack.
library;

/// One USB serial device visible to the Android USB host stack.
///
/// [deviceId] is the platform identifier the Kotlin side accepts in
/// `open`, `hasPermission` and `requestPermission`.
class UsbDevice {
  const UsbDevice({
    required this.deviceId,
    required this.vendorId,
    required this.productId,
    this.label = '',
  });

  /// Parses the map shape produced by `UsbSerialManager.listDevices`.
  factory UsbDevice.fromMap(Map<Object?, Object?> map) {
    return UsbDevice(
      deviceId: map['deviceId'] as String,
      vendorId: map['vendorId'] as int,
      productId: map['productId'] as int,
      label: (map['label'] as String?) ?? '',
    );
  }

  /// Platform identifier (Android `UsbDevice.getDeviceName`).
  final String deviceId;

  final int vendorId;

  final int productId;

  /// Human-readable name, best effort (`UsbDevice.getProductName`).
  final String label;

  /// True for Espressif's native USB-Serial-JTAG peripheral (303A:1001),
  /// as opposed to an external UART bridge (CP210x, CH340, FTDI, ...).
  bool get isUsbJtag => vendorId == 0x303A && productId == 0x1001;

  @override
  bool operator ==(Object other) =>
      other is UsbDevice &&
      other.deviceId == deviceId &&
      other.vendorId == vendorId &&
      other.productId == productId &&
      other.label == label;

  @override
  int get hashCode => Object.hash(deviceId, vendorId, productId, label);

  @override
  String toString() =>
      'UsbDevice($deviceId, ${vendorId.toRadixString(16)}:'
      '${productId.toRadixString(16)}, $label)';
}
