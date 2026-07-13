import SwiftUI
import AppKit

// MARK: - Reset Detection, Notifications & Pace

/// Reset detection, toast/sound dispatch, and the rolling pace history. Extracted from
/// `UsageViewModel.swift` to keep each file focused on one responsibility.
extension UsageViewModel {

    /// Compares previous `resetsAt` timestamps to the new response to detect window resets.
    ///
    /// A window is considered reset when both of the following hold:
    /// - The `resetsAt` timestamp has changed (the server issued a new window period), and
    /// - Utilization has dropped below 5 % (guards against a timestamp refresh without an actual reset).
    ///
    /// On the first fetch (`old == nil`) timestamps are recorded as a baseline without firing a notification.
    func checkForResets(accountID: UUID, old: UsageResponse?, new: UsageResponse) {
        guard old != nil else {
            recordResetsAt(accountID: accountID, response: new)
            return
        }

        // Only fire reset notifications for the *active* account; idle accounts shouldn't
        // surface toasts/sounds for resets the user can't act on right now.
        let isActive = (accountID == activeAccountID)

        guard isActive, resetSoundEnabled || notifyToast else {
            recordResetsAt(accountID: accountID, response: new)
            return
        }

        let prev = statesByAccount[accountID]?.previousResetsAt ?? [:]
        var resets: [String] = []

        if notify5Hour,
           let oldDate = prev["five_hour"],
           let newWindow = new.fiveHour,
           let newDate = newWindow.resetsAtDate,
           isWindowReset(previous: oldDate, next: newDate, utilization: newWindow.utilization) {
            resets.append(String(localized: "5-Hour Window"))
        }

        if notify7Day,
           let oldDate = prev["seven_day"],
           let newWindow = new.sevenDay,
           let newDate = newWindow.resetsAtDate,
           isWindowReset(previous: oldDate, next: newDate, utilization: newWindow.utilization) {
            resets.append(String(localized: "7-Day Window"))
        }

        recordResetsAt(accountID: accountID, response: new)

        if !resets.isEmpty {
            dispatchNotifications(windows: resets)
        }
    }

    private func recordResetsAt(accountID: UUID, response: UsageResponse) {
        if let w = response.fiveHour, let d = w.resetsAtDate {
            statesByAccount[accountID, default: .init()].previousResetsAt["five_hour"] = d
        }
        if let w = response.sevenDay, let d = w.resetsAtDate {
            statesByAccount[accountID, default: .init()].previousResetsAt["seven_day"] = d
        }
    }

    // MARK: - Notification Dispatch

    private func dispatchNotifications(windows: [String]) {
        let title = String(localized: "Claude Usage Reset")
        let body  = String(format: String(localized: "%@ reset — you're good to go!"), windows.joined(separator: " & "))

        if notifyToast       { ToastWindowController.shared.show(title: title, message: body, duration: toastDuration, permanent: toastPermanent) }
        if resetSoundEnabled { NSSound(named: .init("Hero"))?.play() }
    }

    /// Triggers a test reset notification through all currently enabled channels.
    func sendTestNotification() {
        dispatchNotifications(windows: [String(localized: "5-Hour Window")])
    }

    /// Triggers a test pace notification through all currently enabled pace channels.
    func sendTestPaceNotification() {
        let title = String(localized: "Approaching usage limit")
        let body  = String(format: String(localized: "%@ fills in %d min at %@"),
                           String(localized: "5-Hour Window"), 25, paceRateUnit.format(45.0))
        if paceToastEnabled {
            ToastWindowController.shared.show(title: title, message: body,
                icon: "exclamationmark.triangle.fill", iconColor: .orange,
                duration: paceToastDuration, permanent: paceToastPermanent)
        }
        if paceSoundEnabled { NSSound(named: .init("Basso"))?.play() }
    }

    // MARK: - Pace

    /// Appends the current utilization readings to the rolling history for each window.
    ///
    /// Readings older than 5 minutes are discarded. If utilization for a window drops by
    /// more than 20 percentage points compared to the last recorded value, the history is
    /// cleared first — this handles window resets, which drop utilization back to near zero.
    func recordHistory(accountID: UUID, response: UsageResponse) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-5 * 60)

        func append(key: String, utilization: Double?) {
            guard let utilization else { return }
            var s = statesByAccount[accountID] ?? .init()
            var history = s.utilizationHistory[key] ?? []
            if let last = history.last, shouldResetPaceHistory(last: last.1, current: utilization) {
                history = []
                s.paceWarned.remove(key)
                if let tid = s.paceToastIDs.removeValue(forKey: key) {
                    ToastWindowController.shared.dismiss(id: tid)
                }
            }
            history.append((now, utilization))
            s.utilizationHistory[key] = history.filter { $0.0 >= cutoff }
            statesByAccount[accountID] = s
        }

        append(key: "five_hour",        utilization: response.fiveHour?.utilization)
        append(key: "seven_day",         utilization: response.sevenDay?.utilization)
        append(key: "seven_day_sonnet",  utilization: response.sevenDaySonnet?.utilization)
        for scoped in response.scopedModelWindows {
            append(key: scoped.paceKey, utilization: scoped.window.utilization)
        }
    }

    /// Fires a pace alert through all enabled channels when a watched window is on track to
    /// fill before it resets. Each window can only trigger one alert per window period;
    /// the warned flag resets automatically when utilization drops (i.e. the window resets).
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

        var candidates: [(key: String, name: String, watched: Bool)] = [
            ("five_hour",        String(localized: "5-Hour Window"), notify5Hour),
            ("seven_day",        String(localized: "7-Day Window"),  notify7Day),
            ("seven_day_sonnet", String(localized: "7-Day Sonnet"),  notify7Day && showModelWindows),
        ]
        for scoped in response.scopedModelWindows {
            candidates.append((scoped.paceKey,
                               String(format: String(localized: "7-Day %@"), scoped.label),
                               notify7Day && showModelWindows))
        }

        for (key, name, watched) in candidates {
            guard watched else { continue }
            let paceData = pace(accountID: accountID, key: key)
            let isConcerning = paceData.flatMap(\.projectedHours).map { $0 * 60 < paceWarningMinutes } ?? false
            var s = statesByAccount[accountID] ?? .init()
            if isConcerning, !s.paceWarned.contains(key), let pd = paceData, let projHours = pd.projectedHours {
                s.paceWarned.insert(key)
                let minsLeft = max(1, Int(projHours * 60))
                let title = String(localized: "Approaching usage limit")
                let body  = String(format: String(localized: "%@ fills in %d min at %@"), name, minsLeft, paceRateUnit.format(pd.rate))
                if paceToastEnabled {
                    s.paceToastIDs[key] = ToastWindowController.shared.show(title: title, message: body,
                        icon: "exclamationmark.triangle.fill", iconColor: .orange,
                        duration: paceToastDuration, permanent: paceToastPermanent)
                }
                if paceSoundEnabled { NSSound(named: .init("Basso"))?.play() }
            } else if !isConcerning, s.paceWarned.contains(key) {
                // Pace improved past the threshold — dismiss the alert even if set to permanent.
                if let tid = s.paceToastIDs.removeValue(forKey: key) {
                    ToastWindowController.shared.dismiss(id: tid)
                }
                if paceData == nil { s.paceWarned.remove(key) }
            }
            statesByAccount[accountID] = s
        }

        // A scoped toast whose limit entry vanished from the response never reaches the
        // improvement branch above (its key drops out of the candidates) — sweep it here.
        var s = statesByAccount[accountID] ?? .init()
        let candidateKeys = Set(candidates.map(\.key))
        for key in s.paceToastIDs.keys where key.hasPrefix("scoped.") && !candidateKeys.contains(key) {
            if let tid = s.paceToastIDs.removeValue(forKey: key) {
                ToastWindowController.shared.dismiss(id: tid)
            }
            s.paceWarned.remove(key)
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
        let point = UsageDataPoint(
            timestamp: Date(),
            fiveHour: response.fiveHour?.utilization,
            sevenDay: response.sevenDay?.utilization,
            fiveHourPace: pace(accountID: accountID, key: "five_hour")?.rate,
            sevenDayPace: pace(accountID: accountID, key: "seven_day")?.rate
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
