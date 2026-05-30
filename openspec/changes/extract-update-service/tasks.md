## 1. New file — `UpdateService.swift`

- [x] 1.1 `@Observable @MainActor final class UpdateService` with `availableUpdate`, `isCheckingForUpdates`, `updateDownloadState`, `autoUpdate` (+`didSet`), `updateCheckIntervalLabel`, `checkForUpdates()`, `downloadAndInstall()`, `triggerAutoInstall()`, `schedulePeriodicUpdateCheck()`, `UpdateError`.
- [x] 1.2 Moved `UpdateDownloadState` enum here.
- [x] 1.3 `func start()`: loads persisted update prefs, schedules the periodic check, fires the +10 s initial check.
- [x] 1.4 `checkForUpdates()` parses `published_at` → `[Date]` and calls the free `adaptiveCheckInterval(from:)`.

## 2. `Models.swift` — pure functions for testing

- [x] 2.1 `adaptiveCheckInterval(from:)`.
- [x] 2.2 `isWindowReset(previous:next:utilization:)`.
- [x] 2.3 `windowIsStale(resetsAt:lastUpdated:now:)`.

## 3. `UsageViewModel.swift` — remove update subsystem

- [x] 3.1 Removed all moved update members; added `var updates = UpdateService()` (`var` so `@Bindable`'s nested key path is reference-writable).
- [x] 3.2 Removed the `autoUpdate`/`lastNotifiedUpdateVersion`/`updateCheckInterval` loads from `loadPersistedPreferences()`.
- [x] 3.3 Removed dead `clearCache()` (ClaudeAPIService) and `signOut()`; converted `error` to get-only. (Left `handleSessionFound(_ key:)` as-is — `key` is part of the required `(String) -> Void` callback signature; an unused function parameter is no warning.)

## 4. `UsageViewModel.swift` — construction vs. startup

- [x] 4.1 `init()` shrunk to `loadPersistedPreferences(); isInitialized = true`.
- [x] 4.2 Added `func start()` with the wake observer (calls `updates.checkForUpdates()`), `loadAccountsAndStartActive()`, `updates.start()`, and the deferred appearance subscription.

## 5. `UsageViewModel.swift` — rewire to pure functions

- [x] 5.1 `checkForResets` uses `isWindowReset(...)`.
- [x] 5.2 `isDataStale` / `isWindowStale(_:)` use `windowIsStale(...)`.
- [x] 5.3 `intervalForProjMins(_:)` de-`private`d.

## 6. Call-site rewiring

- [x] 6.1 `ClaudeTrackerApp.init()`: `let vm = UsageViewModel(); vm.start(); _viewModel = State(initialValue: vm)`.
- [x] 6.2 `MenuBarView.swift` → `viewModel.updates.*`.
- [x] 6.3 `SettingsView.swift` → `viewModel.updates.*`; `$viewModel.updates.autoUpdate` (worked once `updates` was `var`).

## 7. Tests — `ClaudeTrackerTests.swift`

- [x] 7.1 `adaptiveCheckInterval` (defaults / floor / ceiling / averages+unsorted).
- [x] 7.2 `isWindowReset` (large jump+low util / exactly 1h / util still high).
- [x] 7.3 `windowIsStale` (reset-after-fetch / fetched-after-reset / future reset / nil inputs).
- [x] 7.4 `intervalForProjMins` boundaries — constructs `UsageViewModel()` in-test (proves the construction/startup split). 30 → 42 tests, all pass.

## 8. Build, verify, document

- [x] 8.1 `make run` — builds, launches as a menu bar item.
- [x] 8.2 `make test` → 42 tests, `TEST SUCCEEDED`. `make lint` → 0 violations.
- [x] 8.3 Comment drift fixed: recordHistory "15 minutes" → "5 minutes"; `UsageDataPoint` "2016-entry / 7 days" → "8640-entry / 30 days".
- [x] 8.4 `CLAUDE.md`: added `UpdateService.swift` + init/start split; removed stale `ClaudeCodeKeychain`/CLI integration/`claudeCodeLinked` references; reframed the Sandboxing note.
- [x] 8.5 `openspec validate extract-update-service` passes.

## 9. `UsageViewModel` line count

- [x] 9.1 1185 → 950 lines (under the 1000 `type_body_length` warning); `UpdateService` 240 lines.
