/// The app's single connection to a device.
///
/// Both the flash screen and the serial monitor use this one session:
/// selecting a device, granting USB permission and opening the port
/// happen exactly once, in one place. Screens then use the open port for
/// what they do — writing flash, or reading logs.
///
/// Connecting deliberately does *not* put the chip into the ROM
/// bootloader. Download mode and running firmware are mutually
/// exclusive states, and a monitor cannot read logs from a chip parked
/// in the bootloader. Flashing enters the bootloader itself, right
/// before it writes, and reboots the chip afterwards.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../esp/errors.dart';
import '../usb/usb_device.dart';
import '../usb/usb_events.dart';
import '../usb/usb_service.dart';

/// Connection state of the shared session.
enum DeviceConnection { disconnected, connecting, connected }

/// What currently owns the open port; screens check this so two
/// activities can't fight over one device.
enum DeviceActivity { none, flashing, monitoring }

final class DeviceSessionState {
  const DeviceSessionState({
    this.devices = const <UsbDevice>[],
    this.selectedDeviceId,
    this.connection = DeviceConnection.disconnected,
    this.activity = DeviceActivity.none,
    this.error,
  });

  final List<UsbDevice> devices;
  final String? selectedDeviceId;
  final DeviceConnection connection;
  final DeviceActivity activity;
  final String? error;

  bool get isConnected => connection == DeviceConnection.connected;

  UsbDevice? get selectedDevice {
    for (final device in devices) {
      if (device.deviceId == selectedDeviceId) {
        return device;
      }
    }
    return null;
  }

  DeviceSessionState copyWith({
    List<UsbDevice>? devices,
    String? Function()? selectedDeviceId,
    DeviceConnection? connection,
    DeviceActivity? activity,
    String? Function()? error,
  }) {
    return DeviceSessionState(
      devices: devices ?? this.devices,
      selectedDeviceId: selectedDeviceId != null
          ? selectedDeviceId()
          : this.selectedDeviceId,
      connection: connection ?? this.connection,
      activity: activity ?? this.activity,
      error: error != null ? error() : this.error,
    );
  }
}

/// The one device session for the whole app.
final deviceSessionProvider =
    NotifierProvider<DeviceSession, DeviceSessionState>(DeviceSession.new);

/// Shared USB service, so every screen talks to the same port.
final usbServiceProvider = Provider<UsbService>((ref) => UsbService());

final class DeviceSession extends Notifier<DeviceSessionState> {
  DeviceSession([UsbService? usb]) : _injected = usb;

  final UsbService? _injected;
  late final UsbService _usb = _injected ?? ref.read(usbServiceProvider);

  StreamSubscription<UsbEvent>? _eventsSub;
  Completer<bool>? _permissionWaiter;
  String? _permissionDeviceId;
  bool _disposed = false;
  bool _connectingInFlight = false;
  Future<void> _closing = Future<void>.value();
  int _connectionGeneration = 0;
  int _snapshotGeneration = 0;

  /// Fires when the device goes away while connected.
  final StreamController<void> _lostController =
      StreamController<void>.broadcast();

  Stream<void> get onDeviceLost => _lostController.stream;

  UsbService get usb => _usb;

  @override
  DeviceSessionState build() {
    _eventsSub ??= _usb.events.listen(
      _onUsbEvent,
      onError: (Object _) {
        // No USB host stack (desktop, tests).
      },
    );
    ref.onDispose(() async {
      _disposed = true;
      _connectionGeneration++;
      _completePermission(false);
      await _eventsSub?.cancel();
      await _lostController.close();
      await _closePort();
    });
    return const DeviceSessionState();
  }

  Future<void> refreshDevices() async {
    final generation = ++_snapshotGeneration;
    try {
      await _usb.reconcileUsb();
      final devices = await _usb.listRawDevices();
      if (!_disposed && generation == _snapshotGeneration) {
        _applySnapshot(devices);
      }
    } on Object catch (error) {
      if (!_disposed && generation == _snapshotGeneration) {
        state = state.copyWith(error: () => 'USB not available: $error');
      }
    }
  }

  void _applySnapshot(List<UsbDiagnosticDevice> raw) {
    final devices = raw
        .where((d) => d.hasSerialDriver)
        .map((d) => d.device)
        .toList();
    final current = state.selectedDeviceId;
    final stillAttached = devices.any((d) => d.deviceId == current);
    if (!stillAttached && state.connection != DeviceConnection.disconnected) {
      _deviceLost();
    }
    state = state.copyWith(
      devices: devices,
      selectedDeviceId: () => stillAttached
          ? current
          : devices.length == 1
          ? devices.single.deviceId
          : null,
      error: () => devices.isNotEmpty
          ? null
          : raw.isEmpty
          ? 'No USB device detected. Check the cable and enable OTG '
                'in Settings, then retry.'
          : 'USB device detected, but no supported serial driver was found.',
    );
  }

  void _deviceLost() {
    _connectionGeneration++;
    _completePermission(false);
    if (!_lostController.isClosed) _lostController.add(null);
    state = state.copyWith(
      connection: DeviceConnection.disconnected,
      activity: DeviceActivity.none,
      error: () => 'Device unplugged. Reconnect to continue.',
    );
    unawaited(_closePort());
  }

  void selectDevice(String? deviceId) {
    if (state.connection != DeviceConnection.disconnected) {
      return; // Disconnect first; the port belongs to the current device.
    }
    state = state.copyWith(selectedDeviceId: () => deviceId);
  }

  /// Permission + open port. Leaves the chip running its firmware.
  Future<void> connect() async {
    final device = state.selectedDevice;
    if (_connectingInFlight ||
        device == null ||
        state.connection != DeviceConnection.disconnected) {
      return;
    }
    _connectingInFlight = true;
    final generation = ++_connectionGeneration;
    state = state.copyWith(
      connection: DeviceConnection.connecting,
      error: () => null,
    );
    try {
      await _closing;
      _checkConnection(generation);
      // Re-read the attachment before permission and every open attempt.
      // Never silently substitute a same-VID/PID adapter on a hub.
      for (final delay in [0, 100, 250, 500, 1000]) {
        if (delay != 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
        _checkConnection(generation);
        final devices = await _usb.listDevices();
        _checkConnection(generation);
        final matches = devices.where(
          (d) =>
              d.deviceId == device.deviceId &&
              d.vendorId == device.vendorId &&
              d.productId == device.productId,
        );
        if (matches.length != 1) {
          throw const EspDeviceLostError(
            'USB attachment changed. Reconnect to continue.',
          );
        }
        final current = matches.single;
        await _ensurePermission(current, generation);
        _checkConnection(generation);
        // Permission is tied to an attachment, and may have expired while
        // the system dialog was open. Native open also checks current state.
        final afterPermission = await _usb.listDevices();
        _checkConnection(generation);
        if (!afterPermission.any(
          (d) =>
              d.deviceId == current.deviceId &&
              d.vendorId == current.vendorId &&
              d.productId == current.productId,
        )) {
          throw const EspDeviceLostError(
            'USB attachment changed during permission.',
          );
        }
        if (!await _usb.hasPermission(current)) {
          throw const EspDeviceLostError(
            'USB permission expired after reconnect.',
          );
        }
        _checkConnection(generation);
        try {
          await _usb.open(current);
          _checkConnection(generation);
          state = state.copyWith(connection: DeviceConnection.connected);
          return;
        } on PlatformException catch (error) {
          if (error.code != 'openFailed' || delay == 1000) rethrow;
        }
      }
    } on Object catch (error) {
      if (!_disposed && generation == _connectionGeneration) {
        await _closePort();
        if (!_disposed && generation == _connectionGeneration) {
          state = state.copyWith(
            connection: DeviceConnection.disconnected,
            error: () => '$error',
          );
          unawaited(refreshDevices());
        }
      }
      rethrow;
    } finally {
      _connectingInFlight = false;
    }
  }

  void _checkConnection(int generation) {
    if (_disposed || generation != _connectionGeneration) {
      throw const EspDeviceLostError('USB connection canceled');
    }
  }

  Future<void> disconnect() async {
    _connectionGeneration++;
    _completePermission(false);
    state = state.copyWith(
      connection: DeviceConnection.disconnected,
      activity: DeviceActivity.none,
    );
    await _closePort();
  }

  /// Claim the port for [activity]; returns false when something else
  /// already owns it.
  bool claim(DeviceActivity activity) {
    if (state.activity != DeviceActivity.none && state.activity != activity) {
      return false;
    }
    state = state.copyWith(activity: activity);
    return true;
  }

  void release(DeviceActivity activity) {
    if (state.activity == activity) {
      state = state.copyWith(activity: DeviceActivity.none);
    }
  }

  Future<void> _ensurePermission(UsbDevice device, int generation) async {
    final permitted = await _usb.hasPermission(device);
    _checkConnection(generation);
    if (permitted) {
      return;
    }
    final waiter = Completer<bool>();
    _permissionWaiter = waiter;
    _permissionDeviceId = device.deviceId;
    try {
      await _usb.requestPermission(device);
      final granted = await waiter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => false,
      );
      if (!granted) {
        throw const EspPermissionDeniedError(
          'USB permission denied or device disconnected',
        );
      }
    } finally {
      if (identical(_permissionWaiter, waiter)) {
        _permissionWaiter = null;
        _permissionDeviceId = null;
      }
    }
  }

  void _completePermission(bool granted) {
    final waiter = _permissionWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete(granted);
  }

  void _onUsbEvent(UsbEvent event) {
    if (_disposed) return;
    switch (event) {
      case UsbSnapshot():
        _snapshotGeneration++;
        _applySnapshot(event.devices);
      case UsbPermissionGranted():
        if (event.deviceId == _permissionDeviceId) _completePermission(true);
      case UsbPermissionDenied():
        if (event.deviceId == _permissionDeviceId) _completePermission(false);
      case UsbDeviceAttached():
        unawaited(refreshDevices());
      case UsbDeviceDetached():
        if (event.deviceId == _permissionDeviceId) _completePermission(false);
        if (event.deviceId == state.selectedDeviceId) _deviceLost();
        unawaited(refreshDevices());
    }
  }

  Future<void> _closePort() =>
      _closing = _closing.then((_) => _closePortImpl());

  Future<void> _closePortImpl() async {
    try {
      await _usb.jtagClose();
    } on Object {
      // Not open.
    }
    try {
      await _usb.close();
    } on Object {
      // Already gone.
    }
  }
}
