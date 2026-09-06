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

  /// Attachment-instance token (Android `UsbDevice.getDeviceName`).
  /// Invalid after disconnect; never a durable hardware identity.
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

/// Driver matching is enrichment, never evidence of raw attachment presence.
enum UsbProbeStatus { pending, supported, unsupported, error }

/// A raw attachment survives missing metadata, permission and probing errors.
final class UsbDiagnosticDevice {
  const UsbDiagnosticDevice({
    required this.deviceId,
    this.vendorId,
    this.productId,
    this.label,
    this.hasPermission,
    this.probeStatus = UsbProbeStatus.pending,
    this.probeError,
    this.fieldErrors = const {},
  });

  factory UsbDiagnosticDevice.fromMap(Map<Object?, Object?> map) =>
      UsbDiagnosticDevice(
        deviceId: map['deviceId'] as String,
        vendorId: (map['vendorId'] as num?)?.toInt(),
        productId: (map['productId'] as num?)?.toInt(),
        label: map['label'] as String?,
        hasPermission: map['hasPermission'] as bool?,
        probeStatus: UsbProbeStatus.values.byName(map['probeStatus'] as String),
        probeError: map['probeError'] as String?,
        fieldErrors:
            (map['fieldErrors'] as Map<Object?, Object?>?)
                ?.cast<String, String>() ??
            const {},
      );

  final String deviceId;
  final int? vendorId;
  final int? productId;
  final String? label;
  final bool? hasPermission;
  final UsbProbeStatus probeStatus;
  final String? probeError;
  final Map<String, String> fieldErrors;

  bool get hasSerialDriver => probeStatus == UsbProbeStatus.supported;

  /// Available only after the necessary metadata was read successfully.
  UsbDevice? get device {
    final vendor = vendorId;
    final product = productId;
    if (vendor == null || product == null) return null;
    return UsbDevice(
      deviceId: deviceId,
      vendorId: vendor,
      productId: product,
      label: label ?? '',
    );
  }
}
