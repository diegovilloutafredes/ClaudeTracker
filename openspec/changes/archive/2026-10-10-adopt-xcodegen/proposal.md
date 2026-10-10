## Why

`ClaudeTracker.xcodeproj/project.pbxproj` is hand-maintained (objectVersion 56, no file-system-synchronized groups). Adding a source file requires manually allocating unique object IDs and wiring four `pbxproj` entries (build file, file reference, group child, sources phase) — error-prone, and the pbxproj is a chronic merge-conflict source for an open-source repo that takes contributions. The monorepo already standardizes on XcodeGen for `Libraries/common` and `Personal/Bencinometro`, so the tool and workflow are established.

Adopting XcodeGen makes `project.yml` the source of truth and reduces "add a file" to "create the file." This is sequenced **before** the `extract-update-service` refactor so that adding `UpdateService.swift` (and future file splits like `MenuBarView.swift`) needs no `pbxproj` surgery.

## What Changes

- Add `project.yml` — a verbatim transcription of the current project (two targets, Release-only Hardened Runtime, the test host, `LSUIElement` plist, entitlements, `MARKETING_VERSION`). `settingPresets: none` so XcodeGen injects no extra Apple-template settings.
- **Gitignore the generated `ClaudeTracker.xcodeproj`**; `project.yml` is the only committed source.
- `Makefile`: add a `generate` target; `build`/`test` depend on it so the project is always in sync; `make tag` now bumps `MARKETING_VERSION` in `project.yml` (not the pbxproj).
- `release.yml`: install `xcodegen` explicitly and run `make generate` before building.
- Docs: `README`, `CONTRIBUTING`, and `CLAUDE.md` document `brew install xcodegen` + `make generate`.

Non-goals:
- **No build-output change.** Verified: `xcodebuild -showBuildSettings` is byte-identical across all four config×target combos; the built `Info.plist` keeps `LSUIElement`/`SUFeedURL`/version; tests pass.
- No change to signing, notarization, or the release pipeline's behavior — only how the project file is produced.

## Capabilities

### New Capabilities

- `build-system`: The Xcode project is generated from `project.yml` via XcodeGen and is not committed; the generated project must reproduce the previous build settings exactly.

### Modified Capabilities

(None — no product behavior changes.)

## Impact

- **New**: `project.yml`.
- **Removed from git**: `ClaudeTracker.xcodeproj/` (now generated + ignored).
- **`Makefile`**: `generate` target; `build: generate`, `test: generate`; `tag` bumps `project.yml`.
- **`.github/workflows/release.yml`**: Install XcodeGen + Generate steps.
- **`.gitignore`**: `/ClaudeTracker.xcodeproj/`.
- **Docs**: `README.md`, `CONTRIBUTING.md`, `CLAUDE.md`.
- **Contributor impact**: `brew install xcodegen` required; `make generate` (or any `make build`/`run`) produces the project before opening Xcode.
