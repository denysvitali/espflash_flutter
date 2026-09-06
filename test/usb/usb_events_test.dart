import 'package:espflash_flutter/usb/usb_events.dart';
import 'package:espflash_flutter/usb/usb_device.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsbEvent.fromMap', () {
    test('raw roster does not require device metadata or probe result', () {
      final event =
          UsbEvent.fromMap({
                'type': 'snapshot',
                'epoch': 4,
                'sequence': 1,
                'stage': 'raw',
                'status': 'ok',
                'devices': [
                  {'deviceId': 'raw', 'probeStatus': 'pending'},
                ],
              })
              as UsbSnapshot;
      expect(event.epoch, 4);
      expect(event.devices.single.deviceId, 'raw');
      expect(event.devices.single.device, isNull);
      expect(event.devices.single.hasPermission, isNull);
      expect(event.devices.single.probeStatus, UsbProbeStatus.pending);
    });

    test(
      'enumeration failure has no roster and differs from successful empty',
      () {
        final error =
            UsbEvent.fromMap({
                  'type': 'snapshot',
                  'epoch': 4,
                  'sequence': 2,
                  'stage': 'raw',
                  'status': 'error',
                  'scanError': 'host error',
                })
                as UsbSnapshot;
        expect(error.status, UsbScanStatus.error);
        expect(error.scanError, 'host error');
        final empty =
            UsbEvent.fromMap({
                  'type': 'snapshot',
                  'epoch': 4,
                  'sequence': 3,
                  'stage': 'raw',
                  'status': 'ok',
                  'devices': [],
                })
                as UsbSnapshot;
        expect(empty.status, UsbScanStatus.ok);
        expect(empty.devices, isEmpty);
      },
    );

    test('per-device probe and optional field errors survive decoding', () {
      final event =
          UsbEvent.fromMap({
                'type': 'snapshot',
                'epoch': 4,
                'sequence': 1,
                'stage': 'enriched',
                'status': 'ok',
                'devices': [
                  {
                    'deviceId': 'raw',
                    'probeStatus': 'error',
                    'probeError': 'broken descriptor',
                    'label': null,
                    'fieldErrors': {'label': 'permission required'},
                  },
                ],
              })
              as UsbSnapshot;
      expect(event.devices.single.probeStatus, UsbProbeStatus.error);
      expect(event.devices.single.probeError, 'broken descriptor');
      expect(event.devices.single.fieldErrors['label'], 'permission required');
    });

    test('parses attached', () {
      final UsbEvent event = UsbEvent.fromMap(const <String, Object?>{
        'type': 'attached',
        'deviceId': '/dev/bus/usb/001/002',
        'vendorId': 0x303A,
        'productId': 0x1001,
      });
      expect(event, isA<UsbDeviceAttached>());
      expect((event as UsbDeviceEvent).deviceId, '/dev/bus/usb/001/002');
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
            const UsbDeviceDetached(deviceId: 'dev', vendorId: 1, productId: 2),
        isFalse,
      );
    });
  });
}
