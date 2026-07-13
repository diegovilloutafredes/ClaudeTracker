#!/bin/bash
# ClaudeTracker one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/diegovilloutafredes/ClaudeTracker/main/scripts/install.sh | bash
#
# Downloads the latest release ZIP, installs to /Applications, and launches.
# Because curl does not set the com.apple.quarantine attribute, Gatekeeper
# never blocks the app — no "Open Anyway" dance needed for unsigned builds.
set -euo pipefail

APP_NAME="ClaudeTracker.app"
APP_DEST="/Applications/$APP_NAME"
ZIP_URL="https://github.com/diegovilloutafredes/ClaudeTracker/releases/latest/download/ClaudeTracker.zip"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ ! -w /Applications ]; then
    echo "error: /Applications is not writable — run from an administrator account." >&2
    exit 1
fi

echo "==> Downloading latest ClaudeTracker release..."
curl -fSL --progress-bar -o "$TMP_DIR/ClaudeTracker.zip" "$ZIP_URL"

echo "==> Extracting..."
unzip -q "$TMP_DIR/ClaudeTracker.zip" -d "$TMP_DIR"

if [ ! -d "$TMP_DIR/$APP_NAME" ]; then
    echo "error: $APP_NAME not found in the downloaded archive." >&2
    exit 1
fi

# Quit a running instance so the relaunch picks up the new binary
if pgrep -xq ClaudeTracker; then
    echo "==> Quitting running ClaudeTracker..."
    pkill -x ClaudeTracker || true
    sleep 1
fi

echo "==> Installing to /Applications..."
# Delete first, then copy — Launch Services caches the old binary if overwritten in place
rm -rf "$APP_DEST"
cp -R "$TMP_DIR/$APP_NAME" "$APP_DEST"

# Belt and braces: strip quarantine in case this script was run against a
# browser-downloaded copy
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

echo "==> Launching..."
open "$APP_DEST"

echo "✓ ClaudeTracker installed. Look for the gauge icon in your menu bar."
