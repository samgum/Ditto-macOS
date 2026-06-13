#!/bin/bash
# Builds DittoMac and packages it as Ditto.app inside a DMG.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Ditto"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$BUILD_DIR/stage"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"

echo "==> Building release binary"
swift build --package-path "$ROOT_DIR" -c release

BINARY="$ROOT_DIR/.build/release/DittoMac"
if [[ ! -f "$BINARY" ]]; then
  echo "Build did not produce $BINARY" >&2
  exit 1
fi

echo "==> Staging .app bundle"
rm -rf "$STAGE_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Bundle localizations
if [[ -d "$ROOT_DIR/Sources/DittoMac/Localizations" ]]; then
  cp -R "$ROOT_DIR/Sources/DittoMac/Localizations" "$APP_BUNDLE/Contents/Resources/Localizations"
fi

# PkgInfo
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Building DMG"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO \
  "$DIST_DIR/Ditto-macOS.dmg"

echo "==> Done: $DIST_DIR/Ditto-macOS.dmg"
