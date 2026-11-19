#!/bin/zsh
# Builds assets/AppIcon.icns from the Blender render (assets/icon.blend → assets/icon-render.png).
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift "$ROOT/scripts/make-icon.swift" "$ROOT/assets/icon-render.png" "$WORK/master.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/master.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/master.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/assets/AppIcon.icns"
print "Wrote $ROOT/assets/AppIcon.icns"
