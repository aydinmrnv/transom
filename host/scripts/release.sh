#!/usr/bin/env bash
#
# release.sh — build, package, and cut a unified Transom release.
#
# A product release contains both halves from this repository:
#   - Transom Host.app for macOS
#   - transom-client.exe for Windows
# The diagnostic probe remains available as a separate optional build.
#
# Releases are prereleases until notarization, authentication, and broader
# hardware coverage are complete. The host/client pair is usable on a trusted
# private LAN.
#
# Usage:
#   scripts/release.sh [host|probe] [--dry-run]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$HOST_ROOT/.." && pwd)"
cd "$PROJECT_ROOT"

TARGET="host"
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    host|probe) TARGET="$arg" ;;
    *) echo "usage: $0 [host|probe] [--dry-run]" >&2; exit 2 ;;
  esac
done

if [[ "$TARGET" == "probe" ]]; then
  TAG="v0.0.1-m0"
  APP_NAME="Transom Probe"
  ZIP_PATH="$HOST_ROOT/build/Transom-Probe-${TAG}.zip"
  RELEASE_TITLE="Transom Probe ${TAG} (diagnostic probe)"
else
  TAG="v0.1.0"
  APP_NAME="Transom Host"
  ZIP_PATH="$HOST_ROOT/build/Transom-Host-${TAG}.zip"
  CLIENT_ZIP_PATH="$HOST_ROOT/build/Transom-Client-Windows-${TAG}.zip"
  CHECKSUMS_PATH="$HOST_ROOT/build/Transom-${TAG}-SHA256SUMS.txt"
  RELEASE_TITLE="Transom ${TAG} (macOS host + Windows client)"
fi
APP_DIR="$HOST_ROOT/build/${APP_NAME}.app"

"$HOST_ROOT/scripts/make-app.sh" "$TARGET"

echo "==> zipping ${APP_DIR}"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
echo "zip: $ZIP_PATH"

if [[ "$TARGET" == "host" ]]; then
  CLIENT_TARGET="x86_64-pc-windows-gnu"
  CLIENT_DIR="$PROJECT_ROOT/client"
  CLIENT_BIN="$CLIENT_DIR/target/${CLIENT_TARGET}/release/transom-client.exe"

  if ! command -v rustup >/dev/null 2>&1; then
    echo "error: rustup is required to build the Windows client" >&2
    exit 1
  fi
  if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    echo "error: x86_64-w64-mingw32-gcc is required to build the Windows client" >&2
    exit 1
  fi
  if ! rustup target list --installed | grep -qx "$CLIENT_TARGET"; then
    echo "error: missing Rust target ${CLIENT_TARGET}; run: rustup target add ${CLIENT_TARGET}" >&2
    exit 1
  fi

  CARGO_BIN="$(rustup which cargo)"
  RUSTC_BIN="$(rustup which rustc)"
  echo "==> building Windows client (${CLIENT_TARGET})"
  (
    cd "$CLIENT_DIR"
    RUSTC="$RUSTC_BIN" \
      CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="$(command -v x86_64-w64-mingw32-gcc)" \
      "$CARGO_BIN" build --locked --release --target "$CLIENT_TARGET"
  )

  CLIENT_STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/transom-client-release.XXXXXX")"
  CLIENT_STAGE="$CLIENT_STAGE_ROOT/Transom Client"
  mkdir -p "$CLIENT_STAGE"
  cp "$CLIENT_BIN" "$CLIENT_STAGE/transom-client.exe"
  cp "$CLIENT_DIR/README.md" "$CLIENT_STAGE/README-Windows.md"
  cp "$PROJECT_ROOT/LICENSE" "$CLIENT_STAGE/LICENSE"
  rm -f "$CLIENT_ZIP_PATH"
  ditto -c -k --keepParent "$CLIENT_STAGE" "$CLIENT_ZIP_PATH"
  rm -rf "$CLIENT_STAGE_ROOT"
  echo "zip: $CLIENT_ZIP_PATH"

  shasum -a 256 "$ZIP_PATH" "$CLIENT_ZIP_PATH" > "$CHECKSUMS_PATH"
  echo "checksums: $CHECKSUMS_PATH"
fi

NOTES_FILE="$(mktemp)"
if [[ "$TARGET" == "probe" ]]; then
  cat > "$NOTES_FILE" <<NOTES
# Transom Probe ${TAG} — diagnostic probe

This is a diagnostic build for macOS capture and Accessibility experiments.
It is separate from the Transom product release and does not provide the
Windows client workflow.

Launch it, grant Screen Recording and Accessibility in System Settings, then
use the Live Probe view to inspect app windows, menus, and geometry alignment.
The app is signed but not notarized; right-click and choose Open on first launch
if macOS blocks it.
NOTES
else
  cat > "$NOTES_FILE" <<NOTES
# Transom ${TAG} — macOS host + Windows client

Transom is one product with a macOS host and Windows client. The host tiles an
app's windows on a virtual display, captures and encodes the display, and serves
window geometry and video over TCP. The Windows client opens each tracked Mac
window as a native Windows window, forwards input, and reconnects after a link
interruption.

## Included artifacts

- \`Transom-Host-${TAG}.zip\` — signed macOS host app.
- \`Transom-Client-Windows-${TAG}.zip\` — Windows x86-64 client.
- \`Transom-${TAG}-SHA256SUMS.txt\` — SHA-256 checksums.

## Install

1. On the Mac, unzip and open \`Transom Host.app\`; grant Screen Recording and
   Accessibility when prompted.
2. Create/configure the BetterDisplay virtual display, choose the display and
   app in Transom Host, set the Mac's private LAN address, and press Start.
3. On Windows, unzip the client and run \`transom-client.exe\`. With no command
   line it opens a connection window; enter the Mac address and press Connect.

The transport is unauthenticated and unencrypted. Use only on a trusted private
network; do not port-forward it. The Mac app is signed but not notarized.
NOTES
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> dry run: skipping gh release create"
  echo "notes preview:"
  echo "----"
  cat "$NOTES_FILE"
  echo "----"
  rm -f "$NOTES_FILE"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found; cannot create the release" >&2
  exit 1
fi

echo "==> creating prerelease ${TAG}"
if [[ "$TARGET" == "host" ]]; then
  gh release create "$TAG" "$ZIP_PATH" "$CLIENT_ZIP_PATH" "$CHECKSUMS_PATH" \
    --title "$RELEASE_TITLE" \
    --notes-file "$NOTES_FILE" \
    --prerelease
else
  gh release create "$TAG" "$ZIP_PATH" \
    --title "$RELEASE_TITLE" \
    --notes-file "$NOTES_FILE" \
    --prerelease
fi

rm -f "$NOTES_FILE"
echo "done."
