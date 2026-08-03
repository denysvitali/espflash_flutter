/// Serial monitor screen: stage an ELF, attach to the device's UART
/// output, watch defmt frames decoded live (raw text passes through).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../defmt/table.dart';
import '../usb/usb_device.dart';
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
      ref.read(monitorControllerProvider.notifier).refreshDevices();
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
                _TopBar(state: state, controller: controller),
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
          Expanded(child: _LogView(state: state, scroll: _logScroll)),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.state, required this.controller});

  final MonitorState state;
  final MonitorController controller;

  @override
  Widget build(BuildContext context) {
    final streaming = state.phase == MonitorPhase.streaming;
    final busy = state.phase == MonitorPhase.connecting;
    return Row(
      children: <Widget>[
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            hint: Text(
              state.devices.isEmpty ? 'No USB devices' : 'Select USB device',
            ),
            value: state.selectedDeviceId,
            items: <DropdownMenuItem<String>>[
              for (final UsbDevice device in state.devices)
                DropdownMenuItem<String>(
                  value: device.deviceId,
                  child: Text(
                    _deviceLabel(device),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: streaming || busy ? null : controller.selectDevice,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Rescan devices',
          onPressed: busy ? null : controller.refreshDevices,
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          FilledButton.tonalIcon(
            onPressed: state.selectedDevice == null
                ? null
                : (streaming ? controller.stop : controller.start),
            icon: Icon(streaming ? Icons.stop : Icons.play_arrow),
            label: Text(streaming ? 'Stop' : 'Start'),
          ),
      ],
    );
  }
}

class _ControlsBar extends StatelessWidget {
  const _ControlsBar({required this.state, required this.controller});

  final MonitorState state;
  final MonitorController controller;

  @override
  Widget build(BuildContext context) {
    final elf = state.elf;
    final streaming = state.phase == MonitorPhase.streaming;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            if (elf != null)
              Expanded(
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
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: controller.pickElf,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Pick ELF for defmt decoding'),
                ),
              ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.restart_alt),
              tooltip: 'Reset chip (reboot into firmware)',
              onPressed: streaming ? controller.resetChip : null,
            ),
            IconButton(
              icon: Icon(state.paused ? Icons.play_circle : Icons.pause_circle),
              tooltip: state.paused ? 'Resume' : 'Pause',
              onPressed: controller.togglePause,
            ),
            IconButton(
              icon: const Icon(Icons.hexagon_outlined),
              tooltip: 'Hex dump (diagnostic)',
              color: state.hexMode
                  ? Theme.of(context).colorScheme.primary
                  : null,
              onPressed: controller.toggleHexMode,
            ),
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy all logs to clipboard',
              onPressed: state.lines.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(
                        ClipboardData(text: controller.copyableLog()),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Logs copied to clipboard'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear log',
              onPressed: controller.clearLog,
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
            DropdownButton<DefmtLevel?>(
              hint: const Text('Level'),
              value: state.minLevel,
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
            if (state.phase == MonitorPhase.streaming)
              Padding(
                padding: const EdgeInsets.only(left: 8),
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
                    ? 'Listening… (${state.bytesReceived} bytes)\n'
                          'Nothing yet? Tap reset to reboot the chip.'
                    : 'Pick an ELF, select a device, press Start.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
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

String _deviceLabel(UsbDevice device) {
  final name = device.label.isEmpty ? 'USB serial' : device.label;
  final vid = device.vendorId.toRadixString(16).padLeft(4, '0');
  final pid = device.productId.toRadixString(16).padLeft(4, '0');
  return '$name ($vid:$pid)';
}

String _byteCounterLabel(MonitorState state) {
  final dropped = state.droppedFrames;
  return '${state.bytesReceived} B'
      '${dropped > 0 ? ', $dropped dropped' : ''}';
}
