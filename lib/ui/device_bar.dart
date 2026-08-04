/// The app's one device control: pick a device, connect, disconnect.
///
/// Shown on every screen so there is a single place to connect and a
/// single visible connection state.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../usb/usb_device.dart';
import 'device_session.dart';

class DeviceBar extends ConsumerWidget {
  const DeviceBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(deviceSessionProvider);
    final session = ref.read(deviceSessionProvider.notifier);
    final busy = state.connection == DeviceConnection.connecting;
    final connected = state.isConnected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                hint: Text(
                  state.devices.isEmpty
                      ? 'No USB devices — plug one in'
                      : 'Select USB device',
                ),
                value: state.selectedDeviceId,
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
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Rescan devices',
              onPressed: busy || connected ? null : session.refreshDevices,
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
              FilledButton.icon(
                onPressed: state.selectedDevice == null
                    ? null
                    : () async {
                        if (connected) {
                          await session.disconnect();
                        } else {
                          // Errors surface in the session's banner.
                          try {
                            await session.connect();
                          } on Object {
                            // Already reported via state.error.
                          }
                        }
                      },
                icon: Icon(connected ? Icons.link_off : Icons.link),
                label: Text(connected ? 'Disconnect' : 'Connect'),
              ),
          ],
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              state.error!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
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
