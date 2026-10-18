#!/bin/bash
# Publishes a signed Islet update: bumps the version, builds, signs the update with the
# Sparkle key in your login Keychain, and uploads the zip, the disk image and the update
# feed to GitHub. Every installed Islet finds it on its next daily check.
#
# Usage: scripts/release.sh <version> ["What's new"]      e.g. scripts/release.sh 1.2 "Faster lyrics"
#        RELEASE_LOCAL=<dir> scripts/release.sh ...         build and sign only, into <dir>, with
#                                                           file:// links (for testing the updater)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="aamodgolegaonkar-star/islet-releases"
VERSION="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-Bug fixes and improvements.}"
PLIST="$ROOT/Resources/Info.plist"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
OUT="${RELEASE_LOCAL:-$ROOT/build/release}"

# Sparkle compares build numbers: each release gets the next one.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" "$PLIST"
echo "Islet $VERSION (build $BUILD)"

"$ROOT/scripts/build-app.sh" release

rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/Islet-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/Islet.app" "$ZIP"
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$ZIP")   # sparkle:edSignature="…" length="…"

STAGE=$(mktemp -d)
ditto "$ROOT/build/Islet.app" "$STAGE/Islet.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Islet -srcfolder "$STAGE" -ov -format UDZO "$OUT/Islet.dmg" > /dev/null
rm -rf "$STAGE"
# Keep build/Islet.dmg current too, for sharing by hand.
cp "$OUT/Islet.dmg" "$ROOT/build/Islet.dmg"

if [ -n "${RELEASE_LOCAL:-}" ]; then
    DOWNLOAD="file://$ZIP"
else
    DOWNLOAD="https://github.com/$REPO/releases/download/v$VERSION/Islet-$VERSION.zip"
fi
ESCAPED=$(printf '%s' "$NOTES" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Islet</title>
    <item>
      <title>Islet $VERSION</title>
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
gh release create "v$VERSION" --repo "$REPO" --title "Islet $VERSION" --notes "$NOTES" \
    "$ZIP" "$OUT/Islet.dmg" "$OUT/appcast.xml"
echo "Published https://github.com/$REPO/releases/tag/v$VERSION"
