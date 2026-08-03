/// Dart facade over the Android USB platform channels. The Kotlin side is
/// `UsbSerialManager` in the android source set.
library;

import 'package:flutter/services.dart';

import '../esp/errors.dart';
import 'channels.dart';
import 'usb_device.dart';
import 'usb_events.dart';

/// Facade over the `espflash_flutter/usb` method channel and the two
/// EventChannels for lifecycle events and raw serial data.
class UsbService {
  UsbService({
    MethodChannel? methodChannel,
    EventChannel? eventsChannel,
    EventChannel? dataChannel,
  }) : _methods = methodChannel ?? const MethodChannel(UsbChannels.methods),
       _events = eventsChannel ?? const EventChannel(UsbChannels.events),
       _data = dataChannel ?? const EventChannel(UsbChannels.data);

  final MethodChannel _methods;
  final EventChannel _events;
  final EventChannel _data;

  Stream<UsbEvent>? _eventsStream;
  Stream<Uint8List>? _dataStream;

  /// Device/permission lifecycle events. Broadcast; safe to listen more
  /// than once.
  Stream<UsbEvent> get events => _eventsStream ??= _events
      .receiveBroadcastStream()
      .map((Object? event) => UsbEvent.fromMap(event as Map<Object?, Object?>));

  /// Raw serial byte chunks, in arrival order. Broadcast.
  Stream<Uint8List> get data =>
      _dataStream ??= _data.receiveBroadcastStream().map((Object? chunk) {
        if (chunk is Uint8List) {
          return chunk;
        }
        final list = chunk as List<Object?>;
        return Uint8List.fromList(list.cast<int>());
      });

  /// All attached devices with a serial driver known to the platform side.
  Future<List<UsbDevice>> listDevices() async {
    final raw = await _methods.invokeMethod<List<Object?>>('listDevices');
    final devices = <UsbDevice>[];
    for (final entry in raw ?? const <Object?>[]) {
      devices.add(UsbDevice.fromMap(entry! as Map<Object?, Object?>));
    }
    return devices;
  }

  /// Whether USB permission is already granted for [device]. A device that
  /// vanished reports `false` rather than an error.
  Future<bool> hasPermission(UsbDevice device) async {
    final granted = await _methods.invokeMethod<bool>(
      'hasPermission',
      <String, Object?>{'deviceId': device.deviceId},
    );
    return granted ?? false;
  }

  /// Triggers the system permission dialog. The outcome arrives later as a
  /// [UsbPermissionGranted] or [UsbPermissionDenied] event on [events].
  Future<void> requestPermission(UsbDevice device) => _guard(
    _methods.invokeMethod<void>('requestPermission', <String, Object?>{
      'deviceId': device.deviceId,
    }),
  );

  /// Opens the port at 115200 8N1 with DTR/RTS raised.
  Future<void> open(UsbDevice device) => _guard(
    _methods.invokeMethod<void>('open', <String, Object?>{
      'deviceId': device.deviceId,
    }),
  );

  Future<void> close() => _methods.invokeMethod<void>('close');

  /// Writes one already-SLIP-framed buffer to the port.
  Future<void> write(List<int> bytes) => _guard(
    _methods.invokeMethod<void>('write', <String, Object?>{
      'bytes': bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    }),
  );

  Future<void> setBaud(int baud) => _guard(
    _methods.invokeMethod<void>('setBaud', <String, Object?>{'baud': baud}),
  );

  Future<void> setDtr(bool value) => _guard(
    _methods.invokeMethod<void>('setDtr', <String, Object?>{'value': value}),
  );

  Future<void> setRts(bool value) => _guard(
    _methods.invokeMethod<void>('setRts', <String, Object?>{'value': value}),
  );

  /// Maps platform errors caused by the device going away to
  /// [EspDeviceLostError]; anything else is rethrown unchanged.
  Future<void> _guard(Future<void> pending) async {
    try {
      await pending;
    } on PlatformException catch (e) {
      const lostCodes = {'notFound', 'notOpen', 'writeFailed'};
      if (lostCodes.contains(e.code)) {
        throw EspDeviceLostError(e.message ?? 'USB device lost');
      }
      rethrow;
    }
  }
}
