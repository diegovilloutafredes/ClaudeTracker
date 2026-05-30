# Design

## Parity is the whole game

A build-tooling swap is only safe if the output doesn't change. The verification, run before wiring anything into CI:

1. Capture `xcodebuild -showBuildSettings` for app+tests × Debug+Release from the **current** pbxproj.
2. Back up the pbxproj, `xcodegen generate`, capture the same four.
3. `diff` each pair → **must be empty**. (Generating in place keeps the project path — and thus the DerivedData hash and all path-derived settings — identical, so any diff is a real setting difference.)

Result: all four diffs empty. Plus: built `Info.plist` retains `LSUIElement`/`SUFeedURL`/`CFBundleShortVersionString=1.19.4`; `Info.plist`/entitlements not in any build phase; `knownRegions` includes `es`; `make build` and `make test` pass.

## `settingPresets: none`

XcodeGen defaults to injecting Apple's project/target template settings (dozens of `CLANG_WARN_*`, etc.). The hand-written project never had those. Using `none` and transcribing the pbxproj's settings verbatim guarantees the `showBuildSettings` diff stays empty — no reliance on XcodeGen's preset values matching Xcode's defaults across tool versions.

## Info.plist handling

The target sets both `GENERATE_INFOPLIST_FILE: YES` and a real `INFOPLIST_FILE` with custom keys. We point `INFOPLIST_FILE` at the existing file and do **not** use an XcodeGen `info:` block (which would synthesize a fresh plist and drop `LSUIElement` → dock icon regression). Verified by reading the built app's plist, not just the settings.

## Generated-but-ignored project

`ClaudeTracker.xcodeproj` is git-ignored; `project.yml` is the source of truth (the `common` convention). Consequences handled here: `build`/`test` depend on a `generate` target (so a stale checkout can't build against an old project); CI installs `xcodegen` explicitly (not assumed on the runner) and generates before building; `make tag` edits `project.yml`.

## Schemes

Both `ClaudeTracker` and `ClaudeTrackerTests` schemes are declared so the **existing** Makefile invocations keep working unchanged (`-scheme ClaudeTracker` for build/run, `-scheme ClaudeTrackerTests` for test) — the pipeline is touched as little as possible.
