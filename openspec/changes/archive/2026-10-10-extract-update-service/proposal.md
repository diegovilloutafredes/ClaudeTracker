## Why

`UsageViewModel` is 1,185 lines and exceeds the project's own `type_body_length` SwiftLint warning (1,000). More importantly, it **cannot be instantiated in a unit test**: `init()` runs the account load, spawns a delayed network update-check `Task`, starts polling, and installs `NSWorkspace`/appearance observers. That is the reason the test suite only covers free functions in `Models.swift` — the most bug-prone logic (reset detection, adaptive polling interval, stale detection) has zero coverage.

The self-installed update system (`checkForUpdates`, `downloadAndInstall`, the adaptive check-interval, auto-install) is ~200 lines, cohesive, and barely touches account state. Extracting it is the highest-leverage, lowest-risk way to shrink the view model and unlock testing.

## What Changes

- Move the entire update subsystem out of `UsageViewModel` into a new `@Observable @MainActor final class UpdateService`. The view model gains a single `let updates = UpdateService()`. Views read `viewModel.updates.availableUpdate` etc.; SwiftUI's transitive observation keeps redraws working (verified against Apple's SwiftUI docs for nested `@Observable`).
- **Separate construction from startup** in `UsageViewModel`: `init()` becomes side-effect-free (loads persisted preferences only); a new `start()` performs all the live work (account load, observers, polling, `updates.start()`). `ClaudeTrackerApp` calls `vm.start()` right after constructing the view model — same launch timing as today. This makes `UsageViewModel()` constructible in tests.
- **De-private / extract the pure logic** needed for tests: a free `adaptiveCheckInterval(from:)` (replacing the `[[String:Any]]`-typed `computeCheckInterval`), a free `isWindowReset(previous:next:utilization:)` (extracted from `checkForResets`), a free `windowIsStale(resetsAt:lastUpdated:now:)` (shared by `isDataStale`/`isWindowStale`), and an internal `intervalForProjMins`.
- **Add unit tests** for the four extracted pure functions.
- Fix the documentation drift discovered during review (comment says "15 minutes"→5 min; "2016-entry/7 days"→8640/30 days; `CLAUDE.md` still documents the removed `ClaudeCodeKeychain`, Claude Code CLI integration, and `Account.claudeCodeLinked`).

Non-goals:
- **No behavior change.** Polling cadence, update flow, auto-install, toasts, notifications, and every persisted `UserDefaults` key (`autoUpdate`, `lastNotifiedUpdateVersion`, `updateCheckInterval`) are byte-for-byte preserved.
- No splitting of `MenuBarView.swift` (separate, optional follow-up).
- No new dependencies, no API changes, no migration.

## Capabilities

### New Capabilities

(None — internal refactor.)

### Modified Capabilities

(None — no user-facing behavior changes, so no spec deltas. Existing `account-management` and `sonnet-window-display` specs are unaffected.)

## Impact

- **New file**: `UpdateService.swift` (~200 lines moved out of `UsageViewModel.swift`).
- **`UsageViewModel.swift`**: removes all update members; adds `let updates`; splits `init()`/`start()`; rewires `checkForResets`/`isDataStale`/`isWindowStale` to the new free functions. Drops back under the lint limit.
- **`Models.swift`**: adds `adaptiveCheckInterval(from:)`, `isWindowReset(...)`, `windowIsStale(...)` free functions; moves `UpdateDownloadState` enum here (or into `UpdateService.swift`).
- **`ClaudeTrackerApp.swift`**: calls `vm.start()`.
- **`MenuBarView.swift` / `SettingsView.swift`**: rewire ~10 read sites to `viewModel.updates.*`; `$viewModel.autoUpdate` → `$viewModel.updates.autoUpdate`.
- **`ClaudeTrackerTests.swift`**: new tests for the four pure functions.
- **Docs**: `CLAUDE.md` (architecture section — add `UpdateService`, fix stale CLI references), `README.md` if it references the update flow.
- **No new persistence keys**, no migration.
