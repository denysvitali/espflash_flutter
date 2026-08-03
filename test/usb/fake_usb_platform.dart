import 'dart:typed_data';

import 'package:espflash_flutter/usb/channels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fakes the Kotlin `UsbSerialManager` at the binary-messenger level:
/// records method calls, serves canned responses, and can push maps onto
/// the events and data EventChannels.
class FakeUsbPlatform {
  FakeUsbPlatform(this.messenger);

  final TestDefaultBinaryMessenger messenger;

  /// Every method call received, in order.
  final List<MethodCall> calls = [];

  /// One-shot error injection per method name.
  final Map<String, PlatformException> errors = {};

  /// Canned `listDevices` response.
  List<Object?> devices = <Object?>[];

  /// Canned `hasPermission` response.
  bool permission = true;

  void install() {
    messenger.setMockMethodCallHandler(
      const MethodChannel(UsbChannels.methods),
      _handleMethodCall,
    );
    // EventChannel control messages (listen/cancel) just need an ack.
    messenger.setMockMethodCallHandler(
      const MethodChannel(UsbChannels.events),
      (MethodCall call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(UsbChannels.data),
      (MethodCall call) async => null,
    );
  }

  void uninstall() {
    messenger.setMockMethodCallHandler(
      const MethodChannel(UsbChannels.methods),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(UsbChannels.events),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(UsbChannels.data),
      null,
    );
  }

  /// The first recorded call with the given method name.
  MethodCall callFor(String method) =>
      calls.firstWhere((MethodCall c) => c.method == method);

  /// Pushes one lifecycle map onto the events EventChannel.
  Future<void> emitEvent(Map<String, Object?> event) =>
      _push(UsbChannels.events, event);

  /// Pushes one raw chunk onto the data EventChannel.
  Future<void> emitData(Uint8List chunk) => _push(UsbChannels.data, chunk);

  Future<Object?> _handleMethodCall(MethodCall call) async {
    calls.add(call);
    final PlatformException? injected = errors.remove(call.method);
    if (injected != null) {
      throw injected;
    }
    switch (call.method) {
      case 'listDevices':
        return devices;
      case 'hasPermission':
        return permission;
      default:
        return null;
    }
  }

  Future<void> _push(String channel, Object? value) async {
    final ByteData envelope =
        const StandardMethodCodec().encodeSuccessEnvelope(value);
    await messenger.handlePlatformMessage(channel, envelope, (ByteData? _) {});
  }
}
