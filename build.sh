#!/bin/bash
# Builds Screencorder.app. Needs only the Xcode command line tools.
#
#   ./build.sh            build/Screencorder.app, for this Mac
#   ./build.sh --release  build/release/Screencorder.app for Apple silicon and
#                         Intel, plus a zip of it to attach to a release
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1

OUT="build"
[[ $RELEASE == 1 ]] && OUT="build/release"
APP="$OUT/Screencorder.app"
BIN="$APP/Contents/MacOS/Screencorder"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$1-apple-macos15.2" \
    Sources/*.swift \
    -o "$2"
}

if [[ $RELEASE == 1 ]]; then
  compile arm64 "$OUT/Screencorder-arm64"
  compile x86_64 "$OUT/Screencorder-x86_64"
  lipo -create "$OUT/Screencorder-arm64" "$OUT/Screencorder-x86_64" -output "$BIN"
  rm "$OUT/Screencorder-arm64" "$OUT/Screencorder-x86_64"
else
  compile "$(uname -m)" "$BIN"
fi

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A local build is signed with a self-signed certificate when one is in the
# keychain (see the README), so macOS sees every build as the same app and
# keeps its Screen Recording permission. Without it, and for a release, the
# build is signed ad hoc.
IDENTITY="${SCREENCORDER_IDENTITY:-Screen Recorder Local Signing}"
if [[ $RELEASE == 0 ]] && security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ $RELEASE == 1 ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
  ZIP="$OUT/Screencorder-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Zipped $ZIP"
fi
