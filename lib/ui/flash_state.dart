/// UI state for the flash screen.
library;

import 'dart:typed_data';


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
    this.phase = FlashPhase.idle,
    this.chipName,
    this.firmware,
    this.suggestedOffset,
    this.bytesWritten = 0,
    this.bytesTotal = 0,
    this.statusBanner,
    this.bannerIsError = false,
    this.log = const <String>[],
  });

  final FlashPhase phase;

  /// Detected chip ('ESP32-C3') once [FlashPhase.ready].
  final String? chipName;

  /// Firmware staged for flashing.
  final FirmwareImage? firmware;

  /// Offset the staged image must go to, when the source knows it (a
  /// build bundle). The UI prefills the offset field with this.
  final int? suggestedOffset;

  /// Progress of the current flash run.
  final int bytesWritten;
  final int bytesTotal;

  /// One-line banner under the flash button (result or error).
  final String? statusBanner;

  /// Red banner when true, green/neutral otherwise.
  final bool bannerIsError;

  /// Monospace activity log, oldest first.
  final List<String> log;

  /// 0..1 progress of the current run; 0 when not flashing.
  double get progress => bytesTotal == 0 ? 0 : bytesWritten / bytesTotal;

  FlashState copyWith({
    FlashPhase? phase,
    String? Function()? chipName,
    FirmwareImage? Function()? firmware,
    int? Function()? suggestedOffset,
    int? bytesWritten,
    int? bytesTotal,
    String? Function()? statusBanner,
    bool? bannerIsError,
    List<String>? log,
  }) {
    return FlashState(
      phase: phase ?? this.phase,
      chipName: chipName != null ? chipName() : this.chipName,
      firmware: firmware != null ? firmware() : this.firmware,
      suggestedOffset: suggestedOffset != null
          ? suggestedOffset()
          : this.suggestedOffset,
      bytesWritten: bytesWritten ?? this.bytesWritten,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      statusBanner: statusBanner != null ? statusBanner() : this.statusBanner,
      bannerIsError: bannerIsError ?? this.bannerIsError,
      log: log ?? this.log,
    );
  }
}
