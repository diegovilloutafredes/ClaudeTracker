#!/bin/bash
# Signs and publishes a release that the Release workflow created as a draft.
#
#   scripts/publish-release.sh --check-key   # only confirm the Keychain key is the one the app embeds
#   scripts/publish-release.sh 1.32.0        # wait for CI, sign ClaudeTracker.zip, upload the .sig, publish
#
# `make tag` runs both; `make publish VERSION=x.y.z` resumes after a failure. Nothing is public
# until the last step, and the app skips drafts, so a failed run leaves users untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

sign_tool() { xcrun --sdk macosx swift scripts/update-signing.swift "$@"; }

# Signing with a key the app doesn't embed would publish a release every install refuses.
key=$(sign_tool public-key)
if ! grep -q "\"$key\"" ClaudeTracker/UpdateService.swift; then
  echo "The Keychain signing key does not match updateSigningPublicKey in UpdateService.swift." >&2
  exit 1
fi
[ "${1:-}" = "--check-key" ] && { echo "==> Signing key matches the app"; exit 0; }

version="${1:?usage: publish-release.sh <version> | --check-key}"
tag="v$version"

echo "==> Waiting for the Release workflow for $tag..."
run=""
for _ in $(seq 1 60); do
  run=$(gh run list --workflow release.yml --branch "$tag" --limit 1 --json databaseId -q '.[0].databaseId')
  [ -n "$run" ] && break
  sleep 5
done
[ -n "$run" ] || { echo "No Release workflow run found for $tag." >&2; exit 1; }
gh run watch "$run" --exit-status --interval 20 > /dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh release download "$tag" --pattern ClaudeTracker.zip --dir "$tmp"

# Sign only the build this version promises; the app re-checks the version after verifying.
unzip -q "$tmp/ClaudeTracker.zip" -d "$tmp/contents"
built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$tmp/contents/ClaudeTracker.app/Contents/Info.plist")
[ "$built" = "$version" ] || { echo "The draft's zip holds $built, expected $version." >&2; exit 1; }

sign_tool sign "$tmp/ClaudeTracker.zip" > /dev/null
gh release upload "$tag" "$tmp/ClaudeTracker.zip.sig" --clobber
gh release edit "$tag" --draft=false --latest > /dev/null
echo "==> Published $tag (signed)"
