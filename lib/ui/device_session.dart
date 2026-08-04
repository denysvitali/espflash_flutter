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
      await _eventsSub?.cancel();
      await _lostController.close();
      await _closePort();
    });
    return const DeviceSessionState();
  }

  Future<void> refreshDevices() async {
    try {
      final devices = await _usb.listDevices();
      state = state.copyWith(
        devices: devices,
        selectedDeviceId: () {
          final current = state.selectedDeviceId;
          if (devices.any((d) => d.deviceId == current)) {
            return current;
          }
          return devices.length == 1 ? devices.single.deviceId : null;
        },
        error: () => devices.isEmpty ? 'No USB devices found.' : null,
      );
    } on Object catch (error) {
      state = state.copyWith(error: () => 'USB not available: $error');
    }
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
    if (device == null ||
        state.connection != DeviceConnection.disconnected) {
      return;
    }
    state = state.copyWith(
      connection: DeviceConnection.connecting,
      error: () => null,
    );
    try {
      await _ensurePermission(device);
      await _usb.open(device);
      state = state.copyWith(connection: DeviceConnection.connected);
    } on Object catch (error) {
      await _closePort();
      state = state.copyWith(
        connection: DeviceConnection.disconnected,
        error: () => '$error',
      );
      rethrow;
    }
  }

  Future<void> disconnect() async {
    await _closePort();
    state = state.copyWith(
      connection: DeviceConnection.disconnected,
      activity: DeviceActivity.none,
    );
  }

  /// Claim the port for [activity]; returns false when something else
  /// already owns it.
  bool claim(DeviceActivity activity) {
    if (state.activity != DeviceActivity.none &&
        state.activity != activity) {
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

  Future<void> _ensurePermission(UsbDevice device) async {
    if (await _usb.hasPermission(device)) {
      return;
    }
    final waiter = Completer<bool>();
    _permissionWaiter = waiter;
    await _usb.requestPermission(device);
    final granted = await waiter.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => false,
    );
    _permissionWaiter = null;
    if (!granted) {
      throw const EspPermissionDeniedError('USB permission denied by the user');
    }
  }

  void _onUsbEvent(UsbEvent event) {
    switch (event) {
      case UsbPermissionGranted():
        _permissionWaiter?.complete(true);
      case UsbPermissionDenied():
        _permissionWaiter?.complete(false);
      case UsbDeviceAttached():
        unawaited(refreshDevices());
      case UsbDeviceDetached():
        if (event.deviceId == state.selectedDeviceId) {
          if (!_lostController.isClosed) {
            _lostController.add(null);
          }
          unawaited(disconnect());
          state = state.copyWith(error: () => 'Device unplugged.');
        }
        unawaited(refreshDevices());
    }
  }

  Future<void> _closePort() async {
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
