#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/ysg-icon.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/AppIcon.iconset"
sips -s format png Resources/IconSource/YeShunguangPet.ico --out "$work/source.png" >/dev/null
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$work/source.png" --out "$work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  twice=$((size*2))
  sips -z "$twice" "$twice" "$work/source.png" --out "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work/AppIcon.iconset" -o Resources/AppIcon.icns
