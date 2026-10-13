#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set Developer ID Application signing identity}"
: "${NOTARY_PROFILE:?Set a notarytool keychain credential profile}"
[[ "$SIGNING_IDENTITY" != "-" ]] || { echo 'Developer ID required'; exit 1; }
bash Scripts/build-app.sh
ditto -c -k --keepParent dist/Mihomo.app dist/Mihomo-notary.zip
xcrun notarytool submit dist/Mihomo-notary.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/Mihomo.app
xcrun stapler validate dist/Mihomo.app
codesign --verify --deep --strict dist/Mihomo.app
spctl --assess --type execute --verbose dist/Mihomo.app
DMG_NAME=Mihomo-0.1.0-macos-arm64.dmg bash Scripts/make-dmg.sh
codesign --sign "$SIGNING_IDENTITY" --timestamp dist/Mihomo-0.1.0-macos-arm64.dmg
xcrun notarytool submit dist/Mihomo-0.1.0-macos-arm64.dmg --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/Mihomo-0.1.0-macos-arm64.dmg
xcrun stapler validate dist/Mihomo-0.1.0-macos-arm64.dmg
(
  cd dist
  shasum -a 256 Mihomo-0.1.0-macos-arm64.dmg > Mihomo-0.1.0-macos-arm64.dmg.sha256
)
