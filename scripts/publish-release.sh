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
# Anything that fails from here on leaves a private draft; this resumes it.
trap 'echo "Publishing $tag failed. The draft stays private; rerun: make publish VERSION=$version" >&2' ERR

echo "==> Waiting for the Release workflow for $tag..."
run=""
for _ in $(seq 1 60); do
  # Newest run for the tag: tags are never reused here (a re-tag would need the old run skipped).
  run=$(gh run list --workflow release.yml --branch "$tag" --limit 1 --json databaseId -q '.[0].databaseId')
  [ -n "$run" ] && break
  sleep 5
done
[ -n "$run" ] || { echo "No Release workflow run found for $tag." >&2; exit 1; }
if ! gh run watch "$run" --exit-status --interval 20 > /dev/null; then
  trap - ERR
  # Rerunning the publish can't help: there is no zip to sign.
  echo "The Release workflow failed: $(gh run view "$run" --json url -q .url)" >&2
  echo "Fix the cause, delete the tag (git push origin :refs/tags/$tag; git tag -d $tag), and tag again." >&2
  exit 1
fi

# The run must have built the commit that is tagged here, in this clone: a tag moved on
# GitHub, or a run started from another commit, is not the release that was meant.
tagged=$(git rev-parse --verify --quiet "$tag^{commit}") || {
  echo "There is no tag $tag in this clone. Fetch it (git fetch origin tag $tag) and check that it is the commit you meant (git log -1 $tag)." >&2
  exit 1
}
built_from=$(gh run view "$run" --json headSha -q .headSha)
[ "$built_from" = "$tagged" ] || { echo "The Release workflow built $built_from, but $tag is $tagged in this clone." >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gh release download "$tag" --pattern ClaudeTracker.zip --dir "$tmp"

# The file on the draft must be the file that run built. The workflow prints the SHA-256 of
# the zip it made (release.yml), and a finished run's log cannot be changed: a file put on
# the draft afterwards does not match it.
# (|| true: with no hash in the log the search fails, and the check below should say so.)
built_hash=$(gh run view "$run" --log | grep -o 'sha256 [0-9a-f]\{64\}' | tail -1 | cut -d' ' -f2 || true)
draft_hash=$(shasum -a 256 "$tmp/ClaudeTracker.zip" | cut -d' ' -f1)
if [ -z "$built_hash" ] || [ "$built_hash" != "$draft_hash" ]; then
  echo "The zip on the draft ($draft_hash) is not the file the workflow built (${built_hash:-no hash found in the log of the run})." >&2
  exit 1
fi

# Sign only the build this version promises; the app re-checks the version after verifying.
unzip -q "$tmp/ClaudeTracker.zip" -d "$tmp/contents"
built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$tmp/contents/ClaudeTracker.app/Contents/Info.plist")
[ "$built" = "$version" ] || { echo "The draft's zip holds $built, expected $version." >&2; exit 1; }

sign_tool sign "$tmp/ClaudeTracker.zip" > /dev/null
gh release upload "$tag" "$tmp/ClaudeTracker.zip.sig" --clobber
gh release edit "$tag" --draft=false --latest > /dev/null
echo "==> Published $tag (signed)"
