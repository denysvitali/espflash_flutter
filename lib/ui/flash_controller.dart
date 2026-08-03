/// Orchestration behind the flash screen: USB permission, bootloader
/// sync, chip detect, firmware staging (file / URL), flash, cancel.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../esp/chip_detect.dart';
import '../esp/connection.dart';
import '../esp/errors.dart';
import '../esp/flasher.dart';
import '../esp/reset.dart';
import '../esp/targets/chip_target.dart';
import '../usb/android_usb_transport.dart';
import '../usb/usb_device.dart';
import '../usb/usb_events.dart';
import '../usb/usb_service.dart';
import 'flash_state.dart';

/// Screen state + actions.
final flashControllerProvider = NotifierProvider<FlashController, FlashState>(
  FlashController.new,
);

final class FlashController extends Notifier<FlashState> {
  FlashController([UsbService? usb]) : _usb = usb ?? UsbService();

  final UsbService _usb;
  final Dio _dio = Dio();

  StreamSubscription<UsbEvent>? _eventsSub;
  Completer<bool>? _permissionWaiter;
  EspConnection? _connection;
  ChipTarget? _target;
  bool _cancelRequested = false;

  @override
  FlashState build() {
    _eventsSub ??= _usb.events.listen(
      _onUsbEvent,
      onError: (Object _) {
        // No USB host stack (desktop, tests): the refresh path
        // reports it; nothing else to do here.
      },
    );
    ref.onDispose(() async {
      await _eventsSub?.cancel();
      await _teardownConnection();
      await _screenOn(false);
    });
    return const FlashState();
  }

  /// Re-scan attached USB devices. Safe on platforms without the
  /// plugin: logs instead of crashing.
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
      );
      if (devices.isEmpty) {
        _log('No USB devices found.');
      }
    } on Object catch (error) {
      _log('USB not available: $error');
    }
  }

  void selectDevice(String? deviceId) {
    state = state.copyWith(selectedDeviceId: () => deviceId);
  }

  /// Ask the user to pick a `.bin` from device storage.
  Future<void> pickFirmwareFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['bin'],
      withData: true,
    );
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) {
      return;
    }
    state = state.copyWith(
      firmware: () => FirmwareImage(
        name: file.name,
        bytes: bytes,
        sourceDescription: 'local file',
      ),
      statusBanner: () => null,
    );
    _log('Staged ${file.name} (${bytes.length} bytes) from local file.');
  }

  /// Download a `.bin` from [url] and stage it.
  Future<void> fetchFirmwareFromUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _log('Downloading $trimmed …');
    try {
      final response = await _dio.get<List<int>>(
        trimmed,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('empty response body');
      }
      final name = Uri.parse(trimmed).pathSegments.isEmpty
          ? 'firmware.bin'
          : Uri.parse(trimmed).pathSegments.last;
      state = state.copyWith(
        firmware: () =>
            FirmwareImage(name: name, bytes: bytes, sourceDescription: trimmed),
        statusBanner: () => null,
      );
      _log('Staged $name (${bytes.length} bytes) from $trimmed.');
    } on Object catch (error) {
      _log('Download failed: $error');
      _banner('Download failed: $error', isError: true);
    }
  }

  void clearFirmware() {
    state = state.copyWith(firmware: () => null);
  }

  /// Permission → open → sync → detect chip. Leaves the connection
  /// open for [flash].
  Future<void> connect() async {
    final device = state.selectedDevice;
    if (device == null || state.phase == FlashPhase.connecting) {
      return;
    }
    state = state.copyWith(
      phase: FlashPhase.connecting,
      statusBanner: () => null,
    );
    try {
      await _ensurePermission(device);
      final label = device.label.isEmpty ? device.deviceId : device.label;
      _log('Opening $label …');
      await _usb.open(device);
      final transport = AndroidUsbTransport(service: _usb, device: device);
      final connection = EspConnection(transport);
      _connection = connection;
      _log('Syncing with the bootloader …');
      await connection.connect(
        resetStrategy: device.isUsbJtag
            ? const UsbJtagReset()
            : const ClassicReset(),
      );
      final target = await detectChip(connection);
      _target = target;
      // The ROM's RTC watchdog resets an idle bootloader within a
      // minute; disarm it before the user takes time to stage firmware.
      await target.disableWatchdogs(connection);
      _log('Detected ${target.chipName}. Ready to flash.');
      state = state.copyWith(
        phase: FlashPhase.ready,
        chipName: () => target.chipName,
      );
    } on Object catch (error) {
      _log('Connect failed: $error');
      await _teardownConnection();
      state = state.copyWith(phase: FlashPhase.idle);
      _banner('$error', isError: true);
    }
  }

  /// Write the staged firmware at [offset], verify MD5, reboot.
  Future<void> flash({required int offset, bool eraseFirst = false}) async {
    final firmware = state.firmware;
    final connection = _connection;
    final target = _target;
    if (state.phase != FlashPhase.ready ||
        firmware == null ||
        connection == null ||
        target == null) {
      return;
    }
    _cancelRequested = false;
    state = state.copyWith(
      phase: FlashPhase.flashing,
      bytesWritten: 0,
      bytesTotal: firmware.bytes.length,
      statusBanner: () => null,
    );
    await _screenOn(true);
    _log(
      'Flashing ${firmware.name} at 0x${offset.toRadixString(16)} '
      '(${firmware.bytes.length} bytes)…',
    );
    var succeeded = false;
    try {
      await EspFlasher(connection, target).flash(
        <FirmwarePart>[
          FirmwarePart(
            offset: offset,
            bytes: firmware.bytes,
            name: firmware.name,
          ),
        ],
        eraseFirst: eraseFirst,
        onProgress: (int partIndex, int written, int total) {
          state = state.copyWith(bytesWritten: written, bytesTotal: total);
        },
        isCancelled: () async => _cancelRequested,
      );
      succeeded = true;
    } on EspCancelledError {
      _log('Flash cancelled.');
      _banner('Cancelled', isError: true);
    } on Object catch (error) {
      _log('Flash failed: $error');
      _banner('$error', isError: true);
    }
    if (succeeded) {
      _log('MD5 verified. Rebooting into the new firmware.');
      _banner('Flash complete — device rebooted.');
    }
    await _screenOn(false);
    // The chip has rebooted (or the ROM is in an unknown state after
    // a failure); a fresh sync is required either way, so tear down.
    await _teardownConnection();
    state = state.copyWith(
      phase: FlashPhase.idle,
      chipName: () => null,
      bytesWritten: 0,
      bytesTotal: 0,
    );
  }

  /// Abort the running flash at the next block boundary.
  void cancelFlash() {
    if (state.phase == FlashPhase.flashing) {
      _cancelRequested = true;
      _log('Cancelling after the current block …');
    }
  }

  /// Close the port and return to idle.
  Future<void> disconnect() async {
    await _teardownConnection();
    state = state.copyWith(phase: FlashPhase.idle, chipName: () => null);
    _log('Disconnected.');
  }

  Future<void> _ensurePermission(UsbDevice device) async {
    if (await _usb.hasPermission(device)) {
      return;
    }
    _log('Requesting USB permission …');
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
    _log('USB permission granted.');
  }

  void _onUsbEvent(UsbEvent event) {
    switch (event) {
      case UsbPermissionGranted():
        _permissionWaiter?.complete(true);
      case UsbPermissionDenied():
        _permissionWaiter?.complete(false);
      case UsbDeviceAttached():
        _log('Device attached: ${event.deviceId}');
        unawaited(refreshDevices());
      case UsbDeviceDetached():
        _log('Device detached: ${event.deviceId}');
        if (event.deviceId == state.selectedDeviceId) {
          unawaited(_teardownConnection());
          state = state.copyWith(phase: FlashPhase.idle, chipName: () => null);
          _banner('Device unplugged.', isError: true);
        }
        unawaited(refreshDevices());
    }
  }

  Future<void> _teardownConnection() async {
    final connection = _connection;
    _connection = null;
    _target = null;
    if (connection != null) {
      await connection.close();
    }
    try {
      await _usb.close();
    } on Object {
      // Port already gone (device unplugged); nothing to close.
    }
  }

  /// Keep the screen awake while flashing; tolerate platforms where the
  /// wakelock plugin is unavailable (desktop, tests).
  Future<void> _screenOn(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } on Object {
      // No wakelock on this platform.
    }
  }

  void _log(String message) {
    state = state.copyWith(log: <String>[...state.log, message]);
  }

  void _banner(String message, {bool isError = false}) {
    state = state.copyWith(statusBanner: () => message, bannerIsError: isError);
  }
}
