#!/bin/zsh
# Universal, signed and notarised zip for a GitHub release.
#   CODESIGN_IDENTITY  "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE     keychain profile made with: xcrun notarytool store-credentials
set -euo pipefail
cd "${0:A:h}/.."

: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your Developer ID Application identity}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
ZIP="$PWD/dist/CliHeads-$VERSION.zip"

UNIVERSAL=1 ./Scripts/make-app.sh
rm -f "$ZIP"
ditto -c -k --keepParent dist/CliHeads.app "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple dist/CliHeads.app
  rm -f "$ZIP"
  ditto -c -k --keepParent dist/CliHeads.app "$ZIP"
else
  echo 'NOTARY_PROFILE not set, so the zip is signed but not notarised.'
fi
shasum -a 256 "$ZIP"
