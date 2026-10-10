## Context

ClaudeTracker already has the data needed to make an informed account-selection decision: per-account utilization across `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` windows, plus pace data (`%/hr` rate and projected hours-to-full from exponentially-weighted linear regression in `Models.swift::computePace`). The CLI integration on `feat/claude-code-cli-integration` exposes `ClaudeCodeKeychain.switchTo(id:)` which copies a saved per-account token onto the active `Claude Code-credentials` slot — the mechanism for a "switch" is already in place.

What's missing is the policy layer: when, why, and to whom to switch. This design defines that layer as a small, pure-decision module separated from the trigger sites that invoke it, so the same logic powers an in-app button, a periodic poll-time check, and an out-of-process shell hook.

## Goals / Non-Goals

**Goals:**
- Three user-selectable strategies (Manual / Prioritize / Balance) covering the common usage patterns surfaced during proposal review.
- Decision logic isolated as a pure function (testable, no side effects) — separate from the side-effecting "apply this decision" path.
- Three trigger surfaces (manual button, shell hook, continuous) that can be enabled independently and call the same decision module.
- Out-of-process triggering (the shell hook) without IPC: a state file the app refreshes each poll and the CLI helper reads.
- Default behavior is unchanged for existing users (Manual strategy is the default).
- Audit trail: every decision and switch is logged in a structured form for after-the-fact analysis.

**Non-Goals:**
- A general-purpose "load balancer" framework; this is one feature with three modes.
- IPC or RPC between the CLI helper and the running app — the state file with stale-data tolerance is the entire integration surface.
- Per-model routing, time-of-day routing, or cost-tier auto-prioritization — listed as out of scope in the proposal.
- Specifying the underlying CLI integration (`Claude Code-credentials` slot, Link/Unlink, sandbox removal) — that is implemented but un-specced; this change only adds the balancing layer on top.

## Decisions

### Decision 1: Strategy as an enum stored in UserDefaults

`enum BalanceStrategy: Codable { case manual, prioritize(preferredID: UUID, threshold: Double), balance(hysteresis: Double) }` persisted as JSON under `balanceStrategy`. Associated values keep the per-strategy parameters bound to the case that uses them — switching modes can't leave dangling settings.

**Alternative considered**: Three separate Bool/UUID/Double UserDefaults keys with an "active mode" string. Rejected — easy to get into invalid combinations (Prioritize with no preferred account, etc.) and harder to evolve.

### Decision 2: Score formula for Balance mode

```
slack         = min(5h_left, 7d_left, 7d_opus_left, 7d_sonnet_left)
pace_penalty  = projectedHoursToFull < 1 ? -10 : projectedHoursToFull < 2 ? -5 : 0
reset_bonus   = (anyWindowResetsIn < 30min) ? +5 : 0
score         = slack + pace_penalty + reset_bonus
```

Worst-window slack is the base because hitting a 7-day cap is just as bad as hitting a 5-hour cap — picking the most-constraining window matches the actual risk. Pace penalty leans on the existing `pace(for:)` helper. Reset bonus rewards an account that's about to refill anyway.

**Alternative considered**: Pure 5h slack. Rejected — leads to over-burning the 7d window when 5h is plentiful.

### Decision 3: Hysteresis to prevent flapping

Switch only when `bestScore - currentScore > 8` (configurable via `balanceHysteresis`). With 8pp gap required, two accounts at 50% and 51% won't ping-pong on noise.

**Alternative considered**: No hysteresis (always pick best). Rejected — every poll could switch the active account on tiny score changes, breaking shell sessions and confusing the user.

### Decision 4: User override window (5 minutes)

After a manual switch via the popover or Settings, auto-balance does not switch the active account for 5 minutes (configurable). Implemented by storing `balanceLastManualSwitch: Date` and short-circuiting the decision module if `Date().timeIntervalSince(lastManual) < 300`.

This is the "respect the human" guardrail — when the user reaches in and overrides, don't immediately undo their choice.

**Alternative considered**: No override window (always trust the algorithm). Rejected — frustrating UX when the user has context the algorithm doesn't (e.g., "I want to use Personal for the next thing because reasons").

### Decision 5: Three trigger surfaces, independent

| Surface | Implementation | Default |
|---|---|---|
| Manual button | Popover row when ≥2 linked accounts; calls `AccountBalancer.applyIfNeeded()` directly | Always available |
| Shell hook (`claude-balance` CLI) | Bash script reads `balance.json`, runs the decision in shell math, swaps Keychain via `security add-generic-password -U`. Wraps `claude` via a shell function in `~/.zshrc`. | Off (user adds the function themselves) |
| Continuous (in-app polling) | `UsageViewModel.scheduleNextPoll()` calls the balancer after each fetch when `balanceTriggerContinuous == true` | Off |

These are three independent toggles, not radio buttons — a user can have continuous on, the shell hook installed, and the manual button visible all at once. The decision module is idempotent: a re-evaluation that picks the already-active account is a no-op.

### Decision 6: State export via `~/Library/Application Support/ClaudeTracker/balance.json`

Schema:
```json
{
  "exportedAt": "2026-05-06T20:31:14Z",
  "currentAccountID": "3FB38455-…",
  "strategy": { "kind": "balance", "hysteresis": 8 },
  "lastManualSwitch": "2026-05-06T20:25:01Z",
  "accounts": [
    {
      "id": "3FB38455-…",
      "label": "Personal",
      "linked": true,
      "fiveHourLeft": 65, "sevenDayLeft": 45, "opusLeft": 30, "sonnetLeft": 80,
      "paceProjectedHours": 4.2,
      "anyResetWithin30min": false,
      "score": 35.0
    },
    { "...": "..." }
  ]
}
```

The CLI helper does NOT re-implement the score — the app already wrote each account's score. The CLI just picks max(score) of `linked == true` accounts (with hysteresis check vs `currentAccountID`'s score). Keeps the algorithm in one place.

**Alternative considered**: XPC service or AppleScript bridge. Rejected — file-based is simpler, has zero install steps beyond the bash script itself, and the stale-data degradation (CLI uses last-poll data, max ~10s old) is fully acceptable for this use case.

### Decision 7: AccountBalancer is pure; UsageViewModel does I/O

```swift
struct BalanceDecision {
    let recommendedAccountID: UUID?
    let currentAccountID: UUID?
    let scoreDiff: Double
    let reason: String
    var shouldSwitch: Bool { /* checks override window + hysteresis */ }
}

enum AccountBalancer {
    static func decide(strategy: BalanceStrategy,
                       accounts: [Account],
                       states: [UUID: AccountState],
                       currentlyActive: UUID?,
                       lastManualSwitch: Date?,
                       now: Date = Date()) -> BalanceDecision
    static func exportState(...) -> Data  // produces balance.json contents
}
```

Pure functions = unit-testable without spinning up the app. UsageViewModel calls `AccountBalancer.decide(...)`, inspects `decision.shouldSwitch`, and dispatches `switchAccount(to:)` if true. This separation is what lets the shell hook reuse the decision logic without reusing the side effects.

## Risks / Trade-offs

- **Mid-conversation Claude Code swap is unsafe — Continuous trigger DROPPED from scope.** Smoke-tested 2026-05-06: writing the `Claude Code-credentials` Keychain slot caused the next prompt in an already-open `claude` session to fail with `API Error: 401 Invalid authentication credentials`. A subsequent in-CLI `/login` reported "Login successful" but the next prompt 401'd again — only quitting and restarting `claude` recovered. Conclusion: `claude` reads its OAuth token at process start and caches it; Keychain writes during a running session break auth on the next request. The Continuous trigger surface (re-evaluate every poll while the app is running) is therefore dropped — it would silently break any in-progress `claude` session every time it fired. Only **Manual** (popover button before starting `claude`) and **Shell hook** (`claude-balance` runs *before* `claude` spawns, so the token is fresh at process start) ship in this change. The Continuous toggle is removed from Settings; the `triggerContinuous` flag is removed from `BalanceSettings`. Re-evaluate if a future `claude` release adds in-process token refresh.
- **Prioritize "switch back when recovered" needs a buffer** → To prevent oscillation when the preferred account hovers near threshold, switch back only when preferred drops below `threshold - 5pp` (e.g. switched away at 80%, switch back at <75%). Documented in spec scenarios.
- **State file race conditions** → Multiple concurrent `claude-balance` invocations could read mid-write data. Mitigation: app writes via `Data.write(to:options:.atomic)` so readers always see a complete file or the previous version.
- **Dual namespace with `claude-account` script** → Existing CLI script saves entries under `Claude Code-account-<human-name>`; the app uses `Claude Code-account-<UUID>`. They coexist but are invisible to each other. Documented; not addressed by this change.
- **Sandboxed app = no `~/Library/Application Support` access** → ClaudeTracker is no longer sandboxed (per the parent CLI integration), so this is fine. If sandboxing returns, the export path needs revisiting.

## Migration Plan

This is opt-in with no migration burden. Default `balanceStrategy` is `.manual`, which behaves identically to the current state. Existing users see a new collapsed Settings section but no behavior change until they pick a strategy.

Rollback: revert the change branch. UserDefaults keys are namespaced with `balance*` prefix and ignored by the pre-change build.

## Open Questions

None blocking — the seven design decisions surfaced during proposal were all resolved with stated defaults. Specific values (8pp hysteresis, 5min override, 80% Prioritize threshold, 30min reset bonus window, etc.) are defaults that the user can tune in Settings; if any prove too aggressive in practice the defaults can be adjusted in a follow-up without spec changes.
