import SwiftUI
import AppKit

// MARK: - Reset Detection, Notifications & Pace

/// Reset detection, toast/sound dispatch, and the rolling pace history. Extracted from
/// `UsageViewModel.swift` to keep each file focused on one responsibility.
extension UsageViewModel {

    /// Compares previous `resetsAt` timestamps to the new response to detect window resets.
    ///
    /// A window is considered reset (see `detectResets`) when its `resetsAt` jumped forward by
    /// more than an hour at under 5 % utilization, or — when `resets_at` came back null or the
    /// window left the response — once its stored reset time has passed at under 5 %.
    ///
    /// On the first fetch (`old == nil`) timestamps are recorded as a baseline without firing a notification.
    func checkForResets(accountID: UUID, old: UsageResponse?, new: UsageResponse) {
        // Bookkeeping runs even when nothing will be announced: a passed reset left in the
        // store would otherwise fire a stale toast once the account is active again.
        let (resetKeys, stored) = detectResets(stored: statesByAccount[accountID]?.previousResetsAt ?? [:],
                                               windows: new.trackedWindows, now: Date())
        statesByAccount[accountID, default: .init()].previousResetsAt = stored

        // Only fire reset notifications for the *active* account; idle accounts shouldn't
        // surface toasts/sounds for resets the user can't act on right now.
        guard old != nil, accountID == activeAccountID, resetSoundEnabled || notifyToast else { return }

        let windows = Dictionary(new.trackedWindows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let resets = resetKeys.map { windows[$0] ?? TrackedWindow(vanishedKey: $0) }.filter(isWatched).map(\.title)
        if !resets.isEmpty {
            dispatchNotifications(windows: resets)
        }
    }

    /// Whether a window's resets and pace are alerted on. The built-in windows follow their
    /// own toggles; per-model windows (legacy Sonnet + scoped limits) ride the 7-day toggle
    /// and additionally require "Show per-model usage" — a window first-class enough to
    /// pace-alert on should announce its reset too, and one that is hidden should do neither.
    private func isWatched(_ tracked: TrackedWindow) -> Bool {
        if tracked.isModelScoped { return notify7Day && showModelWindows }
        return tracked.key == MenuBarWindow.fiveHour.rawValue ? notify5Hour : notify7Day
    }

    // MARK: - Notification Dispatch

    private func dispatchNotifications(windows: [String]) {
        let title = String(localized: "Claude Usage Reset")
        // Locale list join ("A and B" / "A y B"), and a separate key for several windows:
        // Spanish inflects the verb ("se reinició" vs "se reiniciaron").
        let names = windows.formatted(.list(type: .and))
        let body = windows.count > 1
            ? String(format: String(localized: "%@ have reset — you're good to go!"), names)
            : String(format: String(localized: "%@ reset — you're good to go!"), names)

        if notifyToast       { ToastWindowController.shared.show(title: title, message: body, duration: toastDuration, permanent: toastPermanent) }
        if resetSoundEnabled { NSSound(named: .init("Hero"))?.play() }
    }

    /// Triggers a test reset notification through all currently enabled channels.
    func sendTestNotification() {
        dispatchNotifications(windows: [String(localized: "5-Hour Window")])
    }

    /// Triggers a test pace notification through all currently enabled pace channels.
    func sendTestPaceNotification() {
        _ = dispatchPaceAlert(name: MenuBarWindow.fiveHour.label, minsLeft: 25, rate: 45.0)
    }

    /// Fires a pace alert through the enabled pace channels. Returns the toast id when a
    /// toast was shown, so the caller can dismiss it once the pace improves.
    private func dispatchPaceAlert(name: String, minsLeft: Int, rate: Double) -> UUID? {
        let title = String(localized: "Approaching usage limit")
        let body  = String(format: String(localized: "%@ fills in %d min at %@"), name, minsLeft, paceRateUnit.format(rate))
        var toastID: UUID?
        if paceToastEnabled {
            toastID = ToastWindowController.shared.show(title: title, message: body,
                icon: "exclamationmark.triangle.fill", iconColor: .orange,
                duration: paceToastDuration, permanent: paceToastPermanent)
        }
        if paceSoundEnabled { NSSound(named: .init("Basso"))?.play() }
        return toastID
    }

    /// Dismisses a window's pace toast (if any) and re-arms its warning flag.
    private func clearPaceAlert(_ s: inout AccountState, key: String) {
        if let tid = s.paceToastIDs.removeValue(forKey: key) {
            ToastWindowController.shared.dismiss(id: tid)
        }
        s.paceWarned.remove(key)
    }

    // MARK: - Pace

    /// Appends the current utilization readings to the rolling history for each window.
    ///
    /// Readings older than 5 minutes are discarded. The history is cleared first when
    /// `shouldResetPaceHistory` says the window reset: a drop of more than 20 points, or a
    /// drop from ≥ 5 % to below 5 % (which catches resets the 20-point rule would miss).
    func recordHistory(accountID: UUID, response: UsageResponse) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-5 * 60)

        func append(key: String, utilization: Double?) {
            guard let utilization else { return }
            var s = statesByAccount[accountID] ?? .init()
            var history = s.utilizationHistory[key] ?? []
            if let last = history.last, shouldResetPaceHistory(last: last.1, current: utilization) {
                history = []
                clearPaceAlert(&s, key: key)
            }
            history.append((now, utilization))
            s.utilizationHistory[key] = history.filter { $0.0 >= cutoff }
            statesByAccount[accountID] = s
        }

        for tracked in response.trackedWindows {
            append(key: tracked.key, utilization: tracked.window.utilization)
        }
    }

    /// Fires a pace alert through all enabled channels when a watched window is on track to
    /// fill before it resets. Thin delegation: the per-window state machine (warn once per
    /// episode, hysteresis on re-arm, clearing unwatched windows) is the pure, tested
    /// `paceAlertStep` in Models.swift.
    func checkPaceNotifications(accountID: UUID, response: UsageResponse) {
        // Only the active account should trigger pace toasts/sounds.
        let isActive = (accountID == activeAccountID)

        guard notifyPace, isActive else {
            // Clearing paceWarned alone would leave a permanent toast on screen and
            // duplicate it on re-enable — dismiss and forget the toasts too.
            dismissPaceToasts(for: accountID)
            statesByAccount[accountID, default: .init()].paceWarned.removeAll()
            return
        }

        var s = statesByAccount[accountID] ?? .init()
        var candidates = response.trackedWindows.map { (key: $0.key, name: $0.title, watched: isWatched($0)) }
        // A window that left the response (a scoped limit entry gone, or a built-in window
        // the API nulled out — Team orgs null `five_hour` when idle) is cleared like an
        // unwatched one. Its warned flag used to linger when no toast was showing
        // (sound-only alerts), so the window never warned again once it came back.
        let present = Set(candidates.map(\.key))
        for key in Set(s.paceToastIDs.keys).union(s.paceWarned).subtracting(present).sorted() {
            candidates.append((key: key, name: key, watched: false))
        }

        for (key, name, watched) in candidates {
            let paceData = pace(accountID: accountID, key: key)
            let minutes = paceData?.projectedHours.map { $0 * 60 }
            let step = paceAlertStep(watched: watched, warned: s.paceWarned.contains(key),
                                     projectedMinutes: minutes, threshold: paceWarningMinutes)
            if step.dismiss, let tid = s.paceToastIDs.removeValue(forKey: key) {
                ToastWindowController.shared.dismiss(id: tid)
            }
            if step.fire, let paceData, let minutes,
               let tid = dispatchPaceAlert(name: name, minsLeft: max(1, Int(minutes)), rate: paceData.rate) {
                s.paceToastIDs[key] = tid
            }
            if step.warned { s.paceWarned.insert(key) } else { s.paceWarned.remove(key) }
        }
        statesByAccount[accountID] = s
    }

    /// Returns the current consumption rate and projected time to full for a window of the
    /// active account. View code calls this; internal callers that have an explicit account
    /// id should use `pace(accountID:key:)`.
    func pace(for key: String) -> (rate: Double, projectedHours: Double?)? {
        guard let id = activeAccountID else { return nil }
        return pace(accountID: id, key: key)
    }

    /// Variant that explicitly targets a specific account's history bucket.
    private func pace(accountID: UUID, key: String) -> (rate: Double, projectedHours: Double?)? {
        guard let history = statesByAccount[accountID]?.utilizationHistory[key] else { return nil }
        return computePace(history: history, lambda: 2.0)
    }

    /// Appends a chart snapshot for the account, enforcing the 5-minute sampling throttle,
    /// 30-day pruning, and the 8640-point cap (all in the pure `appendPrunedDataPoint`).
    func appendDataPoint(accountID: UUID, response: UsageResponse) {
        var s = statesByAccount[accountID] ?? .init()
        // Recorded regardless of the Charts tab's filter and the Usage tab's per-model
        // toggle: enabling a series later must not present an empty chart.
        var models: [String: Double] = [:]
        var modelPaces: [String: Double] = [:]
        func recordModel(key: String, utilization: Double) {
            models[key] = utilization
            if let rate = pace(accountID: accountID, key: key)?.rate { modelPaces[key] = rate }
        }
        for tracked in response.trackedWindows where tracked.isModelScoped {
            recordModel(key: tracked.key, utilization: tracked.window.utilization)
        }

        let point = UsageDataPoint(
            timestamp: Date(),
            fiveHour: response.fiveHour?.utilization,
            sevenDay: response.sevenDay?.utilization,
            fiveHourPace: pace(accountID: accountID, key: "five_hour")?.rate,
            sevenDayPace: pace(accountID: accountID, key: "seven_day")?.rate,
            // Empty dictionaries would cost bytes in every point stored by an account
            // whose response reports no model-scoped limits.
            models: models.isEmpty ? nil : models,
            modelPaces: modelPaces.isEmpty ? nil : modelPaces
        )
        // Throttle/prune/cap contract lives in the pure helper; nil means "sampled too soon".
        guard let history = appendPrunedDataPoint(point, to: s.usageHistory,
                                                  lastTimestamp: s.lastHistoryTimestamp) else { return }
        s.lastHistoryTimestamp = point.timestamp
        s.usageHistory = history
        statesByAccount[accountID] = s
        saveUsageHistory(history, for: accountID)
    }
}
