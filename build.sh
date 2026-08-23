#!/bin/bash
#
# Build Blend.app from the Swift sources — no Xcode project needed.
#   ./build.sh            compile + assemble + sign Blend.app
#   ./build.sh release    same, then produce dist/Blend-<version>.zip and .dmg
#   open Blend.app        run it
#
# Signing: the two permissions Blend needs (System Audio Recording, and
# Automation → Music) are keyed to the signing identity, so an ad-hoc
# signature (which changes every build) would lose both grants on every
# rebuild. We sign with an "Apple Development" certificate from the keychain.
#
# NOTE: this Mac has two identically-named Apple Development certificates and
# binaries signed with 2103F163… are killed by the kernel on launch (SIGKILL,
# exit 137, no log). 48A547C8… works. build.sh verifies the identity it picks
# by signing and running a tiny probe binary, so a dead cert is caught here
# rather than as a mystery crash. Override with CODESIGN_ID=<sha1>.
#
set -euo pipefail
cd "$(dirname "$0")"

APP="Blend.app"
BIN="Blend"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.4"
BUILD=".build"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"

pick_identity() {
    if [ -n "${CODESIGN_ID:-}" ]; then echo "$CODESIGN_ID"; return; fi
    mkdir -p "$BUILD"
    printf 'int main(void){return 0;}' > "$BUILD/probe.c"
    cc -o "$BUILD/probe" "$BUILD/probe.c" 2>/dev/null
    for id in $(security find-identity -v -p codesigning | awk '/Apple Development/{print $2}'); do
        codesign --force --sign "$id" "$BUILD/probe" 2>/dev/null || continue
        if "$BUILD/probe" 2>/dev/null; then echo "$id"; return; fi
    done
    echo "-"
}

SIGN_ID="$(pick_identity)"
if [ "$SIGN_ID" = "-" ]; then
    echo "warning: no working Apple Development certificate found — falling back to ad-hoc signing." >&2
    echo "warning: permissions will reset on every rebuild until you sign into Xcode with an Apple ID." >&2
fi

rm -rf "$APP"
mkdir -p "$BUILD"

echo "Compiling Blend $VERSION ($TARGET)…"
find Sources -name '*.swift' -print0 | xargs -0 swiftc -O -swift-version 5 -parse-as-library -target "$TARGET" \
    -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework AVFoundation \
    -framework Accelerate -framework UniformTypeIdentifiers \
    -o "$BUILD/$BIN"

echo "Assembling $APP…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$BIN" "$APP/Contents/MacOS/$BIN"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Blend.icns ] && cp Blend.icns "$APP/Contents/Resources/Blend.icns" || true

echo "Signing ($SIGN_ID)…"
if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --timestamp --sign "$SIGN_ID" "$APP" 2>/dev/null \
        || codesign --force --sign "$SIGN_ID" "$APP"
fi

echo "Done → $APP"

if [ "${1:-}" = "release" ]; then
    echo "Packaging release artifacts…"
    rm -rf dist && mkdir -p dist
    ditto -c -k --keepParent "$APP" "dist/Blend-$VERSION.zip"
    STAGE="$BUILD/dmg"
    rm -rf "$STAGE" && mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Blend $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Blend-$VERSION.dmg" >/dev/null
    echo "Done → dist/Blend-$VERSION.zip, dist/Blend-$VERSION.dmg"
fi
