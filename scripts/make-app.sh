#!/usr/bin/env bash
#
# make-app.sh — assemble the Transom .app bundle(s) from the SwiftPM release build.
#
# Two bundles, one script, parameterised (issue #8): the diagnostic probe and the
# host control panel. Each wraps its SwiftPM executable in a proper bundle with a
# STABLE, DISTINCT bundle id so it gets its own TCC identity, and codesigns it
# with a real Developer identity. Why the identity matters (issue Part 3): for a
# properly signed app, TCC keys the Screen Recording / Accessibility grant on the
# code's *Designated Requirement* (identifier + signing cert), which is stable
# across rebuilds — so you grant once. Ad-hoc/unsigned code is instead keyed on
# the cdhash, which changes every build, so you re-approve every build.
#
# The two bundle ids MUST NOT collide: TCC keys on bundle id, and two apps sharing
# one would make the grants ambiguous and the probe useless as a diagnostic.
#   probe -> one.nullstack.transom.probe
#   host  -> one.nullstack.transom.host
#
# Signing identity: pass CODESIGN_IDENTITY to override. Default is the Apple
# Development identity chosen for this project (same for both bundles). Ad-hoc
# ("-") is possible but the cdhash then changes every build and you re-approve TCC
# every time — avoid.
#
# Usage:
#   scripts/make-app.sh [probe|host|all] [--adhoc]   # default: all (both bundles)
#
set -euo pipefail

# Apple Development: aydinmrnv@gmail.com (4X6AGG88Z2)
DEFAULT_IDENTITY="67315A3C68C599F66678516930A4581479BC0DFD"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$DEFAULT_IDENTITY}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- args -------------------------------------------------------------------
TARGET="all"
for arg in "$@"; do
  case "$arg" in
    --adhoc) CODESIGN_IDENTITY="-" ;;
    probe|host|all) TARGET="$arg" ;;
    *) echo "usage: $0 [probe|host|all] [--adhoc]" >&2; exit 2 ;;
  esac
done

BUILD_DIR="$(swift build -c release --show-bin-path)"

# The Transom logo, committed to the repo. make_icns turns it into the .icns the
# bundle references via CFBundleIconFile (Info.plist), so the Dock/Finder show it.
ICON_SOURCE="$REPO_ROOT/Resources/AppIcon.png"

# make_icns <dest.icns> — build a macOS .icns from ICON_SOURCE via an .iconset.
# The source is a single square PNG; sips rescales it to each required slot.
make_icns() {
  local DEST="$1"
  if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "warning: icon source not found at $ICON_SOURCE — bundle will have no icon" >&2
    return 0
  fi
  local ICONSET
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  # size:filename pairs iconutil expects (@2x is the same pixel size as the next slot up).
  local slots=(
    "16:icon_16x16.png"    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"    "64:icon_32x32@2x.png"
    "128:icon_128x128.png" "256:icon_128x128@2x.png"
    "256:icon_256x256.png" "512:icon_256x256@2x.png"
    "512:icon_512x512.png" "1024:icon_512x512@2x.png"
  )
  local slot px name
  for slot in "${slots[@]}"; do
    px="${slot%%:*}"; name="${slot##*:}"
    sips -z "$px" "$px" "$ICON_SOURCE" --out "$ICONSET/$name" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$DEST"
  rm -rf "$(dirname "$ICONSET")"
}

# build_bundle <bundle_id> <app_name> <executable> <version> <build> <category>
build_bundle() {
  local BUNDLE_ID="$1" APP_NAME="$2" EXECUTABLE="$3" VERSION="$4" BUILD="$5" CATEGORY="$6"
  local APP_DIR="$REPO_ROOT/build/${APP_NAME}.app"

  echo "==> building ${EXECUTABLE} (release)"
  swift build -c release --product "$EXECUTABLE"

  if [[ ! -x "$BUILD_DIR/$EXECUTABLE" ]]; then
    echo "error: built executable not found at $BUILD_DIR/$EXECUTABLE" >&2
    exit 1
  fi

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
    <key>CFBundleIconFile</key>                     <string>AppIcon</string>
    <key>CFBundlePackageType</key>                 <string>APPL</string>
    <key>CFBundleShortVersionString</key>          <string>${VERSION}</string>
    <key>CFBundleVersion</key>                     <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>              <string>14.0</string>
    <key>NSHighResolutionCapable</key>             <true/>
    <key>LSApplicationCategoryType</key>           <string>${CATEGORY}</string>
    <key>NSPrincipalClass</key>                    <string>NSApplication</string>
</dict>
</plist>
PLIST

  echo "==> generating AppIcon.icns"
  make_icns "$APP_DIR/Contents/Resources/AppIcon.icns"

  echo "==> codesigning ${APP_NAME} with identity: ${CODESIGN_IDENTITY}"
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
  echo
}

if [[ "$TARGET" == "probe" || "$TARGET" == "all" ]]; then
  build_bundle "one.nullstack.transom.probe" "Transom Probe" "TransomProbeApp" \
    "0.0.1" "1" "public.app-category.developer-tools"
fi

if [[ "$TARGET" == "host" || "$TARGET" == "all" ]]; then
  build_bundle "one.nullstack.transom.host" "Transom Host" "TransomHostApp" \
    "0.1.0" "1" "public.app-category.developer-tools"
fi
