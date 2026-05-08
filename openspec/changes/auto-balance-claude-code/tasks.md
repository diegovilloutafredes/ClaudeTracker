## 1. Pre-flight verification

- [x] 1.1 Smoke-test mid-conversation Claude Code account swap. **Result (2026-05-06): swap is unsafe.** Even before any swap, simply writing the active Keychain slot via the script broke auth on the next prompt (`API Error: 401 Invalid authentication credentials`). A subsequent in-CLI `/login` reported success but the next prompt 401'd again — only quitting and restarting `claude` recovered. Conclusion: `claude` caches its OAuth token at process start; any Keychain write during a live session breaks the next request. **Continuous trigger DROPPED from scope.** Spec, design, and remaining tasks updated to reflect Manual + shell-hook only.

## 2. Models and persistence

- [x] 2.1 Add `BalanceStrategy` enum to `Models.swift`: `case manual`, `case prioritize(preferredID: UUID, threshold: Double)`, `case balance(hysteresis: Double)`, with `Codable` synthesis.
- [x] 2.2 Add `BalanceSettings` struct in `Models.swift` holding the strategy + trigger flag (`triggerOnClaude: Bool`) + `lastManualSwitch: Date?`. Codable, persisted as JSON under `balanceSettings`. (No `triggerContinuous` — Continuous trigger dropped per task 1.1 finding.)
- [x] 2.3 Add `BalanceSettingsStore` enum in `Models.swift` with `load() -> BalanceSettings` and `save(_:)`, mirroring the pattern of `AccountStore`. Default-load returns `BalanceSettings(strategy: .manual, triggerOnClaude: false, lastManualSwitch: nil)`.

## 3. Pure decision module

- [x] 3.1 Create `ClaudeTracker/AccountBalancer.swift` with `BalanceDecision` struct (`recommendedAccountID`, `currentAccountID`, `scoreDiff`, `reason`, `triggerSource`, `shouldSwitch`).
- [x] 3.2 Implement `AccountBalancer.scoreAccount(state:)` returning `(slack: Double, pacePenalty: Double, resetBonus: Double, total: Double)`. Call sites use named tuple components for logging.
- [x] 3.3 Implement `AccountBalancer.decideManual()` — always returns `BalanceDecision` with `shouldSwitch == false`.
- [x] 3.4 Implement `AccountBalancer.decidePrioritize(preferredID:threshold:accounts:states:currentlyActive:)` — uses preferred unless its worst-window utilization > threshold OR pace warning; switches back only when preferred drops below `threshold - 5pp` AND no longer in pace warning.
- [x] 3.5 Implement `AccountBalancer.decideBalance(hysteresis:accounts:states:currentlyActive:)` — picks max-score linked account; `shouldSwitch == true` iff `bestScore - currentScore > hysteresis`.
- [x] 3.6 Implement `AccountBalancer.decide(strategy:accounts:states:currentlyActive:lastManualSwitch:trigger:now:)` — top-level dispatch. Short-circuits to no-switch when `now.timeIntervalSince(lastManualSwitch) < 300` regardless of strategy.

## 4. State export

- [x] 4.1 Implement `AccountBalancer.exportState(settings:accounts:states:currentlyActive:)` returning `Data` containing the JSON described in `design.md` Decision 6.
- [x] 4.2 Add `UsageViewModel.exportBalanceState()` that writes the export to `~/Library/Application Support/ClaudeTracker/balance.json` via `Data.write(to:options:.atomic)`. Creates parent directories as needed.
- [x] 4.3 Wire `exportBalanceState()` into the end of `fetchUsage(...)` so the file refreshes after each successful poll.

## 5. ViewModel integration

- [x] 5.1 Add `var balanceSettings: BalanceSettings` to `UsageViewModel`, loaded in `init()` via `BalanceSettingsStore.load()` (deferred to the same post-init Task that handles other UserDefaults reads to avoid the `NSApp` nil-at-init issue).
- [x] 5.2 Add `applyBalanceDecisionIfNeeded(trigger:)` method that calls `AccountBalancer.decide(...)` with current state, switches the active account if `decision.shouldSwitch`, and logs via the format in spec Requirement "All balance decisions are logged for audit".
- [x] 5.3 Stamp `balanceSettings.lastManualSwitch = Date()` and persist whenever `switchAccount(to:)` is called from a UI source (popover, Settings); not when called from auto-balance itself. Pass an `isManual: Bool` parameter, defaulting to `true`, with auto-balance code paths passing `false`. (Section 5.3 originally was the Continuous-trigger wiring — dropped per task 1.1 finding; this slot reused for the manual-switch timestamping.)

## 6. Popover UI

- [x] 6.1 In `MenuBarView.swift`, add a "Balance" button next to the existing account picker chevron when `viewModel.accounts.filter { $0.claudeCodeLinked }.count >= 2`.
- [x] 6.2 Wire the button to call `viewModel.applyBalanceDecisionIfNeeded(trigger: .manualButton)`.
- [x] 6.3 Visually disable the button when current strategy is Manual (or hide; design.md and spec leave this open — pick "disabled with tooltip explaining why"). **Picked "hide"** — a disabled button that does nothing under Manual is worse UX than no button. The Settings strategy picker is the discoverability path.

## 7. Settings UI

- [x] 7.1 In `SettingsView.swift`, add a new "Auto-balance Claude Code" section visible only when `viewModel.accounts.filter { $0.claudeCodeLinked }.count >= 2`.
- [x] 7.2 Add strategy picker (Picker with three cases: Manual / Prioritize / Balance). On change, update `viewModel.balanceSettings.strategy` and persist.
- [x] 7.3 Conditional sub-controls: when Prioritize selected, show "Preferred account" picker (linked accounts only) and "Switch when above" slider (50–95%, default 80%). When Balance selected, show "Switch threshold" stepper (1–25 pp, default 8).
- [x] 7.4 Add one `Toggle` for the shell-hook trigger: "When you run `claude` (recommended)". Default off. Use `GreenSwitchStyle` per the project constraint in `CLAUDE.md`. (Continuous toggle dropped per task 1.1 finding — would silently break running `claude` sessions.)
- [x] 7.5 Add a small info caption under the toggle: "Requires installing the `claude-balance` shell hook — see Help."

## 8. Shell hook CLI

- [x] 8.1 Create `claude-balance` bash script at `scripts/claude-balance` (~140 lines including comments — wider than the original 40-line estimate to support all three strategies natively in bash, but the runtime path is short).
- [x] 8.2 Implement: read `~/Library/Application Support/ClaudeTracker/balance.json`, parse `accounts[]` for `linked == true`, apply the active strategy (Manual = no-op, Prioritize = preferred-with-recovery-buffer, Balance = hysteresis-gated max-score), swap Keychain via `security add-generic-password -U` if a switch is warranted.
- [x] 8.3 Add idempotency / safety: if the file is missing, stale by >5 minutes, unparseable, jq is missing, the trigger toggle is off, the override window is active, or the chosen account's `Claude Code-account-<UUID>` entry is missing — exit 0 silently. Smoke-tested empty-state path: `exit=0` with no output.
- [x] 8.4 Document installation in `CLAUDE.md`: copy script to `~/.local/bin/claude-balance`, chmod +x, add a `claude()` shell function snippet for `~/.zshrc`. **Done in section 9.**

## 9. Documentation

- [x] 9.1 Update `CLAUDE.md` Architecture section: add `AccountBalancer.swift` entry describing strategies, decision pure-function pattern, and the trigger surfaces.
- [x] 9.2 Update `CLAUDE.md` to mention the new UserDefaults key (`balanceSettings`), the new on-disk export (`balance.json`), and the `claude-balance` shell hook with installation steps.
- [x] 9.3 Add a "Key Constraints" entry noting that `switchAccount(to:)` must distinguish manual vs. auto-balance callers via the `isManual:` parameter, and that the 5-minute override window depends on this distinction being correct. (Folded into the "Auto-balance trigger model" paragraph in CLAUDE.md.)

## 10. Verification

- [x] 10.1 Manual test: Manual strategy hides the popover Balance button entirely (Settings shows the section, picker has all three options). Verified by switching to Balance in Settings — button appeared in popover; switching back to Manual would hide it again.
- [ ] 10.2 Prioritize end-to-end (deferred — requires deliberately consuming claude.ai usage in the web app to cross the threshold; not run in this session).
- [x] 10.3 Balance no-op path verified: with both accounts at score 86 (current=Personal), `diff=0 hyst=8` → no switch, log line `balance [manualButton]: best=Diego Villouta ~ (86) cur=86 diff=0 hyst=8`. The hysteresis-respecting switch path (cross-account) is implemented identically and was not exercised in a live test.
- [x] 10.4 Override window verified: clicked Balance button within 5 min of a manual switch → log line `balance [manualButton]: skipped: manual override window active (19s remaining)`. Exact format from spec Requirement "All balance decisions are logged for audit".
- [ ] 10.5 Shell hook end-to-end (deferred — installation step + Keychain swap verification under a real `claude` invocation; user can install via `cp scripts/claude-balance ~/.local/bin/ && chmod +x ~/.local/bin/claude-balance` plus the documented `~/.zshrc` wrapper, then enable in Settings → Auto-balance → "When you run `claude`").
- [x] 10.6 `balance.json` inspected at `~/Library/Application Support/ClaudeTracker/balance.json` — schema matches design.md Decision 6 (exportedAt, currentAccountID, strategy, lastManualSwitch, triggerOnClaude, accounts[]). Refreshes each poll (verified across two reads).
- [x] 10.7 Decision log lines verified in both formats from the spec: skip-with-reason and switch-evaluation-with-scores. Both seen in `~/Library/Logs/ClaudeTracker/claudetracker.log`.
- [x] 10.8 `make build` + `make run` succeeded throughout sections 2–9; existing flows (Add account, Switch, Link/Unlink) untouched and continued working during testing.

## 11. Wrap-up

- [x] 11.1 Spec scenarios exercised: Manual no-switch (10.1), Balance no-op (10.3), override window skip (10.4), state-file refresh (10.6), log format (10.7). Deferred scenarios (Prioritize threshold cross, shell hook live invocation) are exercises requiring real account-usage burn or shell setup; left for the user to run when convenient.
- [x] 11.2 Each phase committed as a separate commit on `feat/claude-code-cli-integration` with descriptive messages (8 commits across sections 2–9).
- [x] 11.3 Branch pushed.
- [ ] 11.4 Run `/opsx:archive auto-balance-claude-code` to archive the change once you've run the deferred 10.2 / 10.5 tests at your convenience.
