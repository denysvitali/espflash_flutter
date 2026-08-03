/// The single screen: pick a device, stage firmware, flash it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../usb/usb_device.dart';
import 'flash_controller.dart';
import 'flash_state.dart';

/// Home screen of the app.
class FlashHomePage extends ConsumerStatefulWidget {
  const FlashHomePage({super.key});

  @override
  ConsumerState<FlashHomePage> createState() => _FlashHomePageState();
}

class _FlashHomePageState extends ConsumerState<FlashHomePage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _offsetController = TextEditingController(
    text: '0x0',
  );
  final ScrollController _logScroll = ScrollController();
  bool _eraseFirst = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(flashControllerProvider.notifier).refreshDevices();
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _offsetController.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  int? get _offset {
    final text = _offsetController.text.trim().toLowerCase();
    final hex = text.startsWith('0x') ? text.substring(2) : text;
    return int.tryParse(hex, radix: 16);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(flashControllerProvider);
    final controller = ref.read(flashControllerProvider.notifier);
    // Auto-scroll the log when new lines arrive.
    ref.listen(flashControllerProvider.select((s) => s.log.length), (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('espflash'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                state.chipName ?? 'not connected',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _DeviceCard(state: state, controller: controller),
          const SizedBox(height: 12),
          _FirmwareCard(
            state: state,
            controller: controller,
            urlController: _urlController,
            offsetController: _offsetController,
            eraseFirst: _eraseFirst,
            onEraseFirstChanged: (bool value) =>
                setState(() => _eraseFirst = value),
            onOffsetChanged: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          _FlashCard(
            state: state,
            controller: controller,
            offset: _offset,
            eraseFirst: _eraseFirst,
          ),
          const SizedBox(height: 12),
          _LogCard(state: state, scrollController: _logScroll),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.state, required this.controller});

  final FlashState state;
  final FlashController controller;

  @override
  Widget build(BuildContext context) {
    final busy = state.phase == FlashPhase.connecting;
    final connected = state.phase != FlashPhase.idle;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Device', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    hint: Text(
                      state.devices.isEmpty
                          ? 'No USB devices — plug in an ESP32-C3'
                          : 'Select USB device',
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
                    onChanged: connected ? null : controller.selectDevice,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Rescan devices',
                  onPressed: busy ? null : controller.refreshDevices,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (busy)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(),
                ),
              )
            else
              FilledButton.icon(
                onPressed: state.selectedDevice == null
                    ? null
                    : (connected ? controller.disconnect : controller.connect),
                icon: Icon(connected ? Icons.link_off : Icons.link),
                label: Text(connected ? 'Disconnect' : 'Connect'),
              ),
          ],
        ),
      ),
    );
  }
}

class _FirmwareCard extends StatelessWidget {
  const _FirmwareCard({
    required this.state,
    required this.controller,
    required this.urlController,
    required this.offsetController,
    required this.eraseFirst,
    required this.onEraseFirstChanged,
    required this.onOffsetChanged,
  });

  final FlashState state;
  final FlashController controller;
  final TextEditingController urlController;
  final TextEditingController offsetController;
  final bool eraseFirst;
  final ValueChanged<bool> onEraseFirstChanged;
  final VoidCallback onOffsetChanged;

  @override
  Widget build(BuildContext context) {
    final firmware = state.firmware;
    final locked = state.phase == FlashPhase.flashing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Firmware', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (firmware != null)
              InputChip(
                avatar: const Icon(Icons.memory, size: 18),
                label: Text(
                  '${firmware.name} — ${_formatBytes(firmware.bytes.length)}',
                ),
                onDeleted: locked ? null : controller.clearFirmware,
              )
            else ...<Widget>[
              FilledButton.tonalIcon(
                onPressed: locked ? null : controller.pickFirmwareFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Pick .bin file'),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: urlController,
                      enabled: !locked,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        labelText: '…or firmware URL',
                        hintText: 'https://example.com/firmware.bin',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    icon: const Icon(Icons.download),
                    tooltip: 'Download',
                    onPressed: locked
                        ? null
                        : () => controller.fetchFirmwareFromUrl(
                            urlController.text,
                          ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: offsetController,
              enabled: !locked,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-FxX]')),
              ],
              onChanged: (_) => onOffsetChanged(),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Flash offset (hex)',
                hintText: '0x0',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Erase entire flash first'),
              value: eraseFirst,
              onChanged: locked ? null : onEraseFirstChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _FlashCard extends StatelessWidget {
  const _FlashCard({
    required this.state,
    required this.controller,
    required this.offset,
    required this.eraseFirst,
  });

  final FlashState state;
  final FlashController controller;
  final int? offset;
  final bool eraseFirst;

  @override
  Widget build(BuildContext context) {
    final flashing = state.phase == FlashPhase.flashing;
    final canFlash =
        state.phase == FlashPhase.ready &&
        state.firmware != null &&
        offset != null;
    final banner = state.statusBanner;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (flashing) ...<Widget>[
              LinearProgressIndicator(value: state.progress),
              const SizedBox(height: 8),
              Text(
                '${_formatBytes(state.bytesWritten)} / '
                '${_formatBytes(state.bytesTotal)} '
                '(${(state.progress * 100).toStringAsFixed(0)}%)',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: controller.cancelFlash,
                icon: const Icon(Icons.stop),
                label: const Text('Cancel'),
              ),
            ] else
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
                onPressed: canFlash
                    ? () => controller.flash(
                        offset: offset!,
                        eraseFirst: eraseFirst,
                      )
                    : null,
                icon: const Icon(Icons.bolt),
                label: Text(
                  state.phase == FlashPhase.ready
                      ? (state.firmware == null
                            ? 'Pick firmware first'
                            : offset == null
                            ? 'Enter a valid hex offset'
                            : 'Flash')
                      : 'Connect a device first',
                ),
              ),
            if (banner != null) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: state.bannerIsError
                      ? Theme.of(context).colorScheme.errorContainer
                      : Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(banner),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.state, required this.scrollController});

  final FlashState state;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Log',
              key: const ValueKey<String>('logCardTitle'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: state.log.isEmpty
                    ? const Center(child: Text('Nothing yet.'))
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.all(8),
                        itemCount: state.log.length,
                        itemBuilder: (BuildContext context, int index) {
                          return Text(
                            state.log[index],
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace'),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _deviceLabel(UsbDevice device) {
  final name = device.label.isEmpty ? 'USB serial' : device.label;
  final vid = device.vendorId.toRadixString(16).padLeft(4, '0');
  final pid = device.productId.toRadixString(16).padLeft(4, '0');
  return '$name ($vid:$pid)';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}
