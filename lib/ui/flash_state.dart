/// UI state for the flash screen.
library;

import 'dart:typed_data';

import '../usb/usb_device.dart';

/// Where the app is in the connect → flash lifecycle.
enum FlashPhase {
  /// No open connection.
  idle,

  /// Permission / open / sync / chip-detect in progress.
  connecting,

  /// Chip detected; ready to flash.
  ready,

  /// A flash run is in progress.
  flashing,
}

/// A firmware image held in memory, from a picked file or a URL.
final class FirmwareImage {
  FirmwareImage({
    required this.name,
    required List<int> bytes,
    required this.sourceDescription,
  }) : bytes = Uint8List.fromList(bytes);

  /// Display name (file name or URL basename).
  final String name;

  /// Full image content.
  final Uint8List bytes;

  /// Where it came from ('local file' or the URL), for the log.
  final String sourceDescription;
}

/// Immutable view of the flash screen.
final class FlashState {
  const FlashState({
    this.devices = const <UsbDevice>[],
    this.selectedDeviceId,
    this.phase = FlashPhase.idle,
    this.chipName,
    this.firmware,
    this.bytesWritten = 0,
    this.bytesTotal = 0,
    this.statusBanner,
    this.bannerIsError = false,
    this.log = const <String>[],
  });

  /// Devices reported by the platform USB stack.
  final List<UsbDevice> devices;

  /// `deviceId` of the dropdown selection.
  final String? selectedDeviceId;

  final FlashPhase phase;

  /// Detected chip ('ESP32-C3') once [FlashPhase.ready].
  final String? chipName;

  /// Firmware staged for flashing.
  final FirmwareImage? firmware;

  /// Progress of the current flash run.
  final int bytesWritten;
  final int bytesTotal;

  /// One-line banner under the flash button (result or error).
  final String? statusBanner;

  /// Red banner when true, green/neutral otherwise.
  final bool bannerIsError;

  /// Monospace activity log, oldest first.
  final List<String> log;

  UsbDevice? get selectedDevice {
    for (final device in devices) {
      if (device.deviceId == selectedDeviceId) {
        return device;
      }
    }
    return null;
  }

  /// 0..1 progress of the current run; 0 when not flashing.
  double get progress => bytesTotal == 0 ? 0 : bytesWritten / bytesTotal;

  FlashState copyWith({
    List<UsbDevice>? devices,
    String? Function()? selectedDeviceId,
    FlashPhase? phase,
    String? Function()? chipName,
    FirmwareImage? Function()? firmware,
    int? bytesWritten,
    int? bytesTotal,
    String? Function()? statusBanner,
    bool? bannerIsError,
    List<String>? log,
  }) {
    return FlashState(
      devices: devices ?? this.devices,
      selectedDeviceId: selectedDeviceId != null
          ? selectedDeviceId()
          : this.selectedDeviceId,
      phase: phase ?? this.phase,
      chipName: chipName != null ? chipName() : this.chipName,
      firmware: firmware != null ? firmware() : this.firmware,
      bytesWritten: bytesWritten ?? this.bytesWritten,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      statusBanner: statusBanner != null ? statusBanner() : this.statusBanner,
      bannerIsError: bannerIsError ?? this.bannerIsError,
      log: log ?? this.log,
    );
  }
}
