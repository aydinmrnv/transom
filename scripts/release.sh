#!/usr/bin/env bash
#
# release.sh — build, sign, zip, and cut a Transom prerelease.
#
# Two bundles, one script, parameterised (issue #8):
#   probe -> "Transom Probe.app", tag v0.0.1-m0 (the M0 diagnostic probe)
#   host  -> "Transom Host.app",  tag v0.1.0-m2 (the M2 host half)
#
# Both are marked --prerelease with notes that state plainly what does and does
# not work. Neither is a finished product.
#
# NOT notarized. Notarization needs credentials that have not been provided; do
# not add it without asking. On another Mac, the recipient may need to right-click
# > Open (or clear the quarantine attribute) the first time.
#
# Usage:
#   scripts/release.sh [probe|host] [--dry-run]   # default: host (current milestone)
#     --dry-run  build, sign, zip only; skip gh release create
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- args -------------------------------------------------------------------
TARGET="host"
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    probe|host) TARGET="$arg" ;;
    *) echo "usage: $0 [probe|host] [--dry-run]" >&2; exit 2 ;;
  esac
done

# --- per-target config ------------------------------------------------------
if [[ "$TARGET" == "probe" ]]; then
  TAG="v0.0.1-m0"
  APP_NAME="Transom Probe"
  ZIP_PATH="$REPO_ROOT/build/Transom-Probe-${TAG}.zip"
  RELEASE_TITLE="Transom Probe ${TAG} (diagnostic probe)"
else
  TAG="v0.1.0-m2"
  APP_NAME="Transom Host"
  ZIP_PATH="$REPO_ROOT/build/Transom-Host-${TAG}.zip"
  RELEASE_TITLE="Transom Host ${TAG} (host half — streams to nothing yet)"
fi
APP_DIR="$REPO_ROOT/build/${APP_NAME}.app"

# --- build + sign the app ---------------------------------------------------
"$REPO_ROOT/scripts/make-app.sh" "$TARGET"

echo "==> zipping ${APP_DIR}"
rm -f "$ZIP_PATH"
# ditto preserves the code signature and resource forks; plain zip does not.
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
echo "zip: $ZIP_PATH"

# --- notes ------------------------------------------------------------------
NOTES_FILE="$(mktemp)"
if [[ "$TARGET" == "probe" ]]; then
  cat > "$NOTES_FILE" <<'NOTES'
# Transom Probe v0.0.1-m0 — diagnostic probe (NOT a product)

This is **not** a working product. It is a **diagnostic instrument** for the M0
milestone of the Transom host. It does no networking, no encoding, and is not a
client. Its only job is to answer three questions about macOS:

- **OQ-1** (the kill question): do `NSMenu` popups / sheets / completion popups
  appear in a ScreenCaptureKit capture, and does the Accessibility API report
  them with usable frames and a distinguishable role/subrole?
- **OQ-2**: are AX geometry writes honored exactly, or clamped/rounded?
- **OQ-5**: do AX rects align pixel-exactly with SCK pixels, and by how many
  frames does the metadata lag?

## Install / permissions

1. Unzip and move `Transom Probe.app` where you like.
2. Launch it. Grant **Screen Recording** and **Accessibility** in
   System Settings › Privacy & Security. The app shows its own bundle id and
   cdhash so you can confirm which identity holds the grant.
3. Not notarized. First launch may need right-click › Open, or
   `xattr -dr com.apple.quarantine "Transom Probe.app"`.

## What to do

Open the **Live probe** section, pick an app (e.g. Xcode) and the display, press
Start, then open that app's menus. Watch whether the menu lands in the capture
and whether an AX rect (orange) is drawn around it. That is OQ-1.

The same logic is available headless via the `transom-host` CLI (`menuwatch`,
`place`, `probe`, …).
NOTES
else
  cat > "$NOTES_FILE" <<'NOTES'
# Transom Host v0.1.0-m2 — the host half (NOT a usable product)

This is the **host half** of Transom, and only the host half. It runs on the Mac:
it tiles an app's windows non-overlapping on a virtual display, captures that
display with ScreenCaptureKit, HEVC **4:4:4 10-bit** hardware-encodes it, and
serves window geometry (and video) over TCP.

**There is no Windows client in this release.** The client is a separate work in
progress. So this **streams to nothing** — you can start it, grant permissions,
watch the tile layout and the live encoder / fps / bitrate status, and connect a
mock TCP client, but there is no decoder or renderer on the other end. It is not a
product; it is one half of one.

## What works

- **Permissions** panel — Screen Recording + Accessibility, live, with this app's
  own bundle id + cdhash so you can see *which identity* holds the grant. It is
  `one.nullstack.transom.host`, deliberately distinct from the probe's
  `one.nullstack.transom.probe`.
- **Configuration** — pick a display and an app, set a private bind address and
  ports (the private-address gate is enforced and visible), press Start.
- **Status** — connected client (or not), live fps / bitrate / host-side encode
  latency, the tile layout with post-clamp **actual** rects and
  requested-vs-actual deltas (I-4 / OQ-2), and — prominently — whether the encoder
  is really on the **4:4:4 10-bit hardware** path or has fallen back.

## What does NOT work / out of scope

- No Windows client, so nothing renders the stream.
- No input, no geometry roundtrip back to AX, no audio, no clipboard, no auth,
  no encryption. It is **LAN-only**, and it refuses non-private bind addresses.

## Install / permissions

1. Unzip and move `Transom Host.app` where you like.
2. Launch it. Grant **Screen Recording** and **Accessibility** in
   System Settings › Privacy & Security. The app shows its own bundle id + cdhash.
3. Not notarized. First launch may need right-click › Open, or
   `xattr -dr com.apple.quarantine "Transom Host.app"`.

The same pipeline is available headless via `transom-host serve`.
NOTES
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> dry run: skipping gh release create"
  echo "notes preview:"; echo "----"; cat "$NOTES_FILE"; echo "----"
  rm -f "$NOTES_FILE"
  exit 0
fi

# --- cut the GitHub prerelease ----------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found; cannot create the release" >&2
  exit 1
fi

echo "==> creating prerelease ${TAG}"
gh release create "$TAG" "$ZIP_PATH" \
  --title "$RELEASE_TITLE" \
  --notes-file "$NOTES_FILE" \
  --prerelease

rm -f "$NOTES_FILE"
echo "done."
