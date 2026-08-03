# Hardware smoke checklist

Things unit tests cannot cover — run these on a real ESP32-C3 board
before calling a release good. Tick each box with the board + cable
noted.

## Setup

- [ ] Debug APK (`make build-dev`) installs and launches on the phone
- [ ] Phone is OTG-capable; ESP32-C3 connected via known-good data cable

## USB layer

- [ ] USB permission dialog appears on first attach; grant persists per session
- [ ] `USB_DEVICE_ATTACHED` auto-launches the app (or brings it forward)
- [ ] Detach/re-attach mid-session re-enumerates and the app recovers
- [ ] A second detach/attach cycle still works (no stale handles)

## Connection

- [ ] USB-Serial-JTAG board (no bridge chip): sync succeeds via UsbJtagReset
- [ ] Bridge-chip board (CP2102/CH340, if available): sync succeeds via ClassicReset
- [ ] Board stuck in app mode: manual bootloader entry (hold BOOT, tap
      RESET, release BOOT) then sync succeeds
- [ ] Kernel-driver-bound CDC board (if any): falls back to the
      hold-BOOT path with a comprehensible error

## Flashing

- [ ] Small part (< 1 block) flashes and MD5-verifies
- [ ] Multi-part image (bootloader 0x0/0x1000 + partitions 0x8000 + app
      0x10000) flashes in offset order and MD5-verifies each part
- [ ] ~1 MB app: ROM erase phase in FLASH_BEGIN does not trip the
      timeout (expect tens of seconds; progress shows "Erasing…")
- [ ] Cancel mid-flash stops between blocks and leaves the device
      recoverable (re-sync works without unplugging)
- [ ] Full chip erase completes (~160 s for 4 MB) and subsequent flash works
- [ ] After flashing, the device reboots into the new firmware
      (rtcWdtReset on USB-JTAG; RTS hard reset on bridge boards)

## Failure handling

- [ ] Pulling the cable mid-flash surfaces a device-lost error, not a hang
- [ ] Re-enumeration mid-flash (download-mode entry) does not corrupt
      state; parts list survives
- [ ] Encrypted / secure-download chip (if available) is refused with a
      clear message, never flashed
