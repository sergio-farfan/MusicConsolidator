#!/bin/bash
# package-dmg.sh
# Apple Music Consolidator
# Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
#
# Package the signed AppleMusicConsolidator.app into a compressed,
# installer-style .dmg with an /Applications drag-symlink, Finder icon
# layout, volume icon, and a SHA256 checksum file.
#
# Usage:  bash macos-app/scripts/package-dmg.sh
# Requires a built, signed bundle (run macos-app/scripts/build-app.sh first).
# The Finder layout step is best effort: it needs the terminal's
# Automation -> Finder permission and times out safely without it — the
# DMG is valid either way, only the window styling is skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="AppleMusicConsolidator"
APP_BUNDLE="${MACOS_APP_DIR}/build/${APP_NAME}.app"
VOL_NAME="Apple Music Consolidator"
DIST_DIR="${MACOS_APP_DIR}/dist"
MOUNT_DIR="/Volumes/${VOL_NAME}"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: ${APP_BUNDLE} not found. Run macos-app/scripts/build-app.sh first." >&2
    exit 1
fi

echo "==> Verifying code signature…"
codesign --verify --deep --strict "$APP_BUNDLE"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_BUNDLE}/Contents/Info.plist")"
DMG_FINAL="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
DMG_TMP="${DIST_DIR}/${APP_NAME}-tmp.dmg"

echo "==> Staging DMG contents (v${VERSION})…"
mkdir -p "$DIST_DIR"
STAGING="$(mktemp -d)"
cleanup() {
    [ -d "$MOUNT_DIR" ] && hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    rm -rf "$STAGING"
}
trap cleanup EXIT INT TERM

cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Volume icon: reuse the app's own icon.
ICON="${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
[ -f "$ICON" ] && cp "$ICON" "$STAGING/.VolumeIcon.icns"

echo "==> Creating writable image…"
rm -f "$DMG_TMP" "$DMG_FINAL" "${DMG_FINAL}.sha256"
SIZE_MB=$(( $(du -sm "$STAGING" | awk '{print $1}') + 20 ))
hdiutil create -srcfolder "$STAGING" -volname "$VOL_NAME" \
    -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$DMG_TMP" >/dev/null

echo "==> Mounting…"
hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen >/dev/null
sleep 2

echo "==> Applying Finder layout (best effort)…"
apply_layout() {
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "${APP_NAME}.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
}

apply_layout & OSA_PID=$!
( sleep 45; kill "$OSA_PID" 2>/dev/null ) & WATCHER=$!
if wait "$OSA_PID" 2>/dev/null; then
    kill "$WATCHER" 2>/dev/null || true
    echo "    Layout applied."
else
    echo "    Warning: Finder layout not applied (Automation denied or timed out)."
    echo "    The DMG is still valid. Grant 'Automation -> Finder' in System"
    echo "    Settings -> Privacy & Security, then re-run for the styled window."
fi

if [ -f "$STAGING/.VolumeIcon.icns" ] && command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT_DIR" || true
fi

sync
echo "==> Detaching…"
hdiutil detach "$MOUNT_DIR" >/dev/null

echo "==> Converting to compressed image…"
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null
rm -f "$DMG_TMP"

echo "==> Verifying image…"
hdiutil verify "$DMG_FINAL" >/dev/null

echo "==> Writing checksum…"
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_FINAL")" > "$(basename "$DMG_FINAL").sha256" )

echo "==> DONE: ${DMG_FINAL}"
cat "${DMG_FINAL}.sha256"
