# espflash_flutter

Flash an ESP32-C3 from your Android phone over USB — from a local `.bin`
file or a firmware URL.

## Why not [espflash](https://github.com/esp-rs/espflash)?

It cannot run on Android:

- espflash's transport is the Rust `serialport` crate, whose port
  enumeration is unimplemented for Android (serialport-rs issue #6,
  open since 2022).
- Unrooted Android exposes no `/dev/ttyUSB*` / `/dev/ttyACM*` nodes to
  apps; USB is only available through the Java USB Host API
  (fd-based), which espflash's hard-wired `Connection { serial:
  serialport::TTYPort }` cannot use without a fork.

So this app ports what matters instead: the ESP ROM bootloader serial
protocol (SLIP framing, SYNC, SPI_ATTACH/SET_PARAMS, FLASH_BEGIN/DATA,
MD5 verify, reset sequences) is implemented in pure Dart, modeled on
Espressif's Apache-2.0 `esptool-js`, and rides a small Kotlin platform
channel around [mik3y/usb-serial-for-android](https://github.com/mik3y/usb-serial-for-android)
(CDC-ACM for the ESP32-C3 native USB-Serial-JTAG port, plus CP210x /
CH34x / FTDI UART bridges). See `docs/IMPLEMENTATION_PLAN.md`.

Current limits (v1): ROM-only flashing without a stub loader (~1 KB
blocks, roughly 15–20 KB/s), ESP32-C3 only. Stub support (16 KB blocks)
is planned for v2.

## Features

- Pick a firmware `.bin` locally or download it from a URL
- Per-part flash offsets with presets (0x0, 0x1000, 0x8000, 0xe000,
  0x10000)
- Erase flash before writing (optional)
- MD5 verification against the ROM
- Live flashing log, progress per part, cancel support
- Auto-detect when the device is plugged in (USB_DEVICE_ATTACHED)
- Serial monitor with [defmt](https://defmt.ferrous-systems.com/)
  decoding: pick the firmware's ELF and watch `defmt::info!` & friends
  rendered live (rzcobs framing as emitted by esp-println's
  `FF 00 … 00` markers); non-defmt serial output passes through as raw
  text. Level filter, text filter, pause, chip reset included.

## Development

Toolchain is pinned with [mise](https://mise.jdx.dev/) (Flutter 3.41.9,
Dart 3.11.5, Java 21, Make 4.4.1) — same setup as
[happy_flutter](https://github.com/denysvitali/happy_flutter):

```sh
mise install        # or: mise trust && mise install
mise exec -- flutter pub get
mise exec -- flutter analyze
mise exec -- flutter test
```

Build a debug APK:

```sh
make build-dev       # = flutter build apk --debug --flavor development
```

Requires an Android SDK (`local.properties` → `sdk.dir`); CI builds
APKs on every push (see `.github/workflows/ci.yml`) and publishes a
GitHub release for every commit on `main`.

### Release signing (one-time)

Release APKs are signed with a stable key once the CI secrets exist:

```sh
make release-key     # = scripts/setup-release-keystore.sh --upload
```

The script generates `~/.espflash_flutter/release-keystore.jks`
(RSA-4096, 30-year validity), prints the generated passwords exactly
once, and uploads the four `KEYSTORE_*` secrets via `gh`. Back up the
`.jks` and passwords offline — losing them means never shipping an
update under the same signature. Without secrets, CI falls back to
debug signing.

## Using it

1. Enable USB OTG on the phone if needed and plug the ESP32-C3 board
   into the USB port (USB-C or via OTG adapter).
2. For boards without auto-reset circuitry: hold **BOOT**, tap
   **RESET**, release BOOT when the app starts connecting, so the chip
   is in download mode.
3. Grant the USB permission dialog, add one or more firmware parts
   (file or URL) with their offsets, then hit **Flash**.

Supported USB IDs: Espressif USB-Serial-JTAG (`303A:*`), CP210x
(`10C4:EA60`), CH340 (`1A86:7523`), CH9102 (`1A86:55D4`), FTDI
(`0403:*`).

## License

MIT
