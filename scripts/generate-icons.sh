#!/usr/bin/env bash
# Render Android launcher icons from the SVG masters in assets/icon/.
#
# The PNGs are build artifacts (gitignored) — this runs in CI before every
# APK build, and locally via `make icons` / the build-dev / build-release
# targets. Masters: assets/icon/app_icon.svg (legacy), app_icon_foreground.svg
# (adaptive foreground), app_icon_monochrome.svg (Android 13 themed icons).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/assets/icon"
RES="$ROOT/android/app/src/main/res"

# --- rasterizer detection ---------------------------------------------------
TOOL=""
for c in rsvg-convert resvg inkscape magick; do
  if command -v "$c" >/dev/null 2>&1; then TOOL="$c"; break; fi
done

if [ -z "$TOOL" ]; then
  if [ -f "$RES/mipmap-xxxhdpi/ic_launcher.png" ]; then
    echo "generate-icons: no SVG rasterizer found (tried rsvg-convert, resvg," >&2
    echo "  inkscape, magick) — keeping previously generated PNGs." >&2
    exit 0
  fi
  echo "generate-icons: no SVG rasterizer found and no generated icons present." >&2
  echo "  Install one, e.g.: sudo apt-get install librsvg2-bin" >&2
  exit 1
fi

render() { # <size-px> <in.svg> <out.png>
  case "$TOOL" in
    rsvg-convert) rsvg-convert -w "$1" -h "$1" "$2" -o "$3" ;;
    resvg)        resvg -w "$1" -h "$1" "$2" "$3" ;;
    inkscape)     inkscape "$2" -w "$1" -h "$1" -o "$3" ;;
    magick)       magick -background none -density 384 "$2" -resize "${1}x${1}" "$3" ;;
  esac
}

# density : legacy launcher px (48dp) : adaptive layer px (108dp)
DENSITIES="mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432"

echo "generate-icons: rasterizing with $TOOL"
for spec in $DENSITIES; do
  IFS=: read -r density legacy layer <<<"$spec"
  out="$RES/mipmap-$density"
  mkdir -p "$out"
  render "$legacy" "$SRC/app_icon.svg"            "$out/ic_launcher.png"
  render "$layer"  "$SRC/app_icon_foreground.svg" "$out/ic_launcher_foreground.png"
  render "$layer"  "$SRC/app_icon_monochrome.svg" "$out/ic_launcher_monochrome.png"
done
echo "generate-icons: wrote ic_launcher{,_foreground,_monochrome}.png to res/mipmap-*"
