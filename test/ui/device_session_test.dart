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
      deviceId: device.deviceId,
      vendorId: device.vendorId,
      productId: device.productId,
      hasPermission: true,
      probeStatus: supported
          ? UsbProbeStatus.supported
          : UsbProbeStatus.unsupported,
    );

class SessionUsb extends UsbService {
  final controller = StreamController<UsbEvent>.broadcast(sync: true);
  List<UsbDiagnosticDevice> raw = [diagnostic(device)];
  final opened = <String>[];
  final requests = <String>[];
  bool permission = true;
  int openFailures = 0;
  int scans = 0;
  int epoch = 1;
  int sequence = 0;
  Completer<bool>? delayedPermission;

  @override
  Stream<UsbEvent> get events => controller.stream;
  @override
  Future<void> reconcileUsb() async {
    scans++;
    snapshot(raw);
  }

  @override
  Future<UsbSnapshot> listRawDevices() async => UsbSnapshot(
    raw,
    epoch: epoch,
    sequence: ++sequence,
    stage: UsbScanStage.raw,
  );
  @override
  Future<List<UsbDevice>> listDevices() async =>
      raw.where((d) => d.hasSerialDriver).map((d) => d.device!).toList();
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
    controller.add(
      UsbSnapshot(
        raw,
        epoch: epoch,
        sequence: ++sequence,
        stage: UsbScanStage.enriched,
      ),
    );
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

  test('old enrichment cannot overwrite a newer raw attachment', () {
    final oldSequence = usb.sequence;
    usb.snapshot([diagnostic(replacement)]);
    usb.controller.add(
      UsbSnapshot(
        [diagnostic(device)],
        epoch: usb.epoch,
        sequence: oldSequence,
        stage: UsbScanStage.enriched,
      ),
    );
    expect(container.read(deviceSessionProvider).selectedDeviceId, 'new');
  });

  test(
    'scan errors preserve connected device and mark last observation stale',
    () async {
      await session.connect();
      usb.controller.add(
        UsbSnapshot(
          const [],
          epoch: usb.epoch,
          sequence: ++usb.sequence,
          stage: UsbScanStage.raw,
          status: UsbScanStatus.error,
          scanError: 'SecurityException: host query',
        ),
      );
      final state = container.read(deviceSessionProvider);
      expect(state.isConnected, isTrue);
      expect(state.selectedDeviceId, 'old');
      expect(state.rawDevices.single.deviceId, 'old');
      expect(state.observationStale, isTrue);
      expect(state.observationError, contains('host query'));
      usb.snapshot([]);
      expect(container.read(deviceSessionProvider).isConnected, isFalse);
      expect(container.read(deviceSessionProvider).observationStale, isFalse);
    },
  );

  test('raw-only roster and probe error cannot manufacture a detach', () async {
    await session.connect();
    usb.controller.add(
      UsbSnapshot(
        const [UsbDiagnosticDevice(deviceId: 'old')],
        epoch: usb.epoch,
        sequence: ++usb.sequence,
        stage: UsbScanStage.raw,
      ),
    );
    expect(container.read(deviceSessionProvider).isConnected, isTrue);
    expect(container.read(deviceSessionProvider).selectedDeviceId, 'old');
    usb.controller.add(
      UsbSnapshot(
        const [
          UsbDiagnosticDevice(
            deviceId: 'old',
            probeStatus: UsbProbeStatus.error,
            probeError: 'bad descriptor',
          ),
        ],
        epoch: usb.epoch,
        sequence: usb.sequence,
        stage: UsbScanStage.enriched,
      ),
    );
    final state = container.read(deviceSessionProvider);
    expect(state.isConnected, isTrue);
    expect(state.selectedDeviceId, 'old');
    expect(state.rawDevices.single.probeError, 'bad descriptor');
  });

  test(
    'probe failure on a newly seen device is explicit, not an empty host',
    () {
      usb.snapshot([]);
      usb.snapshot(const [
        UsbDiagnosticDevice(
          deviceId: 'new',
          probeStatus: UsbProbeStatus.error,
          probeError: 'bad descriptor',
        ),
      ]);
      final state = container.read(deviceSessionProvider);
      expect(state.rawDevices.single.deviceId, 'new');
      expect(state.devices, isEmpty);
      expect(state.error, contains('driver detection failed'));
      expect(state.observationStale, isFalse);
    },
  );

  test('old epoch is rejected even with a higher sequence', () {
    final oldEpoch = usb.epoch;
    usb.controller.add(UsbObserverState(epoch: ++usb.epoch, active: false));
    usb.snapshot([diagnostic(replacement)]);
    usb.controller.add(
      UsbSnapshot(
        [diagnostic(device)],
        epoch: oldEpoch,
        sequence: 9999,
        stage: UsbScanStage.enriched,
      ),
    );
    expect(container.read(deviceSessionProvider).selectedDeviceId, 'new');
  });

  test(
    'stalled observer is stale without disconnect; resume recovers',
    () async {
      await session.connect();
      usb.controller.add(UsbObserverState(epoch: ++usb.epoch, active: true));
      usb.controller.add(
        UsbSnapshot(
          [diagnostic(device)],
          epoch: usb.epoch,
          sequence: ++usb.sequence,
          stage: UsbScanStage.raw,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 3010));
      expect(container.read(deviceSessionProvider).observationStale, isTrue);
      expect(container.read(deviceSessionProvider).isConnected, isTrue);
      // Late enrichment is not a fresh raw observation.
      usb.controller.add(
        UsbSnapshot(
          [diagnostic(device)],
          epoch: usb.epoch,
          sequence: usb.sequence,
          stage: UsbScanStage.enriched,
        ),
      );
      expect(container.read(deviceSessionProvider).observationStale, isTrue);
      usb.controller.add(UsbObserverState(epoch: ++usb.epoch, active: false));
      await flush();
      usb.controller.add(UsbObserverState(epoch: ++usb.epoch, active: true));
      usb.snapshot([diagnostic(device)]);
      expect(container.read(deviceSessionProvider).observationStale, isFalse);
      expect(container.read(deviceSessionProvider).observationError, isNull);
      container.dispose();
      await flush();
    },
  );

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
    usb.snapshot([diagnostic(device)]);
    expect(container.read(deviceSessionProvider).error, contains('openFailed'));
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
