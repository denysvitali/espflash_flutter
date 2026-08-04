/// The app's one device control: pick a device, connect, disconnect.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../usb/usb_device.dart';
import 'app_widgets.dart';
import 'device_session.dart';

class DeviceBar extends ConsumerWidget {
  const DeviceBar({this.showHeading = true, super.key});

  final bool showHeading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(deviceSessionProvider);
    final session = ref.read(deviceSessionProvider.notifier);
    final busy = state.connection == DeviceConnection.connecting;
    final connected = state.isConnected;
    final selected = state.selectedDevice;
    final scheme = Theme.of(context).colorScheme;

    Future<void> toggleConnection() async {
      if (connected) {
        await session.disconnect();
        return;
      }
      try {
        await session.connect();
      } on Object {
        // The session exposes a friendly error directly below the control.
      }
    }

    final selector = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey<String?>('device-${state.selectedDeviceId}'),
            isExpanded: true,
            initialValue: state.selectedDeviceId,
            decoration: InputDecoration(
              labelText: 'USB device',
              prefixIcon: const Icon(Icons.usb_rounded),
              suffixIcon: connected
                  ? Icon(Icons.check_circle_rounded, color: scheme.primary)
                  : null,
            ),
            hint: Text(
              state.devices.isEmpty
                  ? 'Plug in an ESP device'
                  : 'Choose a device',
              overflow: TextOverflow.ellipsis,
            ),
            items: <DropdownMenuItem<String>>[
              for (final UsbDevice device in state.devices)
                DropdownMenuItem<String>(
                  value: device.deviceId,
                  child: Text(
                    deviceLabel(device),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: connected || busy ? null : session.selectDevice,
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          icon: const Icon(Icons.refresh_rounded),
          tooltip: 'Look for USB devices',
          onPressed: busy || connected ? null : session.refreshDevices,
        ),
      ],
    );

    final connectButton = FilledButton.icon(
      onPressed: selected == null || busy ? null : toggleConnection,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(connected ? Icons.link_off_rounded : Icons.link_rounded),
      label: Text(
        busy
            ? 'Connecting…'
            : connected
            ? 'Disconnect'
            : 'Connect',
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showHeading) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Device connection',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      connected
                          ? deviceLabel(selected!)
                          : 'Select the ESP board connected to this device.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              StatusPill(
                label: connected ? 'Connected' : 'Offline',
                icon: connected ? Icons.check_rounded : Icons.circle_outlined,
                color: connected ? scheme.primary : scheme.outline,
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (constraints.maxWidth < 480) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  selector,
                  const SizedBox(height: 10),
                  connectButton,
                ],
              );
            }
            return Row(
              children: <Widget>[
                Expanded(child: selector),
                const SizedBox(width: 8),
                connectButton,
              ],
            );
          },
        ),
        if (state.error != null) ...<Widget>[
          const SizedBox(height: 10),
          AppBanner(message: state.error!, isError: true),
        ],
      ],
    );
  }
}

/// `Product name (vid:pid)` for a device dropdown entry.
String deviceLabel(UsbDevice device) {
  final name = device.label.isEmpty ? 'USB serial' : device.label;
  final vid = device.vendorId.toRadixString(16).padLeft(4, '0');
  final pid = device.productId.toRadixString(16).padLeft(4, '0');
  return '$name ($vid:$pid)';
}
