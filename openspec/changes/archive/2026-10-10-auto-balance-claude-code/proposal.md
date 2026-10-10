## Why

ClaudeTracker recently gained Claude Code CLI integration: linking an account stores its OAuth token in the macOS Keychain, and switching accounts in the app flips which account `claude` uses. Users with multiple linked accounts now have to manually pick which one is active — the app has all the data needed (per-account utilization across 5h/7d/opus/sonnet windows, plus pace projections) to pick automatically and far better than a human eyeballing percentages.

This change adds opt-in automated account selection so users can either favor one account, balance load across all of them, or keep manual control.

## What Changes

- **New `AccountBalancer` module** with three mutually-exclusive selection strategies: Manual (default, no auto-switching), Prioritize (use a designated account until it crosses a threshold, then fall back), and Balance (score-based across all accounts using worst-window slack + pace penalty + reset proximity bonus, with hysteresis).
- **Three independent trigger surfaces**: a popover "Switch to best account" button, a `claude-balance` shell hook that runs before `claude` invocations, and an opt-in continuous mode that re-evaluates every poll inside the running app.
- **State export** — the app writes `~/Library/Application Support/ClaudeTracker/balance.json` after each poll so the shell hook can run the same decision logic without IPC.
- **New Settings UI section** — strategy picker, per-strategy parameters (preferred account + threshold for Prioritize, hysteresis for Balance), trigger checkboxes.
- **Audit logging** — every balance decision logged via `AppLogger` in a structured form (e.g. `balance: A→B (slack=45→62, pace ok, diff=17)`).
- **No breaking changes**: default strategy is Manual, so existing users see no behavior change until they opt in.

## Capabilities

### New Capabilities
- `claude-code-balancing`: Automated selection of which linked Claude Code account is active, based on per-account utilization and pace data, configurable per user via strategy + trigger settings.

### Modified Capabilities
<!-- None. The existing `account-management` capability is unchanged — its requirements (multi-account isolation, manual switch flow, login window, removal) all continue to hold. The Claude Code CLI integration itself (Link/Unlink, switchAccount → Keychain swap) is currently un-specced; this change does not retroactively spec it. A future change can introduce a `claude-code-cli-integration` capability if desired. -->

## Impact

- **Code**: `ClaudeTracker/AccountBalancer.swift` (new), `ClaudeTracker/UsageViewModel.swift` (call balancer on poll if continuous mode on; expose Balance button helper), `ClaudeTracker/SettingsView.swift` (new settings section), `ClaudeTracker/MenuBarView.swift` (popover Balance button when ≥2 linked accounts), `ClaudeTracker/Models.swift` (strategy enum, persisted settings keys).
- **New CLI artifact**: `~/.local/bin/claude-balance` (bash, ~40 lines). Optional shell setup line for `~/.zshrc`.
- **New on-disk artifact**: `~/Library/Application Support/ClaudeTracker/balance.json`, refreshed each poll.
- **UserDefaults keys added**: `balanceStrategy` (raw), `balancePreferredAccountID` (UUID string), `balancePrioritizeThreshold` (Double), `balanceHysteresis` (Double), `balanceTriggerOnClaude` (Bool), `balanceTriggerContinuous` (Bool), `balanceLastManualSwitch` (Date).
- **Branch scope**: all work on `feat/claude-code-cli-integration`. Not merged to `main` until the parent CLI integration is also approved for release.
- **Dependencies**: none new. Uses existing `Security` framework calls for the Keychain swap, existing `pace(for:)` and `urgencyColor()` helpers in `Models.swift`.
- **Risk**: mid-conversation Claude Code account swap behavior is unverified. The implementation plan includes a 1-prompt smoke test before any code is written; if Claude Code rejects mid-session token changes, we drop the continuous trigger from scope and ship only Manual + session-start triggers.
