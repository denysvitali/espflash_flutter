// Smoke test: the app renders its four sections without a USB host
// stack (the controller logs 'USB not available' instead of crashing).

import 'package:espflash_flutter/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App renders device, firmware, flash and log sections', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: EspflashApp()));
    await tester.pumpAndSettle();

    expect(find.text('espflash'), findsOneWidget);
    expect(find.text('Device'), findsOneWidget);
    expect(find.text('Firmware'), findsOneWidget);
    expect(find.text('not connected'), findsOneWidget);
    // No device connected: the flash button explains the blocker.
    expect(find.text('Connect a device first'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('logCardTitle')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Log'), findsWidgets);
  });
}
