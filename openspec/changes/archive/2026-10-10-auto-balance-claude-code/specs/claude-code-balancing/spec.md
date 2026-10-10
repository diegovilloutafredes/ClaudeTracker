## ADDED Requirements

### Requirement: Strategy is user-selectable and persisted

The system SHALL provide three mutually-exclusive auto-balance strategies — Manual, Prioritize, and Balance — and SHALL persist the user's selection along with any per-strategy parameters across app launches.

#### Scenario: Manual is the default for new and existing users

- **WHEN** the app launches and no `balanceStrategy` value is present in UserDefaults
- **THEN** the system SHALL behave as if Manual is selected
- **AND** no automatic account switching SHALL occur

#### Scenario: Selection persists across launches

- **WHEN** the user picks Balance with a hysteresis of 12 in Settings
- **AND** quits and relaunches the app
- **THEN** Settings SHALL show Balance with hysteresis of 12
- **AND** the same strategy and parameters SHALL drive any subsequent auto-switching

#### Scenario: Per-strategy parameters are scoped to their strategy

- **WHEN** the user is on Prioritize with `preferredID = A` and `threshold = 75%`
- **AND** switches to Balance
- **AND** later switches back to Prioritize
- **THEN** the previously-set `preferredID` and `threshold` SHALL still be present

### Requirement: Manual strategy never auto-switches

The system SHALL NOT change the active Claude Code account on its own when the Manual strategy is selected, regardless of which trigger surfaces are enabled.

#### Scenario: Manual button still works under Manual strategy

- **WHEN** the user has Manual strategy selected
- **AND** clicks the popover "Switch to best account" button (if exposed under Manual)
- **THEN** the system SHALL refuse the action with no state change
- **OR** the button SHALL not be visible under Manual

### Requirement: Prioritize strategy uses the preferred account until it crosses thresholds

The Prioritize strategy SHALL keep the user-designated preferred account active whenever the preferred account's worst-window utilization is below its configured threshold AND the preferred account is not in pace warning. When either condition is violated, the system SHALL switch to the highest-scoring linked alternative account.

#### Scenario: Preferred account stays active while under threshold

- **WHEN** the strategy is Prioritize, preferred = A, threshold = 80%
- **AND** A's worst-window utilization is 50% and A is not in pace warning
- **AND** account B has lower utilization than A
- **THEN** A SHALL remain the active account
- **AND** no switch SHALL be triggered

#### Scenario: Switch away when preferred crosses utilization threshold

- **WHEN** the strategy is Prioritize, preferred = A, threshold = 80%
- **AND** A's worst-window utilization rises from 78% to 82%
- **THEN** the system SHALL switch the active account to the highest-scoring linked account other than A

#### Scenario: Switch away when preferred enters pace warning

- **WHEN** the strategy is Prioritize, preferred = A
- **AND** A's worst-window utilization is 60% (below threshold)
- **AND** A's pace projection drops below the pace warning threshold (`projectedHoursToFull < 1`)
- **THEN** the system SHALL switch away from A even though A is below the utilization threshold

#### Scenario: Switch back to preferred only after recovery buffer

- **WHEN** the strategy is Prioritize, preferred = A, threshold = 80%
- **AND** the system previously switched away because A reached 82%
- **AND** A's worst-window utilization later drops to 78%
- **THEN** the system SHALL NOT switch back to A yet
- **AND** the system SHALL switch back to A only when A drops below `threshold - 5pp` (75% in this case)
- **AND** A SHALL not be in pace warning at the time of the switch-back

### Requirement: Balance strategy picks highest score with hysteresis

The Balance strategy SHALL compute a score for each linked account using `worst_window_slack + pace_penalty + reset_proximity_bonus` (where `pace_penalty` is `-10` if `projectedHoursToFull < 1`, `-5` if `< 2`, else `0`; and `reset_proximity_bonus` is `+5` if any window resets within 30 minutes, else `0`). The system SHALL switch to the highest-scoring linked account only when its score exceeds the active account's score by more than the configured hysteresis threshold.

#### Scenario: No switch when scores are within hysteresis

- **WHEN** the strategy is Balance, hysteresis = 8
- **AND** active account A has score 50, candidate B has score 53
- **THEN** the system SHALL NOT switch (3 ≤ 8)

#### Scenario: Switch when score gap exceeds hysteresis

- **WHEN** the strategy is Balance, hysteresis = 8
- **AND** active account A has score 50, candidate B has score 62
- **THEN** the system SHALL switch the active account to B

#### Scenario: Pace warning is reflected in the score

- **WHEN** account A has worst-window slack of 60 and pace projects to fill in 0.5 hours
- **AND** account B has worst-window slack of 55 and pace is OK
- **THEN** A's score SHALL be `60 - 10 = 50`
- **AND** B's score SHALL be `55`
- **AND** if B is currently active, no switch SHALL occur (5 ≤ 8 hysteresis)

#### Scenario: Reset proximity bonus rewards an about-to-refill account

- **WHEN** account A has worst-window slack of 50 and its 5h window resets in 20 minutes
- **AND** account B has worst-window slack of 52 with no near reset
- **THEN** A's score SHALL be `50 + 5 = 55`
- **AND** B's score SHALL be `52`

### Requirement: Manual switches receive a 5-minute auto-balance freeze

The system SHALL record the timestamp of any manual account switch (popover picker, Settings "Switch" button, or `claude-account use ...` followed by an in-app refresh) and SHALL NOT allow auto-balancing to change the active account for 5 minutes after that timestamp, regardless of strategy or trigger.

#### Scenario: Manual button + recent manual switch + Balance = no auto-switch

- **WHEN** the strategy is Balance
- **AND** the user manually switched to A 2 minutes ago
- **AND** the user clicks the popover "Switch to best account" button
- **AND** account B's score exceeds A's by more than the hysteresis
- **THEN** the system SHALL NOT switch away from A
- **AND** the override window SHALL be reported to the user (e.g. via log or no-op feedback)

#### Scenario: Shell-hook switch obeys the override window via state file

- **WHEN** the strategy is Balance
- **AND** the user manually switched to A within the last 5 minutes
- **AND** `claude-balance` runs before a new `claude` invocation
- **THEN** `claude-balance` SHALL detect the recent manual switch via `lastManualSwitch` in `balance.json`
- **AND** SHALL leave the active Keychain entry unchanged

### Requirement: Two independent trigger surfaces

The system SHALL provide two trigger surfaces — manual popover button and shell hook (`claude-balance` CLI) — that each independently invoke the same decision module and CAN be used in any combination. A continuous in-app polling trigger SHALL NOT be provided in this change because writing the `Claude Code-credentials` Keychain slot during a running `claude` session causes the next request to fail with 401 (verified 2026-05-06); see `design.md` Risks for details.

#### Scenario: Popover button is available when ≥2 accounts are linked

- **WHEN** the user has linked ≥2 accounts to Claude Code
- **AND** the popover is open
- **THEN** a "Switch to best account" button SHALL be visible
- **AND** clicking it SHALL run the current strategy's decision and switch if appropriate
- **AND** clicking it SHALL count as a manual action and reset the 5-minute override window

#### Scenario: Shell hook trigger reads exported state

- **WHEN** the user has installed the `claude-balance` shell function and runs `claude`
- **AND** ClaudeTracker has written `~/Library/Application Support/ClaudeTracker/balance.json` within the last poll interval
- **THEN** `claude-balance` SHALL pick the highest-scoring linked account from the file
- **AND** SHALL swap the `Claude Code-credentials` Keychain entry to that account's saved token before `claude` is invoked

### Requirement: Balance state is exported to a stable file path

The system SHALL write per-account balance data to `~/Library/Application Support/ClaudeTracker/balance.json` after each successful poll cycle, containing all data the shell hook needs to reproduce the decision without IPC.

#### Scenario: File is refreshed after each poll

- **WHEN** a usage poll completes successfully
- **THEN** `balance.json` SHALL be rewritten atomically with the latest scores, current account ID, strategy, and last manual switch timestamp

#### Scenario: File contains the current strategy and override window

- **WHEN** the user changes strategy from Manual to Prioritize with preferred = A
- **AND** the next poll completes
- **THEN** `balance.json` SHALL reflect `strategy.kind == "prioritize"` and `strategy.preferredID == A`

#### Scenario: Atomic write prevents partial reads

- **WHEN** `claude-balance` reads `balance.json` while ClaudeTracker is mid-write
- **THEN** the reader SHALL see either the previous complete file or the new complete file
- **AND** SHALL NEVER see partial JSON

### Requirement: All balance decisions are logged for audit

The system SHALL emit a structured log line via `AppLogger` every time the balancer decides to switch (or considers and rejects a switch when `shouldSwitch` would be true except for hysteresis or override window), including: source trigger, strategy, scores of all linked accounts, decision outcome.

#### Scenario: Switch decision is logged

- **WHEN** the balancer switches the active account from A to B under Balance strategy
- **THEN** a log entry of the form `balance: A→B (slack=45→62, pace ok, diff=17, trigger=continuous)` SHALL be written

#### Scenario: Skipped switch is logged

- **WHEN** the balancer would switch from A to B but the override window is active
- **THEN** a log entry indicating `balance skipped: override window active (Xs remaining)` SHALL be written
