import Foundation

/// What invoked the balance evaluation. Threaded into log lines and the
/// override-window check so logs can attribute decisions to their source.
enum BalanceTrigger: String, Codable {
    case manualButton   // popover "Switch to best account" button
    case shellHook      // claude-balance CLI before `claude` runs
}

/// The decision returned by `AccountBalancer.decide(...)`. The balancer is a
/// pure function (no side effects), so the call site decides whether to act
/// on `shouldSwitch` and what side effects to apply (Keychain write,
/// `switchAccount(to:)`, log line).
struct BalanceDecision {
    let recommendedAccountID: UUID?   // nil iff no linked accounts to choose from
    let currentAccountID: UUID?
    let scoreDiff: Double             // recommended.score - current.score; 0 when same or current absent
    let reason: String                // human-readable, suitable for logging
    let triggerSource: BalanceTrigger
    let shouldSwitch: Bool
}

/// Pure decision module. No I/O, no Keychain, no UserDefaults — caller-side
/// concerns. The same `decide(...)` powers the in-app Manual button and the
/// state file consumed by the `claude-balance` shell hook (which reproduces
/// the same logic in bash off the exported scores).
enum AccountBalancer {

    // MARK: - Tunables (defaults; user-overridable values live in BalanceSettings)

    /// Minutes to freeze auto-balance after a manual switch.
    static let overrideWindowSeconds: TimeInterval = 300
    /// Buffer below the Prioritize threshold before we switch BACK to the
    /// preferred account. Prevents oscillation around the threshold edge.
    static let prioritizeRecoveryBuffer: Double = 5
    /// Pace projection (hours-to-full) below which an account is "in pace warning"
    /// for Prioritize purposes. Matches the spec's phrasing.
    static let pacePrioritizeWarnHours: Double = 1
    /// Reset-bonus is awarded when any window resets within this many minutes.
    static let resetBonusWindowMinutes: Double = 30

    // MARK: - Scoring

    /// Components of an account's Balance score, exposed individually for logging.
    struct Score {
        let slack: Double          // worst-window remaining (0–100)
        let pacePenalty: Double    // -10 / -5 / 0 based on projected hours-to-full
        let resetBonus: Double     // +5 / 0 based on reset proximity
        var total: Double { slack + pacePenalty + resetBonus }
    }

    /// Computes a Balance score for one account from its `AccountState`.
    /// Returns nil iff the account has no usage data yet (newly added, fetch
    /// hasn't completed) — such accounts are excluded from selection.
    static func scoreAccount(state: AccountState, now: Date = Date()) -> Score? {
        guard let usage = state.usage else { return nil }
        let slack = worstWindowSlack(usage: usage)
        let pacePenalty = pacePenalty(state: state)
        let resetBonus = resetBonus(usage: usage, now: now)
        return Score(slack: slack, pacePenalty: pacePenalty, resetBonus: resetBonus)
    }

    /// `100 - max(utilization across all reported windows)`. Picks the
    /// most-constraining window so 7-day pressure isn't masked by 5-hour
    /// headroom.
    static func worstWindowSlack(usage: UsageResponse) -> Double {
        var maxUtil: Double = 0
        if let u = usage.fiveHour?.utilization { maxUtil = max(maxUtil, u) }
        if let u = usage.sevenDay?.utilization { maxUtil = max(maxUtil, u) }
        if let u = usage.sevenDayOpus?.utilization { maxUtil = max(maxUtil, u) }
        if let u = usage.sevenDaySonnet?.utilization { maxUtil = max(maxUtil, u) }
        return max(0, 100 - maxUtil)
    }

    /// Worst projected hours-to-full across windows that have pace data.
    /// Returns nil iff no window has pace data (used to mean "no penalty").
    static func worstPaceProjection(state: AccountState) -> Double? {
        var worst: Double? = nil
        for (_, history) in state.utilizationHistory {
            guard let p = computePace(history: history, lambda: 2.0),
                  let projected = p.projectedHours else { continue }
            if worst == nil || projected < worst! { worst = projected }
        }
        return worst
    }

    private static func pacePenalty(state: AccountState) -> Double {
        guard let proj = worstPaceProjection(state: state) else { return 0 }
        if proj < 1 { return -10 }
        if proj < 2 { return -5 }
        return 0
    }

    private static func resetBonus(usage: UsageResponse, now: Date) -> Double {
        let windows: [UsageWindow?] = [usage.fiveHour, usage.sevenDay, usage.sevenDayOpus, usage.sevenDaySonnet]
        for w in windows {
            guard let date = w?.resetsAtDate else { continue }
            let minutesUntil = date.timeIntervalSince(now) / 60
            if minutesUntil > 0 && minutesUntil < resetBonusWindowMinutes { return 5 }
        }
        return 0
    }

    // MARK: - Strategy decisions

    /// Manual: never auto-switch, regardless of trigger.
    static func decideManual(currentlyActive: UUID?,
                             trigger: BalanceTrigger) -> BalanceDecision {
        BalanceDecision(
            recommendedAccountID: currentlyActive,
            currentAccountID: currentlyActive,
            scoreDiff: 0,
            reason: "manual strategy — no auto-switch",
            triggerSource: trigger,
            shouldSwitch: false
        )
    }

    /// Prioritize: stay on `preferredID` until its worst-window utilization
    /// exceeds `threshold` OR it enters pace warning. When already off the
    /// preferred account, switch back only when preferred drops below
    /// `threshold - prioritizeRecoveryBuffer` AND no longer in pace warning.
    static func decidePrioritize(preferredID: UUID,
                                 threshold: Double,
                                 accounts: [Account],
                                 states: [UUID: AccountState],
                                 currentlyActive: UUID?,
                                 trigger: BalanceTrigger) -> BalanceDecision {
        let linked = accounts.filter { $0.claudeCodeLinked }

        // If preferred isn't linked or has no data, fall back to Balance over
        // the linked set so the user isn't stuck with no usable account.
        guard let preferred = linked.first(where: { $0.id == preferredID }),
              let preferredState = states[preferred.id],
              let preferredUsage = preferredState.usage else {
            return decideBalance(
                hysteresis: 0,
                accounts: accounts, states: states,
                currentlyActive: currentlyActive,
                trigger: trigger,
                fallbackReason: "preferred account unavailable; falling back to Balance"
            )
        }

        let preferredUtilMax = 100 - worstWindowSlack(usage: preferredUsage)
        let preferredInPaceWarn = (worstPaceProjection(state: preferredState) ?? .infinity) < pacePrioritizeWarnHours
        let isCurrentlyOnPreferred = (currentlyActive == preferred.id)

        // CASE 1: We're on preferred. Switch away iff exceeded threshold or in pace warning.
        if isCurrentlyOnPreferred {
            let mustLeave = preferredUtilMax > threshold || preferredInPaceWarn
            if !mustLeave {
                return BalanceDecision(
                    recommendedAccountID: preferred.id,
                    currentAccountID: currentlyActive,
                    scoreDiff: 0,
                    reason: "preferred OK (util=\(Int(preferredUtilMax))%, pace OK)",
                    triggerSource: trigger,
                    shouldSwitch: false
                )
            }
            // Pick the highest-scoring linked alternative.
            return pickBest(
                amongLinkedExcluding: preferred.id,
                accounts: accounts, states: states,
                currentlyActive: currentlyActive, trigger: trigger,
                reasonPrefix: "preferred over threshold (util=\(Int(preferredUtilMax))%) — switching to best alt"
            )
        }

        // CASE 2: We're NOT on preferred. Switch back only after recovery buffer.
        let recoveryThreshold = threshold - prioritizeRecoveryBuffer
        let canReturn = preferredUtilMax < recoveryThreshold && !preferredInPaceWarn
        if canReturn {
            return BalanceDecision(
                recommendedAccountID: preferred.id,
                currentAccountID: currentlyActive,
                scoreDiff: 0,
                reason: "preferred recovered (util=\(Int(preferredUtilMax))% < \(Int(recoveryThreshold))%) — returning",
                triggerSource: trigger,
                shouldSwitch: currentlyActive != preferred.id
            )
        }
        // Stay where we are (already off preferred, preferred not yet recovered).
        return BalanceDecision(
            recommendedAccountID: currentlyActive,
            currentAccountID: currentlyActive,
            scoreDiff: 0,
            reason: "preferred still over recovery (util=\(Int(preferredUtilMax))% ≥ \(Int(recoveryThreshold))%)",
            triggerSource: trigger,
            shouldSwitch: false
        )
    }

    /// Balance: pick max-score linked account; switch only when
    /// `bestScore - currentScore > hysteresis`.
    static func decideBalance(hysteresis: Double,
                              accounts: [Account],
                              states: [UUID: AccountState],
                              currentlyActive: UUID?,
                              trigger: BalanceTrigger,
                              fallbackReason: String? = nil) -> BalanceDecision {
        let linked = accounts.filter { $0.claudeCodeLinked }
        let scored = linked.compactMap { acct -> (Account, Score)? in
            guard let s = states[acct.id], let score = scoreAccount(state: s) else { return nil }
            return (acct, score)
        }
        guard let (best, bestScore) = scored.max(by: { $0.1.total < $1.1.total }) else {
            return BalanceDecision(
                recommendedAccountID: currentlyActive,
                currentAccountID: currentlyActive,
                scoreDiff: 0,
                reason: "no linked accounts with usage data",
                triggerSource: trigger,
                shouldSwitch: false
            )
        }
        let currentScore = currentlyActive
            .flatMap { id in scored.first(where: { $0.0.id == id })?.1.total }
        let diff: Double = (currentScore.map { bestScore.total - $0 }) ?? bestScore.total
        let reason: String = {
            if let prefix = fallbackReason { return "\(prefix): best=\(best.label) score=\(Int(bestScore.total))" }
            if let cur = currentScore {
                return "best=\(best.label) (\(Int(bestScore.total))) cur=\(Int(cur)) diff=\(Int(diff)) hyst=\(Int(hysteresis))"
            }
            return "best=\(best.label) (\(Int(bestScore.total))) cur=none"
        }()
        let shouldSwitch = (best.id != currentlyActive) && diff > hysteresis
        return BalanceDecision(
            recommendedAccountID: best.id,
            currentAccountID: currentlyActive,
            scoreDiff: diff,
            reason: reason,
            triggerSource: trigger,
            shouldSwitch: shouldSwitch
        )
    }

    /// Helper: pick the highest-scoring linked account excluding one id, used
    /// by Prioritize when the preferred account must be abandoned. No
    /// hysteresis applied — once we've decided to leave, we go to the best.
    private static func pickBest(amongLinkedExcluding excluded: UUID,
                                 accounts: [Account],
                                 states: [UUID: AccountState],
                                 currentlyActive: UUID?,
                                 trigger: BalanceTrigger,
                                 reasonPrefix: String) -> BalanceDecision {
        let candidates = accounts
            .filter { $0.claudeCodeLinked && $0.id != excluded }
            .compactMap { acct -> (Account, Score)? in
                guard let s = states[acct.id], let score = scoreAccount(state: s) else { return nil }
                return (acct, score)
            }
        guard let (pick, score) = candidates.max(by: { $0.1.total < $1.1.total }) else {
            return BalanceDecision(
                recommendedAccountID: currentlyActive,
                currentAccountID: currentlyActive,
                scoreDiff: 0,
                reason: "\(reasonPrefix); no alternates available",
                triggerSource: trigger,
                shouldSwitch: false
            )
        }
        return BalanceDecision(
            recommendedAccountID: pick.id,
            currentAccountID: currentlyActive,
            scoreDiff: score.total,
            reason: "\(reasonPrefix) → \(pick.label) (score=\(Int(score.total)))",
            triggerSource: trigger,
            shouldSwitch: pick.id != currentlyActive
        )
    }

    // MARK: - Top-level dispatch

    /// Top-level entry point. Honors the 5-minute manual-override window
    /// regardless of strategy: any decision within that window short-circuits
    /// to no-switch. Per-strategy logic runs only after the override check.
    static func decide(strategy: BalanceStrategy,
                       accounts: [Account],
                       states: [UUID: AccountState],
                       currentlyActive: UUID?,
                       lastManualSwitch: Date?,
                       trigger: BalanceTrigger,
                       now: Date = Date()) -> BalanceDecision {
        if let last = lastManualSwitch,
           now.timeIntervalSince(last) < overrideWindowSeconds {
            let remaining = Int(overrideWindowSeconds - now.timeIntervalSince(last))
            return BalanceDecision(
                recommendedAccountID: currentlyActive,
                currentAccountID: currentlyActive,
                scoreDiff: 0,
                reason: "skipped: manual override window active (\(remaining)s remaining)",
                triggerSource: trigger,
                shouldSwitch: false
            )
        }

        switch strategy {
        case .manual:
            return decideManual(currentlyActive: currentlyActive, trigger: trigger)
        case .prioritize(let preferredID, let threshold):
            return decidePrioritize(preferredID: preferredID, threshold: threshold,
                                    accounts: accounts, states: states,
                                    currentlyActive: currentlyActive, trigger: trigger)
        case .balance(let hysteresis):
            return decideBalance(hysteresis: hysteresis,
                                 accounts: accounts, states: states,
                                 currentlyActive: currentlyActive, trigger: trigger)
        }
    }
}
