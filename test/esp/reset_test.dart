import 'package:espflash_flutter/esp/reset.dart';
import 'package:espflash_flutter/esp/transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_transport.dart';

/// One DTR/RTS transition or sleep, in execution order.
typedef ResetEvent = (String kind, Object value);

void main() {
  late FakeTransport transport;
  late List<ResetEvent> events;

  /// Injectable fake clock: records the duration, never waits.
  Future<void> fakeSleep(Duration duration) async {
    events.add(('sleep', duration));
  }

  setUp(() {
    transport = FakeTransport();
    events = <ResetEvent>[];
    transport.onWrite = null;
  });

  // Wrap the fake transport so line toggles land in [events] too.
  Future<List<ResetEvent>> run(ResetStrategy strategy) async {
    final recording = _RecordingTransport(transport, events);
    await strategy.reset(recording);
    return events;
  }

  group('ClassicReset', () {
    test('D0 R1 W100 D1 R0 W50 D0', () async {
      final events = await run(ClassicReset(sleep: fakeSleep));
      expect(events, [
        ('dtr', false),
        ('rts', true),
        ('sleep', const Duration(milliseconds: 100)),
        ('dtr', true),
        ('rts', false),
        ('sleep', const Duration(milliseconds: 50)),
        ('dtr', false),
      ]);
    });

    test('honors a custom reset delay', () async {
      final events = await run(
        ClassicReset(
          resetDelay: const Duration(milliseconds: 550),
          sleep: fakeSleep,
        ),
      );
      final sleeps = events
          .where((e) => e.$1 == 'sleep')
          .map((e) => e.$2)
          .toList();
      expect(sleeps, [
        const Duration(milliseconds: 100),
        const Duration(milliseconds: 550),
      ]);
    });
  });

  group('UsbJtagReset', () {
    test('follows the plan sequence exactly', () async {
      final events = await run(UsbJtagReset(sleep: fakeSleep));
      expect(events, [
        ('rts', true),
        ('dtr', true),
        ('sleep', const Duration(milliseconds: 100)),
        ('dtr', false),
        ('rts', true),
        ('sleep', const Duration(milliseconds: 100)),
        ('rts', false),
        ('dtr', true),
        ('rts', false),
        ('sleep', const Duration(milliseconds: 100)),
        ('dtr', false), // DTR false -> true
        ('dtr', true),
        ('rts', false), // RTS false -> true
        ('rts', true),
      ]);
    });

    test('sleeps 3 x 100 ms', () async {
      final events = await run(UsbJtagReset(sleep: fakeSleep));
      final sleeps = events.where((e) => e.$1 == 'sleep').toList();
      expect(sleeps, hasLength(3));
      for (final sleep in sleeps) {
        expect(sleep.$2, const Duration(milliseconds: 100));
      }
    });
  });

  group('HardReset', () {
    test('holds RTS low for 100 ms', () async {
      final events = await run(HardReset(sleep: fakeSleep));
      expect(events, [
        ('rts', true),
        ('sleep', const Duration(milliseconds: 100)),
        ('rts', false),
      ]);
    });

    test('never touches DTR', () async {
      final events = await run(HardReset(sleep: fakeSleep));
      expect(events.where((e) => e.$1 == 'dtr'), isEmpty);
    });
  });

  test('real sleep function is used when none is injected', () {
    // Just construction: defaultSleep must be the fallback.
    expect(const ClassicReset().sleep, defaultSleep);
    expect(const UsbJtagReset().sleep, defaultSleep);
    expect(const HardReset().sleep, defaultSleep);
  });
}

/// Routes DTR/RTS writes into the shared event list while delegating
/// everything else to the wrapped transport.
final class _RecordingTransport implements EspTransport {
  _RecordingTransport(this.inner, this.events);

  final FakeTransport inner;
  final List<ResetEvent> events;

  @override
  Future<void> write(List<int> data) => inner.write(data);

  @override
  Stream<List<int>> get chunks => inner.chunks;

  @override
  Future<void> setBaud(int baud) => inner.setBaud(baud);

  @override
  Future<void> setDtr(bool value) async {
    events.add(('dtr', value));
  }

  @override
  Future<void> setRts(bool value) async {
    events.add(('rts', value));
  }

  @override
  int? get vendorId => inner.vendorId;

  @override
  int? get productId => inner.productId;

  @override
  bool get isUsbJtag => inner.isUsbJtag;

  @override
  Future<void> close() => inner.close();
}
