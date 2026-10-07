#!/bin/zsh
# Publishes a new Volumio version that installed copies pick up via Sparkle.
#   ./release.sh 1.2 "Mô tả thay đổi"
# Bumps the version, builds the DMG + update zip, signs the zip with the Sparkle key
# (login keychain, account "Volumio"), writes appcast.xml and creates GitHub release v<version>.
set -e
cd "$(dirname "$0")"

VERSION=${1:?Usage: ./release.sh <version> [notes]}
NOTES=${2:-"Volumio $VERSION"}
REPO=miracle1301/Volumio
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Info.plist

./package.sh

# Sparkle only needs the newest item, so each release gets a fresh single-item appcast.
OUT=build/release-$VERSION
rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent build/Volumio.app "$OUT/Volumio-$VERSION.zip"
print -r -- "$NOTES" > "$OUT/Volumio-$VERSION.txt"
"$SPARKLE_BIN/generate_appcast" --account Volumio \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --embed-release-notes "$OUT"
cp "build/Volumio-$VERSION.dmg" "$OUT/"

git add -A && git commit -m "Release $VERSION" ${COMMIT_TRAILER:+-m "$COMMIT_TRAILER"} || true
git tag "v$VERSION"
git push origin HEAD --tags
gh release create "v$VERSION" --repo "$REPO" --title "Volumio $VERSION" --notes "$NOTES" \
    "$OUT/Volumio-$VERSION.dmg" "$OUT/Volumio-$VERSION.zip" "$OUT/appcast.xml"
echo "Released v$VERSION (build $BUILD)"
