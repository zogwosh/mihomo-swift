#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x Resources/mihomo ]]; then python3 Scripts/fetch-kernel.py; fi
swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)
mkdir -p "$PWD/dist"
STAGE=$(mktemp -d "$PWD/dist/.build-app.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Mihomo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/HelperTools" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN_DIR/MihomoSwift" "$APP/Contents/MacOS/"
cp "$BIN_DIR/MihomoHelper" "$APP/Contents/Library/HelperTools/"
cp .build/checkouts/Yams/LICENSE "$APP/Contents/Resources/Yams-LICENSE.txt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/io.github.zogwosh.MihomoSwift.Helper.plist "$APP/Contents/Library/LaunchDaemons/"
cp Resources/mihomo Resources/kernel-manifest.json Resources/Mihomo-LICENSE.txt Resources/THIRD-PARTY.txt "$APP/Contents/Resources/"
IDENTITY="${SIGNING_IDENTITY:--}"
SIGN_OPTIONS=(--force --timestamp=none)
if [[ "$IDENTITY" != "-" ]]; then SIGN_OPTIONS=(--force --options runtime --timestamp); fi
codesign "${SIGN_OPTIONS[@]}" --sign "$IDENTITY" --identifier io.github.zogwosh.MihomoSwift.Kernel "$APP/Contents/Resources/mihomo"
codesign "${SIGN_OPTIONS[@]}" --sign "$IDENTITY" --identifier io.github.zogwosh.MihomoSwift.Helper "$APP/Contents/Library/HelperTools/MihomoHelper"
codesign "${SIGN_OPTIONS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
if [[ -d "$PWD/dist/Mihomo.app" ]]; then mv "$PWD/dist/Mihomo.app" "$STAGE/previous.app"; fi
mv "$APP" "$PWD/dist/Mihomo.app"
printf 'Built %s\n' "$PWD/dist/Mihomo.app"
