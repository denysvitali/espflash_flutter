/// Receives firmware files used to launch (or resume) the Android app.
library;

import 'package:flutter/services.dart';

const _firmwareSourcesChannel = MethodChannel(
  'com.example.espflash_flutter/firmware_sources',
);

final class IncomingFirmwareFile {
  const IncomingFirmwareFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Bridges Android ACTION_VIEW/ACTION_SEND intents to the flash screen.
///
/// Android retains an incoming content URI until [takePendingFile] reads it,
/// which makes cold starts safe even when Flutter initialization is slower
/// than the activity lifecycle.
final class FirmwareSourceService {
  FirmwareSourceService({MethodChannel channel = _firmwareSourcesChannel})
    : _channel = channel;

  final MethodChannel _channel;
  Future<void> Function(IncomingFirmwareFile file)? _onFile;
  void Function(Object error)? _onError;

  Future<void> start(
    Future<void> Function(IncomingFirmwareFile file) onFile, {
    void Function(Object error)? onError,
  }) async {
    _onFile = onFile;
    _onError = onError;
    _channel.setMethodCallHandler(_handleNativeCall);
    await _consumePendingFile();
  }

  void dispose() {
    _onFile = null;
    _onError = null;
    _channel.setMethodCallHandler(null);
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'fileAvailable') {
      try {
        await _consumePendingFile();
      } on Object catch (error) {
        _onError?.call(error);
      }
    }
  }

  Future<void> _consumePendingFile() async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'takePendingFile',
    );
    if (value == null) {
      return;
    }
    final name = value['name'];
    final bytes = value['bytes'];
    if (name is! String || bytes is! Uint8List) {
      throw const FormatException('Android returned an invalid firmware file');
    }
    await _onFile?.call(IncomingFirmwareFile(name: name, bytes: bytes));
  }
}
