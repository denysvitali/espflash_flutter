import 'dart:async';
import 'dart:typed_data';

import 'package:espflash_flutter/platform/firmware_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('firmware_sources_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('consumes a file that launched the app', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'takePendingFile');
      return <String, Object?>{
        'name': 'build.tar.gz',
        'bytes': Uint8List.fromList(<int>[0x1f, 0x8b, 1, 2]),
      };
    });
    final received = <IncomingFirmwareFile>[];
    final service = FirmwareSourceService(channel: channel);

    await service.start((file) async => received.add(file));

    expect(received, hasLength(1));
    expect(received.single.name, 'build.tar.gz');
    expect(received.single.bytes, <int>[0x1f, 0x8b, 1, 2]);
    service.dispose();
  });

  test('consumes a file delivered while the app is running', () async {
    var pending = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (!pending) {
        return null;
      }
      pending = false;
      return <String, Object?>{
        'name': 'firmware.bin',
        'bytes': Uint8List.fromList(<int>[0xe9, 1, 2, 3]),
      };
    });
    final received = Completer<IncomingFirmwareFile>();
    final service = FirmwareSourceService(channel: channel);
    await service.start((file) async => received.complete(file));

    pending = true;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('fileAvailable'),
      ),
      (_) {},
    );
    final file = await received.future;

    expect(file.name, 'firmware.bin');
    expect(file.bytes, <int>[0xe9, 1, 2, 3]);
    service.dispose();
  });

  test('rejects malformed native payloads', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => <String, Object?>{'name': 'firmware.bin', 'bytes': 'bad'},
    );
    final service = FirmwareSourceService(channel: channel);

    await expectLater(service.start((_) async {}), throwsFormatException);
    service.dispose();
  });
}
