import SwiftUI
import AppKit
import Combine
import WebKit
import ServiceManagement

/// Central state for the app — owns API polling, UserDefaults persistence, and notification dispatch.
@Observable @MainActor
final class UsageViewModel {
    /// Owns the in-app update flow (check / download / auto-install). Views read
    /// `viewModel.updates.<x>`; SwiftUI's transitive `@Observable` tracking keeps them current.
    /// `var` (never reassigned) so `@Bindable`'s `$viewModel.updates.autoUpdate` resolves to a
    /// reference-writable key path for the Settings toggle.
    var updates = UpdateService()
    /// Which window's utilization the menu bar label tracks.
    var menuBarWindow: MenuBarWindow = .fiveHour {
        didSet {
            guard menuBarWindow != oldValue else { return }
            UserDefaults.standard.set(menuBarWindow.rawValue, forKey: PrefKey.menuBarWindow)
        }
    }
    var isLoading = false

    // MARK: - Multi-Account State

    /// All Claude accounts the user has added. Persisted via `AccountStore`.
    var accounts: [Account] = []
    /// UUID of the active account, or nil when the roster is empty. Persisted via `AccountStore`.
    var activeAccountID: UUID? = nil
    /// Per-account state buckets. Each fetch captures its `accountID` at start and writes to
    /// the corresponding bucket so the result lands in the right account even if the user
    /// switched accounts mid-fetch.
    var statesByAccount: [UUID: AccountState] = [:]
    /// True while the one-shot first-launch migration is copying the legacy `.default()`
    /// session into a per-identifier data store. The popover shows a loading state while true.
    var isMigrating: Bool = false

/// Active account's last fetched usage response. Read-only — fetch path writes to the
    /// per-account bucket directly so a mid-fetch account switch can't cross-contaminate state.
    var usage: UsageResponse? { activeState?.usage }
    /// Active account's last error message.
    var error: String? { activeState?.error }
    /// Active account's last successful fetch timestamp.
    var lastUpdated: Date? { activeState?.lastUpdated }
    /// Active account's account profile (display name, email, subscription label).
    var accountInfo: AccountInfo? { activeState?.accountInfo }
    /// True when an account is active and its session is healthy. False during migration,
    /// when no accounts exist, or when a 401 marked the active session expired.
    var isAuthenticated: Bool {
        guard !isMigrating, let id = activeAccountID else { return false }
        return statesByAccount[id]?.sessionExpired != true
    }

    /// Convenience: per-account bucket for the active account.
    private var activeState: AccountState? {
        activeAccountID.flatMap { statesByAccount[$0] }
    }

    // MARK: Notification preferences

    var notify5Hour: Bool = true {
        didSet { guard notify5Hour != oldValue else { return }; UserDefaults.standard.set(notify5Hour, forKey: PrefKey.notify5Hour) }
    }
    var notify7Day: Bool = false {
        didSet { guard notify7Day != oldValue else { return }; UserDefaults.standard.set(notify7Day, forKey: PrefKey.notify7Day) }
    }
    var notifyToast: Bool = true {
        didSet { guard notifyToast != oldValue else { return }; UserDefaults.standard.set(notifyToast, forKey: PrefKey.notifyToast) }
    }
    var resetSoundEnabled: Bool = false {
        didSet {
            guard resetSoundEnabled != oldValue else { return }
            UserDefaults.standard.set(resetSoundEnabled, forKey: PrefKey.notifySound)
            if resetSoundEnabled && isInitialized { NSSound(named: .init("Hero"))?.play() }
        }
    }
    var toastDuration: Double = 3.0 {
        didSet { guard toastDuration != oldValue else { return }; UserDefaults.standard.set(toastDuration, forKey: PrefKey.toastDuration) }
    }
    var toastPermanent: Bool = false {
        didSet { guard toastPermanent != oldValue else { return }; UserDefaults.standard.set(toastPermanent, forKey: PrefKey.toastPermanent) }
    }
    var paceToastEnabled: Bool = false {
        didSet { guard paceToastEnabled != oldValue else { return }; UserDefaults.standard.set(paceToastEnabled, forKey: PrefKey.paceToastEnabled) }
    }
    var paceSoundEnabled: Bool = false {
        didSet {
            guard paceSoundEnabled != oldValue else { return }
            UserDefaults.standard.set(paceSoundEnabled, forKey: PrefKey.paceSoundEnabled)
            if paceSoundEnabled && isInitialized { NSSound(named: .init("Basso"))?.play() }
        }
    }

    /// Whether the pace line is shown inside each window row in the popover.
    var showPace: Bool = true {
        didSet { guard showPace != oldValue else { return }; UserDefaults.standard.set(showPace, forKey: PrefKey.showPace) }
    }
    /// Whether the pace rate badge is shown in the menu bar alongside the utilization percentage.
    var showPaceMenuBar: Bool = true {
        didSet { guard showPaceMenuBar != oldValue else { return }; UserDefaults.standard.set(showPaceMenuBar, forKey: PrefKey.showPaceMenuBar) }
    }
    /// Time unit for displaying the consumption rate (per hour / per minute / per second).
    var paceRateUnit: PaceRateUnit = .perHour {
        didSet { guard paceRateUnit != oldValue else { return }; UserDefaults.standard.set(paceRateUnit.rawValue, forKey: PrefKey.paceRateUnit) }
    }
    /// Whether a notification fires when a watched window is projected to fill before it resets.
    var notifyPace: Bool = false {
        didSet { guard notifyPace != oldValue else { return }; UserDefaults.standard.set(notifyPace, forKey: PrefKey.notifyPace) }
    }
    /// Threshold in minutes: fire the pace alert when projected full time drops below this value.
    var paceWarningMinutes: Double = 30 {
        didSet { guard paceWarningMinutes != oldValue else { return }; UserDefaults.standard.set(paceWarningMinutes, forKey: PrefKey.paceWarningMinutes) }
    }
    /// Toast duration for pace alerts, independent of the reset-notification toast duration.
    var paceToastDuration: Double = 5.0 {
        didSet { guard paceToastDuration != oldValue else { return }; UserDefaults.standard.set(paceToastDuration, forKey: PrefKey.paceToastDuration) }
    }
    /// When `true`, pace alert toasts stay on screen until dismissed by the user.
    var paceToastPermanent: Bool = false {
        didSet { guard paceToastPermanent != oldValue else { return }; UserDefaults.standard.set(paceToastPermanent, forKey: PrefKey.paceToastPermanent) }
    }
    /// Multiplier applied to all spacing, padding, font sizes, and width in the popover.
    var popupScale: Double = 1.0 {
        didSet { guard popupScale != oldValue else { return }; UserDefaults.standard.set(popupScale, forKey: PrefKey.popupScale) }
    }
    /// Historical utilization snapshots for the active account's Chart tab.
    /// Per-account storage; persisted via `usageHistory.<accountID>` UserDefaults key.
    var usageHistory: [UsageDataPoint] {
        activeState?.usageHistory ?? []
    }
    /// Whether the Charts tab is shown in the popover.
    var showChartsTab: Bool = true {
        didSet { guard showChartsTab != oldValue else { return }; UserDefaults.standard.set(showChartsTab, forKey: PrefKey.showChartsTab) }
    }
    /// Whether per-model usage rows (legacy Sonnet sub-window + model-scoped limits such as
    /// Fable) are shown as extra progress bars in the popover.
    var showModelWindows: Bool = true {
        didSet { guard showModelWindows != oldValue else { return }; UserDefaults.standard.set(showModelWindows, forKey: PrefKey.showModelWindows) }
    }
    /// Whether absolute reset times render as 24-hour (true) or AM/PM (false).
    var use24HourTime: Bool = false {
        didSet { guard use24HourTime != oldValue else { return }; UserDefaults.standard.set(use24HourTime, forKey: PrefKey.use24HourTime) }
    }
    /// Whether the app registers itself as a login item so it starts when the user logs in.
    /// The `isInitialized` guard keeps `loadPersistedPreferences()` from touching
    /// `SMAppService` during `init` — registration side effects belong to `start()` and
    /// user toggles only.
    var launchAtLogin: Bool = true {
        didSet {
            guard isInitialized, launchAtLogin != oldValue else { return }
            UserDefaults.standard.set(launchAtLogin, forKey: PrefKey.launchAtLogin)
            applyLaunchAtLogin()
        }
    }

    @ObservationIgnored private var isInitialized = false
    /// API service for the active account. nil before the first account is built or during migration.
    /// Public name kept as `apiService` so existing call sites compile; `var` because the service
    /// is rebuilt against a different `WKWebsiteDataStore` whenever the active account changes.
    @ObservationIgnored var apiService: ClaudeAPIService?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var appearanceCancellable: AnyCancellable?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored var sessionTask: Task<Void, Never>?
    /// Avoids rebuilding `menuBarImage` when neither the icon name nor the status text has
    /// changed. Internal so the `UsageViewModelMenuBar.swift` extension can read/write.
    /// `@ObservationIgnored` is mandatory: the `menuBarImage` getter runs inside the
    /// `MenuBarExtra` label's body, and writing an observed property there schedules an
    /// immediate second render of every menu bar update.
    @ObservationIgnored var cachedMenuBarKey = ""
    @ObservationIgnored var cachedMenuBarImage = NSImage()
    /// Observed render trigger for the menu bar label. Because the caches above are
    /// unobserved, bumping this version is the signal that forces `MenuBarExtra` to
    /// re-read `menuBarImage` after an appearance change or account switch.
    private(set) var menuBarImageVersion = 0

    /// Clears the menu bar image cache and pokes the observed version so the label redraws.
    func invalidateMenuBarImage() {
        cachedMenuBarKey = ""
        menuBarImageVersion += 1
    }

    init() {
        loadPersistedPreferences()
        isInitialized = true
    }

    /// Performs all side-effecting startup work: the wake observer, account load + polling,
    /// the update service, and the appearance subscription. Kept out of `init` so a bare
    /// `UsageViewModel()` can be constructed in tests without spawning network tasks,
    /// observers, or the legacy-session migration. Called once from `ClaudeTrackerApp`.
    func start() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                AppLogger.shared.info("wake detected — scheduling usage fetch and update check")
                try? await Task.sleep(for: .seconds(5))
                self?.fetchUsage()
                try? await Task.sleep(for: .seconds(25))
                self?.updates.checkForUpdates()
            }
        }

        loadAccountsAndStartActive()
        updates.start()
        syncLaunchAtLogin()

        // `NSApp` is nil at this point on macOS 26 because `UsageViewModel` is allocated as a
        // `@State` initializer inside `ClaudeTrackerApp.init`, before `NSApplication.shared`
        // exists. Defer the appearance subscription onto the next main-actor turn so it lands
        // after the app is up. (Implicit unwrap of `NSApp` here used to work on earlier
        // macOS versions.) The sink body hops back to the main actor explicitly so the
        // nonisolated Combine closure never touches actor state directly.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appearanceCancellable = NSApp.publisher(for: \.effectiveAppearance)
                .dropFirst()
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.invalidateMenuBarImage() }
                }
        }
    }

    /// Reconciles the login-item registration with the preference at startup. First launch
    /// with this feature (no stored pref) opts in by default. If the user later removed the
    /// login item in System Settings, the toggle follows the system state instead of
    /// re-registering behind their back.
    private func syncLaunchAtLogin() {
        if UserDefaults.standard.object(forKey: PrefKey.launchAtLogin) == nil {
            UserDefaults.standard.set(true, forKey: PrefKey.launchAtLogin)
            applyLaunchAtLogin()
        } else if launchAtLogin && SMAppService.mainApp.status == .notRegistered {
            launchAtLogin = false
        }
    }

    /// Registers or unregisters the app as a login item to match `launchAtLogin`.
    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
                AppLogger.shared.info("launch at login registered")
            } else {
                try SMAppService.mainApp.unregister()
                AppLogger.shared.info("launch at login unregistered")
            }
        } catch {
            // Unregistering an item the user already removed in System Settings throws;
            // that's the expected no-op path of syncLaunchAtLogin, so log at info level.
            AppLogger.shared.info("launch at login \(launchAtLogin ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    private func loadPersistedPreferences() {
        if let savedWindow = UserDefaults.standard.string(forKey: PrefKey.menuBarWindow),
           let window = MenuBarWindow(rawValue: savedWindow) {
            menuBarWindow = window
        }

        // Version 2 migration: resets any earlier installation that may have had sound and banner
        // enabled by default to the current toast-only defaults.
        if UserDefaults.standard.integer(forKey: PrefKey.notificationDefaultsVersion) < 2 {
            UserDefaults.standard.set(false, forKey: PrefKey.notifySound)
            UserDefaults.standard.set(true,  forKey: PrefKey.notifyToast)
            UserDefaults.standard.set(true,  forKey: PrefKey.notify5Hour)
            UserDefaults.standard.set(false, forKey: PrefKey.notify7Day)
            UserDefaults.standard.set(2, forKey: PrefKey.notificationDefaultsVersion)
        }

        resetSoundEnabled = UserDefaults.standard.object(forKey: PrefKey.notifySound)       as? Bool ?? false
        notifyToast       = UserDefaults.standard.object(forKey: PrefKey.notifyToast)       as? Bool ?? true
        notify5Hour       = UserDefaults.standard.object(forKey: PrefKey.notify5Hour)       as? Bool ?? true
        notify7Day        = UserDefaults.standard.object(forKey: PrefKey.notify7Day)        as? Bool ?? false
        let savedDuration = UserDefaults.standard.double(forKey: PrefKey.toastDuration)
        toastDuration  = savedDuration > 0 ? savedDuration : 3.0
        toastPermanent = UserDefaults.standard.object(forKey: PrefKey.toastPermanent)       as? Bool ?? false
        showPace       = UserDefaults.standard.object(forKey: PrefKey.showPace)             as? Bool ?? true
        showPaceMenuBar = UserDefaults.standard.object(forKey: PrefKey.showPaceMenuBar)     as? Bool ?? true
        if let raw = UserDefaults.standard.string(forKey: PrefKey.paceRateUnit),
           let saved = PaceRateUnit(rawValue: raw) { paceRateUnit = saved }
        notifyPace     = UserDefaults.standard.object(forKey: PrefKey.notifyPace)           as? Bool ?? false
        let savedWarning = UserDefaults.standard.double(forKey: PrefKey.paceWarningMinutes)
        paceWarningMinutes = savedWarning > 0 ? savedWarning : 30
        paceToastEnabled   = UserDefaults.standard.object(forKey: PrefKey.paceToastEnabled) as? Bool ?? false
        let savedPaceDuration = UserDefaults.standard.double(forKey: PrefKey.paceToastDuration)
        paceToastDuration  = savedPaceDuration > 0 ? savedPaceDuration : 5.0
        paceToastPermanent = UserDefaults.standard.object(forKey: PrefKey.paceToastPermanent) as? Bool ?? false
        paceSoundEnabled   = UserDefaults.standard.object(forKey: PrefKey.paceSoundEnabled) as? Bool ?? false
        // v1: rebase — old 1.0 was the original size; new 1.0 matches old 1.1 (base constants grew ×1.1).
        // Reset any saved scale so existing users see the new default appearance unchanged.
        if UserDefaults.standard.object(forKey: PrefKey.popupScaleRebased) == nil {
            UserDefaults.standard.set(1.0, forKey: PrefKey.popupScale)
            UserDefaults.standard.set(1, forKey: PrefKey.popupScaleRebased)
        }
        let savedPopupScale = UserDefaults.standard.double(forKey: PrefKey.popupScale)
        popupScale = savedPopupScale > 0 ? savedPopupScale : 1.0

        launchAtLogin = UserDefaults.standard.object(forKey: PrefKey.launchAtLogin) as? Bool ?? true
        showChartsTab = UserDefaults.standard.object(forKey: PrefKey.showChartsTab) as? Bool ?? true
        showModelWindows = UserDefaults.standard.object(forKey: PrefKey.showModelWindows) as? Bool ?? true
        if let saved24h = UserDefaults.standard.object(forKey: PrefKey.use24HourTime) as? Bool {
            use24HourTime = saved24h
        } else {
            // Fresh install / pre-feature install: seed from the system convention and persist
            // immediately — the didSet skips the write when the seed equals the default (false),
            // which would otherwise re-seed from the live locale on every launch.
            use24HourTime = prefers24HourClock(Locale.current)
            UserDefaults.standard.set(use24HourTime, forKey: PrefKey.use24HourTime)
        }
        // Legacy `usageHistory` (single-account) is migrated into the per-account namespace
        // by `migrateLegacySessionIfPresent`; do not load it here.
        // Update preferences (autoUpdate, lastNotifiedUpdateVersion, updateCheckInterval) are
        // loaded by `UpdateService.start()`.
    }

    // MARK: - In-Flight Work

    /// Cancels the fetch/session tasks and the poll timer. Internal so the account
    /// lifecycle methods (UsageViewModelAccounts.swift) can call it.
    func cancelInFlightWork() {
        fetchTask?.cancel(); fetchTask = nil
        sessionTask?.cancel(); sessionTask = nil
        timer?.cancel(); timer = nil
        isLoading = false
    }

    // MARK: - Polling

    /// Cancels any existing timer and starts a fresh adaptive polling cycle for the active account.
    func startPolling() {
        timer?.cancel()
        timer = nil
        guard let id = activeAccountID else { return }
        statesByAccount[id, default: .init()].consecutiveErrors = 0
        guard isAuthenticated else { return }
        fetchUsage()
    }

    /// Fetches the latest usage data for the active account, detects resets, and schedules the
    /// next adaptive poll. The account ID is captured at task start so a mid-fetch account
    /// switch deposits the response into the right bucket (and the next active poll triggers
    /// independently for the new account).
    func fetchUsage() {
        guard isAuthenticated, let id = activeAccountID, let svc = apiService else { return }
        if isDataStale { AppLogger.shared.info("fetchUsage: refreshing stale data (resetsAt passed since last fetch)") }
        fetchTask?.cancel()
        isLoading = true
        fetchTask = Task { [weak self] in
            guard let self else { return }
            var shouldSchedule = false
            do {
                let response = try await svc.fetchUsage()
                guard !Task.isCancelled else { return }
                let oldUsage = statesByAccount[id]?.usage
                logSeverityTransition(old: oldUsage, new: response)
                checkForResets(accountID: id, old: oldUsage, new: response)
                recordHistory(accountID: id, response: response)
                appendDataPoint(accountID: id, response: response)
                checkPaceNotifications(accountID: id, response: response)
                // Batch the bucket writes into one dictionary store — each separate
                // subscript-write is a full read-modify-write plus an @Observable
                // mutation on a path polled as often as every second.
                var s = statesByAccount[id] ?? .init()
                s.usage = response
                s.error = nil
                s.lastUpdated = Date()
                s.consecutiveErrors = 0
                s.consecutive401s = 0
                s.sessionExpired = false
                statesByAccount[id] = s
                if let name = svc.cachedOrgName { applyOrgNameToRoster(id: id, orgName: name) }
                shouldSchedule = true
            } catch let err as ClaudeAPIService.APIError {
                guard !Task.isCancelled else { return }
                let n = (statesByAccount[id]?.consecutiveErrors ?? 0) + 1
                statesByAccount[id, default: .init()].consecutiveErrors = n
                AppLogger.shared.error("fetchUsage APIError (#\(n)): \(err.localizedDescription)")
                statesByAccount[id, default: .init()].error = err.localizedDescription
                if case .unauthorized = err {
                    // Counted separately from `consecutiveErrors`: a transient error on
                    // the previous poll must not make the first 401 look like a second.
                    let auth401s = (statesByAccount[id]?.consecutive401s ?? 0) + 1
                    statesByAccount[id, default: .init()].consecutive401s = auth401s
                    if auth401s > 1 {
                        statesByAccount[id, default: .init()].sessionExpired = true
                        timer?.cancel(); timer = nil
                    } else {
                        // First 401: mapJSError already cleared isPageReady;
                        // next poll reloads the page and retries automatically.
                        shouldSchedule = true
                    }
                } else {
                    statesByAccount[id, default: .init()].consecutive401s = 0
                    shouldSchedule = true
                }
            } catch let err as DecodingError {
                guard !Task.isCancelled else { return }
                let n = (statesByAccount[id]?.consecutiveErrors ?? 0) + 1
                statesByAccount[id, default: .init()].consecutiveErrors = n
                statesByAccount[id, default: .init()].consecutive401s = 0
                AppLogger.shared.error("fetchUsage decode error (#\(n)): \(err)")
                // A raw DecodingError string is useless to the user — the payload head is
                // already in the log (ClaudeAPIService logs it before rethrowing).
                statesByAccount[id, default: .init()].error =
                    String(localized: "claude.ai API format changed — check for app updates")
                shouldSchedule = true
            } catch {
                guard !Task.isCancelled else { return }
                let n = (statesByAccount[id]?.consecutiveErrors ?? 0) + 1
                statesByAccount[id, default: .init()].consecutiveErrors = n
                statesByAccount[id, default: .init()].consecutive401s = 0
                AppLogger.shared.error("fetchUsage unexpected error (#\(n)): \(error)")
                statesByAccount[id, default: .init()].error = error.localizedDescription
                shouldSchedule = true
            }
            // Only flip the spinner off if this fetch was for the still-active account.
            if id == activeAccountID { isLoading = false }
            if shouldSchedule, id == activeAccountID { scheduleNextPoll() }
        }
    }

    /// Only "normal" limit severity has been observed so far; log transitions to anything
    /// else so the field's semantics can be learned from the field before building UI on it.
    /// Thin delegation — the signature logic is the pure, tested `abnormalSeverities`
    /// in Models.swift.
    private func logSeverityTransition(old: UsageResponse?, new: UsageResponse) {
        let sig = abnormalSeverities(new.limits)
        if !sig.isEmpty, sig != abnormalSeverities(old?.limits) {
            AppLogger.shared.info("limit severity: \(sig)")
        }
    }

/// Schedules the next poll after an adaptive delay derived from current utilization and pace.
    ///
    /// Interval logic (per window, takes the minimum across both windows):
    ///   - Window stale (reset passed while app was idle): 2 s — catch the new window fast
    ///   - Utilization ≥ 100% and reset time known: 10–300 s based on time until reset
    ///   - Utilization < 100% with pace: 1–10 s based on projected minutes to full
    ///   - Utilization < 100% without pace: 3–10 s based on utilization level
    ///   Backoff adds min(consecutiveErrors × 10, 60) s on top.
    private func scheduleNextPoll() {
        guard let id = activeAccountID else { return }
        timer?.cancel()
        let base = computeAdaptiveInterval()
        let errs = statesByAccount[id]?.consecutiveErrors ?? 0
        let backoff = errorBackoff(consecutiveErrors: errs)
        let interval = base + backoff
        if errs > 0 {
            let stem = (error ?? "Error").components(separatedBy: " (retry in ").first ?? "Error"
            statesByAccount[id, default: .init()].error = String(format: String(localized: "%@ (retry in %ds)"), stem, Int(interval))
        }
        AppLogger.shared.info("poll: next in \(String(format: "%.1f", interval))s (base=\(String(format: "%.1f", base))s util=\(String(format: "%.0f", maxUtilization))%)")
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.fetchUsage() }
        }
    }

    /// Computes the adaptive polling interval from the most urgent active window.
    private func computeAdaptiveInterval() -> TimeInterval {
        guard let usage else { return 10 }
        let fh = intervalForWindow(key: "five_hour", window: usage.fiveHour)
        let sd = intervalForWindow(key: "seven_day",  window: usage.sevenDay)
        return min(fh, sd)
    }

    /// Computes the polling interval for a single usage window. The tier logic lives in
    /// the pure `pollInterval(utilization:resetsAt:projectedMinutes:now:)` in Models.swift.
    private func intervalForWindow(key: String, window: UsageWindow?) -> TimeInterval {
        guard let window else { return 10 }
        let projMins = pace(for: key)?.projectedHours.map { $0 * 60 }
        return pollInterval(utilization: window.utilization,
                            resetsAt: window.resetsAtDate,
                            projectedMinutes: projMins)
    }

    func intervalForProjMins(_ projMins: Double) -> TimeInterval {
        pollIntervalForProjectedMinutes(projMins)
    }

    // MARK: - Computed State

    /// Highest utilization across the 5-hour and 7-day windows.
    var maxUtilization: Double {
        [usage?.fiveHour, usage?.sevenDay]
            .compactMap { $0?.utilization }
            .max() ?? 0
    }

    /// Utilization of the window the user has selected for the menu bar label.
    var displayedUtilization: Double {
        guard let usage else { return 0 }
        switch menuBarWindow {
        case .fiveHour: return usage.fiveHour?.utilization ?? 0
        case .sevenDay:  return usage.sevenDay?.utilization  ?? 0
        }
    }

    /// True when the stored `usage` was fetched before a window's `resetsAt` time that has
    /// now passed — meaning the displayed utilization belongs to the previous window cycle
    /// and is definitively wrong. Clears automatically once a fresh fetch succeeds.
    var isDataStale: Bool {
        guard let usage, let lastUpdated else { return false }
        let now = Date()
        return [usage.fiveHour, usage.sevenDay].compactMap { $0 }.contains { window in
            windowIsStale(resetsAt: window.resetsAtDate, lastUpdated: lastUpdated, now: now)
        }
    }

    func isWindowStale(_ window: UsageWindow) -> Bool {
        windowIsStale(resetsAt: window.resetsAtDate, lastUpdated: lastUpdated, now: Date())
    }

    var statusText: String {
        guard isAuthenticated else { return "–" }
        guard usage != nil else { return error != nil ? "!" : "…" }
        if isDataStale { return "…" }
        return "\(Int(displayedUtilization))%"
    }

    var statusIcon: String {
        if isDataStale { return "bolt.fill" }
        let effectiveUrgency = max(displayedUtilization / 100.0, displayedWindowPaceUrgency())
        if effectiveUrgency >= 0.8 { return "exclamationmark.triangle.fill" }
        if effectiveUrgency >= 0.5 { return "bolt.badge.clock.fill" }
        return "bolt.fill"
    }

    var statusColor: NSColor {
        guard isAuthenticated, usage != nil, !isDataStale else { return .labelColor }
        let effectiveUrgency = max(displayedUtilization / 100.0, displayedWindowPaceUrgency())
        return urgencyNSColor(effectiveUrgency)
    }

    func urgencyNSColor(_ urgency: Double) -> NSColor {
        let t = max(0, min(1, urgency))
        return NSColor(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.9, alpha: 1.0)
    }

    func displayedWindowPaceUrgency() -> Double {
        let key: String
        let window: UsageWindow?
        switch menuBarWindow {
        case .fiveHour: key = "five_hour"; window = usage?.fiveHour
        case .sevenDay:  key = "seven_day";  window = usage?.sevenDay
        }
        guard let paceData = pace(for: key),
              let proj = paceData.projectedHours,
              proj > 0,
              let resetDate = window?.resetsAtDate else { return 0 }
        let hoursToReset = resetDate.timeIntervalSinceNow / 3600
        guard hoursToReset > 0 else { return 0 }
        return min(hoursToReset / proj, 1.0)
    }

}
