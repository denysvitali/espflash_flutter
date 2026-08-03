/// Orchestration behind the serial monitor screen: ELF staging, USB
/// permission, raw serial streaming, defmt decoding.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../defmt/defmt.dart';
import '../esp/chip_detect.dart';
import '../esp/connection.dart';
import '../esp/errors.dart';
import '../esp/reset.dart';
import '../esp/transport.dart';
import '../usb/android_usb_transport.dart';
import '../usb/usb_device.dart';
import '../usb/usb_events.dart';
import '../usb/usb_service.dart';
import 'monitor_state.dart';

/// Screen state + actions.
final monitorControllerProvider =
    NotifierProvider<MonitorController, MonitorState>(MonitorController.new);

/// Keeps the log bounded; oldest lines drop off the front.
const _maxLines = 5000;

final class MonitorController extends Notifier<MonitorState> {
  MonitorController([UsbService? usb]) : _usb = usb ?? UsbService();

  final UsbService _usb;

  StreamSubscription<UsbEvent>? _eventsSub;
  StreamSubscription<Uint8List>? _dataSub;
  Completer<bool>? _permissionWaiter;
  DefmtTable? _table;
  DefmtLogDecoder? _decoder;

  /// While the USB-JTAG reset dance runs, SLIP chatter hits the data
  /// stream; don't decode it as log output.
  bool _suppressData = false;

  /// Partial raw text not yet terminated by a newline.
  final List<int> _rawPending = <int>[];

  @override
  MonitorState build() {
    _eventsSub ??= _usb.events.listen(
      _onUsbEvent,
      onError: (Object _) {
        // No USB host stack (desktop, tests).
      },
    );
    ref.onDispose(() async {
      await _dataSub?.cancel();
      await _eventsSub?.cancel();
      try {
        await _usb.close();
      } on Object {
        // Port already gone.
      }
    });
    return const MonitorState();
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
      );
    } on Object catch (error) {
      _banner('USB not available: $error', isError: true);
    }
  }

  void selectDevice(String? deviceId) {
    state = state.copyWith(selectedDeviceId: () => deviceId);
  }

  /// Pick an ELF and build the defmt table from it.
  Future<void> pickElf() async {
    final result = await FilePicker.pickFiles(withData: true);
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) {
      return;
    }
    try {
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
      _rawPending.clear();
      state = state.copyWith(
        elf: () => ElfInfo(
          name: file.name,
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
    state = state.copyWith(elf: () => null);
  }

  /// Permission → open → start streaming. No bootloader sync: the device
  /// runs its normal firmware and we just listen.
  Future<void> start() async {
    final device = state.selectedDevice;
    if (device == null || state.phase != MonitorPhase.idle) {
      return;
    }
    state = state.copyWith(
      phase: MonitorPhase.connecting,
      statusBanner: () => null,
    );
    try {
      await _ensurePermission(device);
      // The flash screen may hold the port; make sure it's free.
      try {
        await _usb.close();
      } on Object {
        // Wasn't open.
      }
      await _usb.open(device);
      _rawPending.clear();
      _dataSub = _usb.data.listen(
        _onData,
        onError: (Object error) =>
            _banner('serial error: $error', isError: true),
      );
      state = state.copyWith(phase: MonitorPhase.streaming, bytesReceived: 0);
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
    final device = state.selectedDevice;
    if (state.phase != MonitorPhase.streaming || device == null) {
      return;
    }
    try {
      await _resetChip(device);
    } on Object catch (error) {
      _banner('reset failed: $error', isError: true);
    }
  }

  Future<void> _resetChip(UsbDevice device) async {
    if (!device.isUsbJtag) {
      // Release the auto-reset lines, then pulse EN.
      await _usb.setDtr(false);
      await _usb.setRts(false);
      await const HardReset().reset(_TransportAdapter(_usb));
      return;
    }
    _suppressData = true;
    try {
      final transport = AndroidUsbTransport(service: _usb, device: device);
      final connection = EspConnection(transport);
      await connection.connect(resetStrategy: const UsbJtagReset());
      final target = await detectChip(connection);
      await target.rtcWdtReset(connection);
      await connection.close();
    } finally {
      _suppressData = false;
      _rawPending.clear();
      // SLIP noise may have left the frame parser mid-frame; start fresh.
      final table = _table;
      if (table != null) {
        _decoder = DefmtLogDecoder(table);
      }
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
      lines.add(MonitorLine(text: _hexDump(bytes), isRaw: true));
    }
    if (decoder == null) {
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
          unawaited(_teardown());
          _banner('Device unplugged.', isError: true);
        }
        unawaited(refreshDevices());
    }
  }

  Future<void> _teardown() async {
    await _dataSub?.cancel();
    _dataSub = null;
    try {
      await _usb.close();
    } on Object {
      // Port already gone.
    }
    state = state.copyWith(phase: MonitorPhase.idle);
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
