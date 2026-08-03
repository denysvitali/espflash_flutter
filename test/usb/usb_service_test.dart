import 'dart:async';
import 'dart:typed_data';

import 'package:espflash_flutter/esp/errors.dart';
import 'package:espflash_flutter/usb/usb_device.dart';
import 'package:espflash_flutter/usb/usb_events.dart';
import 'package:espflash_flutter/usb/usb_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_usb_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const UsbDevice device = UsbDevice(
    deviceId: '/dev/bus/usb/001/002',
    vendorId: 0x303A,
    productId: 0x1001,
    label: 'USB-Serial-JTAG',
  );

  late FakeUsbPlatform fake;
  late UsbService service;

  setUp(() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    fake = FakeUsbPlatform(messenger)..install();
    service = UsbService();
  });

  tearDown(() => fake.uninstall());

  group('method channel', () {
    test('listDevices parses device maps', () async {
      fake.devices = <Object?>[
        <String, Object?>{
          'deviceId': '/dev/bus/usb/001/002',
          'vendorId': 0x303A,
          'productId': 0x1001,
          'label': 'USB-Serial-JTAG',
        },
        <String, Object?>{
          'deviceId': '/dev/bus/usb/001/003',
          'vendorId': 0x10C4,
          'productId': 0xEA60,
          'label': null,
        },
      ];
      final List<UsbDevice> devices = await service.listDevices();
      expect(devices, hasLength(2));
      expect(devices[0].isUsbJtag, isTrue);
      expect(devices[0].label, 'USB-Serial-JTAG');
      expect(devices[1].isUsbJtag, isFalse);
      expect(devices[1].label, '');
      expect(fake.calls.single.method, 'listDevices');
    });

    test('hasPermission forwards deviceId and returns platform answer',
        () async {
      fake.permission = false;
      expect(await service.hasPermission(device), isFalse);
      final MethodCall call = fake.calls.single;
      expect(call.method, 'hasPermission');
      expect(
        call.arguments,
        <String, Object?>{'deviceId': '/dev/bus/usb/001/002'},
      );
    });

    test('requestPermission forwards deviceId', () async {
      await service.requestPermission(device);
      final MethodCall call = fake.calls.single;
      expect(call.method, 'requestPermission');
      expect(
        call.arguments,
        <String, Object?>{'deviceId': '/dev/bus/usb/001/002'},
      );
    });

    test('open forwards deviceId', () async {
      await service.open(device);
      final MethodCall call = fake.calls.single;
      expect(call.method, 'open');
      expect(
        call.arguments,
        <String, Object?>{'deviceId': '/dev/bus/usb/001/002'},
      );
    });

    test('close takes no arguments', () async {
      await service.close();
      final MethodCall call = fake.calls.single;
      expect(call.method, 'close');
      expect(call.arguments, isNull);
    });

    test('write sends bytes as a byte buffer', () async {
      await service.write(<int>[0xC0, 0x00, 0x08, 0xC0]);
      final MethodCall call = fake.calls.single;
      expect(call.method, 'write');
      final Map<Object?, Object?> args =
          call.arguments as Map<Object?, Object?>;
      expect(args['bytes'], isA<Uint8List>());
      expect(args['bytes'], <int>[0xC0, 0x00, 0x08, 0xC0]);
    });

    test('setBaud/setDtr/setRts forward their arguments', () async {
      await service.setBaud(921600);
      await service.setDtr(true);
      await service.setRts(false);
      expect(
        fake.calls.map((MethodCall c) => c.method),
        <String>['setBaud', 'setDtr', 'setRts'],
      );
      expect(
        fake.callFor('setBaud').arguments,
        <String, Object?>{'baud': 921600},
      );
      expect(
        fake.callFor('setDtr').arguments,
        <String, Object?>{'value': true},
      );
      expect(
        fake.callFor('setRts').arguments,
        <String, Object?>{'value': false},
      );
    });
  });

  group('error mapping', () {
    test('write failure surfaces as EspDeviceLostError', () async {
      fake.errors['write'] =
          PlatformException(code: 'writeFailed', message: 'gone');
      await expectLater(
        service.write(<int>[1]),
        throwsA(isA<EspDeviceLostError>()),
      );
    });

    test('open of a vanished device surfaces as EspDeviceLostError',
        () async {
      fake.errors['open'] =
          PlatformException(code: 'notFound', message: 'not attached');
      await expectLater(
        service.open(device),
        throwsA(isA<EspDeviceLostError>()),
      );
    });

    test('setBaud on a closed port surfaces as EspDeviceLostError',
        () async {
      fake.errors['setBaud'] = PlatformException(code: 'notOpen');
      await expectLater(
        service.setBaud(115200),
        throwsA(isA<EspDeviceLostError>()),
      );
    });

    test('unknown platform errors are rethrown unchanged', () async {
      fake.errors['setBaud'] =
          PlatformException(code: 'usbError', message: 'boom');
      await expectLater(
        service.setBaud(115200),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('event channels', () {
    test('events stream parses lifecycle maps in order', () async {
      final List<UsbEvent> received = <UsbEvent>[];
      final StreamSubscription<UsbEvent> sub =
          service.events.listen(received.add);
      await fake.emitEvent(<String, Object?>{
        'type': 'attached',
        'deviceId': '/dev/bus/usb/001/002',
        'vendorId': 0x303A,
        'productId': 0x1001,
      });
      await fake.emitEvent(<String, Object?>{
        'type': 'permissionGranted',
        'deviceId': '/dev/bus/usb/001/002',
        'vendorId': 0x303A,
        'productId': 0x1001,
      });
      await fake.emitEvent(<String, Object?>{
        'type': 'detached',
        'deviceId': '/dev/bus/usb/001/002',
        'vendorId': 0x303A,
        'productId': 0x1001,
      });
      await pumpEventQueue();
      expect(received, <UsbEvent>[
        const UsbDeviceAttached(
          deviceId: '/dev/bus/usb/001/002',
          vendorId: 0x303A,
          productId: 0x1001,
        ),
        const UsbPermissionGranted(
          deviceId: '/dev/bus/usb/001/002',
          vendorId: 0x303A,
          productId: 0x1001,
        ),
        const UsbDeviceDetached(
          deviceId: '/dev/bus/usb/001/002',
          vendorId: 0x303A,
          productId: 0x1001,
        ),
      ]);
      await sub.cancel();
    });

    test('events getter returns the same broadcast stream', () {
      expect(identical(service.events, service.events), isTrue);
    });

    test('data stream delivers raw chunks in order', () async {
      final List<Uint8List> chunks = <Uint8List>[];
      final StreamSubscription<Uint8List> sub =
          service.data.listen(chunks.add);
      await fake.emitData(Uint8List.fromList(<int>[1, 2, 3]));
      await fake.emitData(Uint8List.fromList(<int>[0xC0, 0xDB]));
      await pumpEventQueue();
      expect(chunks, <List<int>>[
        <int>[1, 2, 3],
        <int>[0xC0, 0xDB],
      ]);
      await sub.cancel();
    });
  });
}
