#!/usr/bin/env bash
#
# release.sh — build, sign, zip, and cut the M0 prerelease.
#
# Produces "Transom Probe.app", zips it, and creates a GitHub prerelease tagged
# v0.0.1-m0 whose notes state plainly that this is a diagnostic probe, not a
# working product (issue Part 3).
#
# NOT notarized. Notarization needs credentials that have not been provided;
# do not add it without asking. On another Mac, the recipient may need to
# right-click > Open (or clear the quarantine attribute) the first time.
#
# Usage:
#   scripts/release.sh            # build, sign, zip, and create the GH release
#   scripts/release.sh --dry-run  # build, sign, zip only; skip gh release create
#
set -euo pipefail

TAG="v0.0.1-m0"
APP_NAME="Transom Probe"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# --- build + sign the app ---------------------------------------------------
"$REPO_ROOT/scripts/make-app.sh"

APP_DIR="$REPO_ROOT/build/${APP_NAME}.app"
ZIP_PATH="$REPO_ROOT/build/Transom-Probe-${TAG}.zip"

echo "==> zipping ${APP_DIR}"
rm -f "$ZIP_PATH"
# ditto preserves the code signature and resource forks; plain zip does not.
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
echo "zip: $ZIP_PATH"

NOTES_FILE="$(mktemp)"
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
  --title "Transom Probe ${TAG} (diagnostic probe)" \
  --notes-file "$NOTES_FILE" \
  --prerelease

rm -f "$NOTES_FILE"
echo "done."
