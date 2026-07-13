#!/bin/bash
# Double-click this file in Finder to install ClaudeTracker.
# If macOS blocks it ("cannot verify the developer"), run it from Terminal
# instead: bash install.command

APP_NAME="ClaudeTracker.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/$APP_NAME"
APP_DEST="/Applications/$APP_NAME"

if [ ! -d "$APP_SRC" ]; then
    osascript -e 'display alert "Installation failed" message "ClaudeTracker.app must be in the same folder as this installer." as critical'
    exit 1
fi

# Quit a running instance so the relaunch picks up the new binary — otherwise
# `open` just re-activates the old in-memory process
if pgrep -xq ClaudeTracker; then
    pkill -x ClaudeTracker || true
    sleep 1
fi

# Remove existing version so Launch Services does not cache the old binary
if [ -d "$APP_DEST" ]; then
    rm -rf "$APP_DEST"
fi

cp -R "$APP_SRC" "$APP_DEST"

# Strip the quarantine flag Gatekeeper sets on downloaded files
xattr -dr com.apple.quarantine "$APP_DEST"

osascript -e 'display notification "ClaudeTracker installed successfully." with title "Installation complete"'

open "$APP_DEST"
