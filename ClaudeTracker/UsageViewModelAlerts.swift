import SwiftUI
import AppKit

// MARK: - Reset Detection, Notifications & Pace

/// Reset detection, toast/sound dispatch, and the rolling pace history. Extracted from
/// `UsageViewModel.swift` to keep each file focused on one responsibility.
extension UsageViewModel {

    /// Compares previous `resetsAt` timestamps to the new response to detect window resets.
    ///
    /// A window is considered reset when both of the following hold (see `isWindowReset`):
    /// - The `resetsAt` timestamp jumped forward by more than an hour (the server issued a
    ///   new window period — plain inequality would fire on rolling-expiry timestamp noise), and
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

        for tracked in new.trackedWindows where isWatched(tracked) {
            if let oldDate = prev[tracked.key],
               let newDate = tracked.window.resetsAtDate,
               isWindowReset(previous: oldDate, next: newDate, utilization: tracked.window.utilization) {
                resets.append(tracked.title)
            }
        }

        recordResetsAt(accountID: accountID, response: new)

        if !resets.isEmpty {
            dispatchNotifications(windows: resets)
        }
    }

    private func recordResetsAt(accountID: UUID, response: UsageResponse) {
        for tracked in response.trackedWindows {
            if let d = tracked.window.resetsAtDate {
                statesByAccount[accountID, default: .init()].previousResetsAt[tracked.key] = d
            }
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
    /// fill before it resets. Each window triggers at most one alert per concerning episode:
    /// the warned flag re-arms when the pace improves past the threshold (so a later
    /// re-acceleration in the same window warns again) and on window reset.
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

        let candidates = response.trackedWindows.map { (key: $0.key, name: $0.title, watched: isWatched($0)) }

        for (key, name, watched) in candidates {
            guard watched else {
                // A window that just became unwatched (e.g. "Show per-model usage"
                // toggled off) must not strand its toast on screen or stay warned.
                var s = statesByAccount[accountID] ?? .init()
                clearPaceAlert(&s, key: key)
                statesByAccount[accountID] = s
                continue
            }
            let paceData = pace(accountID: accountID, key: key)
            let isConcerning = paceData.flatMap(\.projectedHours).map { $0 * 60 < paceWarningMinutes } ?? false
            var s = statesByAccount[accountID] ?? .init()
            if isConcerning, !s.paceWarned.contains(key), let pd = paceData, let projHours = pd.projectedHours {
                s.paceWarned.insert(key)
                if let tid = dispatchPaceAlert(name: name, minsLeft: max(1, Int(projHours * 60)), rate: pd.rate) {
                    s.paceToastIDs[key] = tid
                }
            } else if !isConcerning, s.paceWarned.contains(key) {
                // Pace improved past the threshold — dismiss the alert even if set to
                // permanent, and re-arm so a later re-acceleration in the same window
                // can warn again (previously the flag stayed set for the whole window).
                if let tid = s.paceToastIDs.removeValue(forKey: key) {
                    ToastWindowController.shared.dismiss(id: tid)
                }
                // Re-arm only once the projection clears the threshold with 25% margin
                // (or pace vanished): the 5-minute regression jitters, and re-arming at
                // the exact boundary would re-fire toast + sound every few polls.
                let projMinutes = paceData.flatMap(\.projectedHours).map { $0 * 60 }
                if paceData == nil || (projMinutes ?? .infinity) > paceWarningMinutes * 1.25 {
                    s.paceWarned.remove(key)
                }
            }
            statesByAccount[accountID] = s
        }

        // A toast for a window that vanished from the response (a scoped limit entry gone,
        // or a built-in window the API nulled out — Team orgs null `five_hour` when idle)
        // never reaches the improvement branch above — sweep it here so it can re-arm.
        var s = statesByAccount[accountID] ?? .init()
        let candidateKeys = Set(candidates.map(\.key))
        for key in s.paceToastIDs.keys where !candidateKeys.contains(key) {
            clearPaceAlert(&s, key: key)
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
