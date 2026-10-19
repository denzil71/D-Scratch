#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) D-Scratch.app into ./build.
# Usage: ./build.sh [--open] [--dmg]
#   --open  launch the app after building
#   --dmg   also package it as dist/D-Scratch-<version>.dmg (unsigned)
set -euo pipefail
cd "$(dirname "$0")"

OPEN=0
DMG=0
for arg in "$@"; do
    case "$arg" in
        --open) OPEN=1 ;;
        --dmg) DMG=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# One build per architecture, then merged with lipo (a multi-arch `swift build` needs full Xcode).
BINS=()
for TRIPLE in arm64-apple-macosx13.0 x86_64-apple-macosx13.0; do
    swift build -c release --triple "$TRIPLE"
    BINS+=("$(swift build -c release --triple "$TRIPLE" --show-bin-path)/DScratch")
done

APP="build/D-Scratch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/DScratch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - "$APP"
# Register with Launch Services so Finder lists it under "Open With".
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"

if (( DMG )); then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    DMG_PATH="dist/D-Scratch-$VERSION.dmg"
    # Disk image with the app and an Applications shortcut to drag it onto.
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    mkdir -p dist
    hdiutil create -volname "D-Scratch $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG_PATH" >/dev/null
    rm -rf "$STAGE"
    echo "Built $DMG_PATH"
fi

(( OPEN )) && open "$APP"
exit 0
