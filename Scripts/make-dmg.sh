#!/bin/bash
# Wraps dist/CliHeads.app in a drag to Applications disk image.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/CliHeads.app/Contents/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto dist/CliHeads.app "$STAGE/CliHeads.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/CliHeads-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "CliHeads" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
echo "$DMG"
