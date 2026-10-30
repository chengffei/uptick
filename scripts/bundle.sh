#!/bin/bash
# Builds build/Uptick.app. Usage: scripts/bundle.sh [--release] [--universal] [--open]
set -e
cd "$(dirname "$0")/.."

CONFIG=debug
OPEN=0
UNIVERSAL=0
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        --open) OPEN=1 ;;
        --universal) UNIVERSAL=1 ;;
    esac
done

# SwiftPM from Command Line Tools lacks the SwiftUI macro plugins; use Xcode's toolchain.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ "$UNIVERSAL" = 1 ]; then
    swift build -c "$CONFIG" --product UptickApp --arch arm64 --arch x86_64
    CAP="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
    # Xcode 26+ puts multi-arch products here; older toolchains used .build/apple/.
    BIN=".build/out/Products/$CAP/UptickApp"
    [ -f "$BIN" ] || BIN=".build/apple/Products/$CAP/UptickApp"
else
    swift build -c "$CONFIG" --product UptickApp
    BIN=".build/$CONFIG/UptickApp"
fi

APP=build/Uptick.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Uptick"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj Resources/AppIcon.icns "$APP/Contents/Resources/"

# A stable signing identity keeps macOS permissions (App Management) across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [ "$OPEN" = 1 ]; then
    pkill -f "$PWD/$APP/Contents/MacOS/Uptick" || true
    open "$APP"
fi
