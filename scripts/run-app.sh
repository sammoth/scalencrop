#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_OUTPUT="$ROOT/.build/debug/Scale n Crop.app" "$ROOT/scripts/build-app.sh" debug
open "$ROOT/.build/debug/Scale n Crop.app" --args "$@"
