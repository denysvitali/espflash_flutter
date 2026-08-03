import 'package:espflash_flutter/defmt/table.dart';
import 'package:espflash_flutter/ui/monitor_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MonitorState.visibleLines', () {
    const lines = <MonitorLine>[
      MonitorLine(text: 'ESP-ROM boot', isRaw: true),
      MonitorLine(text: 'starting app', level: DefmtLevel.info),
      MonitorLine(text: 'sensor read 42', level: DefmtLevel.debug),
      MonitorLine(text: 'bus hung', level: DefmtLevel.error),
      MonitorLine(text: 'plain println'),
    ];

    test('no filter, no level → everything', () {
      const state = MonitorState(lines: lines);
      expect(state.visibleLines, hasLength(5));
    });

    test('substring filter is case-insensitive', () {
      const state = MonitorState(lines: lines, filter: 'SENSOR');
      expect(state.visibleLines, hasLength(1));
      expect(state.visibleLines.single.text, 'sensor read 42');
    });

    test('min level hides lower defmt levels, keeps raw/println', () {
      const state = MonitorState(lines: lines, minLevel: DefmtLevel.info);
      expect(
        state.visibleLines.map((l) => l.text),
        ['ESP-ROM boot', 'starting app', 'bus hung', 'plain println'],
      );
    });

    test('error-only level', () {
      const state = MonitorState(lines: lines, minLevel: DefmtLevel.error);
      expect(
        state.visibleLines.map((l) => l.text),
        ['ESP-ROM boot', 'bus hung', 'plain println'],
      );
    });

    test('filter and level compose', () {
      const state = MonitorState(
        lines: lines,
        filter: 'u',
        minLevel: DefmtLevel.warn,
      );
      expect(state.visibleLines.map((l) => l.text), ['bus hung']);
    });
  });
}
