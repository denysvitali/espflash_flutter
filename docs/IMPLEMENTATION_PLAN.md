# espflasher — Implementation Plan

Drives parallel implementation agents. Reference mirror: `../happy_flutter`.

---

## 1. VERDICT: espflash-on-Android — NO. Port the protocol instead.

The espflash Rust crate cannot run on Android as-is. serialport-rs enumeration is explicitly unimplemented for Android (issue #6, open since 2022: "Not implemented for this OS"), unrooted Android exposes no `/dev/ttyUSB*`/`ttyACM*` nodes to apps (USB is delivered only as an fd via UsbHost), and espflash's `Connection` struct hard-codes `pub type Port = serialport::TTYPort` — no transport trait, so a custom Android transport needs a fork. A fork buys only protocol code (command/, target/, flasher/, stubs); the transport is still ours to build, plus JNI plumbing. The stalled Termux packaging request (TUR #2285) confirms nobody has cracked this path. **Decision: skip espflash entirely. Implement the ESP ROM bootloader protocol in pure Dart (~1.2k lines, fully unit-testable) over a small Kotlin platform channel wrapping mik3y/usb-serial-for-android.** Canonical reference: esptool-js (Apache-2.0). esptool.py is GPL-2.0 — read docs only, never copy code.

---

## 2. Transport choice — custom Kotlin channel over mik3y usb-serial-for-android

**Pick: custom MethodChannel/EventChannel code in `android/app` (NOT a pub.dev plugin) wrapping `com.github.mik3y:usb-serial-for-android:3.11.0` from JitPack (pin exact tag).**

Rejected:
- `usb_serial 0.5.2` — orphaned ("looking for maintainer", last code 2024-05), wraps dead felHR85/UsbSerial 6.1.0 (138 open issues).
- `flutter_turbo_serialport 1.2.1` — same dead felHR85 base, 0 stars.
- flutter_esptool (pure Dart, MIT) — 1★, v0.1.5, pins patched platform_serial fork; reference-only, not a dependency.

Why mik3y 3.11.0 (released 2026-07-18, actively maintained, MIT, pure Java):
1. CDC-ACM detection by USB interface class since v3.5.0 → ESP32-C3 USB-Serial-JTAG `303A:1001` works with zero VID/PID probing; CP2102 `10C4:EA60`, CH340 `1A86:7523` covered by built-in drivers.
2. Proven in production for exactly this job (esp-flash-android flashes C3/S3/C6 over this stack).
3. We own the Gradle file → AGP 9.2.1 / Kotlin 2.4.0 migration is under our control.

Channels:
- MethodChannel `espflasher/usb` — `listDevices`, `hasPermission(deviceId)`, `requestPermission(deviceId)`, `open(deviceId)`, `close`, `write(bytes)`, `setBaud(baud)`, `setDtr(bool)`, `setRts(bool)`.
- EventChannel `espflasher/usb/events` — maps `{type: attached|detached|permissionGranted|permissionDenied, deviceId, vendorId, productId}`.
- EventChannel `espflasher/usb/data` — raw byte chunks from `SerialInputOutputManager.onNewData`, dispatched on main thread.

Effort: 2–4h Kotlin + 2h Dart side.

---

## 3. Protocol — pure-Dart port of the ESP ROM protocol

### Stub decision (ESP32-C3)

**v1 = ROM-only, no stub. v2 = stub.**
- ROM-only is correct-but-slower: 1KB blocks (FLASH_WRITE_SIZE=0x400), synchronous writes ≈15–20 KB/s → 1 MB app ≈ 60–90 s. Acceptable.
- CDC-ACM ignores baud, so staying at 115200 costs nothing on USB-JTAG.
- Fewer failure modes: no OHAI handshake failure on boards without auto-reset circuitry.
- v2 adds: MEM_BEGIN/MEM_DATA/MEM_END upload, OHAI wait, 16KB blocks (0x4000), just-in-time erase, FLASH_END(reboot=0). Stub blobs vendored from esptool-js `stub_flasher/2/esp32c3.json` (Apache-2.0; ship NOTICE/attribution).

### Modules (all byte constants are ground truth — implement exactly)

| File | Classes | Responsibility | Mirrors |
|---|---|---|---|
| `lib/esp/slip.dart` | `SlipCodec`, `SlipStream` | encode/decode with END=0xC0, ESC=0xDB, ESC_END=0xDC, ESC_ESC=0xDD. Escaping applied AFTER header/checksum construction. `SlipStream` = incremental parser fed arbitrary chunks, emits complete frames, handles 0xDB split across chunks. | esptool-js transport slip reader |
| `lib/esp/protocol.dart` | `EspCommand` (enum), `EspRequest`, `EspResponse`, `RomError` | Request header LE `<BBHI>`: dir=0x00, opcode, u16 size, u32 checksum. Response: dir=0x01, opcode, u16 size, u32 value, data; **ROM status = LAST 4 data bytes** [status,error,rsvd,rsvd]. `checksum(data, seed=0xEF)` XOR. Opcodes: flashBegin 0x02, flashData 0x03, flashEnd 0x04, memBegin 0x05, memEnd 0x06, memData 0x07, sync 0x08, writeReg 0x09, readReg 0x0A, spiSetParams 0x0B, spiAttach 0x0D, changeBaud 0x0F, flashDeflBegin 0x10, flashDeflData 0x11, flashDeflEnd 0x12, spiFlashMd5 0x13, getSecurityInfo 0x14. Error map: 0x01 invalid param, 0x05 invalid msg, 0x07 checksum, 0x08 flash write, 0x0b deflate fail, … | esptool loader.py `struct.pack('<BBHI',...)`; esptool-js `command()` |
| `lib/esp/transport.dart` | `abstract class EspTransport` | `Future<void> write(Uint8List)`, `Stream<Uint8List> get chunks`, `setDtr(bool)`, `setRts(bool)`, `setBaud(int)`, `close()`, `int vendorId`, `int productId`, `bool get isUsbJtag => vendorId==0x303A && productId==0x1001`. Everything above the transport is pure Dart + fake-testable. | esptool-js Transport |
| `lib/usb/android_usb_transport.dart` | `AndroidUsbTransport implements EspTransport` | Wraps the two EventChannels + MethodChannel from §2. Buffers `espflasher/usb/data` into `chunks` stream. | — |
| `lib/esp/connection.dart` | `EspConnection` | `sync()`: payload 36 B = `07 07 12 20` + 32×0x55; timeout 100 ms; 5 sync tries per connect attempt × 7 attempts; reset strategy runs before each attempt; ROM response has nonzero `value` (value==0 ⇒ stub already running). `command(op, data, {timeout, checksum})`: writes SLIP frame, then reads frames until one matches opcode (skip others), checks ROM status bytes, throws `EspProtocolError` with RomError decode. `readReg(addr)`, `writeReg(addr, val, mask=0xFFFFFFFF)`. Drain up to 8 duplicate responses after unsupported commands. | esptool `_connect_attempt`/`command`; espflash connection/mod.rs |
| `lib/esp/targets/esp32c3.dart` | `Esp32C3` (implements `ChipTarget`) | chipId=5; magic fallbacks [0x6921506f, 0x1b31506f, 0x4881606F, 0x4361606f] at CHIP_DETECT_MAGIC_REG 0x40001000; FLASH_WRITE_SIZE=0x400, STUB_FLASH_WRITE_SIZE=0x4000, FLASH_SECTOR_SIZE=0x1000, RAM_BLOCK=0x1800, bootloader offset 0x0; `disableWatchdogs(conn)` for USB-JTAG: writeReg(0x600080A8,0x50D83AA1) → writeReg(0x60008090,0) → writeReg(0x600080A8,0) → writeReg(0x600080B0,0x8F1D312A) → writeReg(0x600080AC,1<<31) → writeReg(0x600080B0,0); `rtcWdtReset(conn)`: unlock 0x600080A8, WDTCONFIG1(0x60008094)=2000, WDTCONFIG0=(1<<31)|(5<<28)|(1<<8)|2, lock — the reliable post-flash reboot over USB-JTAG. | esptool ESP32C3ROM |
| `lib/esp/chip_detect.dart` | `detectChip(conn)` | Primary: GET_SECURITY_INFO (0x14) → payload LE: [u32 flags][1B crypt_cnt][7B key purposes][u32 chip_id @ offset 12][u32 api] → chip_id==5 ⇒ C3. If flags indicate flash encryption / secure download → throw `UnsupportedSecurityError` (v1 refuses). Fallback: readReg(0x40001000) vs magic list. | esptool-js chipType; espflash target/mod.rs |
| `lib/esp/reset.dart` | `sealed ResetStrategy` + `ClassicReset`, `UsbJtagReset`, `HardReset` | ClassicReset: DTR=false, RTS=true, 100ms, DTR=true, RTS=false, 50ms, DTR=false. UsbJtagReset: RTS=true, DTR=true, 100ms, DTR=false, RTS=true, 100ms, RTS=false, DTR=true, RTS=false, 100ms, DTR=false→true, RTS=false→true. HardReset: RTS low 100ms. All take `EspTransport`; timing must use real async sleeps (injectable clock for tests). | esp-pylib serial_reset.py |
| `lib/esp/flasher.dart` | `EspFlasher`, `FirmwarePart{offset, bytes, name}` | Orchestration below; progress callback `onProgress(int partIndex, int written, int total)` (esptool-js FlashOptions model); cancel flag checked between blocks. | esptool write_flash; esptool-js writeFlash |
| `lib/esp/stub.dart` (v2) | `StubLoader` | Parse `assets/stubs/esp32c3.json` (entry/text/text_start/data/data_start, base64), MEM_BEGIN(size, blocks, 0x1800, offset) → MEM_DATA ×n → MEM_END(entry), wait OHAI (`C0 4F 48 41 49 C0`), switch blockSize→0x4000, enable FLASH_END. | esptool-js stubFlasher.ts |
| `lib/esp/errors.dart` | `EspError`, `EspProtocolError`, `EspTimeoutError`, `EspSecurityError` | Typed errors with ROM error-code text. | — |

### v1 flash sequence (exact order)

1. Open transport → **setDtr(true) + setRts(true) immediately after open** (mik3y opens lines low; ESP USB-JTAG ignores OUT endpoint while DTR low — every write times out; this is the drakosha/esp-flash-android fix).
2. `connect()`: pick reset strategy (isUsbJtag ? UsbJtagReset : ClassicReset), sync loop (7×5).
3. `detectChip()` → must be C3 (chip_id=5) else refuse with chip name.
4. If isUsbJtag: `disableWatchdogs()`.
5. SKIP CHANGE_BAUDRATE entirely in v1 (115200; USB CDC ignores baud; bridges tolerate it, just slower).
6. SPI_ATTACH data = `<u32 0><u32 0>`.
7. SPI_SET_PARAMS = six u32: `0, 0x400000 (4MB assumed), 0x10000, 0x1000, 0x100, 0xFFFF`.
8. Per part (sorted by offset):
   a. FLASH_BEGIN five u32: `erase_size=size, num_blocks=ceil(size/0x400), block_size=0x400, offset, encrypted=0`. Timeout = max(30s, 40s/MB) — ROM erases up-front here.
   b. FLASH_DATA per block: 16-B prefix `<u32 len><u32 seq><0><0>` + data (last block padded to 0x400 with 0xFF); header checksum = XOR of data seeded 0xEF; timeout 3s×retries(3). Progress after each block.
   c. **Do NOT send FLASH_END to ROM** (it exits the bootloader).
9. SPI_FLASH_MD5 per part: payload `<u32 addr><u32 size><0><0>`; ROM returns 32 ASCII hex chars in data; compare `crypto` MD5 hex; timeout 8s/MB.
10. Reboot: isUsbJtag → `rtcWdtReset()`; bridge → HardReset.
11. Erase feature: FLASH_BEGIN with `num_blocks=0` over 0x400000 (ROM erase-only). UI warns: ~160 s for 4 MB. Verify on hardware.

---

## 4. UI plan (flutter_riverpod 3.x)

### Screens
One screen, `HomeScreen` (single-purpose tool, esp-web-tools flow):
1. **Device card** — state machine: `noDevice` → `attached(noPermission)` (Grant button) → `opening` → `connected(chip badge: "ESP32-C3 rev …")`. Live from USB events; replug-safe.
2. **Firmware section** — rows of `FirmwarePartRow`: file name, size, hex offset field with presets dropdown (0x0 merged, 0x1000 bootloader, 0x8000 partitions, 0xe000 boot_app, 0x10000 app). Buttons: "Add .bin file" (file_picker), "Add from URL" (dialog → dio download w/ progress + cancel).
3. **Action bar** — Erase (confirm dialog), Flash, Cancel. Flash disabled unless connected + ≥1 valid part + offsets sorted/unique.
4. **Progress area** — overall % + per-part LinearProgressIndicator driven by `(partIndex, written, total)`; phase label (Connecting… / Erasing… / Writing part 2/3… / Verifying MD5… / Rebooting…).
5. **Log view** — collapsible bottom panel: custom monospace `ListView.builder` ring buffer (500 lines, autoscroll, clear). No xterm dependency.
6. Manual-bootloader help sheet: "hold BOOT → tap RESET → release" for boards without auto-reset (shown after 2 sync failures).

### Providers (`lib/state/`)
| Provider | Kind | Holds |
|---|---|---|
| `usbEventsProvider` | StreamProvider<UsbEvent> | raw EventChannel |
| `usbDevicesProvider` | NotifierProvider<List<UsbDevice>> | listDevices + attach/detach folds |
| `usbControllerProvider` | NotifierProvider<UsbController, UsbState> | permission req, open, DTR/RTS-on-open, transport instance; auto-reopen on re-attach (Risk 1) |
| `firmwarePartsProvider` | NotifierProvider<List<FirmwarePart>> | picked/downloaded parts |
| `downloadControllerProvider` | NotifierProvider<DownloadState> | dio.download + CancelToken |
| `flashControllerProvider` | NotifierProvider<FlashState> | idle/connecting/detecting/erasing/writing(idx,w,t)/verifying/rebooting/done/error(msg) |
| `logProvider` | NotifierProvider<LogBuffer> | ring buffer; EspFlasher + UsbController log into it |

Flows: pick → validate (.ext `bin` or FileType.any fallback + magic/size check; merged image first byte 0xE9 at offset 0) → add part. Flash button → `flashController.flash(transport, parts)` runs §3 sequence, streams progress + log. Cancel = flag checked between blocks + transport close.

---

## 5. Android plumbing

### `android/app/build.gradle.kts` deltas (mirror happy_flutter base)
- Same as reference: compileSdk 36, minSdk 24, targetSdk 36, Java 17, `kotlin { jvmToolchain(17) }`, flavors development/.preview/.production + APP_ENV, arm64-only NOT needed (no native libs — drop abiFilters + ndkVersion + NDK CI steps).
- Add: `dependencies { implementation("com.github.mik3y:usb-serial-for-android:3.11.0") }`.

### `android/settings.gradle.kts`
- Copy reference `patchPluginBuildForAgp9` verbatim (covers file_picker/path_provider pub-cache builds under AGP 9).
- Add `maven { url = uri("https://jitpack.io") }` to `dependencyResolutionManagement.repositories` (PREFER_SETTINGS mode — app-level repos won't resolve).
- Keep `android.newDsl=false` in gradle.properties (mirror reference). Gradle wrapper 9.5.1, AGP 9.2.1, Kotlin 2.4.0 apply false.

### `android/app/src/main/AndroidManifest.xml`
```xml
<uses-feature android:name="android.hardware.usb.host" android:required="true"/>
```
On MainActivity (`android:launchMode="singleTop"`, so replug doesn't stack instances):
```xml
<intent-filter>
  <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"/>
</intent-filter>
<meta-data android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
           android:resource="@xml/device_filter"/>
```

### `android/app/src/main/res/xml/device_filter.xml` — DECIMAL ids (hex strings fail silently)
```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <usb-device vendor-id="12346"/>              <!-- 0x303A Espressif: C3/S2/S3 USB-JTAG PID 0x1001=4097 -->
    <usb-device vendor-id="4292" product-id="60000"/>  <!-- 0x10C4/0xEA60 CP210x -->
    <usb-device vendor-id="6790" product-id="29987"/>  <!-- 0x1A86/0x7523 CH340 -->
    <usb-device vendor-id="6790" product-id="21972"/>  <!-- 0x1A86/0x55D4 CH9102 -->
    <usb-device vendor-id="1027"/>               <!-- 0x0403 FTDI any PID -->
</resources>
```

### Kotlin (`android/app/src/main/kotlin/com/example/espflasher/`)
- `MainActivity.kt` — FlutterActivity; registers channels in `configureFlutterEngine`; reads EXTRA_DEVICE on create/onNewIntent → emits `attached`.
- `usb/UsbSerialManager.kt` — wraps UsbManager + `UsbSerialProber.getDefaultProber().findAllDrivers()`; `open()` = `driver.createPort(connection)` → `port.open(conn)` → `setParameters(115200, 8, STOPBITS_1, PARITY_NONE)` → **port.dtr = true; port.rts = true** → start SerialInputOutputManager. Permission: `PendingIntent.getBroadcast(ctx, 0, Intent(ACTION_USB_PERMISSION).setPackage(packageName), FLAG_MUTABLE or FLAG_UPDATE_CURRENT)`; runtime BroadcastReceiver registered with `RECEIVER_NOT_EXPORTED` (API 33+); reads EXTRA_PERMISSION_GRANTED; forwards to events EventChannel. Detach receiver always registered.

---

## 6. Test plan (pure Dart, no hardware)

| Test file | Covers |
|---|---|
| `test/esp/slip_test.dart` | encode/decode roundtrip; payload containing 0xC0/0xDB/0xDB-0xDC; empty frame; `SlipStream` frames split mid-escape and mid-frame across chunks |
| `test/esp/protocol_test.dart` | golden request bytes for SYNC header (`00 08 24 00 00 00 00 00` + 36 B); checksum seed 0xEF known vector; response parse: opcode skip, value field, ROM status from last 4 data bytes; every RomError code maps to message |
| `test/esp/connection_test.dart` | `FakeTransport` (scripted byte replies + recorded writes): sync retry count on timeout, multi-SYNC-response drain, command opcode-mismatch skip, timeout throws `EspTimeoutError`, writeReg/readReg framing |
| `test/esp/reset_test.dart` | recorded DTR/RTS transitions + fake clock assert exact sequences & timings for Classic/UsbJtag/Hard |
| `test/esp/flasher_test.dart` | `FakeRomTransport` scripted ROM: full 2-part flash asserts — SPI_ATTACH bytes, SPI_SET_PARAMS bytes, FLASH_BEGIN 5 words (incl. num_blocks math), block prefix/checksum, 0xFF last-block padding, NO FLASH_END sent, MD5 hex compare pass + mismatch→error, erase = FLASH_BEGIN num_blocks=0, progress callback values, cancel mid-flash |
| `test/esp/chip_detect_test.dart` | GET_SECURITY_INFO payload vectors → C3; encrypted flag → refuse; magic fallback |
| `test/firmware/downloader_test.dart` | dio via fake HttpClientAdapter: progress ticks, cancel, non-200 error |
| `test/ui/home_screen_test.dart` | widget test: state machine renders each FlashState; offset preset fills field |

**NOT testable without hardware (manual smoke checklist, `docs/HARDWARE_SMOKE.md`):** USB permission dialog, ATTACHED auto-launch, re-enumeration mid-flash, actual sync timing, ROM erase duration, bridge-chip DTR/RTS vendor behavior, kernel-driver-bound CDC boards (hold-BOOT fallback), real MD5 over real flash.

---

## 7. File tree, order, risks

### Tree (new files only; rest = `flutter create --platforms android --org com.example`)
```
.mise.toml                                  # copy happy_flutter verbatim
Makefile                                    # analyze/test/build-dev targets
.github/workflows/ci.yml                    # analyze + test shards + build apk
android/settings.gradle.kts                 # + jitpack repo + AGP9 patcher
android/gradle.properties                   # android.newDsl=false etc.
android/app/build.gradle.kts                # + mik3y dep, flavors
android/app/src/main/AndroidManifest.xml    # + usb.host + ATTACHED filter
android/app/src/main/res/xml/device_filter.xml
android/app/src/main/kotlin/com/example/espflasher/MainActivity.kt
android/app/src/main/kotlin/com/example/espflasher/usb/UsbSerialManager.kt
lib/main.dart
lib/app.dart                                # MaterialApp + ProviderScope
lib/esp/{slip,protocol,transport,connection,chip_detect,reset,flasher,errors}.dart
lib/esp/targets/esp32c3.dart
lib/esp/stub.dart                           # v2
lib/usb/{usb_events,usb_device_info,usb_serial_channel,android_usb_transport}.dart
lib/firmware/{firmware_part,firmware_picker,firmware_downloader}.dart
lib/state/{usb_providers,flash_providers,firmware_providers,log_providers}.dart
lib/ui/{home_screen}.dart
lib/ui/widgets/{device_card,firmware_part_row,offset_field,flash_progress,log_view,manual_bootloader_sheet}.dart
assets/stubs/esp32c3.json                   # v2, from esptool-js + NOTICE
test/… (mirrors lib/)
docs/{IMPLEMENTATION_PLAN,HARDWARE_SMOKE}.md
NOTICE                                      # esptool-js Apache-2.0 + stub attribution
```
pubspec deps (keep minimal): `flutter_riverpod ^3`, `file_picker ^11.0.3`, `dio ^5.11.0`, `path_provider ^2.1.6`, `crypto ^3`.

### Ordered steps (parallel lanes after step 1)
1. **Scaffold (Agent D, ~3h):** git init, flutter create, .mise.toml, gradle mirror, Makefile, CI yml, pubspec, empty main/app compiling. Gate: `mise exec -- flutter build apk --debug --flavor development` green.
2. **Lane B — ESP core (critical path, ~1 day):** slip → protocol → connection → reset → esp32c3 → chip_detect → flasher, tests-first. Zero platform deps; done when 6 test files green.
3. **Lane A — USB transport (~1 day, parallel with B):** Kotlin UsbSerialManager + MainActivity + manifest + device_filter + jitpack dep; Dart usb_serial_channel + android_usb_transport over FakeTransport until Kotlin lands.
4. **Lane C — UI/state (~1 day, starts once B's interfaces freeze):** providers + widgets against `FlashState`; dev-loop uses a `FakeEspTransport` provider override so UI is testable with zero hardware.
5. **Integrate (~4h):** wire real transport → flashController; run HARDWARE_SMOKE on a real C3.
6. **v2:** stub loader (3–4h), CHANGE_BAUD for bridges only, erase UI polish, URL manifest format.

### Top 3 risks
1. **USB re-enumeration on download-mode entry kills connection/permission mid-flash.** Mitigation: `usbController` listens for ATTACHED, auto-re-requests permission + reopens; flash resumable per-part (FLASH_BEGIN re-erases only that region); never clear parts list on device loss.
2. **mik3y opens DTR/RTS low → ESP32 USB-JTAG ignores OUT endpoint → all writes time out.** Mitigation: setDtr(true)+setRts(true) as literal first ops after open (both Kotlin and Dart sides); unit-test the open sequence.
3. **ROM erases up-front in FLASH_BEGIN; multi-MB images block ACK for tens of seconds → naive timeouts abort a working flash.** Mitigation: timeout = max(30s, 40s/MB) per FLASH_BEGIN; UI shows "Erasing (can take minutes)"; v2 stub moves erase just-in-time.

Runners-up (not top-3): JitPack first-resolution flake → pin tag + warm gradle cache in CI; AGP 9 plugin breakage → reference patcher already copied; secure-boot/encrypted chips → refuse in chip_detect with clear message.
