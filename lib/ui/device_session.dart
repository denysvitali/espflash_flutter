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

import 'package:flutter/foundation.dart';
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
    this.rawDevices = const [],
    this.observerActive = false,
    this.observationStale = true,
    this.observationError,
  });

  final List<UsbDevice> devices;
  final String? selectedDeviceId;
  final DeviceConnection connection;
  final DeviceActivity activity;
  final String? error;
  final List<UsbDiagnosticDevice> rawDevices;
  final bool observerActive;
  final bool observationStale;
  final String? observationError;

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
    List<UsbDiagnosticDevice>? rawDevices,
    bool? observerActive,
    bool? observationStale,
    String? Function()? observationError,
  }) {
    return DeviceSessionState(
      devices: devices ?? this.devices,
      selectedDeviceId: selectedDeviceId != null
          ? selectedDeviceId()
          : this.selectedDeviceId,
      connection: connection ?? this.connection,
      activity: activity ?? this.activity,
      error: error != null ? error() : this.error,
      rawDevices: rawDevices ?? this.rawDevices,
      observerActive: observerActive ?? this.observerActive,
      observationStale: observationStale ?? this.observationStale,
      observationError: observationError != null
          ? observationError()
          : this.observationError,
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

  static const _emptyHostMessage =
      'No USB device detected. Check the cable and enable OTG '
      'in Settings, then retry.';
  static const _unsupportedMessage =
      'USB device detected, but no supported serial driver was found.';

  static const _checkingMessage =
      'USB device detected. Checking serial support…';
  static const _probeErrorMessage =
      'USB device detected, but serial driver detection failed.';
  static const _metadataErrorMessage =
      'USB device detected, but some device details could not be read.';
  static const _discoveryMessages = {
    _emptyHostMessage,
    _unsupportedMessage,
    _checkingMessage,
    _probeErrorMessage,
    _metadataErrorMessage,
  };

  final UsbService? _injected;
  late final UsbService _usb = _injected ?? ref.read(usbServiceProvider);

  StreamSubscription<UsbEvent>? _eventsSub;
  Completer<bool>? _permissionWaiter;
  String? _permissionDeviceId;
  bool _disposed = false;
  bool _connectingInFlight = false;
  Future<void> _closing = Future<void>.value();
  int _connectionGeneration = 0;
  int _observerEpoch = -1;
  int _observerSequence = -1;
  int _observerStage = -1;
  Timer? _observationDeadline;

  /// Fires when the device goes away while connected.
  final StreamController<void> _lostController =
      StreamController<void>.broadcast();

  Stream<void> get onDeviceLost => _lostController.stream;

  UsbService get usb => _usb;

  @override
  DeviceSessionState build() {
    _eventsSub ??= _usb.events.listen(
      _onUsbEvent,
      onError: (Object error) {
        if (_disposed) return;
        _observationDeadline?.cancel();
        debugPrint('EspFlashUsb stage=dart-stream-error error=$error');
        state = state.copyWith(
          observationStale: true,
          observationError: () => 'USB observation stream failed: $error',
        );
      },
    );
    ref.onDispose(() async {
      _disposed = true;
      _observationDeadline?.cancel();
      _connectionGeneration++;
      _completePermission(false);
      await _eventsSub?.cancel();
      await _lostController.close();
      await _closePort();
    });
    return const DeviceSessionState();
  }

  Future<void> refreshDevices() async {
    try {
      // One event path owns state. A method response cannot overwrite a newer
      // raw observation or bypass epoch/sequence validation.
      await _usb.reconcileUsb();
    } on Object catch (error) {
      if (!_disposed) {
        state = state.copyWith(
          observationStale: true,
          observationError: () => 'USB discovery request failed: $error',
        );
      }
    }
  }

  void _armObservationDeadline() {
    _observationDeadline?.cancel();
    if (!state.observerActive) return;
    _observationDeadline = Timer(const Duration(seconds: 3), () {
      if (!_disposed) {
        state = state.copyWith(
          observationStale: true,
          observationError: () =>
              'USB discovery is not returning fresh scans. '
              'Showing last known devices.',
        );
      }
    });
  }

  void _applyObservation(UsbSnapshot snapshot) {
    _traceObservation(snapshot, 'dart-received');
    if (snapshot.epoch < _observerEpoch ||
        (snapshot.epoch == _observerEpoch &&
            (snapshot.sequence < _observerSequence ||
                (snapshot.sequence == _observerSequence &&
                    snapshot.stage.index <= _observerStage)))) {
      _traceObservation(snapshot, 'dart-discarded');
      return;
    }
    final newRaw =
        snapshot.epoch != _observerEpoch ||
        snapshot.sequence != _observerSequence;
    _observerEpoch = snapshot.epoch;
    _observerSequence = snapshot.sequence;
    _observerStage = snapshot.stage.index;
    if (snapshot.status == UsbScanStatus.error) {
      _observationDeadline?.cancel();
      state = state.copyWith(
        observationStale: true,
        observationError: () =>
            'USB enumeration failed: '
            '${snapshot.scanError ?? 'unknown error'}. '
            'Showing last known devices.',
      );
    } else {
      _applySnapshot(snapshot.devices);
      // Enrichment is not a new raw observation and must not extend freshness.
      if (newRaw) {
        state = state.copyWith(
          observationStale: false,
          observationError: () => null,
        );
        _armObservationDeadline();
      }
    }
    _traceObservation(snapshot, 'dart-applied');
  }

  void _traceObservation(UsbSnapshot snapshot, String stage) {
    debugPrint(
      'EspFlashUsb epoch=${snapshot.epoch} seq=${snapshot.sequence} '
      'stage=$stage observationStage=${snapshot.stage.name} '
      'status=${snapshot.status.name} '
      'count=${snapshot.status == UsbScanStatus.ok ? snapshot.devices.length : 'unavailable'} '
      'wallMs=${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  void _applySnapshot(List<UsbDiagnosticDevice> raw) {
    final current = state.selectedDeviceId;
    // Presence comes exclusively from a successful raw roster, never from
    // whether optional metadata/probing happened to succeed this time.
    final stillAttached = raw.any((d) => d.deviceId == current);
    if (!stillAttached && state.connection != DeviceConnection.disconnected) {
      _deviceLost();
    }
    final previous = {
      for (final device in state.devices) device.deviceId: device,
    };
    final devices = <UsbDevice>[];
    for (final entry in raw) {
      final supported = entry.hasSerialDriver ? entry.device : null;
      final retainKnown =
          entry.probeStatus != UsbProbeStatus.unsupported ||
          (entry.deviceId == current &&
              state.connection != DeviceConnection.disconnected);
      final device =
          supported ?? (retainKnown ? previous[entry.deviceId] : null);
      if (device != null) devices.add(device);
    }
    final String? discoveryMessage;
    if (devices.isNotEmpty) {
      discoveryMessage = null;
    } else if (raw.isEmpty) {
      discoveryMessage = _emptyHostMessage;
    } else if (raw.any((d) => d.probeStatus == UsbProbeStatus.error)) {
      discoveryMessage = _probeErrorMessage;
    } else if (raw.every((d) => d.probeStatus == UsbProbeStatus.unsupported)) {
      discoveryMessage = _unsupportedMessage;
    } else if (raw.any((d) => d.probeStatus == UsbProbeStatus.pending)) {
      discoveryMessage = _checkingMessage;
    } else {
      discoveryMessage = _metadataErrorMessage;
    }
    state = state.copyWith(
      rawDevices: raw,
      devices: devices,
      selectedDeviceId: () => devices.any((d) => d.deviceId == current)
          ? current
          : devices.length == 1
          ? devices.single.deviceId
          : null,
      error: () =>
          discoveryMessage ??
          (_discoveryMessages.contains(state.error) ? null : state.error),
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
        _applyObservation(event);
      case UsbObserverState():
        if (event.epoch < _observerEpoch) return;
        if (event.epoch != _observerEpoch) {
          _observerEpoch = event.epoch;
          _observerSequence = -1;
          _observerStage = -1;
        }
        state = state.copyWith(
          observerActive: event.active,
          observationStale: true,
          observationError: () => null,
        );
        _armObservationDeadline();
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
