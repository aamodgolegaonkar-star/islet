#!/bin/bash
# Builds Islet and replaces every local copy with the new build: the installed apps in
# /Applications, build/Islet.dmg and the disk images in ~/Downloads. Relaunches Islet.
# Publishing to GitHub is separate (scripts/release.sh).
#
# Usage: scripts/sync-local.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Islet.app"

"$ROOT/scripts/build-app.sh" release

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Islet.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Islet -srcfolder "$STAGE" -ov -format UDZO "$ROOT/build/Islet.dmg" > /dev/null
rm -rf "$STAGE"
echo "Updated $ROOT/build/Islet.dmg"

for dmg in "$HOME/Downloads"/Islet*.dmg; do
    [ -e "$dmg" ] || continue
    cp "$ROOT/build/Islet.dmg" "$dmg"
    echo "Updated $dmg"
done

pkill -x Islet || true
sleep 1
for installed in /Applications/Islet*.app; do
    [ -e "$installed" ] || continue
    rsync -a --delete "$APP/" "$installed/"
    echo "Updated $installed"
done
open /Applications/Islet.app
