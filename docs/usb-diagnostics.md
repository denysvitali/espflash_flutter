# OnePlus USB observation: investigation and capture plan

This is a diagnostic/liveness change, not a demonstrated fix for the reported
OnePlus 13 failure. The failure still needs to be captured on hardware. CI cannot
establish whether OxygenOS, the cable, board firmware, the serial driver or the
application is the first failing layer.

## Observation contract

`UsbManager.deviceList` is read on the dedicated `EspFlashUsb-discovery` worker.
Its returned keys are logged and sent to Flutter **before any UsbDevice metadata
getter or serial prober is called**. The raw roster contains attachment paths and
`probeStatus: pending`; vendor/product IDs are enrichment, not prerequisites for
reporting presence. No serial number is read.

| Observation | Wire representation | Session behavior |
| --- | --- | --- |
| Successful empty enumeration | `status: ok`, `stage: raw`, `devices: []` | An absent selected attachment is invalidated |
| Enumeration exception | `status: error`, `scanError`, no `devices` field | Keep last known devices/connection; mark observation stale |
| Present, enrichment pending | Device entry with `probeStatus: pending` | Show presence; retain previously recognized current attachments |
| Driver found | `probeStatus: supported` | Selectable when VID/PID metadata is available |
| No matching driver | `probeStatus: unsupported` | Distinct from an empty host list |
| Probing throws | `probeStatus: error`, `probeError` | Preserve raw entry; do not invent a detach |
| Optional field throws | Field is `null`, error under `fieldErrors[field]` | Preserve raw entry and other readable fields |

Enrichment runs on a second worker, `EspFlashUsb-enrichment`. It records VID/PID,
product name, permission, device class fields, interface count and interface
class/subclass/protocol/endpoint counts independently. A bad device does not
remove its neighbors. Slow enrichment has one replaceable pending snapshot;
it does not block raw scans or build an unbounded work queue.

`UsbService.listRawDevices()` now returns a **UsbSnapshot envelope**, not the old
list of enriched devices. Its explicit raw request does not invoke enrichment.
The normal UI uses the EventChannel's raw/enriched observations; refresh requests
a burst rather than applying a second asynchronous method response.

## Liveness and threading

- Observation starts at activity `onStart`, stops at `onStop`, and is disposed
  with the activity. A newly subscribed Flutter listener receives current
  observer state even if the activity started before it subscribed.
- A one-second watchdog continues while the activity is visible, including when
  the roster is nonempty. The interval is an engineering default to measure,
  not a USB enumeration deadline guaranteed by Android.
- Attach/resume/refresh/permission/detach hints retain the fast
  0/100/250/500/1000/2000 ms burst. Replacing a burst never cancels the watchdog.
- Raw scans are serialized on their dedicated scheduled worker. An enumeration
  call can still block that worker; scheduled/start/completion logs reveal this.
- USB method operations, including serial/JTAG open and close, use a third
  worker, `EspFlashUsb-operations`. They cannot block raw enumeration or Flutter's
  main thread. Existing serial/JTAG I/O executors remain separate.
- Results and native EventChannel events are delivered on the platform main
  thread. After three seconds without a new successful raw observation, Dart
  reports stale observation while preserving last known state. Enumeration and
  stream errors are reported immediately. Enrichment does not extend freshness.

Each visibility interval has an `epoch`. Each executed raw scan has a monotonic
`sequence`; raw and enriched events share it. Dart rejects older epochs,
sequences and duplicate/out-of-order stages. Native enrichment also rejects a
result superseded by a newer observation. A scheduling `request` identifier joins
scheduled/coalesced tasks to the sequence assigned when a scan actually starts.

Log stages:

```text
scan-scheduled (request, epoch, requested time, due time)
  -> scan-started (request, epoch, sequence, actual start time)
  -> raw-completed (status, count, raw paths or explicit error)
  -> native-emitted (raw, subscriber present/absent)
  -> enrichment-completed (per-device results/errors)
  -> native-emitted (enriched, subscriber present/absent)
  -> dart-received
  -> dart-applied or dart-discarded
```

Native timing fields use Android elapsed realtime milliseconds; logcat provides
wall-clock timestamps. Dart records wall-clock milliseconds and the same
`epoch`/`sequence`. Native logs use the `EspFlashUsb` tag. Dart messages contain
`EspFlashUsb` but are normally logged under Flutter's tag, so a tag-only capture
would miss half the delivery timeline.

## Preserve the failure before changing settings

Use wireless ADB and dedicate the USB port to the board. Keep the phone unlocked
and app visible. Enable OTG once, attach once, and leave OTG/debugging unchanged
for the initial capture. With multiple ADB targets, set `ANDROID_SERIAL` to the
wireless target before running these commands.

Terminal 1:

```bash
adb devices -l
adb logcat -b all -v threadtime > oneplus-usb-logcat.txt
```

Terminal 2 (Bash):

```bash
adb shell getprop ro.build.fingerprint > oneplus-build.txt
adb shell getprop ro.build.version.sdk >> oneplus-build.txt
adb shell dumpsys usb > usb-failed.txt

for i in $(seq 1 30); do
  printf '\n=== sample %s ===\n' "$i"
  adb shell 'date; cat /proc/uptime; dumpsys usb'
  sleep 1
done > usb-timeline.txt
```

Then press **only Refresh**, record its time, and capture another `dumpsys usb`.
Only afterward test one OTG toggle. Test USB debugging as a separate intervention.
Keep originals private; redact unrelated personal data before public sharing.

Optional, where supported by the vendor build:

```bash
adb shell dumpsys usb dump-descriptors -dump-raw > usb-last-descriptors.txt
```

Descriptor output can be historical. Inspect the **current host-device roster**
and port data role; do not infer host attachment solely from gadget-side
`connected=false`, MTP or ADB function values.

Record the installed APK commit/build number, OnePlus model/region and OS build,
board VID/PID, board firmware/mode, and exact cable/adapter/power topology.

## Choose the next fix from the first failing stage

| Failed-stage evidence | Next investigation |
| --- | --- |
| Tasks scheduled but not started/completed | Observer worker blockage or framework enumeration exception |
| Raw snapshots continue but native emission/Dart stops | Main-thread delivery, subscription or Flutter event handling |
| Board appears after two seconds without a new hint | Measure watchdog convergence; compare framework-to-UI delay |
| Raw roster contains board, enrichment errors/unsupported | Inspect per-device errors and interface descriptors; verify driver compatibility |
| Supported enriched snapshot emitted but UI has no device | Match epoch/sequence in received/applied/discarded logs |
| Board visible but permission/open fails | Detection succeeded; investigate access/open separately |
| Repeated successful raw scans and current system host roster both lack board | Compare role negotiation, topology, board state and platform restrictions |

Permission PendingIntent flags, receiver registration, driver mappings, library
version, hardware-identity continuation and open retry policy are unchanged by
this patch. In particular, this patch does not change the permission protocol to
immutable intents or use positive snapshots to complete permission waiters.
Investigate those only once enumeration has been demonstrated.

## Physical controls and acceptance

1. Compare a tiny native raw-enumeration-only app (no Flutter, prober or open).
2. For native ESP32-C3 USB Serial/JTAG, compare the board's documented ROM
   download mode with application firmware. This comparison has a different
   meaning for an independent USB-UART bridge.
3. Compare direct USB-C with a known-good host adapter plus USB-A data cable.
   Test an externally powered hub separately; a hub changes negotiation and
   topology as well as power.
4. Repeat on the Xiaomi with the same APK, board state, firmware, cable and
   adapter. Capture failed and working states before drawing platform conclusions.

Acceptance: every supported attachment Android exposes becomes visible without
manual refresh within a measured observation interval; raw enumeration failures,
probe failures and below-Android absence remain distinguishable. Do not claim
100% physical detection or an OxygenOS root cause from CI results.

Native JVM tests exercise arrivals at 3/5/10/30 seconds, repeated hints, missed
detach, enumeration errors, isolated metadata/probe failures, delayed enrichment,
visibility changes and a blocked USB operation worker. Flutter tests verify stale
state preservation, stage ordering, raw-only presence and error decoding. Both
native tests and the release APK build are run in CI.
