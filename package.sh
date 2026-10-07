#!/bin/zsh
# Builds Volumio and wraps it in a drag-to-install DMG: build/Volumio-<version>.dmg
set -e
cd "$(dirname "$0")"
./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
STAGE=build/dmg
DMG=build/Volumio-$VERSION.dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Volumio.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "scripts/Huong dan cai dat.txt" "$STAGE/Hướng dẫn cài đặt.txt"

hdiutil create -volname "Volumio" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Packaged $DMG"
