#!/bin/bash
# Builds DittoMac and packages a launchable Ditto.app inside a DMG that also
# contains an /Applications drag-target (the "guiding arrow").
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Ditto"
EXEC_NAME="Ditto"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$BUILD_DIR/stage"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
RESOURCES_DIR="$ROOT_DIR/Resources"

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

# CFBundleExecutable is "Ditto" (see Info.plist) — the binary must match.
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
cp "$RESOURCES_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Bundle localizations
if [[ -d "$ROOT_DIR/Sources/DittoMac/Localizations" ]]; then
  cp -R "$ROOT_DIR/Sources/DittoMac/Localizations" "$APP_BUNDLE/Contents/Resources/Localizations"
fi

# PkgInfo
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Generate the app icon if missing (CFBundleIconFile = AppIcon)
if [[ ! -f "$RESOURCES_DIR/AppIcon.icns" ]]; then
  echo "==> Generating app icon"
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift "$ROOT_DIR/scripts/make_icon.swift" "$BUILD_DIR/icon_1024.png"
  declare -a SIZES=(16 32 128 256 512)
  for s in "${SIZES[@]}"; do
    sips -z $s $s "$BUILD_DIR/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$BUILD_DIR/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  cp "$BUILD_DIR/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"
fi
cp "$RESOURCES_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc code signing"
# Plain ad-hoc signature WITHOUT Hardened Runtime. Hardened Runtime + ad-hoc
# is the documented cause of Accessibility grants not "sticking" on recent
# macOS — the toggle appears but has no effect, so every synthesized ⌘V
# re-prompts. A plain ad-hoc signature lets the Accessibility grant apply
# persistently, so paste works without re-prompting.
codesign --force --deep --sign - "$APP_BUNDLE"
echo "    signature:"
codesign -dv "$APP_BUNDLE" 2>&1 | sed 's/^/    /' || true

echo "==> Staging DMG contents (Ditto.app + /Applications link)"
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> Building DMG"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Version-stamped filename, read from Info.plist.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$RESOURCES_DIR/Info.plist" 2>/dev/null || echo "0.0.0")
DMG_NAME="Ditto-macOS-${VERSION}.dmg"

hdiutil create -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov -format UDZO \
  "$DIST_DIR/$DMG_NAME"

# Also keep an unversioned symlink-style copy for convenience/CI defaults.
cp "$DIST_DIR/$DMG_NAME" "$DIST_DIR/Ditto-macOS.dmg"

echo "==> Done: $DIST_DIR/$DMG_NAME"
echo "    (Ad-hoc signed — to open on another Mac: right-click ▸ Open, or"
echo "     approve in System Settings ▸ Privacy & Security.)"
