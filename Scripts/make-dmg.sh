#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d dist/Mihomo.app ]] || bash Scripts/build-app.sh
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R dist/Mihomo.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.md "$STAGE/安装说明.md"
NAME="${DMG_NAME:-Mihomo-0.1.0-macos-arm64-development.dmg}"
hdiutil create -volname Mihomo -srcfolder "$STAGE" -ov -format UDZO "dist/$NAME"
(
  cd dist
  shasum -a 256 "$NAME" > "$NAME.sha256"
)
