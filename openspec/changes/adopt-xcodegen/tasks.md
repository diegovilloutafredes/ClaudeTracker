## 1. Author project.yml

- [x] 1.1 Transcribe project + target settings verbatim from `project.pbxproj`, `settingPresets: none`.
- [x] 1.2 Two targets (`ClaudeTracker` app, `ClaudeTrackerTests` unit-test with `target` dependency); Release-only `ENABLE_HARDENED_RUNTIME`; `INFOPLIST_FILE` → existing plist (no `info:` block); `SWIFT_STRICT_CONCURRENCY: minimal` on tests.
- [x] 1.3 Declare both `ClaudeTracker` and `ClaudeTrackerTests` schemes so existing Makefile `-scheme` calls keep working.

## 2. Verify parity (before touching CI)

- [x] 2.1 Diff `xcodebuild -showBuildSettings` (app/tests × Debug/Release), baseline vs generated → all four empty.
- [x] 2.2 Built `Info.plist` retains `LSUIElement`, `SUFeedURL`, `CFBundleShortVersionString` (1.19.4); `Info.plist`/entitlements not compiled; `knownRegions` includes `es`.
- [x] 2.3 `make build` (clean Release) succeeds; `make test` → `TEST SUCCEEDED`.

## 3. Wire it in

- [x] 3.1 `Makefile`: `generate` target; `build: generate`, `test: generate`; `make tag` bumps `MARKETING_VERSION` in `project.yml`; add `generate` to `.PHONY`.
- [x] 3.2 `.gitignore`: ignore `/ClaudeTracker.xcodeproj/`.
- [x] 3.3 `release.yml`: "Install XcodeGen" + "Generate Xcode project" steps after Select Xcode.
- [ ] 3.4 `git rm -r --cached ClaudeTracker.xcodeproj` to untrack the now-generated project (done at commit time).

## 4. Docs

- [x] 4.1 `README.md`: "Building from source" — `brew install xcodegen`, `make generate`/`make run`.
- [x] 4.2 `CONTRIBUTING.md`: edit `project.yml`, not the pbxproj; run `make generate`.
- [x] 4.3 `CLAUDE.md`: build section — XcodeGen, `make generate`, `project.yml` source of truth, project git-ignored; update the `make tag` description (bumps `project.yml`).

## 5. Final verification

- [x] 5.1 `make run` — app builds via the generated project, installs, launches as a menu bar item (no dock icon).
- [ ] 5.2 At commit: `git rm -r --cached ClaudeTracker.xcodeproj` so the generated project is untracked; confirm `project.yml` is tracked.
