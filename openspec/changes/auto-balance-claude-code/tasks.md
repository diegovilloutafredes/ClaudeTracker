## 1. Pre-flight verification

- [x] 1.1 Smoke-test mid-conversation Claude Code account swap. **Result (2026-05-06): swap is unsafe.** Even before any swap, simply writing the active Keychain slot via the script broke auth on the next prompt (`API Error: 401 Invalid authentication credentials`). A subsequent in-CLI `/login` reported success but the next prompt 401'd again — only quitting and restarting `claude` recovered. Conclusion: `claude` caches its OAuth token at process start; any Keychain write during a live session breaks the next request. **Continuous trigger DROPPED from scope.** Spec, design, and remaining tasks updated to reflect Manual + shell-hook only.

## 2. Models and persistence

- [x] 2.1 Add `BalanceStrategy` enum to `Models.swift`: `case manual`, `case prioritize(preferredID: UUID, threshold: Double)`, `case balance(hysteresis: Double)`, with `Codable` synthesis.
- [x] 2.2 Add `BalanceSettings` struct in `Models.swift` holding the strategy + trigger flag (`triggerOnClaude: Bool`) + `lastManualSwitch: Date?`. Codable, persisted as JSON under `balanceSettings`. (No `triggerContinuous` — Continuous trigger dropped per task 1.1 finding.)
- [x] 2.3 Add `BalanceSettingsStore` enum in `Models.swift` with `load() -> BalanceSettings` and `save(_:)`, mirroring the pattern of `AccountStore`. Default-load returns `BalanceSettings(strategy: .manual, triggerOnClaude: false, lastManualSwitch: nil)`.

## 3. Pure decision module

- [ ] 3.1 Create `ClaudeTracker/AccountBalancer.swift` with `BalanceDecision` struct (`recommendedAccountID`, `currentAccountID`, `scoreDiff`, `reason`, `triggerSource`, `shouldSwitch`).
- [ ] 3.2 Implement `AccountBalancer.scoreAccount(state:)` returning `(slack: Double, pacePenalty: Double, resetBonus: Double, total: Double)`. Call sites use named tuple components for logging.
- [ ] 3.3 Implement `AccountBalancer.decideManual()` — always returns `BalanceDecision` with `shouldSwitch == false`.
- [ ] 3.4 Implement `AccountBalancer.decidePrioritize(preferredID:threshold:accounts:states:currentlyActive:)` — uses preferred unless its worst-window utilization > threshold OR pace warning; switches back only when preferred drops below `threshold - 5pp` AND no longer in pace warning.
- [ ] 3.5 Implement `AccountBalancer.decideBalance(hysteresis:accounts:states:currentlyActive:)` — picks max-score linked account; `shouldSwitch == true` iff `bestScore - currentScore > hysteresis`.
- [ ] 3.6 Implement `AccountBalancer.decide(strategy:accounts:states:currentlyActive:lastManualSwitch:trigger:now:)` — top-level dispatch. Short-circuits to no-switch when `now.timeIntervalSince(lastManualSwitch) < 300` regardless of strategy.

## 4. State export

- [ ] 4.1 Implement `AccountBalancer.exportState(settings:accounts:states:currentlyActive:)` returning `Data` containing the JSON described in `design.md` Decision 6.
- [ ] 4.2 Add `UsageViewModel.exportBalanceState()` that writes the export to `~/Library/Application Support/ClaudeTracker/balance.json` via `Data.write(to:options:.atomic)`. Creates parent directories as needed.
- [ ] 4.3 Wire `exportBalanceState()` into the end of `fetchUsage(...)` so the file refreshes after each successful poll.

## 5. ViewModel integration

- [ ] 5.1 Add `var balanceSettings: BalanceSettings` to `UsageViewModel`, loaded in `init()` via `BalanceSettingsStore.load()` (deferred to the same post-init Task that handles other UserDefaults reads to avoid the `NSApp` nil-at-init issue).
- [ ] 5.2 Add `applyBalanceDecisionIfNeeded(trigger:)` method that calls `AccountBalancer.decide(...)` with current state, switches the active account if `decision.shouldSwitch`, and logs via the format in spec Requirement "All balance decisions are logged for audit".
- [ ] 5.3 Stamp `balanceSettings.lastManualSwitch = Date()` and persist whenever `switchAccount(to:)` is called from a UI source (popover, Settings); not when called from auto-balance itself. Pass an `isManual: Bool` parameter, defaulting to `true`, with auto-balance code paths passing `false`. (Section 5.3 originally was the Continuous-trigger wiring — dropped per task 1.1 finding; this slot reused for the manual-switch timestamping.)

## 6. Popover UI

- [ ] 6.1 In `MenuBarView.swift`, add a "Balance" button next to the existing account picker chevron when `viewModel.accounts.filter { $0.claudeCodeLinked }.count >= 2`.
- [ ] 6.2 Wire the button to call `viewModel.applyBalanceDecisionIfNeeded(trigger: .manualButton)`.
- [ ] 6.3 Visually disable the button when current strategy is Manual (or hide; design.md and spec leave this open — pick "disabled with tooltip explaining why").

## 7. Settings UI

- [ ] 7.1 In `SettingsView.swift`, add a new "Auto-balance Claude Code" section visible only when `viewModel.accounts.filter { $0.claudeCodeLinked }.count >= 2`.
- [ ] 7.2 Add strategy picker (Picker with three cases: Manual / Prioritize / Balance). On change, update `viewModel.balanceSettings.strategy` and persist.
- [ ] 7.3 Conditional sub-controls: when Prioritize selected, show "Preferred account" picker (linked accounts only) and "Switch when above" slider (50–95%, default 80%). When Balance selected, show "Switch threshold" stepper (1–25 pp, default 8).
- [ ] 7.4 Add one `Toggle` for the shell-hook trigger: "When you run `claude` (recommended)". Default off. Use `GreenSwitchStyle` per the project constraint in `CLAUDE.md`. (Continuous toggle dropped per task 1.1 finding — would silently break running `claude` sessions.)
- [ ] 7.5 Add a small info caption under the toggle: "Requires installing the `claude-balance` shell hook — see Help."

## 8. Shell hook CLI

- [ ] 8.1 Create `claude-balance` bash script (~40 lines) at the project root or a clear location.
- [ ] 8.2 Implement: read `~/Library/Application Support/ClaudeTracker/balance.json`, parse `accounts[]` for `linked == true`, find max `score`, compare against `currentAccountID`'s score using strategy's hysteresis, swap Keychain via `security add-generic-password -U` if a switch is warranted.
- [ ] 8.3 Add idempotency / safety: if the file is missing, stale by >5 minutes, or unparseable, exit 0 silently (don't block `claude` invocation). If the chosen account's `Claude Code-account-<UUID>` entry is missing, exit 0 silently.
- [ ] 8.4 Document installation in `CLAUDE.md`: copy script to `~/.local/bin/claude-balance`, chmod +x, add a `claude()` shell function snippet for `~/.zshrc`.

## 9. Documentation

- [ ] 9.1 Update `CLAUDE.md` Architecture section: add `AccountBalancer.swift` entry describing strategies, decision pure-function pattern, and the three trigger surfaces.
- [ ] 9.2 Update `CLAUDE.md` to mention the new UserDefaults key (`balanceSettings`), the new on-disk export (`balance.json`), and the `claude-balance` shell hook.
- [ ] 9.3 Add a "Key Constraints" entry noting that `switchAccount(to:)` must distinguish manual vs. auto-balance callers via the `isManual:` parameter, and that the 5-minute override window depends on this distinction being correct.

## 10. Verification

- [ ] 10.1 Manual test: set strategy to Manual. Click the popover Balance button. Observe it refuses to switch. Verify spec Requirement "Manual strategy never auto-switches".
- [ ] 10.2 Manual test: set strategy to Prioritize, preferred = lower-utilization account, threshold = current utilization + 5pp. Observe no switch. Manually consume in claude.ai web app to push preferred over threshold; observe switch within one poll. Verify spec Requirement "Prioritize strategy".
- [ ] 10.3 Manual test: set strategy to Balance, hysteresis = 1. Observe rapid back-and-forth. Set hysteresis = 50. Observe no switching. Verify spec Requirement "Balance strategy".
- [ ] 10.4 Manual test: trigger a manual switch via popover. Within 5 minutes, click the popover Balance button. Verify no auto-switch occurs (override window respected). Wait > 5 minutes; click again; verify it now switches.
- [ ] 10.5 Manual test: install the shell hook. Run `claude` from a fresh shell. Verify Keychain `Claude Code-credentials` entry value matches the expected account's saved entry. Re-run from same session — verify no spurious switching.
- [ ] 10.6 Inspect `balance.json` — verify schema matches `design.md` Decision 6 and that scores update each poll.
- [ ] 10.7 Inspect `~/Library/Logs/ClaudeTracker/claudetracker.log` — verify decision log lines appear in the format from spec Requirement "All balance decisions are logged for audit".
- [ ] 10.8 Run `make build` and `make run`; smoke-test the existing app flows (Add account, Switch, Link/Unlink) to verify no regression on the parent CLI integration features.

## 11. Wrap-up

- [ ] 11.1 Verify all spec scenarios are exercised by the manual tests in section 10. If any aren't, add a corresponding test step.
- [ ] 11.2 Commit each phase (sections 2, 3, 4, 5, 6, 7, 8, 9) as a separate commit on `feat/claude-code-cli-integration` with descriptive messages.
- [ ] 11.3 Push branch. Do NOT merge to main — the parent CLI integration is also still on the branch.
- [ ] 11.4 Run `/opsx:archive auto-balance-claude-code` to archive the change once implementation is complete and verified.
