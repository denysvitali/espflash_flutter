/// Orchestration behind the flash screen: firmware staging (file, URL or
/// build bundle), bootloader entry, flash, cancel.
///
/// Device selection, USB permission and the open port belong to
/// [DeviceSession] — the app connects once, and this screen uses that
/// connection.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../esp/chip_detect.dart';
import '../esp/connection.dart';
import '../esp/errors.dart';
import '../esp/firmware_bundle.dart';
import '../esp/flasher.dart';
import '../esp/reset.dart';
import '../esp/targets/chip_target.dart';
import '../usb/android_usb_transport.dart';
import '../usb/usb_device.dart';
import '../usb/usb_service.dart';
import 'device_session.dart';
import 'flash_state.dart';

/// Screen state + actions.
final flashControllerProvider = NotifierProvider<FlashController, FlashState>(
  FlashController.new,
);

final class FlashController extends Notifier<FlashState> {
  FlashController();

  late final UsbService _usb = ref.read(deviceSessionProvider.notifier).usb;
  final Dio _dio = Dio();

  EspConnection? _connection;
  ChipTarget? _target;
  bool _cancelRequested = false;

  @override
  FlashState build() {
    ref.onDispose(() async {
      await _closeConnection();
      await _screenOn(false);
    });
    return const FlashState();
  }

  /// Ask the user to pick firmware: a raw `.bin`, or a `.tar.gz` build
  /// bundle (whose image, offset and ELF are taken automatically).
  Future<void> pickFirmwareFile() async {
    final result = await FilePicker.pickFiles(withData: true);
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) {
      return;
    }
    if (looksLikeBundle(file.name, bytes)) {
      _stageBundle(file.name, bytes);
      return;
    }
    if (looksLikeElf(bytes)) {
      // An ELF is not a flashable image: the ROM writes raw flash
      // contents, not program headers. Bundles ship the matching .bin.
      _log('${file.name} is an ELF — pick the .bin or the .tar.gz bundle.');
      _banner(
        'ELF files carry symbols, not a flash image. Use the .bin '
        '(or the .tar.gz bundle, which contains both).',
        isError: true,
      );
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

  /// Unpack a build bundle and stage its preferred image.
  void _stageBundle(String name, Uint8List bytes) {
    try {
      final bundle = parseFirmwareBundle(bytes);
      final image = bundle.preferredImage!;
      state = state.copyWith(
        firmware: () => FirmwareImage(
          name: image.name,
          bytes: image.bytes,
          sourceDescription: 'bundle $name',
        ),
        suggestedOffset: () => image.offset,
        statusBanner: () => null,
      );
      final checked = bundle.verifiedFiles;
      _log(
        'Bundle $name: staged ${image.name} (${image.label}, '
        '${image.bytes.length} bytes) at '
        '0x${image.offset.toRadixString(16)}'
        '${checked > 0 ? ', $checked checksums verified' : ''}.',
      );
      if (bundle.images.length > 1) {
        final others = bundle.images.skip(1).map((i) => i.name).join(', ');
        _log('Bundle also contains: $others.');
      }
      if (bundle.elfName != null) {
        _log(
          'Bundle ships ${bundle.elfName} — pick the same bundle in the '
          'serial monitor to decode defmt logs.',
        );
      }
    } on Object catch (error) {
      _log('Bundle rejected: $error');
      _banner('$error', isError: true);
    }
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
  /// Enter the ROM bootloader on the already-open port and identify the
  /// chip.
  ///
  /// Called from [flash], not from connecting: download mode stops the
  /// firmware, so a chip is only parked there for the moment it is
  /// actually being written. The watchdog is disarmed straight away
  /// because the ROM resets an idle bootloader within a minute.
  Future<void> _enterBootloader(UsbDevice device) async {
    _log('Entering the bootloader …');
    final transport = AndroidUsbTransport(service: _usb, device: device);
    final connection = EspConnection(transport);
    _connection = connection;
    await connection.connect(
      resetStrategy:
          device.isUsbJtag ? const UsbJtagReset() : const ClassicReset(),
    );
    final target = await detectChip(connection);
    _target = target;
    await target.disableWatchdogs(connection);
    _log('Detected ${target.chipName}.');
    state = state.copyWith(chipName: () => target.chipName);
  }

  /// Write the staged firmware at [offset], verify MD5, reboot.
  Future<void> flash({required int offset, bool eraseFirst = false}) async {
    final firmware = state.firmware;
    final session = ref.read(deviceSessionProvider.notifier);
    final device = ref.read(deviceSessionProvider).selectedDevice;
    if (state.phase == FlashPhase.flashing ||
        firmware == null ||
        device == null ||
        !ref.read(deviceSessionProvider).isConnected) {
      return;
    }
    if (!session.claim(DeviceActivity.flashing)) {
      _banner('The serial monitor is using the port — stop it first.',
          isError: true);
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
    var succeeded = false;
    try {
      await _enterBootloader(device);
      final connection = _connection!;
      final target = _target!;
      _log(
        'Flashing ${firmware.name} at 0x${offset.toRadixString(16)} '
        '(${firmware.bytes.length} bytes)…',
      );
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
    // The chip left the bootloader (or the ROM is in an unknown state
    // after a failure): drop the protocol layer, keep the port open so
    // the monitor can watch the firmware boot.
    await _closeConnection();
    session.release(DeviceActivity.flashing);
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

  /// Drops the ROM-protocol layer. The port itself stays open — it
  /// belongs to [DeviceSession], not to this screen.
  Future<void> _closeConnection() async {
    final connection = _connection;
    _connection = null;
    _target = null;
    if (connection != null) {
      await connection.close();
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
