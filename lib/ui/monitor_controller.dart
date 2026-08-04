/// Orchestration behind the serial monitor screen: ELF staging, USB
/// permission, raw serial streaming, defmt decoding.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../defmt/defmt.dart';
import '../defmt/rzcobs_stream.dart';
import '../esp/firmware_bundle.dart';
import '../esp/reset.dart';
import '../esp/transport.dart';
import '../jtag/esp_usb_jtag.dart';
import '../jtag/riscv_debug.dart';
import '../rtt/rtt.dart';
import '../usb/usb_device.dart';
import '../usb/usb_service.dart';
import 'device_session.dart';
import 'monitor_state.dart';

/// Screen state + actions.
final monitorControllerProvider =
    NotifierProvider<MonitorController, MonitorState>(MonitorController.new);

/// Keeps the log bounded; oldest lines drop off the front.
const _maxLines = 5000;

final class MonitorController extends Notifier<MonitorState> {
  MonitorController();

  late final DeviceSession _session = ref.read(deviceSessionProvider.notifier);
  late final UsbService _usb = _session.usb;

  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<void>? _lostSub;
  ElfFile? _elfFile;
  DefmtTable? _table;
  DefmtLogDecoder? _decoder;

  /// RTT mode state.
  Timer? _rttTimer;
  RttChannelReader? _rttReader;
  DefmtStreamDecoder? _rttDecoder;
  RiscvDtm? _dtm;
  bool _rttPolling = false;

  /// Suppresses log rendering while a control sequence owns the port.
  bool _suppressData = false;

  /// Partial raw text not yet terminated by a newline.
  final List<int> _rawPending = <int>[];

  @override
  MonitorState build() {
    _lostSub ??= _session.onDeviceLost.listen((_) {
      unawaited(_teardown());
      _banner('Device unplugged.', isError: true);
    });
    ref.onDispose(() async {
      await _dataSub?.cancel();
      await _lostSub?.cancel();
      await _screenOn(false);
    });
    return const MonitorState();
  }

  /// The device the app is connected to, per [DeviceSession].
  UsbDevice? get _device => ref.read(deviceSessionProvider).selectedDevice;

  /// Pick an ELF — or a `.tar.gz` firmware bundle, whose ELF is used.
  Future<void> pickElf() async {
    final result = await FilePicker.pickFiles(withData: true);
    final file = result?.files.single;
    final picked = file?.bytes;
    if (file == null || picked == null) {
      return;
    }
    var name = file.name;
    var bytes = picked;
    try {
      if (looksLikeBundle(file.name, picked)) {
        final bundle = parseFirmwareBundle(picked);
        final elfBytes = bundle.elf;
        if (elfBytes == null) {
          throw const FormatException(
            'bundle carries no .elf — needed to decode defmt logs',
          );
        }
        bytes = elfBytes;
        name = bundle.elfName ?? file.name;
      }
      final elf = ElfFile.parse(bytes);
      final table = DefmtTable.parse(elf);
      if (table == null) {
        throw const FormatException(
          'no .defmt section — firmware was not built with defmt',
        );
      }
      if (table.encoding != DefmtEncoding.rzcobs) {
        throw const FormatException(
          'firmware uses defmt "raw" encoding; serial monitoring needs '
          'rzcobs (the default)',
        );
      }
      _decoder = DefmtLogDecoder(table);
      _table = table;
      _elfFile = elf;
      _rawPending.clear();
      state = state.copyWith(
        elf: () => ElfInfo(
          name: name,
          entryCount: table.entries.length,
          version: table.version,
          hasTimestamp: table.hasTimestamp,
        ),
        statusBanner: () => null,
        droppedFrames: 0,
      );
    } on Object catch (error) {
      _decoder = null;
      state = state.copyWith(elf: () => null);
      _banner('ELF rejected: $error', isError: true);
    }
  }

  void clearElf() {
    _decoder = null;
    _table = null;
    _elfFile = null;
    state = state.copyWith(elf: () => null);
  }

  /// Which transport [connect] should use.
  void setSource(MonitorSource source) {
    if (state.phase == MonitorPhase.idle) {
      state = state.copyWith(preferredSource: source);
    }
  }

  /// Single entry point: attaches over the selected transport.
  ///
  /// [MonitorSource.auto] takes RTT when the chip is on its native USB
  /// port and the staged ELF carries an RTT control block (firmware that
  /// logs over RTT never writes to the serial port), serial otherwise.
  Future<void> connect() async {
    if (state.phase != MonitorPhase.idle) {
      await stop();
      return;
    }
    final device = _device;
    if (device == null || !ref.read(deviceSessionProvider).isConnected) {
      _banner('Connect to the device first.', isError: true);
      return;
    }
    if (!_session.claim(DeviceActivity.monitoring)) {
      _banner('A flash is running — wait for it to finish.', isError: true);
      return;
    }
    final source = switch (state.preferredSource) {
      MonitorSource.serial => MonitorSource.serial,
      MonitorSource.rtt => MonitorSource.rtt,
      MonitorSource.auto =>
        device.isUsbJtag && _elfFile != null && _elfHasRtt
            ? MonitorSource.rtt
            : MonitorSource.serial,
    };
    if (source == MonitorSource.rtt) {
      await startRtt();
      // Auto must never leave the user with nothing: if the JTAG path
      // fails, fall back to the serial port and say so.
      if (state.phase == MonitorPhase.idle &&
          state.preferredSource == MonitorSource.auto) {
        final why = state.statusBanner;
        await start();
        if (state.phase == MonitorPhase.streaming) {
          _banner('RTT unavailable ($why) — showing serial output instead.');
        }
      }
    } else {
      await start();
    }
  }

  /// True when the staged ELF exposes an RTT control block symbol.
  bool get _elfHasRtt {
    final elf = _elfFile;
    return elf != null && symbolByName(elf, '_SEGGER_RTT') != null;
  }

  /// Attach via the built-in USB JTAG and read defmt logs from the RTT
  /// ring buffer in RAM — the probe-rs workflow, firmware untouched.
  /// Needs an ELF (defmt table + `_SEGGER_RTT` symbol) and a device on
  /// its native USB-Serial-JTAG port.
  Future<void> startRtt() async {
    final device = _device;
    final table = _table;
    if (device == null || state.phase != MonitorPhase.idle) {
      return;
    }
    if (table == null) {
      _banner('Pick the firmware ELF first — RTT decoding needs it',
          isError: true);
      return;
    }
    if (!device.isUsbJtag) {
      _banner(
        "RTT needs the chip's native USB port (USB JTAG); "
        "UART bridges can't do this",
        isError: true,
      );
      return;
    }
    state = state.copyWith(
      phase: MonitorPhase.connecting,
      statusBanner: () => null,
    );
    try {
      await _usb.jtagOpen(device);
      final dtm = RiscvDtm(JtagTap(EspUsbJtag(_UsbJtagWire(_usb))));
      await dtm.init();
      // Without this the debug module stays in reset and every memory
      // read comes back as zeros.
      await dtm.attach();
      _dtm = dtm;
      final mem = _SbaMemory(dtm);
      final block = await locateRtt(mem, _elfFile);
      // Prefer the channel named "defmt".
      RttUpChannel? chosen;
      for (final channel in block.upChannels) {
        final reader = RttChannelReader(mem, channel);
        final name = await reader.readName();
        chosen ??= channel;
        if (name == 'defmt') {
          chosen = channel;
          break;
        }
      }
      final channel = chosen;
      if (channel == null) {
        throw const RttError('control block has no up channels');
      }
      _rttReader = RttChannelReader(mem, channel);
      _rttDecoder = DefmtStreamDecoder(table);
      state = state.copyWith(
        phase: MonitorPhase.streaming,
        source: () => 'rtt',
        bytesReceived: 0,
        droppedFrames: 0,
      );
      await _screenOn(true);
      _rttTimer = Timer.periodic(
        const Duration(milliseconds: 60),
        (_) => unawaited(_pollRtt()),
      );
    } on Object catch (error) {
      final details = _dtm?.diagnostics ?? '';
      await _teardown();
      _banner(
        '$error${details.isEmpty ? '' : ' [$details]'}',
        isError: true,
      );
    }
  }

  Future<void> _pollRtt() async {
    if (_rttPolling) {
      return; // previous poll still in flight
    }
    _rttPolling = true;
    try {
      final reader = _rttReader;
      final decoder = _rttDecoder;
      if (reader == null || decoder == null) {
        return;
      }
      final bytes = await reader.poll();
      if (bytes.isEmpty || state.paused) {
        return;
      }
      final lines = <MonitorLine>[
        for (final line in decoder.feed(bytes))
          switch (line) {
            DefmtLine(:final frame) => MonitorLine(
              text: frame.text,
              level: frame.level,
              timestamp: frame.timestamp,
            ),
            RawLine(:final bytes) => MonitorLine(
              text: String.fromCharCodes(bytes),
              isRaw: true,
            ),
          },
      ];
      var all = <MonitorLine>[...state.lines, ...lines];
      if (all.length > _maxLines) {
        all = all.sublist(all.length - _maxLines);
      }
      state = state.copyWith(
        lines: all,
        bytesReceived: state.bytesReceived + bytes.length,
        droppedFrames: decoder.droppedFrames,
      );
    } on Object catch (error) {
      _banner('RTT read failed: $error', isError: true);
      await _teardown();
    } finally {
      _rttPolling = false;
    }
  }

  /// Stream the serial port the session already opened. No bootloader
  /// sync: the chip runs its firmware and we just listen.
  Future<void> start() async {
    final device = _device;
    if (device == null || state.phase != MonitorPhase.idle) {
      return;
    }
    state = state.copyWith(
      phase: MonitorPhase.connecting,
      statusBanner: () => null,
    );
    try {
      _rawPending.clear();
      _dataSub = _usb.data.listen(
        _onData,
        onError: (Object error) =>
            _banner('serial error: $error', isError: true),
      );
      state = state.copyWith(
        phase: MonitorPhase.streaming,
        source: () => 'serial',
        bytesReceived: 0,
      );
      await _screenOn(true);
      // Most firmware logs at boot: reset so the user actually sees
      // output. A failed reset must not kill the stream.
      try {
        await _resetChip(device);
      } on Object catch (error) {
        _banner('auto-reset failed: $error (streaming anyway)');
      }
    } on Object catch (error) {
      await _teardown();
      _banner('$error', isError: true);
    }
  }

  Future<void> stop() async {
    await _teardown();
  }

  /// Reboot the chip into its firmware.
  ///
  /// On UART bridges this is an EN pulse via RTS. On the native
  /// USB-Serial-JTAG port DTR/RTS never reach the chip, so we enter the
  /// ROM bootloader and trigger an RTC watchdog reset instead (same as
  /// the flasher's post-flash reboot).
  Future<void> resetChip() async {
    final device = _device;
    if (state.phase != MonitorPhase.streaming || device == null) {
      return;
    }
    try {
      await _resetChip(device);
    } on Object catch (error) {
      _banner('reset failed: $error', isError: true);
    }
  }

  /// Reboot the chip into its firmware.
  ///
  /// Never enters the ROM bootloader: syncing requires the chip to be in
  /// download mode, which fails outright while user firmware runs (the
  /// old path reported "Failed to sync with the ROM bootloader"). In RTT
  /// mode the debug module does a system reset; otherwise the auto-reset
  /// lines are pulsed, which is a no-op on native USB but harmless.
  Future<void> _resetChip(UsbDevice device) async {
    final dtm = _dtm;
    if (dtm != null) {
      await dtm.resetSystem();
      return;
    }
    // Release the lines first: a stuck-low EN holds the chip in reset.
    await _usb.setDtr(false);
    await _usb.setRts(false);
    await const HardReset().reset(_TransportAdapter(_usb));
    _rawPending.clear();
    final table = _table;
    if (table != null) {
      _decoder = DefmtLogDecoder(table);
    }
  }

  void togglePause() {
    state = state.copyWith(paused: !state.paused);
  }

  void toggleHexMode() {
    state = state.copyWith(hexMode: !state.hexMode);
  }

  /// One line of offset-prefixed lowercase hex, 16 bytes per row.
  String _hexDump(Uint8List bytes) => [
    for (var i = 0; i < bytes.length; i += 16)
      _hexRow(bytes, i),
  ].join('\n');

  String _hexRow(Uint8List bytes, int offset) {
    final end = offset + 16 > bytes.length ? bytes.length : offset + 16;
    final hex = bytes
        .sublist(offset, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return '${offset.toRadixString(16).padLeft(4, '0')}: $hex';
  }

  void clearLog() {
    state = state.copyWith(lines: const <MonitorLine>[]);
  }

  /// All captured lines, rendered as shown in the log view.
  String copyableLog() => state.lines
      .map((line) {
        final ts = line.timestamp == null ? '' : '[${line.timestamp}] ';
        final level = line.level == null
            ? ''
            : '${line.level!.name.toUpperCase()} ';
        return '$ts$level${line.text}';
      })
      .join('\n');

  void setFilter(String filter) {
    state = state.copyWith(filter: filter);
  }

  void setMinLevel(DefmtLevel? level) {
    state = state.copyWith(minLevel: () => level);
  }

  void _onData(Uint8List bytes) {
    if (_suppressData || state.paused) {
      return;
    }
    final decoder = _decoder;
    final lines = <MonitorLine>[];
    if (state.hexMode) {
      // Pure diagnostic view: hex only, decoded lines would just
      // duplicate the same bytes as (mangled) text.
      lines.add(MonitorLine(text: _hexDump(bytes), isRaw: true));
      decoder?.feed(bytes); // keep dropped-frame counter honest
    } else if (decoder == null) {
      // No ELF staged: everything is raw text.
      lines.addAll(_rawTextLines(bytes));
    } else {
      for (final line in decoder.feed(bytes)) {
        switch (line) {
          case RawLine(:final bytes):
            lines.addAll(_rawTextLines(bytes));
          case DefmtLine(:final frame):
            if (_rawPending.isNotEmpty) {
              lines.add(_rawLine(_rawPending));
              _rawPending.clear();
            }
            lines.add(
              MonitorLine(
                text: frame.text,
                level: frame.level,
                timestamp: frame.timestamp,
              ),
            );
        }
      }
    }
    var all = <MonitorLine>[...state.lines, ...lines];
    if (all.length > _maxLines) {
      all = all.sublist(all.length - _maxLines);
    }
    state = state.copyWith(
      lines: all,
      bytesReceived: state.bytesReceived + bytes.length,
      droppedFrames: decoder?.droppedFrames ?? 0,
    );
  }

  /// Split raw bytes into newline-terminated text lines; hold the
  /// trailing partial line until its newline arrives.
  List<MonitorLine> _rawTextLines(List<int> bytes) {
    _rawPending.addAll(bytes);
    final lines = <MonitorLine>[];
    var start = 0;
    for (var i = 0; i < _rawPending.length; i++) {
      if (_rawPending[i] == 0x0a) {
        lines.add(_rawLine(_rawPending.sublist(start, i)));
        start = i + 1;
      }
    }
    _rawPending.removeRange(0, start);
    // Don't let an unterminated line grow unbounded.
    if (_rawPending.length > 512) {
      lines.add(_rawLine(_rawPending));
      _rawPending.clear();
    }
    return lines;
  }

  MonitorLine _rawLine(List<int> bytes) {
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.endsWith('\r')) {
      text = text.substring(0, text.length - 1);
    }
    return MonitorLine(text: text, isRaw: true);
  }

  /// Stops streaming. The port stays open: it belongs to the session,
  /// and the flash screen may want it next.
  Future<void> _teardown() async {
    _rttTimer?.cancel();
    _rttTimer = null;
    _rttReader = null;
    _rttDecoder = null;
    _dtm = null;
    await _dataSub?.cancel();
    _dataSub = null;
    try {
      await _usb.jtagClose();
    } on Object {
      // Not open / device gone.
    }
    await _screenOn(false);
    _session.release(DeviceActivity.monitoring);
    state = state.copyWith(phase: MonitorPhase.idle, source: () => null);
  }

  /// Keep the screen awake while streaming; tolerate platforms where the
  /// wakelock plugin is unavailable (desktop, tests).
  Future<void> _screenOn(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } on Object {
      // No wakelock on this platform.
    }
  }

  void _banner(String message, {bool isError = false}) {
    state = state.copyWith(statusBanner: () => message, bannerIsError: isError);
  }
}

/// Minimal [EspTransport] view over [UsbService] so reset strategies can
/// toggle DTR/RTS without the full connection layer.
final class _TransportAdapter implements EspTransport {
  const _TransportAdapter(this._usb);

  final UsbService _usb;

  @override
  Future<void> setDtr(bool value) => _usb.setDtr(value);

  @override
  Future<void> setRts(bool value) => _usb.setRts(value);

  @override
  Future<void> write(List<int> data) => _usb.write(data);

  @override
  Stream<List<int>> get chunks => _usb.data;

  @override
  Future<void> setBaud(int baud) => _usb.setBaud(baud);

  @override
  int? get vendorId => null;

  @override
  int? get productId => null;

  @override
  bool get isUsbJtag => false;

  @override
  Future<void> close() => _usb.close();
}

/// [JtagWire] over the USB JTAG bulk endpoints.
final class _UsbJtagWire implements JtagWire {
  const _UsbJtagWire(this._usb);

  final UsbService _usb;

  @override
  Future<void> write(Uint8List bytes) => _usb.jtagWrite(bytes);

  @override
  Future<Uint8List> read(int maxLen, Duration timeout) =>
      _usb.jtagRead(maxLen: maxLen, timeoutMs: timeout.inMilliseconds);
}

/// [TargetMemory] over the DTM's System Bus Access.
final class _SbaMemory implements TargetMemory {
  const _SbaMemory(this._dtm);

  final RiscvDtm _dtm;

  @override
  Future<int> read32(int address) => _dtm.readMem32(address);

  @override
  Future<Uint32List> readBlock(int address, int wordCount) =>
      _dtm.readMemBlock(address, wordCount);

  @override
  Future<void> write32(int address, int value) =>
      _dtm.writeMem32(address, value);
}
