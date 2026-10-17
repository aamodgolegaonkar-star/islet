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
# Each installed copy's top folder is left read-only: tools that write into the folder
# they run in (Claude Code's ruflo hooks, when a session starts in Islet.app) can't add
# files beside Contents, which would break the code signature and with it Islet's
# permissions. Islet makes it writable again before a Sparkle update moves it.
for installed in /Applications/Islet*.app; do
    [ -e "$installed" ] || continue
    chmod u+w "$installed"
    rsync -a --delete "$APP/" "$installed/"
    chmod a-w "$installed"
    echo "Updated $installed"
done
open /Applications/Islet.app
