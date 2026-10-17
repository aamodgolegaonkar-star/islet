#!/bin/bash
# Builds Islet.app into ./build: compiles the Swift package, builds the pinned
# mediaremote-adapter (BSD-3) if needed, assembles the bundle and signs it. The app is
# universal (Apple silicon + Intel).
#
# Signing uses a self-signed "Islet Local Code Signing" certificate, created in the login
# keychain on first use, so the app keeps one identity across builds and macOS remembers
# its permissions (Accessibility…). ISLET_ADHOC=1, or a failure to create it, signs ad hoc.
#
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
ADAPTER="$ROOT/Vendor/mediaremote-adapter"
ADAPTER_COMMIT="797729d9b16316dc313844476c153d7a107ca0df"
APP="$ROOT/build/Islet.app"

if [ ! -d "$ADAPTER/.git" ]; then
    git clone --quiet https://github.com/ungive/mediaremote-adapter.git "$ADAPTER"
fi
if [ "$(git -C "$ADAPTER" rev-parse HEAD)" != "$ADAPTER_COMMIT" ]; then
    git -C "$ADAPTER" fetch --quiet origin
    git -C "$ADAPTER" checkout --quiet "$ADAPTER_COMMIT"
    rm -rf "$ADAPTER/build"
fi
# Rebuild an older single-architecture adapter as universal.
if [ -d "$ADAPTER/build/MediaRemoteAdapter.framework" ] &&
   ! lipo -archs "$ADAPTER/build/MediaRemoteAdapter.framework/MediaRemoteAdapter" | grep -q x86_64; then
    rm -rf "$ADAPTER/build"
fi
if [ ! -d "$ADAPTER/build/MediaRemoteAdapter.framework" ]; then
    cmake -S "$ADAPTER" -B "$ADAPTER/build" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" > /dev/null
    cmake --build "$ADAPTER/build" > /dev/null
fi

cd "$ROOT"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCHS[@]}" --product Islet
PRODUCTS="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"
BIN="$PRODUCTS/Islet"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Islet"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$ADAPTER/build/MediaRemoteAdapter.framework" "$APP/Contents/Resources/"
# Sparkle (MIT), the updater.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/"
cp "$ADAPTER/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"

IDENTITY_NAME="Islet Local Code Signing"
# A keychain of its own, so the script can unlock it and let codesign use the key without
# a prompt. Its password only guards this local signing key.
KEYCHAIN="$HOME/Library/Keychains/islet-signing.keychain-db"
KEYCHAIN_PASSWORD="islet-local-signing"
identity() {
    [ -f "$KEYCHAIN" ] || return 0
    security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null |
        awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }'
}
make_identity() {
    local dir; dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' RETURN
    cat > "$dir/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
    [ -f "$KEYCHAIN" ] || security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"  # no auto-lock timeout
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.cnf" \
        -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null &&
    openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$IDENTITY_NAME" \
        -passout pass:islet -out "$dir/identity.p12" 2>/dev/null &&
    security import "$dir/identity.p12" -k "$KEYCHAIN" -P islet -T /usr/bin/codesign > /dev/null &&
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null
}

SIGN="-"
if [ "${ISLET_ADHOC:-0}" != 1 ]; then
    if [ -z "$(identity)" ]; then
        make_identity || echo "Couldn't create the signing certificate; signing ad hoc." >&2
    fi
    SIGN="$(identity)"
    SIGN="${SIGN:--}"
fi
if [ "$SIGN" != "-" ]; then
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    if ! codesign --force --deep --keychain "$KEYCHAIN" --sign "$SIGN" "$APP"; then
        echo "Signing with $IDENTITY_NAME failed; signing ad hoc." >&2
        SIGN="-"
    fi
fi
if [ "$SIGN" = "-" ]; then
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"
