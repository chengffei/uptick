#!/bin/bash
# Universal release build, then dist/Uptick-<version>.dmg, .zip and .sha256.
set -e
cd "$(dirname "$0")/.."

scripts/bundle.sh --release --universal

APP=build/Uptick.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p dist
DMG="dist/Uptick-$VERSION.dmg"
ZIP="dist/Uptick-$VERSION.zip"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG" "$ZIP"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Uptick $VERSION" -srcfolder "$STAGE" -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
# A fixed name too, so install.sh and the in-app updater can use
# releases/latest/download/Uptick.zip without the rate-limited GitHub API.
cp "$ZIP" dist/Uptick.zip
rm -rf "$STAGE"
(cd dist && shasum -a 256 "Uptick-$VERSION.dmg" "Uptick-$VERSION.zip" Uptick.zip | tee "Uptick-$VERSION.sha256" > Uptick.sha256)
