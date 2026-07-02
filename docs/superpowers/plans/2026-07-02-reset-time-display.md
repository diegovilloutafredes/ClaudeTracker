# Reset Time Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the absolute wall-clock reset time next to the existing reset countdown in each usage window row, with a Settings picker choosing AM/PM vs 24-hour rendering.

**Architecture:** A pure formatting function `resetTimeText` in `Models.swift` (tested in `PureLogicTests.swift`) pins the hour cycle via `Locale.Components.hourCycle` and adds an abbreviated weekday when the reset is not today. `UsageViewModel` persists a `use24HourTime` Bool (default seeded from the system locale); `UsageWindowView` appends the formatted time to its countdown line; `SettingsView` gets a segmented picker in the Display section.

**Tech Stack:** Swift / SwiftUI (macOS 14+), Foundation `Date.FormatStyle`, XCTest, XcodeGen project (`make generate` produces `ClaudeTracker.xcodeproj` — run it once if the project file is missing).

**Spec:** `docs/superpowers/specs/2026-07-02-reset-time-display-design.md`

## Global Constraints

- Strict concurrency is `complete` project-wide — new code must build warning-free under it.
- All UserDefaults keys go through the `PrefKey` namespace in `Models.swift` — never a string literal.
- All user-visible strings are localized: add English key + Spanish (`es`) entry to `ClaudeTracker/Localizable.xcstrings`. Edit the catalog JSON surgically with the Edit tool (Xcode's formatting uses `"key" : {` with spaces — do NOT rewrite the file with a JSON serializer, it would churn the whole diff).
- Commit messages: plain, imperative, **no AI attribution of any kind** (no Co-Authored-By, no "Generated with" footers).
- Tests: `make test` runs the suite. Single test: `xcodebuild test -project ClaudeTracker.xcodeproj -scheme ClaudeTrackerTests -destination 'platform=macOS' -only-testing:ClaudeTrackerTests/PureLogicTests/<name>`.
- New behavioral logic = pure function in `Models.swift` + tests in `ClaudeTrackerTests/PureLogicTests.swift`, thin delegation from view code.

---

### Task 1: Pure formatter `resetTimeText` + tests

**Files:**
- Modify: `ClaudeTracker/Models.swift` (add free function near the other pure helpers, e.g. after the `PrefKey` enum block that ends at ~line 129)
- Test: `ClaudeTrackerTests/PureLogicTests.swift` (append inside `final class PureLogicTests`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `func resetTimeText(reset: Date, now: Date, use24Hour: Bool, calendar: Calendar = .current, locale: Locale = .current) -> String` — Task 2's view code calls exactly this.

- [ ] **Step 1: Write the failing tests**

Append to `ClaudeTrackerTests/PureLogicTests.swift` inside the class:

```swift
    // MARK: - resetTimeText

    private func gmtCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        return cal
    }

    /// ICU inserts a narrow no-break space before AM/PM on recent OSes; normalize for comparison.
    private func normalizedTime(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ")
         .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private let enUS = Locale(identifier: "en_US")

    func testResetTimeTextSameDay12Hour() {
        let cal = gmtCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 17, minute: 30))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: false, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(text), "5:30 PM")
    }

    func testResetTimeTextSameDay24Hour() {
        let cal = gmtCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 17, minute: 30))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: true, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(text), "17:30")
    }

    func testResetTimeTextNextDayAddsWeekday() {
        let cal = gmtCalendar()
        // 2026-07-01 is a Wednesday; reset lands Thursday 2026-07-02.
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 23, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 17, minute: 30))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: false, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(text), "Thu 5:30 PM")
    }

    func testResetTimeTextSixDaysOutAddsWeekday24Hour() {
        let cal = gmtCalendar()
        // Reset lands Tuesday 2026-07-07.
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 10, minute: 0))!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9, minute: 5))!
        let text = resetTimeText(reset: reset, now: now, use24Hour: true, calendar: cal, locale: enUS)
        XCTAssertEqual(normalizedTime(text), "Tue 9:05")
    }
```

Note: exact ICU separator output (e.g. a comma after the weekday, or `09:05` vs `9:05`) can vary by OS. If a test fails on separator/padding only, eyeball the actual output — if it is a correct rendering of the right instant/cycle/weekday, update the expected literal to the actual and note it in the commit body. The tests pin behavior (cycle forced, weekday rule), not ICU aesthetics.

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` (or the single-test invocation from Global Constraints)
Expected: FAIL — `cannot find 'resetTimeText' in scope` (compile error counts as the failing state).

- [ ] **Step 3: Write the implementation**

Add to `ClaudeTracker/Models.swift`, after the `PrefKey` enum's closing brace (before the `// MARK: - Polling Tuning` section):

```swift
// MARK: - Reset Time Display

/// Formats the absolute wall-clock time of a window reset for display next to the countdown.
///
/// The hour cycle is pinned via `Locale.Components.hourCycle` so the user's 12/24-hour choice
/// wins over the locale's preference while weekday names stay localized. An abbreviated
/// weekday is prepended when the reset is not on the same calendar day as `now` — 7-day
/// windows always reset within a week, so a full date is never needed.
func resetTimeText(reset: Date, now: Date, use24Hour: Bool,
                   calendar: Calendar = .current, locale: Locale = .current) -> String {
    var components = Locale.Components(locale: locale)
    components.hourCycle = use24Hour ? .zeroToTwentyThree : .oneToTwelve
    let pinned = Locale(components: components)

    var style = Date.FormatStyle(locale: pinned, calendar: calendar, timeZone: calendar.timeZone)
        .hour(.defaultDigits(amPM: use24Hour ? .omitted : .abbreviated))
        .minute()
    if !calendar.isDate(reset, inSameDayAs: now) {
        style = style.weekday(.abbreviated)
    }
    return reset.formatted(style)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS (all four new tests + full existing suite green).

- [ ] **Step 5: Commit**

```bash
git add ClaudeTracker/Models.swift ClaudeTrackerTests/PureLogicTests.swift
git commit -m "Add resetTimeText pure formatter with pinned hour cycle"
```

---

### Task 2: Persisted preference + usage row wiring

**Files:**
- Modify: `ClaudeTracker/Models.swift` (`PrefKey` enum, ~line 128)
- Modify: `ClaudeTracker/UsageViewModel.swift` (property near `showSonnetWindow` ~line 135; load in `loadPersistedPreferences()` near ~line 253)
- Modify: `ClaudeTracker/UsageWindowView.swift` (new property + reset line, ~lines 11 and 31–39)
- Modify: `ClaudeTracker/MenuBarView.swift` (both `UsageWindowView(` call sites, ~lines 223 and 278)
- Modify: `ClaudeTracker/Localizable.xcstrings` (replace `Resets %@` key)

**Interfaces:**
- Consumes: `resetTimeText(reset:now:use24Hour:calendar:locale:)` from Task 1.
- Produces: `UsageViewModel.use24HourTime: Bool` (persisted, `@Observable`-tracked) — Task 3's Settings picker binds `$viewModel.use24HourTime`.

- [ ] **Step 1: Add the PrefKey**

In `ClaudeTracker/Models.swift`, inside `enum PrefKey`, after `static let showSonnetWindow = "showSonnetWindow"`:

```swift
    static let use24HourTime = "use24HourTime"
```

- [ ] **Step 2: Add the view model preference**

In `ClaudeTracker/UsageViewModel.swift`, directly after the `showSonnetWindow` property (its `didSet` one-liner):

```swift
    var use24HourTime: Bool = false {
        didSet { guard use24HourTime != oldValue else { return }; UserDefaults.standard.set(use24HourTime, forKey: PrefKey.use24HourTime) }
    }
```

In `loadPersistedPreferences()`, after the `showSonnetWindow = ...` line:

```swift
        if let saved24h = UserDefaults.standard.object(forKey: PrefKey.use24HourTime) as? Bool {
            use24HourTime = saved24h
        } else {
            // Fresh install / pre-feature install: seed from the system convention.
            let cycle = Locale.current.hourCycle
            use24HourTime = cycle == .zeroToTwentyThree || cycle == .oneToTwentyFour
        }
```

- [ ] **Step 3: Append the absolute time in the usage row**

In `ClaudeTracker/UsageWindowView.swift`:

Add after `var isStale: Bool = false`:

```swift
    var use24Hour: Bool = false
```

Replace the reset line block

```swift
            if let resetDate = window.resetsAtDate {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                    Text("Resets \(resetDate, style: .relative)")
                }
                .font(sf(11))
                .foregroundStyle(.secondary)
            }
```

with

```swift
            if let resetDate = window.resetsAtDate {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                    Text("Resets \(resetDate, style: .relative) · \(resetTimeText(reset: resetDate, now: Date(), use24Hour: use24Hour))")
                }
                .font(sf(11))
                .foregroundStyle(.secondary)
            }
```

- [ ] **Step 4: Pass the preference at both call sites**

In `ClaudeTracker/MenuBarView.swift`, both `UsageWindowView(` initializers (the Sonnet row ~line 223 and `windowRow` ~line 278) gain a final argument after `isStale:`:

```swift
                    isStale: sonnetIsStale,
                    use24Hour: viewModel.use24HourTime
```

```swift
            isStale: windowIsStale,
            use24Hour: viewModel.use24HourTime
```

(`use24Hour` is declared after `isStale`, so it comes last in the memberwise init.)

- [ ] **Step 5: Update the String Catalog**

In `ClaudeTracker/Localizable.xcstrings`, using the Edit tool, replace the `"Resets %@"` entry (preserving the file's exact `"key" : {` spacing style) with:

```json
    "Resets %@ · %@" : {
      "comment" : "Reset countdown: Resets <relative time> · <absolute time>",
      "localizations" : {
        "es" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Reinicia en %@ · %@"
          }
        }
      }
    },
```

Check the alphabetical position: `Resets %@ · %@` sorts where `Resets %@` was (verify neighbors; keep the catalog's existing key ordering convention). The old `Resets %@` key is removed — `UsageWindowView.swift:35` was its only call site.

- [ ] **Step 6: Build and run the suite**

Run: `make test`
Expected: PASS, zero warnings (strict concurrency is `complete`; `Locale`/`Calendar` are Sendable value types so the pure function is safe).

- [ ] **Step 7: Commit**

```bash
git add ClaudeTracker/Models.swift ClaudeTracker/UsageViewModel.swift ClaudeTracker/UsageWindowView.swift ClaudeTracker/MenuBarView.swift ClaudeTracker/Localizable.xcstrings
git commit -m "Show absolute reset time next to the countdown"
```

---

### Task 3: Settings picker for time format

**Files:**
- Modify: `ClaudeTracker/SettingsView.swift` (Display section, after the conditional "Rate unit" block that ends ~line 309)
- Modify: `ClaudeTracker/Localizable.xcstrings` (three new keys)

**Interfaces:**
- Consumes: `$viewModel.use24HourTime` from Task 2.
- Produces: nothing downstream.

- [ ] **Step 1: Add the picker row**

In `ClaudeTracker/SettingsView.swift`, in the Display section, immediately after the closing brace of the `if viewModel.showPace || viewModel.showPaceMenuBar || viewModel.notifyPace { ... }` block (the "Rate unit" row):

```swift
            HStack(spacing: 10) {
                Text("Time format")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Picker("", selection: $viewModel.use24HourTime) {
                    Text("AM/PM").tag(false)
                    Text("24-hour").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
```

This mirrors the existing "Rate unit" row exactly (no `Toggle`, so the `GreenSwitchStyle` rule does not apply; no leading padding since it is not a child control of a toggle).

- [ ] **Step 2: Add the localization keys**

In `ClaudeTracker/Localizable.xcstrings`, insert each entry at its alphabetical position, matching the file's spacing style:

```json
    "24-hour" : {
      "localizations" : {
        "es" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "24 horas"
          }
        }
      }
    },
```

```json
    "AM/PM" : {
      "localizations" : {
        "es" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "AM/PM"
          }
        }
      }
    },
```

```json
    "Time format" : {
      "localizations" : {
        "es" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Formato de hora"
          }
        }
      }
    },
```

- [ ] **Step 3: Build and run the suite**

Run: `make test`
Expected: PASS, zero warnings.

- [ ] **Step 4: Commit**

```bash
git add ClaudeTracker/SettingsView.swift ClaudeTracker/Localizable.xcstrings
git commit -m "Add AM/PM vs 24-hour time format setting"
```

---

### Task 4: Docs + visual verification

**Files:**
- Modify: `CLAUDE.md` (UsageWindowView/SettingsView/Models bullets)
- Modify: `README.md` (only if it enumerates settings or popover rows — check first)

- [ ] **Step 1: Update CLAUDE.md**

In the ClaudeTracker `CLAUDE.md`:
- In the **MenuBarView.swift** architecture bullet (which covers `UsageWindowView.swift`), mention the reset line now appends the absolute reset time via the pure `resetTimeText(reset:now:use24Hour:calendar:locale:)` helper (weekday added when the reset is not today; hour cycle pinned via `Locale.Components`).
- In the **SettingsView.swift** bullet, add the "Time format" AM/PM / 24-hour segmented picker to the Display section list.
- In the **Models.swift** bullet's pure-helper enumeration, add `resetTimeText`.
- `PrefKey.use24HourTime` needs no separate callout (PrefKey is already documented as the namespace for all keys).

- [ ] **Step 2: Check README**

Run: `grep -in "settings\|popover\|reset" README.md | head -30` — if the README describes the usage row or Display settings, add one line for the reset time + format picker. If it does not go into that detail, leave it untouched.

- [ ] **Step 3: Visual verification**

Run: `make run`
Expected: app builds, installs to `/Applications/`, launches. Open the popover: each window row shows `Resets in <countdown> · <time>`; rows whose reset is tomorrow or later show a weekday. Open Settings → Display: flip "Time format" between AM/PM and 24-hour and confirm the popover text switches immediately.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "Document reset time display and time format setting"
```
