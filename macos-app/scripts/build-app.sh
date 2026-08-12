#!/bin/bash
# build-app.sh
# Apple Music Consolidator
# Copyright (C) 2026 Sergio Farfan <sergio.farfan@gmail.com>. All rights reserved.
#
# build-app.sh — build, assemble, and sign AppleMusicConsolidator.app
#
# Author: Sergio Farfan
#
# Idempotent: every run rebuilds the release binary (incremental via
# SwiftPM), reassembles macos-app/build/AppleMusicConsolidator.app from
# scratch, re-signs, and re-verifies. Safe to run repeatedly; the TCC
# Automation grant survives rebuilds because the signing identity
# ("Sergio Farfan Code Signing") and bundle id are stable.
#
# This script NEVER launches the app and sends no Apple events.
# Launch is a manual step for Sergio in the GUI session:
#     open /Users/sergio.farfan/projects/git/MusicConsolidator/macos-app/build/AppleMusicConsolidator.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_DIR="${MACOS_APP_DIR}/ConsolidatorKit"
ENTITLEMENTS="${MACOS_APP_DIR}/App/AppleMusicConsolidator.entitlements"
BUILD_DIR="${MACOS_APP_DIR}/build"
APP="${BUILD_DIR}/AppleMusicConsolidator.app"

IDENTITY="Sergio Farfan Code Signing"
PRODUCT="AppleMusicConsolidatorApp"     # SwiftPM executable product
EXEC_NAME="AppleMusicConsolidator"      # CFBundleExecutable
BUNDLE_ID="com.sergiofarfan.AppleMusicConsolidator"

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[ -f "${ENTITLEMENTS}" ] || fail "entitlements not found: ${ENTITLEMENTS}"
plutil -lint "${ENTITLEMENTS}" || fail "entitlements plist does not lint"

# --- 1. Build the release binary -------------------------------------------
step "swift build -c release (product ${PRODUCT})"
swift build -c release --package-path "${PACKAGE_DIR}" --product "${PRODUCT}"

BIN_DIR="$(swift build -c release --package-path "${PACKAGE_DIR}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${PRODUCT}"
[ -f "${BIN_PATH}" ] || fail "built binary not found: ${BIN_PATH}"

# --- 2. Static-linkage check (package libs must NOT be dylib deps) ---------
step "otool -L static-linkage check"
OTOOL_OUT="$(otool -L "${BIN_PATH}")"
echo "${OTOOL_OUT}"
if echo "${OTOOL_OUT}" | grep -E 'ConsolidatorCore|MusicBridge' >/dev/null; then
    fail "package library appears as a dynamic dependency — expected static linkage"
fi
if echo "${OTOOL_OUT}" | grep '@rpath/' >/dev/null; then
    fail "unexpected @rpath dylib dependency — bundle embeds no frameworks"
fi
echo "OK: no package dylibs, no @rpath dependencies (static linkage confirmed)"

# --- 3. Assemble the bundle (from scratch, idempotent) ---------------------
step "assemble ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp "${BIN_PATH}" "${APP}/Contents/MacOS/${EXEC_NAME}"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

ICON_SRC="${MACOS_APP_DIR}/assets/appicon/AppIcon.icns"
[ -f "${ICON_SRC}" ] || fail "app icon not found: ${ICON_SRC}"
cp "${ICON_SRC}" "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleIdentifier</key>
	<string>com.sergiofarfan.AppleMusicConsolidator</string>
	<key>CFBundleName</key>
	<string>AppleMusicConsolidator</string>
	<key>CFBundleDisplayName</key>
	<string>Apple Music Consolidator</string>
	<key>CFBundleExecutable</key>
	<string>AppleMusicConsolidator</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.1.1</string>
	<key>CFBundleVersion</key>
	<string>3</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.music</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Apple Music Consolidator needs to control Music to read playlists and (in a later step, only after your explicit approval) create new consolidated playlists. Source playlists are never modified.</string>
	<key>NSHumanReadableCopyright</key>
	<string>© 2026 Sergio Farfan. All rights reserved.</string>
</dict>
</plist>
PLIST

step "plutil -lint Info.plist"
plutil -lint "${APP}/Contents/Info.plist" || fail "Info.plist does not lint"

# --- 4. Sign ----------------------------------------------------------------
# No --options: default signature flags are 0x0 (none) — hardened runtime
# deliberately OFF (self-signed local development; see XCODE-SETUP.md §4).
# codesign takes the signing identifier from CFBundleIdentifier.
#
# Watchdog: using the private key raises a keychain authorization prompt
# ("codesign wants to access key ... in your keychain") unless the key's
# partition list already allows codesign. That prompt is drawn by
# SecurityAgent in the logged-in GUI session; from a non-GUI context
# (ssh, background/automation runner) it never renders and codesign blocks
# FOREVER. Rather than hang, wait CODESIGN_TIMEOUT seconds (default 600 —
# ample for a human to click Allow) then kill and explain.
# Implemented with a portable bash watchdog: stock macOS has no
# /usr/bin/timeout (that is Homebrew coreutils).
CODESIGN_TIMEOUT="${CODESIGN_TIMEOUT:-600}"

step "codesign with identity '${IDENTITY}'"
echo "(if a keychain prompt appears, click Allow / Always Allow;"
echo " waiting up to ${CODESIGN_TIMEOUT}s)"

codesign --force \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${IDENTITY}" \
    "${APP}" &
CODESIGN_PID=$!

WAITED=0
while kill -0 "${CODESIGN_PID}" 2>/dev/null; do
    sleep 2
    WAITED=$((WAITED + 2))
    if [ "${WAITED}" -ge "${CODESIGN_TIMEOUT}" ]; then
        kill "${CODESIGN_PID}" 2>/dev/null || true
        wait "${CODESIGN_PID}" 2>/dev/null || true
        cat >&2 <<EOF

codesign blocked for ${CODESIGN_TIMEOUT}s without completing.

Cause: the private key of "${IDENTITY}" requires authorization, and the
SecurityAgent prompt cannot be displayed (or was not answered). This is the
same class of failure as the documented hiservices/-1701 issue: a GUI/TCC
session is required.

Fix, in order:
  1. Run this script from your NORMAL Terminal in the logged-in GUI session
     (not ssh, not a background/automation runner), and answer the keychain
     prompt with "Always Allow".
  2. To stop the prompt recurring, add codesign to the key's partition list
     (prompts once for your login password):

     security set-key-partition-list -S apple-tool:,apple:,codesign: \\
         -s -l "${IDENTITY}" \\
         -k "<your login password>" ~/Library/Keychains/login.keychain-db

The bundle at
  ${APP}
is fully assembled and lint-clean but UNSIGNED (or carries a stale
signature); re-run this script to finish.
EOF
        exit 1
    fi
done
wait "${CODESIGN_PID}" || fail "codesign exited non-zero"

# --- 5. Verify ---------------------------------------------------------------
step "codesign --verify --strict --verbose=2"
codesign --verify --strict --verbose=2 "${APP}" || fail "codesign verification failed"

step "codesign -dvvv --entitlements -"
# -dvvv, not -dv: the Authority line is only emitted at the higher verbosity.
SIGN_INFO="$(codesign -dvvv --entitlements - "${APP}" 2>&1)"
echo "${SIGN_INFO}"

echo "${SIGN_INFO}" | grep -F "Identifier=${BUNDLE_ID}" >/dev/null \
    || fail "signature identifier is not ${BUNDLE_ID}"
echo "${SIGN_INFO}" | grep -F "Authority=${IDENTITY}" >/dev/null \
    || fail "signature authority is not '${IDENTITY}'"
echo "${SIGN_INFO}" | grep -F "com.apple.security.automation.apple-events" >/dev/null \
    || fail "automation entitlement missing from the signature"
if echo "${SIGN_INFO}" | grep -E '^CodeDirectory .*flags=.*runtime' >/dev/null; then
    fail "hardened runtime flag present — it must be OFF"
fi
if echo "${SIGN_INFO}" | grep -F "com.apple.security.app-sandbox" >/dev/null; then
    fail "sandbox entitlement present — the app must NOT be sandboxed"
fi

step "DONE"
echo "Signed bundle: ${APP}"
echo "Launch (Sergio, GUI session only — Music open first):"
echo "    open ${APP}"
