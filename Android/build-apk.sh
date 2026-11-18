#!/bin/zsh
# Builds the signed release APK and copies it to Android/IsletLink.apk, where Islet's
# build-app.sh picks it up and bundles it into the Mac app.
set -euo pipefail
cd "$(dirname "$0")"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
./gradlew --quiet :app:testDebugUnitTest :app:assembleRelease
cp app/build/outputs/apk/release/app-release.apk IsletLink.apk
echo "Built $(pwd)/IsletLink.apk"
