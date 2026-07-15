#!/usr/bin/env bash
#
# make-app.sh — assemble "Transom Probe.app" from the SwiftPM release build.
#
# This wraps the TransomProbeApp executable in a proper bundle with a STABLE
# bundle id (one.nullstack.transom.probe) so it gets its own TCC identity, and
# codesigns it with a real Developer identity. Why this matters (issue Part 3):
# for a properly signed app, TCC keys the Screen Recording / Accessibility grant
# on the code's *Designated Requirement* (identifier + signing cert), which is
# stable across rebuilds — so you grant once. Ad-hoc/unsigned code is instead
# keyed on the cdhash, which changes every build, so you re-approve every build.
#
# Signing identity: pass CODESIGN_IDENTITY to override. Default is the Apple
# Development identity chosen for this project. Ad-hoc ("-") is possible but the
# cdhash then changes every build and you re-approve TCC every time — avoid.
#
# Usage:
#   scripts/make-app.sh [--adhoc]
#
set -euo pipefail

# --- config -----------------------------------------------------------------
BUNDLE_ID="one.nullstack.transom.probe"   # STABLE. TCC keys on this. Do not change.
APP_NAME="Transom Probe"
EXECUTABLE="TransomProbeApp"
VERSION="0.0.1"
BUILD="1"
# Apple Development: aydinmrnv@gmail.com (4X6AGG88Z2)
DEFAULT_IDENTITY="67315A3C68C599F66678516930A4581479BC0DFD"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$DEFAULT_IDENTITY}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ "${1:-}" == "--adhoc" ]]; then
  CODESIGN_IDENTITY="-"
fi

BUILD_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$REPO_ROOT/build/${APP_NAME}.app"

# --- build ------------------------------------------------------------------
echo "==> building ${EXECUTABLE} (release)"
swift build -c release --product "$EXECUTABLE"

if [[ ! -x "$BUILD_DIR/$EXECUTABLE" ]]; then
  echo "error: built executable not found at $BUILD_DIR/$EXECUTABLE" >&2
  exit 1
fi

# --- assemble bundle --------------------------------------------------------
echo "==> assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>          <string>en</string>
    <key>CFBundleExecutable</key>                 <string>${EXECUTABLE}</string>
    <key>CFBundleIdentifier</key>                 <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
    <key>CFBundleName</key>                        <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>                 <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>                 <string>APPL</string>
    <key>CFBundleShortVersionString</key>          <string>${VERSION}</string>
    <key>CFBundleVersion</key>                     <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>              <string>14.0</string>
    <key>NSHighResolutionCapable</key>             <true/>
    <key>LSApplicationCategoryType</key>           <string>public.app-category.developer-tools</string>
    <key>NSPrincipalClass</key>                    <string>NSApplication</string>
</dict>
</plist>
PLIST

# --- codesign (hardened runtime) --------------------------------------------
echo "==> codesigning with identity: ${CODESIGN_IDENTITY}"
codesign --force \
  --sign "$CODESIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  --timestamp=none \
  "$APP_DIR/Contents/MacOS/$EXECUTABLE"

codesign --force \
  --sign "$CODESIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  --timestamp=none \
  "$APP_DIR"

echo "==> verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo
echo "signing identity (TCC keys the grant on the Designated Requirement below,"
echo "so a stable signed identity survives rebuilds; cdhash may still change):"
codesign -dvvv "$APP_DIR" 2>&1 | grep -E "^(Identifier|CDHash|Authority)" || true
codesign -d --requirements - "$APP_DIR" 2>&1 | grep -i "designated" || true

echo
echo "built: $APP_DIR"
