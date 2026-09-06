import 'dart:async';

import 'package:espflash_flutter/esp/errors.dart';
import 'package:espflash_flutter/ui/device_session.dart';
import 'package:espflash_flutter/usb/usb_device.dart';
import 'package:espflash_flutter/usb/usb_events.dart';
import 'package:espflash_flutter/usb/usb_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const device = UsbDevice(deviceId: 'old', vendorId: 0x303a, productId: 0x1001);
const replacement = UsbDevice(
  deviceId: 'new',
  vendorId: 0x303a,
  productId: 0x1001,
);

UsbDiagnosticDevice diagnostic(UsbDevice device, {bool supported = true}) =>
    UsbDiagnosticDevice(
      device: device,
      hasPermission: true,
      hasSerialDriver: supported,
    );

class SessionUsb extends UsbService {
  final controller = StreamController<UsbEvent>.broadcast(sync: true);
  List<UsbDiagnosticDevice> raw = [diagnostic(device)];
  final opened = <String>[];
  final requests = <String>[];
  bool permission = true;
  int openFailures = 0;
  int scans = 0;
  Completer<List<UsbDiagnosticDevice>>? delayedRaw;
  Completer<bool>? delayedPermission;

  @override
  Stream<UsbEvent> get events => controller.stream;
  @override
  Future<void> reconcileUsb() async {
    scans++;
  }

  @override
  Future<List<UsbDiagnosticDevice>> listRawDevices() async =>
      delayedRaw == null ? raw : delayedRaw!.future;
  @override
  Future<List<UsbDevice>> listDevices() async =>
      raw.where((d) => d.hasSerialDriver).map((d) => d.device).toList();
  @override
  Future<bool> hasPermission(UsbDevice device) async =>
      delayedPermission == null ? permission : delayedPermission!.future;
  @override
  Future<void> requestPermission(UsbDevice device) async {
    requests.add(device.deviceId);
  }

  @override
  Future<void> open(UsbDevice device) async {
    opened.add(device.deviceId);
    if (openFailures-- > 0) throw PlatformException(code: 'openFailed');
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> jtagClose() async {}

  void snapshot(List<UsbDiagnosticDevice> devices) {
    raw = devices;
    controller.add(UsbSnapshot(raw));
  }

  void grant(String id) => controller.add(
    UsbPermissionGranted(
      deviceId: id,
      vendorId: device.vendorId,
      productId: device.productId,
    ),
  );
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  late SessionUsb usb;
  late ProviderContainer container;
  late DeviceSession session;

  setUp(() async {
    usb = SessionUsb();
    container = ProviderContainer(
      overrides: [usbServiceProvider.overrideWithValue(usb)],
    );
    session = container.read(deviceSessionProvider.notifier);
    await session.refreshDevices();
  });
  tearDown(() async {
    container.dispose();
    await flush();
    await usb.controller.close();
  });

  test('late enumeration replaces empty state without an attach event', () {
    usb.snapshot([]);
    expect(container.read(deviceSessionProvider).devices, isEmpty);
    expect(
      container.read(deviceSessionProvider).error,
      contains('No USB device'),
    );
    usb.snapshot([diagnostic(replacement)]);
    expect(container.read(deviceSessionProvider).selectedDeviceId, 'new');
    expect(container.read(deviceSessionProvider).error, isNull);
  });

  test('raw unsupported peripheral is distinguished from empty host', () {
    usb.snapshot([diagnostic(device, supported: false)]);
    final state = container.read(deviceSessionProvider);
    expect(state.devices, isEmpty);
    expect(state.error, contains('no supported serial driver'));
  });

  test('old refresh cannot overwrite a newer platform snapshot', () async {
    usb.delayedRaw = Completer<List<UsbDiagnosticDevice>>();
    final refresh = session.refreshDevices();
    await flush();
    usb.snapshot([diagnostic(replacement)]);
    usb.delayedRaw!.complete([diagnostic(device)]);
    await refresh;
    expect(container.read(deviceSessionProvider).selectedDeviceId, 'new');
  });

  test(
    'permission is instance-specific and duplicate callbacks are harmless',
    () async {
      usb.permission = false;
      final connect = session.connect();
      await flush();
      await session.connect();
      expect(usb.requests, ['old']);
      usb.grant('other');
      await flush();
      expect(usb.opened, isEmpty);
      usb.permission = true;
      usb.grant('old');
      usb.grant('old');
      await connect;
      expect(usb.opened, ['old']);
      expect(container.read(deviceSessionProvider).isConnected, isTrue);
    },
  );

  test(
    're-enumeration during permission cancels stale open and selects new instance',
    () async {
      usb.permission = false;
      final connect = session.connect();
      final failed = expectLater(
        connect,
        throwsA(isA<EspPermissionDeniedError>()),
      );
      await flush();
      usb.snapshot([diagnostic(replacement)]);
      usb.permission = true;
      usb.grant('old');
      await failed;
      expect(usb.opened, isEmpty);
      expect(container.read(deviceSessionProvider).selectedDeviceId, 'new');
      await session.connect();
      expect(usb.opened, ['new']);
    },
  );

  test(
    'permission grant re-enumerates even when detach notification is missed',
    () async {
      usb.permission = false;
      final connect = session.connect();
      final failed = expectLater(connect, throwsA(isA<EspDeviceLostError>()));
      await flush();
      usb.raw = [diagnostic(replacement)];
      usb.permission = true;
      usb.grant('old');
      await failed;
      expect(usb.opened, isEmpty);
    },
  );

  test('snapshot detects missed detach and releases active session', () async {
    await session.connect();
    session.claim(DeviceActivity.monitoring);
    final lost = session.onDeviceLost.first;
    usb.snapshot([]);
    await lost;
    expect(container.read(deviceSessionProvider).isConnected, isFalse);
    expect(container.read(deviceSessionProvider).activity, DeviceActivity.none);
  });

  test('does not automatically select one of multiple matching adapters', () {
    usb.snapshot([]);
    usb.snapshot([diagnostic(device), diagnostic(replacement)]);
    expect(container.read(deviceSessionProvider).selectedDeviceId, isNull);
  });

  test(
    'disconnect while permission lookup is pending cannot launch a dialog',
    () async {
      usb.delayedPermission = Completer<bool>();
      final connect = session.connect();
      final failed = expectLater(connect, throwsA(isA<EspDeviceLostError>()));
      await flush();
      await session.disconnect();
      usb.delayedPermission!.complete(false);
      await failed;
      expect(usb.requests, isEmpty);
      expect(usb.opened, isEmpty);
    },
  );

  test(
    'transient open failure retries the current permitted attachment',
    () async {
      usb.openFailures = 1;
      await session.connect();
      expect(usb.opened, ['old', 'old']);
      expect(container.read(deviceSessionProvider).isConnected, isTrue);
    },
  );

  test('persistent open failure stops after five attempts', () async {
    usb.openFailures = 10;
    await expectLater(session.connect(), throwsA(isA<PlatformException>()));
    expect(usb.opened, hasLength(5));
    expect(container.read(deviceSessionProvider).isConnected, isFalse);
  });

  test(
    'dispose during permission lookup prevents further USB operations',
    () async {
      usb.delayedPermission = Completer<bool>();
      final connect = session.connect();
      final failed = expectLater(connect, throwsA(isA<EspDeviceLostError>()));
      await flush();
      container.dispose();
      usb.delayedPermission!.complete(false);
      await failed;
      expect(usb.requests, isEmpty);
      expect(usb.opened, isEmpty);
    },
  );
}
