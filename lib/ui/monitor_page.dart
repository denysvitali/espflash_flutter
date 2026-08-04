/// A focused live console for serial and RTT output with defmt decoding.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../defmt/table.dart';
import 'app_theme.dart';
import 'app_widgets.dart';
import 'device_bar.dart';
import 'device_session.dart';
import 'monitor_controller.dart';
import 'monitor_state.dart';

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

    final streaming = state.phase == MonitorPhase.streaming;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Serial monitor'),
            Text(
              streaming
                  ? 'Live ${state.source?.toUpperCase()} output'
                  : 'Inspect live device logs',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: StatusPill(
              label: streaming ? 'Live' : 'Stopped',
              icon: streaming ? Icons.circle : Icons.stop_circle_outlined,
              color: streaming ? scheme.primary : scheme.outline,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final logHeight = (constraints.maxHeight * .48).clamp(300.0, 560.0);
            return CustomScrollView(
              slivers: <Widget>[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: const DeviceBar(showHeading: false),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _FirmwareTile(state: state, controller: controller),
                        const SizedBox(height: 10),
                        _StreamControls(state: state, controller: controller),
                        const SizedBox(height: 10),
                        _FilterBar(state: state, controller: controller),
                        if (state.statusBanner != null) ...<Widget>[
                          const SizedBox(height: 10),
                          AppBanner(
                            message: state.statusBanner!,
                            isError: state.bannerIsError,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: logHeight,
                    child: _LogView(state: state, scroll: _logScroll),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FirmwareTile extends StatelessWidget {
  const _FirmwareTile({required this.state, required this.controller});

  final MonitorState state;
  final MonitorController controller;

  @override
  Widget build(BuildContext context) {
    final elf = state.elf;
    final locked = state.phase != MonitorPhase.idle;
    final scheme = Theme.of(context).colorScheme;
    if (elf == null) {
      return OutlinedButton.icon(
        onPressed: locked ? null : controller.pickElf,
        icon: const Icon(Icons.note_add_outlined),
        label: const Text('Pick ELF or .tar.gz bundle'),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: .15)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.description_outlined, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  elf.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Text(
                  '${elf.entryCount} log strings • defmt v${elf.version}'
                  '${elf.hasTimestamp ? '' : ' • no timestamps'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove ELF',
            onPressed: locked ? null : controller.clearElf,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}

class _StreamControls extends ConsumerWidget {
  const _StreamControls({required this.state, required this.controller});

  final MonitorState state;
  final MonitorController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streaming = state.phase == MonitorPhase.streaming;
    final connecting = state.phase == MonitorPhase.connecting;
    final connected = ref.watch(deviceSessionProvider).isConnected;
    return Row(
      children: <Widget>[
        Expanded(
          child: FilledButton.icon(
            onPressed: connected && !connecting ? controller.connect : null,
            icon: connecting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    streaming ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  ),
            label: Text(
              connecting
                  ? 'Starting…'
                  : streaming
                  ? 'Stop monitoring'
                  : 'Start monitoring',
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          icon: Icon(
            state.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          ),
          tooltip: state.paused ? 'Resume output' : 'Pause output',
          onPressed: streaming ? controller.togglePause : null,
        ),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          icon: const Icon(Icons.restart_alt_rounded),
          tooltip: 'Restart device',
          onPressed: streaming ? controller.resetChip : null,
        ),
        _MoreMenu(state: state, controller: controller),
      ],
    );
  }
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({required this.state, required this.controller});

  final MonitorState state;
  final MonitorController controller;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More console actions',
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (String action) {
        switch (action) {
          case 'hex':
            controller.toggleHexMode();
          case 'copy':
            Clipboard.setData(ClipboardData(text: controller.copyableLog()));
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Logs copied')));
          case 'clear':
            controller.clearLog();
        }
      },
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        CheckedPopupMenuItem<String>(
          value: 'hex',
          checked: state.hexMode,
          child: const Text('Show hexadecimal'),
        ),
        PopupMenuItem<String>(
          value: 'copy',
          enabled: state.lines.isNotEmpty,
          child: const Text('Copy all output'),
        ),
        PopupMenuItem<String>(
          value: 'clear',
          enabled: state.lines.isNotEmpty,
          child: const Text('Clear output'),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.state, required this.controller});

  final MonitorState state;
  final MonitorController controller;

  @override
  Widget build(BuildContext context) {
    final streaming = state.phase == MonitorPhase.streaming;
    return Column(
      children: <Widget>[
        TextField(
          decoration: const InputDecoration(
            isDense: true,
            hintText: 'Search output',
            prefixIcon: Icon(Icons.search_rounded),
          ),
          onChanged: controller.setFilter,
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<MonitorSource>(
                key: ValueKey<MonitorSource>(state.preferredSource),
                isExpanded: true,
                initialValue: state.preferredSource,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Source',
                ),
                onChanged: streaming
                    ? null
                    : (MonitorSource? value) {
                        if (value != null) controller.setSource(value);
                      },
                items: const <DropdownMenuItem<MonitorSource>>[
                  DropdownMenuItem(
                    value: MonitorSource.auto,
                    child: Text('Automatic'),
                  ),
                  DropdownMenuItem(
                    value: MonitorSource.serial,
                    child: Text('Serial'),
                  ),
                  DropdownMenuItem(
                    value: MonitorSource.rtt,
                    child: Text('RTT'),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<DefmtLevel?>(
                key: ValueKey<DefmtLevel?>(state.minLevel),
                isExpanded: true,
                initialValue: state.minLevel,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Log level',
                ),
                onChanged: controller.setMinLevel,
                items: const <DropdownMenuItem<DefmtLevel?>>[
                  DropdownMenuItem(child: Text('All levels')),
                  DropdownMenuItem(
                    value: DefmtLevel.trace,
                    child: Text('Trace+'),
                  ),
                  DropdownMenuItem(
                    value: DefmtLevel.debug,
                    child: Text('Debug+'),
                  ),
                  DropdownMenuItem(
                    value: DefmtLevel.info,
                    child: Text('Info+'),
                  ),
                  DropdownMenuItem(
                    value: DefmtLevel.warn,
                    child: Text('Warnings+'),
                  ),
                  DropdownMenuItem(
                    value: DefmtLevel.error,
                    child: Text('Errors only'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
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
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.console,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: <Widget>[
          _ConsoleHeader(state: state, visibleCount: lines.length),
          const Divider(height: 1, color: Color(0xFF28363B)),
          Expanded(
            child: lines.isEmpty
                ? _ConsoleEmptyState(state: state)
                : SelectionArea(
                    child: ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      itemCount: lines.length,
                      itemBuilder: (BuildContext context, int index) {
                        final line = lines[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            _render(line),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12.5,
                              height: 1.42,
                              color: Color(0xFFD6E2E5),
                            ).copyWith(color: _lineColor(line)),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _render(MonitorLine line) {
    final stamp = line.timestamp;
    final timestamp = stamp == null || stamp.isEmpty ? '' : '[$stamp] ';
    final level = line.level == null
        ? ''
        : '${line.level!.name.toUpperCase()} ';
    return '$timestamp$level${line.text}';
  }

  Color _lineColor(MonitorLine line) => switch (line.level) {
    DefmtLevel.error => const Color(0xFFFF858D),
    DefmtLevel.warn => const Color(0xFFFFC66D),
    DefmtLevel.info => const Color(0xFFD6E2E5),
    DefmtLevel.debug => const Color(0xFF9DB2B8),
    DefmtLevel.trace => const Color(0xFF758A91),
    null => line.isRaw ? const Color(0xFF9DB2B8) : const Color(0xFFD6E2E5),
  };
}

class _ConsoleHeader extends StatelessWidget {
  const _ConsoleHeader({required this.state, required this.visibleCount});

  final MonitorState state;
  final int visibleCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.terminal_rounded,
            color: Color(0xFF8EA3A9),
            size: 18,
          ),
          const SizedBox(width: 8),
          const Text(
            'OUTPUT',
            style: TextStyle(
              color: Color(0xFFB9C9CD),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const Spacer(),
          Text(
            state.phase == MonitorPhase.streaming
                ? _byteCounterLabel(state)
                : '$visibleCount lines',
            style: TextStyle(
              color: state.droppedFrames > 0
                  ? const Color(0xFFFF858D)
                  : const Color(0xFF8EA3A9),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsoleEmptyState extends StatelessWidget {
  const _ConsoleEmptyState({required this.state});

  final MonitorState state;

  @override
  Widget build(BuildContext context) {
    final streaming = state.phase == MonitorPhase.streaming;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              streaming ? Icons.graphic_eq_rounded : Icons.terminal_rounded,
              size: 30,
              color: const Color(0xFF758A91),
            ),
            const SizedBox(height: 10),
            Text(
              streaming ? 'Waiting for device output…' : 'Ready when you are',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFD6E2E5),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              streaming
                  ? 'The console is listening. Restart the device if it '
                        'stays quiet.'
                  : 'Connect a device, then tap Start monitoring.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF8EA3A9),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _byteCounterLabel(MonitorState state) {
  return '${_formatBytes(state.bytesReceived)}'
      '${state.droppedFrames > 0 ? ' • ${state.droppedFrames} dropped' : ''}';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
