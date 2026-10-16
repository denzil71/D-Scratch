#!/bin/zsh
# Builds D-Scratch.app into ./build. Usage: ./build.sh [--open]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/DScratch"

APP="build/D-Scratch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DScratch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - "$APP"
echo "Built $APP"

[[ "${1:-}" == "--open" ]] && open "$APP"
exit 0
