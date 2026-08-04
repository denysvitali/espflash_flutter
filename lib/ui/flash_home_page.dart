/// The guided connect → choose firmware → flash workflow.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_theme.dart';
import 'app_widgets.dart';
import 'device_bar.dart';
import 'device_session.dart';
import 'flash_controller.dart';
import 'flash_state.dart';
import 'monitor_page.dart';

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
      ref.read(deviceSessionProvider.notifier).refreshDevices();
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
    final session = ref.watch(deviceSessionProvider);
    ref
      ..listen(flashControllerProvider.select((s) => s.suggestedOffset), (
        _,
        int? offset,
      ) {
        if (offset != null) {
          _offsetController.text = '0x${offset.toRadixString(16)}';
          setState(() {});
        }
      })
      ..listen(flashControllerProvider.select((s) => s.log.length), (_, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logScroll.hasClients) {
            _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
          }
        });
      });

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: const Text('espflash'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.terminal_rounded),
            tooltip: 'Open serial monitor',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const MonitorPage()),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: StatusPill(
                label: session.isConnected
                    ? (state.chipName ?? 'connected')
                    : 'not connected',
                icon: session.isConnected
                    ? Icons.check_rounded
                    : Icons.circle_outlined,
                color: session.isConnected ? scheme.primary : scheme.outline,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              cacheExtent: 1600,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: <Widget>[
                _WelcomeHeader(connected: session.isConnected),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const StepTitle(
                          step: 1,
                          title: 'Connect your device',
                          subtitle:
                              'Plug in your ESP board and approve USB access.',
                        ),
                        const SizedBox(height: 18),
                        const DeviceBar(showHeading: false),
                      ],
                    ),
                  ),
                ),
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
          ),
        ),
      ),
    );
  }
}

class _WelcomeHeader extends StatelessWidget {
  const _WelcomeHeader({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Flash firmware',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 6),
          Text(
            connected
                ? 'Your device is ready. Choose firmware to continue.'
                : 'Connect a device first',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
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
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            StepTitle(
              step: 2,
              title: 'Firmware',
              subtitle: firmware == null
                  ? 'Choose a local build or download one from a link.'
                  : 'Ready to install on your device.',
              trailing: firmware == null
                  ? null
                  : StatusPill(
                      label: 'Ready',
                      icon: Icons.check_rounded,
                      color: scheme.primary,
                    ),
            ),
            const SizedBox(height: 18),
            if (firmware != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: .4),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.memory_rounded, color: scheme.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            firmware.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          Text(
                            '${_formatBytes(firmware.bytes.length)} • '
                            '${firmware.sourceDescription}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove firmware',
                      onPressed: locked ? null : controller.clearFirmware,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              )
            else ...<Widget>[
              FilledButton.tonalIcon(
                onPressed: locked ? null : controller.pickFirmwareFile,
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Choose firmware file'),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(child: Divider(color: scheme.outlineVariant)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'OR USE A LINK',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        letterSpacing: .8,
                      ),
                    ),
                  ),
                  Expanded(child: Divider(color: scheme.outlineVariant)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: urlController,
                      enabled: !locked,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Firmware URL',
                        hintText: 'https://…/firmware.bin',
                        prefixIcon: Icon(Icons.link_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    icon: const Icon(Icons.download_rounded),
                    tooltip: 'Download firmware',
                    onPressed: locked
                        ? null
                        : () => controller.fetchFirmwareFromUrl(
                            urlController.text,
                          ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 4),
                leading: const Icon(Icons.tune_rounded),
                title: const Text('Advanced options'),
                subtitle: const Text('Most people can leave these unchanged.'),
                children: <Widget>[
                  TextField(
                    controller: offsetController,
                    enabled: !locked,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.allow(
                        RegExp('[0-9a-fA-FxX]'),
                      ),
                    ],
                    onChanged: (_) => onOffsetChanged(),
                    decoration: const InputDecoration(
                      labelText: 'Flash offset',
                      hintText: '0x0',
                      helperText: 'Hexadecimal memory address',
                    ),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Erase device before flashing'),
                    subtitle: const Text(
                      'Removes all existing data on flash memory.',
                    ),
                    value: eraseFirst,
                    onChanged: locked ? null : onEraseFirstChanged,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FlashCard extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final flashing = state.phase == FlashPhase.flashing;
    final connected = ref.watch(deviceSessionProvider).isConnected;
    final canFlash = connected && state.firmware != null && offset != null;
    final scheme = Theme.of(context).colorScheme;
    final buttonLabel = !connected
        ? 'Connect a device first'
        : state.firmware == null
        ? 'Choose firmware first'
        : offset == null
        ? 'Check the flash offset'
        : 'Flash firmware';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            StepTitle(
              step: 3,
              title: flashing ? 'Installing firmware' : 'Install',
              subtitle: flashing
                  ? 'Keep the device connected until this finishes.'
                  : 'The device will restart automatically when complete.',
            ),
            const SizedBox(height: 18),
            if (flashing) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: LinearProgressIndicator(
                      value: state.progress,
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    '${(state.progress * 100).toStringAsFixed(0)}%',
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: scheme.primary),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '${_formatBytes(state.bytesWritten)} of '
                '${_formatBytes(state.bytesTotal)} written',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: controller.cancelFlash,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('Cancel installation'),
              ),
            ] else
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                onPressed: canFlash
                    ? () => controller.flash(
                        offset: offset!,
                        eraseFirst: eraseFirst,
                      )
                    : null,
                icon: const Icon(Icons.bolt_rounded),
                label: Text(buttonLabel),
              ),
            if (state.statusBanner != null) ...<Widget>[
              const SizedBox(height: 12),
              AppBanner(
                message: state.statusBanner!,
                isError: state.bannerIsError,
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
      child: ExpansionTile(
        key: const ValueKey<String>('logCardTitle'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        leading: const Icon(Icons.receipt_long_outlined),
        title: const Text('Log'),
        subtitle: Text(
          state.log.isEmpty
              ? 'Technical activity will appear here.'
              : '${state.log.length} events',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.copy_rounded, size: 18),
              tooltip: 'Copy activity log',
              onPressed: state.log.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(
                        ClipboardData(text: state.log.join('\n')),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Activity log copied')),
                      );
                    },
            ),
            const Icon(Icons.expand_more_rounded),
          ],
        ),
        children: <Widget>[
          SizedBox(
            height: 220,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppTheme.console,
                borderRadius: BorderRadius.circular(14),
              ),
              child: state.log.isEmpty
                  ? const Center(
                      child: Text(
                        'Nothing yet',
                        style: TextStyle(color: Color(0xFF8EA3A9)),
                      ),
                    )
                  : SelectionArea(
                      child: ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.all(12),
                        itemCount: state.log.length,
                        itemBuilder: (_, int index) => Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            state.log[index],
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.4,
                              color: Color(0xFFD6E2E5),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}
