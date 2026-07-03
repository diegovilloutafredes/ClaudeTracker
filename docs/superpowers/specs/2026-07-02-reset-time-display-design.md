# Reset Time Display — Design

**Date:** 2026-07-02
**Status:** Approved

## Goal

Each usage window row shows a live countdown to the window reset ("Resets in 2 hr, 15 min"). Add the absolute wall-clock time of that reset on the same line, plus a Settings control to choose between AM/PM and 24-hour rendering.

## UI

**Usage row (`UsageWindowView.swift`):** the reset line becomes

```
🕐 Resets in 2 hr, 15 min · 5:30 PM         (12-hour)
🕐 Resets in 2 hr, 15 min · 17:30           (24-hour)
🕐 Resets in 2 days · Wed 5:30 PM           (5-hour window past midnight → weekday prefix)
🕐 Resets in 6 days · Thu, Jul 9 at 17:00   (7-day windows → full date)
```

Implemented as `Text("Resets \(resetDate, style: .relative) · \(absoluteText)")`. The relative part keeps SwiftUI's live per-second updating; the absolute part is a plain `String` recomputed on every poll-driven render, which is more than enough (it only changes when `resets_at` changes or midnight passes).

Visibility rules are unchanged: the line renders only when `resetsAtDate` exists; stale windows keep their existing banner/color behavior.

**Settings (`SettingsView.swift`, Display section):** a "Time format" row following the existing "Rate unit" pattern — secondary label + segmented picker with two options, **AM/PM** and **24-hour**, using `ScaledSegmentedPicker`-style plain `Picker(.segmented)`. Always visible in the Display section (the reset line is always shown when authenticated). No `Toggle`, so `GreenSwitchStyle` is not involved.

## Data / State

- `PrefKey.use24HourTime` — new UserDefaults key, `Bool`.
- `UsageViewModel.use24HourTime: Bool` with the standard `didSet`-persist pattern, loaded in `loadPersistedPreferences()`.
- **Default for fresh installs / existing installs without the key:** derived from the system locale — `Locale.current.hourCycle` (`.zeroToTwentyThree` / `.oneToTwentyFour` → `true`). The user's system convention wins until they explicitly pick one.
- `UsageWindowView` gains `var use24Hour: Bool = false`; both call sites in `MenuBarView.swift` (`windowRow` and the Sonnet row) pass `viewModel.use24HourTime`.

## Formatting logic (pure, tested)

New free function in `Models.swift`, following the established pure-function-plus-tests pattern:

```swift
func resetTimeText(reset: Date, now: Date, use24Hour: Bool,
                   calendar: Calendar = .current, locale: Locale = .current) -> String
```

Rules:
- **Weekday:** included (abbreviated) when `reset` is not in the same calendar day as `now`.
- **Full date (`includeDate: Bool = false`):** the 7-day windows (7-Day, Sonnet) pass `true` — when the reset is not today, the abbreviated month + day are added (`Thu, Jul 9 at 17:00`; ICU supplies the locale's date–time connector). Rationale: a weekday alone reads ambiguous when a reset ~7 days out lands on today's weekday, and week-scale planning is calendar-date planning. The 5-hour window passes `false`; a same-day 7-day reset also shows time only (the countdown already covers it). Exposed on `UsageWindowView` as `includeResetDate`, set per call site (`windowKey == .sevenDay`, Sonnet row hardcodes `true`).
- **Hour cycle:** build the format locale from `Locale.Components(locale:)` with `hourCycle` pinned to `.zeroToTwentyThree` (24 h) or `.oneToTwelve` (12 h), then `Locale(components:)`. Pinning the cycle at the locale level makes every hour symbol resolve to the chosen cycle while keeping localized weekday names (e.g. "mié" in Spanish).
- **Symbols:** `.hour(.defaultDigits(amPM: use24Hour ? .omitted : .abbreviated)).minute()`, plus `.weekday(.abbreviated)` when the weekday rule applies. `Date.FormatStyle` handles the rest.

## Localization

New String Catalog keys (`Localizable.xcstrings`), Spanish added alongside so the catalog stays 100 % translated:

| Key | Spanish |
|---|---|
| `Resets %@ · %@` | `Reinicia en %@ · %@` |
| `Time format` | `Formato de hora` |
| `AM/PM` | `AM/PM` |
| `24-hour` | `24 horas` |

The old `Resets %@` key stays (still used by other call sites if any; otherwise inert).

## Testing

Unit tests in `PureLogicTests.swift` for `resetTimeText` with a fixed Gregorian/GMT calendar and `en_US` base locale:
- same day, 12-hour → `5:30 PM`
- same day, 24-hour → `17:30`
- next day (boundary), 12-hour → weekday prefix appears
- 6 days out, 24-hour → weekday prefix appears
- Comparisons normalize the narrow no-break space (U+202F) that newer ICU inserts before AM/PM.

Then the full suite (`make test`) and a visual check via `make run`.

## Out of scope

- No change to the menu bar label, charts, or toast content.
- No third "System" option in the picker — the system convention is only the default seed.
