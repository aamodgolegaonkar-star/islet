#!/bin/bash
# Islet Legacy (macOS 15+): its own releases repo and update feed, so the official Islet
# releases are never touched.
#
# Publishes a signed Islet Legacy update: bumps the version, builds, signs the update with the
# Sparkle key in your login Keychain, and uploads the zip, the disk image and the update
# feed to GitHub. Every installed Islet finds it on its next daily check.
#
# Usage: scripts/release.sh <version> ["What's new"]      e.g. scripts/release.sh 1.2 "Faster lyrics"
#        RELEASE_LOCAL=<dir> scripts/release.sh ...         build and sign only, into <dir>, with
#                                                           file:// links (for testing the updater)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="aamodgolegaonkar-star/islet-legacy-releases"
VERSION="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-Bug fixes and improvements.}"
PLIST="$ROOT/Resources/Info.plist"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
OUT="${RELEASE_LOCAL:-$ROOT/build/release}"

# Sparkle compares build numbers: each release gets the next one.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" "$PLIST"
echo "Islet Legacy $VERSION (build $BUILD)"

"$ROOT/scripts/build-app.sh" release

rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/Islet-Legacy-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/Islet Legacy.app" "$ZIP"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$ZIP")   # sparkle:edSignature="…" length="…"

STAGE=$(mktemp -d)
ditto "$ROOT/build/Islet Legacy.app" "$STAGE/Islet Legacy.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Islet Legacy" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Islet-Legacy.dmg" > /dev/null
rm -rf "$STAGE"
# Keep build/Islet-Legacy.dmg current too, for sharing by hand.
cp "$OUT/Islet-Legacy.dmg" "$ROOT/build/Islet-Legacy.dmg"

if [ -n "${RELEASE_LOCAL:-}" ]; then
    DOWNLOAD="file://$ZIP"
else
    DOWNLOAD="https://github.com/$REPO/releases/download/v$VERSION/Islet-Legacy-$VERSION.zip"
fi
ESCAPED=$(printf '%s' "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Islet Legacy</title>
    <item>
      <title>Islet Legacy $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$ESCAPED</p>]]></description>
      <enclosure url="$DOWNLOAD" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML

if [ -n "${RELEASE_LOCAL:-}" ]; then
    echo "Local test release in $OUT"
    exit 0
fi
gh release create "v$VERSION" --repo "$REPO" --title "Islet Legacy $VERSION" --notes "$NOTES" \
    "$ZIP" "$OUT/Islet-Legacy.dmg" "$OUT/appcast.xml"
echo "Published https://github.com/$REPO/releases/tag/v$VERSION"
