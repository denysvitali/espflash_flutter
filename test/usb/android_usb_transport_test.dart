import 'dart:async';
import 'dart:typed_data';

import 'package:espflash_flutter/esp/errors.dart';
import 'package:espflash_flutter/esp/transport.dart';
import 'package:espflash_flutter/usb/android_usb_transport.dart';
import 'package:espflash_flutter/usb/usb_device.dart';
import 'package:espflash_flutter/usb/usb_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_usb_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const UsbDevice jtagDevice = UsbDevice(
    deviceId: '/dev/bus/usb/001/002',
    vendorId: 0x303A,
    productId: 0x1001,
    label: 'USB-Serial-JTAG',
  );

  const UsbDevice bridgeDevice = UsbDevice(
    deviceId: '/dev/bus/usb/001/003',
    vendorId: 0x10C4,
    productId: 0xEA60,
    label: 'CP2102',
  );

  late FakeUsbPlatform fake;
  late UsbService service;
  late AndroidUsbTransport transport;

  setUp(() {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    fake = FakeUsbPlatform(messenger)..install();
    service = UsbService();
    transport = AndroidUsbTransport(service: service, device: jtagDevice);
  });

  tearDown(() => fake.uninstall());

  test('implements EspTransport', () {
    expect(transport, isA<EspTransport>());
  });

  test('exposes device identity', () {
    expect(transport.vendorId, 0x303A);
    expect(transport.productId, 0x1001);
    expect(transport.isUsbJtag, isTrue);
    expect(transport.device, jtagDevice);
  });

  test('external UART bridge is not USB-JTAG', () {
    final AndroidUsbTransport bridge =
        AndroidUsbTransport(service: service, device: bridgeDevice);
    expect(bridge.vendorId, 0x10C4);
    expect(bridge.productId, 0xEA60);
    expect(bridge.isUsbJtag, isFalse);
  });

  test('write forwards SLIP-framed bytes untouched', () async {
    await transport.write(<int>[0xC0, 0x00, 0x08, 0x24, 0x00, 0xC0]);
    final MethodCall call = fake.calls.single;
    expect(call.method, 'write');
    final Map<Object?, Object?> args =
        call.arguments as Map<Object?, Object?>;
    expect(args['bytes'], isA<Uint8List>());
    expect(args['bytes'], <int>[0xC0, 0x00, 0x08, 0x24, 0x00, 0xC0]);
  });

  test('write failure surfaces as EspDeviceLostError', () async {
    fake.errors['write'] = PlatformException(code: 'writeFailed');
    await expectLater(
      transport.write(<int>[1, 2]),
      throwsA(isA<EspDeviceLostError>()),
    );
  });

  test('setBaud/setDtr/setRts pass through with arguments', () async {
    await transport.setBaud(921600);
    await transport.setDtr(true);
    await transport.setRts(false);
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

  test('chunks delivers platform data in order', () async {
    final List<int> received = <int>[];
    final StreamSubscription<List<int>> sub =
        transport.chunks.listen(received.addAll);
    await fake.emitData(Uint8List.fromList(<int>[0xC0, 0x01]));
    await fake.emitData(Uint8List.fromList(<int>[0x08, 0x00, 0xC0]));
    await pumpEventQueue();
    expect(received, <int>[0xC0, 0x01, 0x08, 0x00, 0xC0]);
    await sub.cancel();
  });

  test('close closes the platform port', () async {
    await transport.close();
    expect(fake.calls.single.method, 'close');
  });
}
