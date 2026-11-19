#!/bin/zsh
# Builds dist/Scale n Crop.app (release, ad-hoc signed unless CODESIGN_IDENTITY is set).
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG="${1:-release}"
OUTPUT="${APP_OUTPUT:-$ROOT/dist/Scale n Crop.app}"
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build --package-path "$ROOT" -c "$CONFIG" --product ScaleNCrop
BUILD_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
install -m 755 "$BUILD_DIR/ScaleNCrop" "$OUTPUT/Contents/MacOS/ScaleNCrop"
cp "$ROOT/Sources/ScaleNCrop/Info.plist" "$OUTPUT/Contents/Info.plist"
if [[ ! -f "$ROOT/assets/AppIcon.icns" || "$ROOT/assets/icon-render.png" -nt "$ROOT/assets/AppIcon.icns" ]]; then
    "$ROOT/scripts/generate-app-icon.sh"
fi
cp "$ROOT/assets/AppIcon.icns" "$OUTPUT/Contents/Resources/AppIcon.icns"
plutil -lint "$OUTPUT/Contents/Info.plist" >/dev/null

codesign --force --sign "$IDENTITY" "$OUTPUT"
print "Built: $OUTPUT"
