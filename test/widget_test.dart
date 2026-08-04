// Smoke test: the app renders its sections without a USB host stack
// (the session reports 'USB not available' instead of crashing), and
// offers exactly one place to connect.

import 'package:espflash_flutter/main.dart';
import 'package:espflash_flutter/ui/device_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App renders firmware, flash and log sections', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: EspflashApp()));
    await tester.pumpAndSettle();

    expect(find.text('espflash'), findsOneWidget);
    expect(find.text('Firmware'), findsOneWidget);
    expect(find.text('not connected'), findsOneWidget);
    // Exactly one connect control in the whole app.
    expect(find.byType(DeviceBar), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    // Nothing connected: the flash button explains the blocker.
    expect(find.text('Connect a device first'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('logCardTitle')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Log'), findsWidgets);
  });
}
