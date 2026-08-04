// Layout regression test: the monitor controls used to share one Row
// with six icon buttons, which starved the file-picker button until its
// label wrapped one letter per line. Renders at a narrow phone width and
// asserts no overflow and a readable label.

import 'package:espflash_flutter/ui/monitor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('controls fit a 360dp phone without overflowing', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: MonitorPage()),
      ),
    );
    await tester.pumpAndSettle();

    // A RenderFlex overflow is reported through the exception channel.
    expect(tester.takeException(), isNull);

    // The picker label must render on at most two lines — the bug made
    // it one character per line (26+ lines).
    final label = find.text('Pick ELF or .tar.gz bundle');
    expect(label, findsOneWidget);
    final box = tester.renderObject<RenderBox>(label);
    final lineHeight =
        tester.widget<Text>(label).style?.fontSize ?? 14.0;
    expect(
      box.size.height,
      lessThan(lineHeight * 4),
      reason: 'label wrapped into a vertical column of letters',
    );
    expect(box.size.width, greaterThan(100));
    expect(
      box.size.width,
      greaterThan(box.size.height),
      reason: 'a taller-than-wide label means it wrapped per character',
    );
  });

  testWidgets('controls survive large system text sizes', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: MonitorPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
