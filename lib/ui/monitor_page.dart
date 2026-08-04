/// Serial monitor screen: stage an ELF, attach to the device's UART
/// output, watch defmt frames decoded live (raw text passes through).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../defmt/table.dart';
import 'device_bar.dart';
import 'device_session.dart';
import 'monitor_controller.dart';
import 'monitor_state.dart';

/// Serial monitor with defmt decoding.
class MonitorPage extends ConsumerStatefulWidget {
  const MonitorPage({super.key});

  @override
  ConsumerState<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends ConsumerState<MonitorPage> {
  final ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(deviceSessionProvider.notifier).refreshDevices();
    });
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(monitorControllerProvider);
    final controller = ref.read(monitorControllerProvider.notifier);
    ref.listen(monitorControllerProvider.select((s) => s.lines.length), (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Serial monitor')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              children: <Widget>[
                const DeviceBar(),
                const SizedBox(height: 8),
                _ControlsBar(state: state, controller: controller),
                if (state.statusBanner != null) ...<Widget>[
                  const SizedBox(height: 8),
                  _Banner(state: state),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _LogView(state: state, scroll: _logScroll),
          ),
        ],
      ),
    );
  }
}

class _ControlsBar extends ConsumerWidget {
  const _ControlsBar({required this.state, required this.controller});

  final MonitorState state;
  final MonitorController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final elf = state.elf;
    final streaming = state.phase == MonitorPhase.streaming;
    final connected = ref.watch(deviceSessionProvider).isConnected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Firmware picker gets its own full-width row: sharing one row
        // with the action icons left it a few pixels wide, which wrapped
        // the label one letter per line.
        if (elf != null)
          Align(
            alignment: Alignment.centerLeft,
            child: InputChip(
              avatar: const Icon(Icons.description_outlined, size: 18),
              label: Text(
                '${elf.name} — ${elf.entryCount} strings, '
                'defmt v${elf.version}'
                '${elf.hasTimestamp ? '' : ' (no timestamp)'}',
                overflow: TextOverflow.ellipsis,
              ),
              onDeleted: streaming ? null : controller.clearElf,
            ),
          )
        else
          FilledButton.tonalIcon(
            onPressed: controller.pickElf,
            icon: const Icon(Icons.folder_open),
            label: const Text('Pick ELF or .tar.gz bundle'),
          ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            FilledButton.icon(
              onPressed: connected ? controller.connect : null,
              icon: Icon(streaming ? Icons.stop : Icons.play_arrow),
              label: Text(streaming ? 'Stop' : 'Start'),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(state.paused ? Icons.play_circle : Icons.pause_circle),
              tooltip: state.paused ? 'Resume' : 'Pause',
              onPressed: controller.togglePause,
            ),
            IconButton(
              icon: const Icon(Icons.restart_alt),
              tooltip: 'Reset chip',
              onPressed: streaming ? controller.resetChip : null,
            ),
            const Spacer(),
            // Secondary actions live in an overflow menu so the row can
            // never run out of width.
            PopupMenuButton<String>(
              tooltip: 'More actions',
              onSelected: (String action) {
                switch (action) {
                  case 'hex':
                    controller.toggleHexMode();
                  case 'copy':
                    Clipboard.setData(
                      ClipboardData(text: controller.copyableLog()),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Logs copied to clipboard'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  case 'clear':
                    controller.clearLog();
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                CheckedPopupMenuItem<String>(
                  value: 'hex',
                  checked: state.hexMode,
                  child: const Text('Hex dump'),
                ),
                PopupMenuItem<String>(
                  value: 'copy',
                  enabled: state.lines.isNotEmpty,
                  child: const Text('Copy all logs'),
                ),
                PopupMenuItem<String>(
                  value: 'clear',
                  enabled: state.lines.isNotEmpty,
                  child: const Text('Clear log'),
                ),
              ],
            ),
          ],
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  labelText: 'Filter',
                  prefixIcon: Icon(Icons.filter_alt_outlined, size: 18),
                ),
                onChanged: controller.setFilter,
              ),
            ),
            const SizedBox(width: 8),
            // Flexible, not fixed: at large system text sizes these
            // dropdowns grow and would otherwise overflow the row.
            Flexible(
              child: DropdownButton<MonitorSource>(
                isExpanded: true,
                value: state.preferredSource,
                underline: const SizedBox.shrink(),
                onChanged: streaming
                    ? null
                    : (MonitorSource? source) {
                        if (source != null) {
                          controller.setSource(source);
                        }
                      },
                items: const <DropdownMenuItem<MonitorSource>>[
                  DropdownMenuItem<MonitorSource>(
                    value: MonitorSource.auto,
                    child: Text('Auto'),
                  ),
                  DropdownMenuItem<MonitorSource>(
                    value: MonitorSource.serial,
                    child: Text('Serial'),
                  ),
                  DropdownMenuItem<MonitorSource>(
                    value: MonitorSource.rtt,
                    child: Text('RTT'),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: DropdownButton<DefmtLevel?>(
                isExpanded: true,
                hint: const Text('All'),
                value: state.minLevel,
                underline: const SizedBox.shrink(),
                items: const <DropdownMenuItem<DefmtLevel?>>[
                  DropdownMenuItem<DefmtLevel?>(child: Text('All')),
                  DropdownMenuItem<DefmtLevel?>(
                    value: DefmtLevel.trace,
                    child: Text('≥ trace'),
                  ),
                  DropdownMenuItem<DefmtLevel?>(
                    value: DefmtLevel.debug,
                    child: Text('≥ debug'),
                  ),
                  DropdownMenuItem<DefmtLevel?>(
                    value: DefmtLevel.info,
                    child: Text('≥ info'),
                  ),
                  DropdownMenuItem<DefmtLevel?>(
                    value: DefmtLevel.warn,
                    child: Text('≥ warn'),
                  ),
                  DropdownMenuItem<DefmtLevel?>(
                    value: DefmtLevel.error,
                    child: Text('error'),
                  ),
                ],
                onChanged: controller.setMinLevel,
              ),
            ),
          ],
        ),
        if (state.phase == MonitorPhase.streaming)
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _byteCounterLabel(state),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: state.droppedFrames > 0
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.state});

  final MonitorState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: state.bannerIsError
            ? Theme.of(context).colorScheme.errorContainer
            : Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(state.statusBanner!),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.state, required this.scroll});

  final MonitorState state;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final lines = state.visibleLines;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: lines.isEmpty
          ? Center(
              child: Text(
                state.phase == MonitorPhase.streaming
                    ? 'Listening via '
                          '${state.source == 'rtt' ? 'RTT' : 'serial'}'
                          '… (${state.bytesReceived} bytes)\n'
                          'Nothing yet? Tap reset to reboot the chip.'
                    : 'Connect the device above, then press Start.\n'
                          'Pick the ELF (or .tar.gz bundle) to decode defmt.',
                textAlign: TextAlign.center,
              ),
            )
          : SelectionArea(
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.all(8),
                itemCount: lines.length,
                itemBuilder: (BuildContext context, int index) {
                  final line = lines[index];
                  return Text(
                    _render(line),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: _lineColor(context, line),
                    ),
                  );
                },
              ),
            ),
    );
  }

  String _render(MonitorLine line) {
    final ts = line.timestamp == null ? '' : '[${line.timestamp}] ';
    final level = line.level == null
        ? ''
        : '${line.level!.name.toUpperCase()} ';
    return '$ts$level${line.text}';
  }

  Color? _lineColor(BuildContext context, MonitorLine line) {
    final scheme = Theme.of(context).colorScheme;
    return switch (line.level) {
      DefmtLevel.error => scheme.error,
      DefmtLevel.warn => scheme.tertiary,
      DefmtLevel.info => null,
      DefmtLevel.debug => scheme.outline,
      DefmtLevel.trace => scheme.outlineVariant,
      null => line.isRaw ? scheme.outline : null,
    };
  }
}

String _byteCounterLabel(MonitorState state) {
  final dropped = state.droppedFrames;
  return '${state.bytesReceived} B'
      '${dropped > 0 ? ', $dropped dropped' : ''}';
}
