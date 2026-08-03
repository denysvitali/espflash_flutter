import 'package:espflash_flutter/usb/usb_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsbEvent.fromMap', () {
    test('parses attached', () {
      final UsbEvent event = UsbEvent.fromMap(const <String, Object?>{
        'type': 'attached',
        'deviceId': '/dev/bus/usb/001/002',
        'vendorId': 0x303A,
        'productId': 0x1001,
      });
      expect(event, isA<UsbDeviceAttached>());
      expect(event.deviceId, '/dev/bus/usb/001/002');
      expect(event.vendorId, 0x303A);
      expect(event.productId, 0x1001);
    });

    test('parses detached', () {
      final UsbEvent event = UsbEvent.fromMap(const <String, Object?>{
        'type': 'detached',
        'deviceId': '/dev/bus/usb/001/002',
        'vendorId': 0x303A,
        'productId': 0x1001,
      });
      expect(event, isA<UsbDeviceDetached>());
    });

    test('parses permissionGranted', () {
      final UsbEvent event = UsbEvent.fromMap(const <String, Object?>{
        'type': 'permissionGranted',
        'deviceId': 'dev',
        'vendorId': 1,
        'productId': 2,
      });
      expect(event, isA<UsbPermissionGranted>());
    });

    test('parses permissionDenied', () {
      final UsbEvent event = UsbEvent.fromMap(const <String, Object?>{
        'type': 'permissionDenied',
        'deviceId': 'dev',
        'vendorId': 1,
        'productId': 2,
      });
      expect(event, isA<UsbPermissionDenied>());
    });

    test('unknown type throws FormatException', () {
      expect(
        () => UsbEvent.fromMap(const <String, Object?>{
          'type': 'exploded',
          'deviceId': 'dev',
          'vendorId': 1,
          'productId': 2,
        }),
        throwsFormatException,
      );
    });

    test('missing type throws FormatException', () {
      expect(
        () => UsbEvent.fromMap(const <String, Object?>{
          'deviceId': 'dev',
          'vendorId': 1,
          'productId': 2,
        }),
        throwsFormatException,
      );
    });
  });

  group('equality', () {
    test('same type and fields are equal', () {
      expect(
        const UsbDeviceAttached(
          deviceId: 'dev',
          vendorId: 0x303A,
          productId: 0x1001,
        ),
        const UsbDeviceAttached(
          deviceId: 'dev',
          vendorId: 0x303A,
          productId: 0x1001,
        ),
      );
    });

    test('different subtypes are not equal', () {
      expect(
        const UsbDeviceAttached(deviceId: 'dev', vendorId: 1, productId: 2) ==
            const UsbDeviceDetached(
              deviceId: 'dev',
              vendorId: 1,
              productId: 2,
            ),
        isFalse,
      );
    });
  });
}
