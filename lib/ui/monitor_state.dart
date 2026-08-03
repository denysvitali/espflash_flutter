/// State for the serial monitor screen.
library;

import '../defmt/table.dart';
import '../usb/usb_device.dart';

/// Connection/streaming phase of the monitor.
enum MonitorPhase { idle, connecting, streaming }

/// One rendered line in the monitor log.
final class MonitorLine {
  const MonitorLine({
    required this.text,
    this.level,
    this.timestamp,
    this.isRaw = false,
  });

  final String text;

  /// defmt severity; null for `println!` frames and raw serial output.
  final DefmtLevel? level;
  final String? timestamp;

  /// True for non-defmt serial bytes (boot ROM messages, `print!`, …).
  final bool isRaw;
}

/// Parsed info about the staged ELF, for display.
final class ElfInfo {
  const ElfInfo({
    required this.name,
    required this.entryCount,
    required this.version,
    required this.hasTimestamp,
  });

  final String name;
  final int entryCount;
  final String version;
  final bool hasTimestamp;
}

final class MonitorState {
  const MonitorState({
    this.devices = const <UsbDevice>[],
    this.selectedDeviceId,
    this.phase = MonitorPhase.idle,
    this.elf,
    this.lines = const <MonitorLine>[],
    this.paused = false,
    this.filter = '',
    this.minLevel,
    this.droppedFrames = 0,
    this.statusBanner,
    this.bannerIsError = false,
  });

  final List<UsbDevice> devices;
  final String? selectedDeviceId;
  final MonitorPhase phase;
  final ElfInfo? elf;
  final List<MonitorLine> lines;
  final bool paused;

  /// Case-insensitive substring filter applied to rendered text.
  final String filter;

  /// Minimum defmt level shown; null shows everything (incl. raw).
  final DefmtLevel? minLevel;
  final int droppedFrames;
  final String? statusBanner;
  final bool bannerIsError;

  UsbDevice? get selectedDevice {
    for (final device in devices) {
      if (device.deviceId == selectedDeviceId) {
        return device;
      }
    }
    return null;
  }

  /// [lines] with filter and minimum level applied.
  List<MonitorLine> get visibleLines {
    final needle = filter.trim().toLowerCase();
    return lines.where((line) {
      if (line.level != null &&
          minLevel != null &&
          line.level!.index < minLevel!.index) {
        return false;
      }
      if (needle.isNotEmpty && !line.text.toLowerCase().contains(needle)) {
        return false;
      }
      return true;
    }).toList();
  }

  MonitorState copyWith({
    List<UsbDevice>? devices,
    String? Function()? selectedDeviceId,
    MonitorPhase? phase,
    ElfInfo? Function()? elf,
    List<MonitorLine>? lines,
    bool? paused,
    String? filter,
    DefmtLevel? Function()? minLevel,
    int? droppedFrames,
    String? Function()? statusBanner,
    bool? bannerIsError,
  }) {
    return MonitorState(
      devices: devices ?? this.devices,
      selectedDeviceId: selectedDeviceId != null
          ? selectedDeviceId()
          : this.selectedDeviceId,
      phase: phase ?? this.phase,
      elf: elf != null ? elf() : this.elf,
      lines: lines ?? this.lines,
      paused: paused ?? this.paused,
      filter: filter ?? this.filter,
      minLevel: minLevel != null ? minLevel() : this.minLevel,
      droppedFrames: droppedFrames ?? this.droppedFrames,
      statusBanner: statusBanner != null ? statusBanner() : this.statusBanner,
      bannerIsError: bannerIsError ?? this.bannerIsError,
    );
  }
}
