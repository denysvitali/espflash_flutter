#!/usr/bin/env bash
# Stream defmt logs from a target via probe-rs (RTT), decoding with the given ELF.
#
# Usage:
#   ./scripts/defmt-log.sh path/to/firmware.elf [--flash] [--chip esp32s3]
#
# Modes:
#   default    attach to running target, stream defmt/RTT logs (no reflash)
#   --flash    flash the ELF, reset, then stream logs (probe-rs run)
#
# Chip is auto-detected via `probe-rs info` when not given.
set -euo pipefail

PROBE_RS="$HOME/.cargo/bin/probe-rs"

ELF=""
FLASH=0
CHIP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flash) FLASH=1; shift ;;
    --chip)  CHIP="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *)
      if [[ -z "$ELF" ]]; then ELF="$1"; shift
      else echo "unexpected arg: $1" >&2; exit 2; fi ;;
  esac
done

[[ -n "$ELF" ]] || { echo "error: no ELF given. usage: $0 firmware.elf [--flash] [--chip X]" >&2; exit 2; }
[[ -f "$ELF" ]] || { echo "error: $ELF not found" >&2; exit 2; }

# defmt needs the ELF's symbol/format data — refuse raw .bin early
if ! head -c4 "$ELF" | grep -q $'\x7fELF'; then
  echo "error: $ELF is not an ELF file (defmt decoding needs the ELF, not a .bin)" >&2
  exit 2
fi

if [[ -z "$CHIP" ]]; then
  echo ">> detecting chip..."
  CHIP="$("$PROBE_RS" info 2>/dev/null | grep -oP '(?i)identified.*?\b(esp32[\w-]*|rp2040|nrf52\w*|stm32\w*)' | grep -oP '(esp32[\w-]*|rp2040|nrf52\w*|stm32\w*)' | head -1 || true)"
  [[ -n "$CHIP" ]] || { echo "error: could not auto-detect chip. pass --chip esp32s3 (etc.)" >&2; exit 1; }
  echo ">> chip: $CHIP"
fi

if [[ "$FLASH" -eq 1 ]]; then
  echo ">> flashing + running $ELF"
  exec "$PROBE_RS" run --chip "$CHIP" "$ELF"
else
  echo ">> attaching (no reflash), streaming defmt logs. Ctrl-C to stop."
  exec "$PROBE_RS" attach --chip "$CHIP" "$ELF"
fi
