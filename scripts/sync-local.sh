#!/bin/bash
# Islet Legacy: builds the app and build/Islet-Legacy.dmg only. It never touches the
# official Islet installed in /Applications or its disk images.
# Publishing to GitHub is separate (scripts/release.sh).
#
# Usage: scripts/sync-local.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Islet Legacy.app"

"$ROOT/scripts/build-app.sh" release

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Islet Legacy.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Islet Legacy" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/build/Islet-Legacy.dmg" > /dev/null
rm -rf "$STAGE"
echo "Updated $ROOT/build/Islet-Legacy.dmg"
