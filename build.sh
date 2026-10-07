#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) Volumio.app into build/.
set -e
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
PRODUCTS=.build/apple/Products/Release

APP=build/Volumio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$PRODUCTS/Volumio" "$APP/Contents/MacOS/Volumio"
cp Info.plist "$APP/Contents/Info.plist"
ditto "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Sign inside-out: Sparkle's helpers, the framework, then the app (ad-hoc).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPARKLE/XPCServices/"*.xpc "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    codesign --force --sign - "$item"
done
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"
echo "Built $APP"
