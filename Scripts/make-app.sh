#!/bin/zsh
# Builds dist/CliHeads.app.
#   UNIVERSAL=1          build for Apple silicon and Intel
#   CODESIGN_IDENTITY    "Developer ID Application: ..." to sign for release (default: ad hoc)
set -euo pipefail
cd "${0:A:h}/.."

if ! xcode-select -p >/dev/null 2>&1; then
  echo 'Swift not found. Install the Xcode command line tools: xcode-select --install'
  exit 1
fi

APP="$PWD/dist/CliHeads.app"
BIN="$APP/Contents/MacOS/CliHeads"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx14.0"
  done
  lipo -create -output "$BIN" \
    "$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/CliHeads" \
    "$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/CliHeads"
else
  swift build -c release
  cp "$(swift build -c release --show-bin-path)/CliHeads" "$BIN"
fi

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/HeadIcons/*.png "$APP/Contents/Resources/"
chmod 755 "$BIN"

IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
echo "Built: $APP"
