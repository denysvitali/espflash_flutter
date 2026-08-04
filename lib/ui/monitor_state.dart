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
    this.source,
    this.elf,
    this.lines = const <MonitorLine>[],
    this.paused = false,
    this.hexMode = false,
    this.filter = '',
    this.minLevel,
    this.droppedFrames = 0,
    this.bytesReceived = 0,
    this.statusBanner,
    this.bannerIsError = false,
  });

  final List<UsbDevice> devices;
  final String? selectedDeviceId;
  final MonitorPhase phase;

  /// 'serial' or 'rtt' while streaming; null when idle.
  final String? source;
  final ElfInfo? elf;
  final List<MonitorLine> lines;
  final bool paused;

  /// Show every incoming byte as hex lines (diagnostic: bypasses
  /// defmt/raw rendering, decoder still runs underneath).
  final bool hexMode;

  /// Case-insensitive substring filter applied to rendered text.
  final String filter;

  /// Minimum defmt level shown; null shows everything (incl. raw).
  final DefmtLevel? minLevel;
  final int droppedFrames;

  /// Total serial bytes seen since Start (even undecodable ones) —
  /// distinguishes "device silent" from "decoder drops everything".
  final int bytesReceived;
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
    String? Function()? source,
    ElfInfo? Function()? elf,
    List<MonitorLine>? lines,
    bool? paused,
    bool? hexMode,
    String? filter,
    DefmtLevel? Function()? minLevel,
    int? droppedFrames,
    int? bytesReceived,
    String? Function()? statusBanner,
    bool? bannerIsError,
  }) {
    return MonitorState(
      devices: devices ?? this.devices,
      selectedDeviceId: selectedDeviceId != null
          ? selectedDeviceId()
          : this.selectedDeviceId,
      phase: phase ?? this.phase,
      source: source != null ? source() : this.source,
      elf: elf != null ? elf() : this.elf,
      lines: lines ?? this.lines,
      paused: paused ?? this.paused,
      hexMode: hexMode ?? this.hexMode,
      filter: filter ?? this.filter,
      minLevel: minLevel != null ? minLevel() : this.minLevel,
      droppedFrames: droppedFrames ?? this.droppedFrames,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      statusBanner: statusBanner != null ? statusBanner() : this.statusBanner,
      bannerIsError: bannerIsError ?? this.bannerIsError,
    );
  }
}
