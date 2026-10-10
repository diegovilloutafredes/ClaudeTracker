# Design

## Extraction boundary

The update subsystem is self-contained. Its only outward couplings are global singletons (`ToastWindowController.shared`, `AppLogger.shared`), Foundation/AppKit (`URLSession`, `FileManager`, `Process`, `NSWorkspace`, `NSApp`), `Bundle.main` for the current version, and three `UserDefaults` keys (`autoUpdate`, `lastNotifiedUpdateVersion`, `updateCheckInterval`). None of it reads account state. So it lifts cleanly into:

```swift
@Observable @MainActor
final class UpdateService {
    var availableUpdate: UpdateInfo?
    var isCheckingForUpdates = false
    var updateDownloadState: UpdateDownloadState = .idle
    var autoUpdate: Bool { didSet { persist + schedulePeriodicUpdateCheck() } }
    var updateCheckIntervalLabel: String { ... }

    @ObservationIgnored private var updateCheckTimer: AnyCancellable?
    @ObservationIgnored private var lastNotifiedUpdateVersion = ""
    private var nextCheckInterval: TimeInterval = 12 * 3600

    func start()              // load prefs, schedule periodic, fire +10s initial check
    func checkForUpdates()
    func downloadAndInstall()
    private func triggerAutoInstall()
    private func schedulePeriodicUpdateCheck()
    private enum UpdateError
}
```

`UsageViewModel` holds `let updates = UpdateService()`.

## Why nested `@Observable` is safe

Apple's SwiftUI documentation (verified via context7, `developer.apple.com/documentation/swiftui`) states a view forms a dependency on **nested** observable properties it reads — the canonical example renders `book.author.name` and updates when the nested `name` changes. Because `updates` is an `@Observable` reference and views read `viewModel.updates.availableUpdate`, the existing redraw behavior is preserved with no extra plumbing. `updates` is a `let`, so the outer view model never needs to publish a change to the reference itself.

## `@Bindable` through the nested object

`SettingsView` currently binds `$viewModel.autoUpdate`. After the move it binds `$viewModel.updates.autoUpdate`. `@Bindable`'s dynamic-member lookup composes a `ReferenceWritableKeyPath<UsageViewModel, Bool>` (`\.updates.autoUpdate`) — valid because the root is a class and the leaf is settable through the `let` reference. If the compiler rejects the nested path, fall back to an explicit `Binding(get:set:)`. (Verified at build time in tasks §7.)

## Construction vs. startup split

Today `UsageViewModel.init()` does pure work (load `UserDefaults`) **and** live work (observers, network, polling). Splitting:

- `init()` → `loadPersistedPreferences()` + `isInitialized = true`. No tasks, no observers, no network. The `didSet` sound-trigger guards on `isInitialized` (already false during load) so nothing fires.
- `start()` → wake observer (calls `fetchUsage()` + `updates.checkForUpdates()`), `loadAccountsAndStartActive()`, the appearance subscription, and `updates.start()`.
- `ClaudeTrackerApp.init()`:
  ```swift
  SandboxMigration.runIfNeeded()
  let vm = UsageViewModel()
  vm.start()
  _viewModel = State(initialValue: vm)
  ```
  This runs `start()` at the **same point in app launch** as today's `init()` side effects (inside `App.init`), so the `NSApp`-is-nil deferral and account-load timing are unchanged. The payoff: tests can `UsageViewModel()` without triggering any of it.

## Testability extractions (pure functions in `Models.swift`)

| Function | Replaces / extracted from | Test |
|---|---|---|
| `adaptiveCheckInterval(from dates: [Date]) -> TimeInterval` | `computeCheckInterval(from: [[String:Any]])` — date parsing stays in `checkForUpdates`, math moves out | gaps→avg/2 clamped [4h,24h]; <2 dates→12h |
| `isWindowReset(previous: Date, next: Date, utilization: Double) -> Bool` | the `newDate.timeIntervalSince(oldDate) > 3600 && util < 5` predicate in `checkForResets` | boundary at +3600s and util 5% |
| `windowIsStale(resetsAt: Date?, lastUpdated: Date?, now: Date) -> Bool` | shared by `isDataStale` + `isWindowStale` | reset-passed-since-fetch true; nil-safe |
| `intervalForProjMins(_:) ` (de-`private`d) | unchanged body | step boundaries 1/2/3/5/8/10s |

`isNewerVersion` is already free and tested.

## Risk & verification

The single risk is a behavior regression in the update/polling path. Mitigation: every persisted key, the +10s initial check, the wake-triggered check, the auto-install countdown, and the adaptive interval math are preserved verbatim — only their *home* changes. Verified by `make run` (launch, popover, Settings update row, toggle auto-update) plus the new unit tests (tasks §7).
