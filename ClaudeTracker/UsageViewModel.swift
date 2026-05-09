import SwiftUI
import AppKit
import Combine
import WebKit

enum UpdateDownloadState {
    case idle
    case downloading
    case installing
    case failed(String)
}

/// Central state for the app — owns API polling, UserDefaults persistence, and notification dispatch.
@Observable @MainActor
final class UsageViewModel {
    var availableUpdate: UpdateInfo? = nil
    var isCheckingForUpdates = false
    var updateDownloadState: UpdateDownloadState = .idle
    var autoUpdate: Bool = false {
        didSet {
            guard autoUpdate != oldValue else { return }
            UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate")
            schedulePeriodicUpdateCheck()
        }
    }
    /// Which window's utilization the menu bar label tracks.
    var menuBarWindow: MenuBarWindow = .fiveHour {
        didSet {
            guard menuBarWindow != oldValue else { return }
            UserDefaults.standard.set(menuBarWindow.rawValue, forKey: "menuBarWindow")
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
    var error: String? {
        get { activeState?.error }
        set {
            guard let id = activeAccountID else { return }
            statesByAccount[id, default: .init()].error = newValue
        }
    }
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
        didSet { guard notify5Hour != oldValue else { return }; UserDefaults.standard.set(notify5Hour, forKey: "notify5Hour") }
    }
    var notify7Day: Bool = false {
        didSet { guard notify7Day != oldValue else { return }; UserDefaults.standard.set(notify7Day, forKey: "notify7Day") }
    }
    var notifyToast: Bool = true {
        didSet { guard notifyToast != oldValue else { return }; UserDefaults.standard.set(notifyToast, forKey: "notifyToast") }
    }
    var resetSoundEnabled: Bool = false {
        didSet {
            guard resetSoundEnabled != oldValue else { return }
            UserDefaults.standard.set(resetSoundEnabled, forKey: "notifySound")
            if resetSoundEnabled && isInitialized { NSSound(named: .init("Hero"))?.play() }
        }
    }
    var toastDuration: Double = 3.0 {
        didSet { guard toastDuration != oldValue else { return }; UserDefaults.standard.set(toastDuration, forKey: "toastDuration") }
    }
    var toastPermanent: Bool = false {
        didSet { guard toastPermanent != oldValue else { return }; UserDefaults.standard.set(toastPermanent, forKey: "toastPermanent") }
    }
    var paceToastEnabled: Bool = false {
        didSet { guard paceToastEnabled != oldValue else { return }; UserDefaults.standard.set(paceToastEnabled, forKey: "paceToastEnabled") }
    }
    var paceSoundEnabled: Bool = false {
        didSet {
            guard paceSoundEnabled != oldValue else { return }
            UserDefaults.standard.set(paceSoundEnabled, forKey: "paceSoundEnabled")
            if paceSoundEnabled && isInitialized { NSSound(named: .init("Basso"))?.play() }
        }
    }

    /// Whether the pace line is shown inside each window row in the popover.
    var showPace: Bool = true {
        didSet { guard showPace != oldValue else { return }; UserDefaults.standard.set(showPace, forKey: "showPace") }
    }
    /// Whether the pace rate badge is shown in the menu bar alongside the utilization percentage.
    var showPaceMenuBar: Bool = true {
        didSet { guard showPaceMenuBar != oldValue else { return }; UserDefaults.standard.set(showPaceMenuBar, forKey: "showPaceMenuBar") }
    }
    /// Time unit for displaying the consumption rate (per hour / per minute / per second).
    var paceRateUnit: PaceRateUnit = .perHour {
        didSet { guard paceRateUnit != oldValue else { return }; UserDefaults.standard.set(paceRateUnit.rawValue, forKey: "paceRateUnit") }
    }
    /// Whether a notification fires when a watched window is projected to fill before it resets.
    var notifyPace: Bool = false {
        didSet { guard notifyPace != oldValue else { return }; UserDefaults.standard.set(notifyPace, forKey: "notifyPace") }
    }
    /// Threshold in minutes: fire the pace alert when projected full time drops below this value.
    var paceWarningMinutes: Double = 30 {
        didSet { guard paceWarningMinutes != oldValue else { return }; UserDefaults.standard.set(paceWarningMinutes, forKey: "paceWarningMinutes") }
    }
    /// Toast duration for pace alerts, independent of the reset-notification toast duration.
    var paceToastDuration: Double = 5.0 {
        didSet { guard paceToastDuration != oldValue else { return }; UserDefaults.standard.set(paceToastDuration, forKey: "paceToastDuration") }
    }
    /// When `true`, pace alert toasts stay on screen until dismissed by the user.
    var paceToastPermanent: Bool = false {
        didSet { guard paceToastPermanent != oldValue else { return }; UserDefaults.standard.set(paceToastPermanent, forKey: "paceToastPermanent") }
    }
    /// Multiplier applied to all spacing, padding, font sizes, and width in the popover.
    var popupScale: Double = 1.0 {
        didSet { guard popupScale != oldValue else { return }; UserDefaults.standard.set(popupScale, forKey: "popupScale") }
    }
    /// Historical utilization snapshots for the active account's Chart tab.
    /// Per-account storage; persisted via `usageHistory.<accountID>` UserDefaults key.
    var usageHistory: [UsageDataPoint] {
        activeState?.usageHistory ?? []
    }
    /// Whether the Charts tab is shown in the popover.
    var showChartsTab: Bool = true {
        didSet { guard showChartsTab != oldValue else { return }; UserDefaults.standard.set(showChartsTab, forKey: "showChartsTab") }
    }
    /// Whether the Sonnet 7-day sub-window is shown as a third progress bar in the popover.
    var showSonnetWindow: Bool = true {
        didSet { guard showSonnetWindow != oldValue else { return }; UserDefaults.standard.set(showSonnetWindow, forKey: "showSonnetWindow") }
    }

    @ObservationIgnored private var isInitialized = false
    /// API service for the active account. nil before the first account is built or during migration.
    /// Public name kept as `apiService` so existing call sites compile; `var` because the service
    /// is rebuilt against a different `WKWebsiteDataStore` whenever the active account changes.
    @ObservationIgnored var apiService: ClaudeAPIService?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var updateCheckTimer: AnyCancellable?
    @ObservationIgnored private var appearanceCancellable: AnyCancellable?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var lastNotifiedUpdateVersion: String = ""
    /// Adaptive check interval (seconds), computed from release cadence. Clamped 4h–24h.
    private var nextCheckInterval: TimeInterval = 12 * 3600

    var updateCheckIntervalLabel: String {
        let h = (nextCheckInterval / 3600).rounded()
        if h < 24 { return "Checks every ~\(Int(h))h — on launch and wake" }
        return "Checks every ~\(max(1, Int((h / 24).rounded())))d — on launch and wake"
    }
    /// Avoids rebuilding `menuBarImage` when neither the icon name nor the status text has
    /// changed. Internal so the `UsageViewModelMenuBar.swift` extension can read/write.
    var cachedMenuBarKey = ""
    var cachedMenuBarImage = NSImage()

    init() {
        loadPersistedPreferences()
        isInitialized = true

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                AppLogger.shared.info("wake detected — scheduling usage fetch and update check")
                try? await Task.sleep(for: .seconds(5))
                self?.fetchUsage()
                try? await Task.sleep(for: .seconds(25))
                self?.checkForUpdates()
            }
        }

        loadAccountsAndStartActive()
        Task { try? await Task.sleep(for: .seconds(10)); checkForUpdates() }
        schedulePeriodicUpdateCheck()

        // `NSApp` is nil at this point on macOS 26 because `UsageViewModel` is allocated as a
        // `@State` initializer inside `ClaudeTrackerApp.init`, before `NSApplication.shared`
        // exists. Defer the appearance subscription onto the main queue so it lands after the
        // app is up. (Implicit unwrap of `NSApp` here used to work on earlier macOS versions.)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appearanceCancellable = NSApp.publisher(for: \.effectiveAppearance)
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.cachedMenuBarKey = ""
                }
        }
    }

    private func loadPersistedPreferences() {
        if let savedWindow = UserDefaults.standard.string(forKey: "menuBarWindow"),
           let window = MenuBarWindow(rawValue: savedWindow) {
            menuBarWindow = window
        }

        // Version 2 migration: resets any earlier installation that may have had sound and banner
        // enabled by default to the current toast-only defaults.
        if UserDefaults.standard.integer(forKey: "notificationDefaultsVersion") < 2 {
            UserDefaults.standard.set(false, forKey: "notifySound")
            UserDefaults.standard.set(true,  forKey: "notifyToast")
            UserDefaults.standard.set(true,  forKey: "notify5Hour")
            UserDefaults.standard.set(false, forKey: "notify7Day")
            UserDefaults.standard.set(2, forKey: "notificationDefaultsVersion")
        }

        resetSoundEnabled = UserDefaults.standard.object(forKey: "notifySound")       as? Bool ?? false
        notifyToast       = UserDefaults.standard.object(forKey: "notifyToast")       as? Bool ?? true
        notify5Hour       = UserDefaults.standard.object(forKey: "notify5Hour")       as? Bool ?? true
        notify7Day        = UserDefaults.standard.object(forKey: "notify7Day")        as? Bool ?? false
        let savedDuration = UserDefaults.standard.double(forKey: "toastDuration")
        toastDuration  = savedDuration > 0 ? savedDuration : 3.0
        toastPermanent = UserDefaults.standard.object(forKey: "toastPermanent")       as? Bool ?? false
        showPace       = UserDefaults.standard.object(forKey: "showPace")             as? Bool ?? true
        showPaceMenuBar = UserDefaults.standard.object(forKey: "showPaceMenuBar")     as? Bool ?? true
        if let raw = UserDefaults.standard.string(forKey: "paceRateUnit"),
           let saved = PaceRateUnit(rawValue: raw) { paceRateUnit = saved }
        notifyPace     = UserDefaults.standard.object(forKey: "notifyPace")           as? Bool ?? false
        let savedWarning = UserDefaults.standard.double(forKey: "paceWarningMinutes")
        paceWarningMinutes = savedWarning > 0 ? savedWarning : 30
        paceToastEnabled   = UserDefaults.standard.object(forKey: "paceToastEnabled") as? Bool ?? false
        let savedPaceDuration = UserDefaults.standard.double(forKey: "paceToastDuration")
        paceToastDuration  = savedPaceDuration > 0 ? savedPaceDuration : 5.0
        paceToastPermanent = UserDefaults.standard.object(forKey: "paceToastPermanent") as? Bool ?? false
        paceSoundEnabled   = UserDefaults.standard.object(forKey: "paceSoundEnabled") as? Bool ?? false
        // v1: rebase — old 1.0 was the original size; new 1.0 matches old 1.1 (base constants grew ×1.1).
        // Reset any saved scale so existing users see the new default appearance unchanged.
        if UserDefaults.standard.object(forKey: "popupScaleRebased") == nil {
            UserDefaults.standard.set(1.0, forKey: "popupScale")
            UserDefaults.standard.set(1, forKey: "popupScaleRebased")
        }
        let savedPopupScale = UserDefaults.standard.double(forKey: "popupScale")
        popupScale = savedPopupScale > 0 ? savedPopupScale : 1.0

        showChartsTab = UserDefaults.standard.object(forKey: "showChartsTab") as? Bool ?? true
        showSonnetWindow = UserDefaults.standard.object(forKey: "showSonnetWindow") as? Bool ?? true
        // Legacy `usageHistory` (single-account) is migrated into the per-account namespace
        // by `migrateLegacySessionIfPresent`; do not load it here.

        lastNotifiedUpdateVersion = UserDefaults.standard.string(forKey: "lastNotifiedUpdateVersion") ?? ""
        let savedCheckInterval = UserDefaults.standard.double(forKey: "updateCheckInterval")
        if savedCheckInterval >= 4 * 3600 { nextCheckInterval = savedCheckInterval }
        // Load autoUpdate last so its didSet fires with nextCheckInterval already correct.
        autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? false
    }

    // MARK: - Multi-Account Lifecycle

    /// Loads the persisted account roster and, if there's an active account, builds its
    /// API service and starts polling. If no accounts exist, runs a one-shot migration to
    /// import any legacy `.default()` session into a per-identifier data store.
    func loadAccountsAndStartActive() {
        accounts = AccountStore.loadAccounts()
        activeAccountID = AccountStore.loadActiveID()

        // Bootstrap state buckets for every known account; load each account's chart history.
        for acct in accounts {
            var s = statesByAccount[acct.id] ?? AccountState()
            s.usageHistory = loadUsageHistory(for: acct.id)
            s.accountInfo = nil  // will be refreshed on next /api/account fetch
            statesByAccount[acct.id] = s
        }

        if accounts.isEmpty, UserDefaults.standard.integer(forKey: "accountsMigrationVersion") < 1 {
            isMigrating = true
            Task { [weak self] in await self?.migrateLegacySessionIfPresent() }
            return
        }

        guard let id = activeAccountID, let acct = accounts.first(where: { $0.id == id }) else {
            // Roster exists but active is invalid — pick the first.
            if let first = accounts.first {
                activeAccountID = first.id
                AccountStore.saveActiveID(first.id)
                buildActiveService(for: first)
                startSession()
            }
            return
        }
        buildActiveService(for: acct)
        startSession()
    }

    /// Tears down the previous service if any, then constructs a fresh `ClaudeAPIService`
    /// against the given account's data store identifier. Resets the menu bar image cache so
    /// a fresh active-account label renders immediately.
    private func buildActiveService(for account: Account) {
        apiService?.tearDown()
        apiService = ClaudeAPIService(dataStoreIdentifier: account.dataStoreIdentifier)
        cachedMenuBarKey = ""
    }

    private func cancelInFlightWork() {
        fetchTask?.cancel(); fetchTask = nil
        timer?.cancel(); timer = nil
        isLoading = false
    }

    /// Called by the login flow once a session cookie has been detected for the active account.
    func handleSessionFound(_ key: String) {
        guard let id = activeAccountID else { return }
        statesByAccount[id, default: .init()].error = nil
        statesByAccount[id, default: .init()].sessionExpired = false
        startSession()
    }

    /// Loads account info for the active account and starts polling.
    func startSession() {
        Task { [weak self] in
            guard let self, let svc = apiService, let id = activeAccountID else { return }
            if let info = try? await svc.fetchAccountInfo() {
                statesByAccount[id, default: .init()].accountInfo = info
                applyAccountInfoToRoster(id: id, info: info)
            }
            startPolling()
        }
    }

    /// Switches the active account: cancels in-flight work, dismisses any toasts that
    /// belonged to the outgoing account, persists the new selection, and starts polling
    /// against the new account's data store. `isManual: true` (the default) timestamps
    func switchAccount(to id: UUID) {
        guard id != activeAccountID, let acct = accounts.first(where: { $0.id == id }) else { return }

        // If this account has a saved CLI token, swap the Keychain entry.
        // On failure, show a toast and still proceed — the user explicitly chose.
        let fromLabel = accounts.first(where: { $0.id == activeAccountID })?.label
        let outgoingLinkedID: UUID? = activeAccountID.flatMap { oid in
            accounts.first(where: { $0.id == oid && $0.claudeCodeLinked }) != nil ? oid : nil
        }
        var cliSwitchSucceeded = false
        if acct.claudeCodeLinked {
            do {
                try ClaudeCodeKeychain.switchTo(incoming: acct.id, savingCurrentAs: outgoingLinkedID)
                cliSwitchSucceeded = true
                AppLogger.shared.info("Claude Code CLI switched to \(acct.label)")
            } catch {
                AppLogger.shared.error("Claude Code CLI switch failed for \(acct.label): \(error)")
                ToastWindowController.shared.show(
                    title: String(localized: "Claude Code switch failed"),
                    message: String(localized: "Could not update CLI credentials for \(acct.label)"),
                    icon: "exclamationmark.triangle",
                    iconColor: .orange,
                    duration: toastDuration,
                    permanent: false
                )
            }
        }

        cancelInFlightWork()
        // Dismiss any active pace toasts owned by the outgoing account.
        if let outgoingID = activeAccountID,
           let outgoing = statesByAccount[outgoingID] {
            for tid in outgoing.paceToastIDs.values {
                ToastWindowController.shared.dismiss(id: tid)
            }
            statesByAccount[outgoingID]?.paceToastIDs.removeAll()
        }
        activeAccountID = id
        AccountStore.saveActiveID(id)
        buildActiveService(for: acct)
        AppLogger.shared.info("switched active account to \(acct.label) (\(id.uuidString.prefix(8)))")

        if cliSwitchSucceeded {
            let message = fromLabel.map { String(format: String(localized: "From %@"), $0) }
                ?? String(localized: "CLI account updated")
            ToastWindowController.shared.show(
                title: String(localized: "Claude Code → \(acct.label)"),
                message: message,
                icon: "terminal",
                iconColor: .green,
                duration: toastDuration,
                permanent: false
            )
        }
        startSession()
    }

    /// Adds a new account record (with a placeholder label until `/api/account` resolves),
    /// makes it active, and opens the login window against its fresh per-identifier data store.
    /// If the user closes the login window without signing in, call `cancelPendingAdd(_:)` to
    /// roll back the empty account and remove its data store.
    @discardableResult
    func addAccount(label: String? = nil) -> Account {
        let placeholder = label ?? String(localized: "Claude account")
        let acct = Account(label: placeholder)
        accounts.append(acct)
        statesByAccount[acct.id] = AccountState()
        AccountStore.saveAccounts(accounts)
        // Mark the new one active so the freshly built service is the live one.
        // Cancel any in-flight work tied to the previous account.
        cancelInFlightWork()
        activeAccountID = acct.id
        AccountStore.saveActiveID(acct.id)
        buildActiveService(for: acct)
        return acct
    }

    /// Removes a partially-added account if the login flow was cancelled before a session
    /// was captured. Wipes the unused `WKWebsiteDataStore` and the `accounts` row.
    func cancelPendingAdd(_ acct: Account) {
        guard accounts.contains(where: { $0.id == acct.id }),
              statesByAccount[acct.id]?.usage == nil,
              statesByAccount[acct.id]?.accountInfo == nil else { return }
        removeAccount(acct.id)
    }

    /// Creates a new account, makes it active, and opens the login window against its data store.
    /// If the user closes the window without signing in, the placeholder account is rolled back.
    func openLoginForNewAccount() {
        let acct = addAccount()
        guard let svc = apiService else { return }
        LoginWindowController.shared.open(
            apiService: svc,
            onSessionFound: handleSessionFound,
            onCancel: { [weak self] in self?.cancelPendingAdd(acct) }
        )
    }

    /// Removes an account: tears down its API service if active, deletes its persistent data
    /// store, removes its namespaced UserDefaults entries, and switches to the next account
    /// (or the empty state if none remains).
    func removeAccount(_ id: UUID) {
        let wasActive = (activeAccountID == id)
        if wasActive {
            cancelInFlightWork()
            apiService?.tearDown()
            apiService = nil
        }
        // Dismiss any of this account's toasts before dropping its state.
        if let s = statesByAccount[id] {
            for tid in s.paceToastIDs.values { ToastWindowController.shared.dismiss(id: tid) }
        }
        let dataStoreID = accounts.first(where: { $0.id == id })?.dataStoreIdentifier
        accounts.removeAll { $0.id == id }
        statesByAccount.removeValue(forKey: id)
        UserDefaults.standard.removeObject(forKey: AccountStore.usageHistoryKey(for: id))
        ClaudeCodeKeychain.remove(id: id)
        AccountStore.saveAccounts(accounts)
        if let dataStoreID {
            WKWebsiteDataStore.remove(forIdentifier: dataStoreID) { err in
                if let err { AppLogger.shared.error("data store remove failed: \(err.localizedDescription)") }
            }
        }
        if wasActive {
            if let next = accounts.first {
                activeAccountID = next.id
                AccountStore.saveActiveID(next.id)
                buildActiveService(for: next)
                startSession()
            } else {
                activeAccountID = nil
                AccountStore.saveActiveID(nil)
                cachedMenuBarKey = ""
            }
        }
    }

    /// Renames an account label. Local-only — claude.ai is not notified.
    /// Reassigns the whole array so `@Observable` reliably re-emits for views that read
    /// `viewModel.accounts.first(where:).label` (subscript-mutate-and-set on the array can
    /// occasionally fail to fire downstream redraws in `Menu` labels).
    func renameAccount(_ id: UUID, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        var copy = accounts
        copy[idx].label = trimmed
        accounts = copy
        AccountStore.saveAccounts(accounts)
    }

    /// Back-compat wrapper for callers that still use `signOut()` semantics — removes the
    /// currently active account.
    func signOut() {
        if let id = activeAccountID { removeAccount(id) }
    }

    // MARK: - Claude Code CLI integration

    /// Captures the currently-active Claude Code CLI OAuth token (whatever the user just
    /// `/login`'d as) and saves a per-account copy so this ClaudeTracker account can later
    /// activate it via `switchAccount`. The user is expected to have just signed into the
    /// matching Claude account in the CLI before tapping Link.
    /// Returns nil on success, or a human-readable error message on failure.
    @discardableResult
    func linkClaudeCode(_ id: UUID) -> String? {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return "Account not found." }
        do {
            try ClaudeCodeKeychain.saveActiveTokenAs(id: id)
            var copy = accounts
            copy[idx].claudeCodeLinked = true
            accounts = copy
            AccountStore.saveAccounts(accounts)
            AppLogger.shared.info("Claude Code linked: \(accounts[idx].label) (\(id.uuidString.prefix(8)))")
            return nil
        } catch {
            AppLogger.shared.error("Claude Code link failed: \(error)")
            return String(describing: error)
        }
    }

/// Forgets the saved per-account CLI token. The active CLI slot is untouched —
    /// whoever the CLI is currently logged in as remains active.
    func unlinkClaudeCode(_ id: UUID) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        ClaudeCodeKeychain.remove(id: id)
        var copy = accounts
        copy[idx].claudeCodeLinked = false
        accounts = copy
        AccountStore.saveAccounts(accounts)
        AppLogger.shared.info("Claude Code unlinked: \(accounts[idx].label)")
    }

    // MARK: - Migration

    /// One-shot migration from the legacy single-account model: copies any `sessionKey` and
    /// related cookies from `WKWebsiteDataStore.default()` into a freshly created
    /// per-identifier store, registers the corresponding `Account`, and migrates the legacy
    /// `usageHistory` UserDefaults key into the per-account namespace.
    private func migrateLegacySessionIfPresent() async {
        defer { isMigrating = false }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let claudeCookies = cookies.filter { $0.domain.contains("claude.ai") || $0.domain.contains("anthropic.com") }
        let hasSession = claudeCookies.contains { $0.name == "sessionKey" }

        guard hasSession else {
            UserDefaults.standard.set(1, forKey: "accountsMigrationVersion")
            AppLogger.shared.info("migration: no legacy session found, starting empty")
            return
        }

        let newID = UUID()
        let dataStoreID = UUID()
        let store = WKWebsiteDataStore(forIdentifier: dataStoreID)
        // Copy cookies into the new identified store.
        for c in claudeCookies {
            await store.httpCookieStore.setCookie(c)
        }
        // Verify the copy: re-read sessionKey from the new store.
        let copiedCookies = await store.httpCookieStore.allCookies()
        let migrated = copiedCookies.contains { $0.name == "sessionKey" && ($0.domain.contains("claude.ai") || $0.domain.contains("anthropic.com")) }
        guard migrated else {
            UserDefaults.standard.set(1, forKey: "accountsMigrationVersion")
            AppLogger.shared.error("migration: cookie copy failed, falling back to empty roster")
            return
        }

        let acct = Account(id: newID, label: String(localized: "Claude account"), dataStoreIdentifier: dataStoreID)
        accounts = [acct]
        AccountStore.saveAccounts(accounts)
        activeAccountID = newID
        AccountStore.saveActiveID(newID)

        // Move legacy usageHistory blob into the per-account namespace.
        if let legacyData = UserDefaults.standard.data(forKey: "usageHistory") {
            UserDefaults.standard.set(legacyData, forKey: AccountStore.usageHistoryKey(for: newID))
            UserDefaults.standard.removeObject(forKey: "usageHistory")
            if let decoded = try? JSONDecoder().decode([UsageDataPoint].self, from: legacyData) {
                statesByAccount[newID, default: .init()].usageHistory = decoded
            }
        } else {
            statesByAccount[newID, default: .init()].usageHistory = []
        }

        UserDefaults.standard.set(1, forKey: "accountsMigrationVersion")
        AppLogger.shared.info("migration: imported legacy session as account \(newID.uuidString.prefix(8))")

        buildActiveService(for: acct)
        startSession()
    }

    /// Persists per-account chart history to the namespaced UserDefaults key.
    private func saveUsageHistory(_ history: [UsageDataPoint], for accountID: UUID) {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: AccountStore.usageHistoryKey(for: accountID))
        }
    }

    /// Loads per-account chart history from the namespaced UserDefaults key.
    private func loadUsageHistory(for accountID: UUID) -> [UsageDataPoint] {
        guard let data = UserDefaults.standard.data(forKey: AccountStore.usageHistoryKey(for: accountID)),
              let decoded = try? JSONDecoder().decode([UsageDataPoint].self, from: data) else { return [] }
        return decoded
    }

    /// Writes API-derived account info back into the persisted roster (display name when the
    /// label is still the placeholder, plus email and subscription badge).
    private func applyAccountInfoToRoster(id: UUID, info: AccountInfo) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        if accounts[idx].label == String(localized: "Claude account") || accounts[idx].label.isEmpty {
            accounts[idx].label = info.displayName
        }
        accounts[idx].email = info.emailAddress
        accounts[idx].subscriptionLabel = info.subscriptionLabel
        AccountStore.saveAccounts(accounts)
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
                checkForResets(accountID: id, old: oldUsage, new: response)
                recordHistory(accountID: id, response: response)
                appendDataPoint(accountID: id, response: response)
                checkPaceNotifications(accountID: id, response: response)
                statesByAccount[id, default: .init()].usage = response
                statesByAccount[id, default: .init()].error = nil
                statesByAccount[id, default: .init()].lastUpdated = Date()
                statesByAccount[id, default: .init()].consecutiveErrors = 0
                statesByAccount[id, default: .init()].sessionExpired = false
                shouldSchedule = true
            } catch let err as ClaudeAPIService.APIError {
                guard !Task.isCancelled else { return }
                let n = (statesByAccount[id]?.consecutiveErrors ?? 0) + 1
                statesByAccount[id, default: .init()].consecutiveErrors = n
                AppLogger.shared.error("fetchUsage APIError (#\(n)): \(err.localizedDescription)")
                statesByAccount[id, default: .init()].error = err.localizedDescription
                if case .unauthorized = err {
                    if n > 1 {
                        statesByAccount[id, default: .init()].sessionExpired = true
                        timer?.cancel(); timer = nil
                    } else {
                        // First 401: mapJSError already cleared isPageReady;
                        // next poll reloads the page and retries automatically.
                        shouldSchedule = true
                    }
                } else {
                    shouldSchedule = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                let n = (statesByAccount[id]?.consecutiveErrors ?? 0) + 1
                statesByAccount[id, default: .init()].consecutiveErrors = n
                AppLogger.shared.error("fetchUsage unexpected error (#\(n)): \(error)")
                statesByAccount[id, default: .init()].error = error.localizedDescription
                shouldSchedule = true
            }
            // Only flip the spinner off if this fetch was for the still-active account.
            if id == activeAccountID { isLoading = false }
            if shouldSchedule, id == activeAccountID { scheduleNextPoll() }
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
        let backoff = errs > 0 ? min(Double(errs) * 10, 60) : 0
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

    /// Computes the polling interval for a single usage window.
    private func intervalForWindow(key: String, window: UsageWindow?) -> TimeInterval {
        guard let window else { return 10 }
        let util = window.utilization

        // Stale: reset already passed — poll aggressively to catch the new window
        if let resetDate = window.resetsAtDate, resetDate < Date() {
            return 2
        }

        // At 100%: only need to catch the upcoming reset
        if util >= 99.9 {
            guard let resetDate = window.resetsAtDate else { return 30 }
            let secs = max(0, resetDate.timeIntervalSinceNow)
            switch secs {
            case 1800...: return 300
            case 600...:  return 120
            case 120...:  return 30
            default:      return 10
            }
        }

        // Active: use projected minutes to full when pace is available
        if let projMins = pace(for: key)?.projectedHours.map({ $0 * 60 }) {
            return intervalForProjMins(projMins)
        }

        // Fallback: utilization-based steps when no pace signal yet
        switch util {
        case 95...: return 3
        case 80...: return 5
        case 50...: return 8
        default:    return 10
        }
    }

    private func intervalForProjMins(_ projMins: Double) -> TimeInterval {
        switch projMins {
        case 60...: return 10
        case 30...: return 8
        case 15...: return 5
        case 5...:  return 3
        case 2...:  return 2
        default:    return 1
        }
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
            guard let resetDate = window.resetsAtDate else { return false }
            return resetDate < now && lastUpdated < resetDate
        }
    }

    func isWindowStale(_ window: UsageWindow) -> Bool {
        guard let lastUpdated, let resetDate = window.resetsAtDate else { return false }
        return resetDate < Date() && lastUpdated < resetDate
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

    // MARK: - Reset Detection

    /// Compares previous `resetsAt` timestamps to the new response to detect window resets.
    ///
    /// A window is considered reset when both of the following hold:
    /// - The `resetsAt` timestamp has changed (the server issued a new window period), and
    /// - Utilization has dropped below 5 % (guards against a timestamp refresh without an actual reset).
    ///
    /// On the first fetch (`old == nil`) timestamps are recorded as a baseline without firing a notification.
    private func checkForResets(accountID: UUID, old: UsageResponse?, new: UsageResponse) {
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
           newDate.timeIntervalSince(oldDate) > 3600,
           newWindow.utilization < 5 {
            resets.append(String(localized: "5-Hour Window"))
        }

        if notify7Day,
           let oldDate = prev["seven_day"],
           let newWindow = new.sevenDay,
           let newDate = newWindow.resetsAtDate,
           newDate.timeIntervalSince(oldDate) > 3600,
           newWindow.utilization < 5 {
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
    /// Readings older than 15 minutes are discarded. If utilization for a window drops by
    /// more than 20 percentage points compared to the last recorded value, the history is
    /// cleared first — this handles window resets, which drop utilization back to near zero.
    private func recordHistory(accountID: UUID, response: UsageResponse) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-5 * 60)

        func append(key: String, utilization: Double?) {
            guard let utilization else { return }
            var s = statesByAccount[accountID] ?? .init()
            var history = s.utilizationHistory[key] ?? []
            if let last = history.last, last.1 - utilization > 20 || (utilization < 5 && last.1 >= 5) {
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

        append(key: "five_hour", utilization: response.fiveHour?.utilization)
        append(key: "seven_day", utilization: response.sevenDay?.utilization)
    }

    /// Fires a pace alert through all enabled channels when a watched window is on track to
    /// fill before it resets. Each window can only trigger one alert per window period;
    /// the warned flag resets automatically when utilization drops (i.e. the window resets).
    private func checkPaceNotifications(accountID: UUID, response: UsageResponse) {
        // Only the active account should trigger pace toasts/sounds.
        let isActive = (accountID == activeAccountID)

        guard notifyPace, isActive else {
            statesByAccount[accountID, default: .init()].paceWarned.removeAll()
            return
        }

        let candidates: [(key: String, name: String, watched: Bool)] = [
            ("five_hour", String(localized: "5-Hour Window"), notify5Hour),
            ("seven_day",  String(localized: "7-Day Window"),  notify7Day),
        ]

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

    private func appendDataPoint(accountID: UUID, response: UsageResponse) {
        let now = Date()
        var s = statesByAccount[accountID] ?? .init()
        if let last = s.lastHistoryTimestamp, now.timeIntervalSince(last) < 300 { return }
        s.lastHistoryTimestamp = now
        let point = UsageDataPoint(
            timestamp: now,
            fiveHour: response.fiveHour?.utilization,
            sevenDay: response.sevenDay?.utilization,
            fiveHourPace: pace(accountID: accountID, key: "five_hour")?.rate,
            sevenDayPace: pace(accountID: accountID, key: "seven_day")?.rate
        )
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        var history = s.usageHistory.filter { $0.timestamp >= cutoff }
        history.append(point)
        if history.count > 8640 { history = Array(history.suffix(8640)) }
        s.usageHistory = history
        statesByAccount[accountID] = s
        saveUsageHistory(history, for: accountID)
    }

    // MARK: - Update Check

    /// Fetches the last 10 GitHub releases, checks for a newer version, and updates the adaptive
    /// check interval from the release cadence. Safe to call multiple times — debounced by
    /// `isCheckingForUpdates`.
    func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        if case .failed = updateDownloadState { updateDownloadState = .idle }
        isCheckingForUpdates = true
        Task {
            defer { isCheckingForUpdates = false }
            guard let url = URL(string: "https://api.github.com/repos/diegovilloutafredes/ClaudeTracker/releases?per_page=10") else { return }
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let latest = releases.first,
                  let tag = latest["tag_name"] as? String,
                  let htmlUrl = latest["html_url"] as? String,
                  let releaseUrl = URL(string: htmlUrl) else { return }

            let remote  = tag.trimmingCharacters(in: .init(charactersIn: "v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if isNewerVersion(remote, than: current) {
                let assets = latest["assets"] as? [[String: Any]]
                let zipAsset = assets?.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                let downloadURL = (zipAsset?["browser_download_url"] as? String).flatMap(URL.init)
                availableUpdate = UpdateInfo(version: remote, releaseURL: releaseUrl, downloadURL: downloadURL)

                // Only notify once per discovered version (persisted across restarts)
                if lastNotifiedUpdateVersion != remote {
                    lastNotifiedUpdateVersion = remote
                    UserDefaults.standard.set(remote, forKey: "lastNotifiedUpdateVersion")
                    if autoUpdate, downloadURL != nil {
                        if case .idle = updateDownloadState { triggerAutoInstall() }
                    } else {
                        ToastWindowController.shared.show(
                            title: String(localized: "Update available"),
                            message: String(format: String(localized: "v%@ is ready — open Settings to install"), remote),
                            icon: "arrow.up.circle.fill",
                            iconColor: .green,
                            duration: 12,
                            permanent: false
                        )
                    }
                }
            }

            let computed = computeCheckInterval(from: releases)
            if computed != nextCheckInterval {
                nextCheckInterval = computed
                UserDefaults.standard.set(computed, forKey: "updateCheckInterval")
                AppLogger.shared.info("update check interval adjusted to \(Int(computed / 3600))h based on release cadence")
                if autoUpdate { schedulePeriodicUpdateCheck() }
            }
        }
    }

    /// Derives a check interval from the average gap between the last N release dates.
    /// Clamped to [4h, 24h]; defaults to 12h when history is insufficient.
    private func computeCheckInterval(from releases: [[String: Any]]) -> TimeInterval {
        let fmt = ISO8601DateFormatter()
        let dates = releases.compactMap { r -> Date? in
            guard let s = r["published_at"] as? String else { return nil }
            return fmt.date(from: s)
        }.sorted(by: >)
        guard dates.count >= 2 else { return 12 * 3600 }
        var gaps: [TimeInterval] = []
        for i in 0..<(dates.count - 1) {
            let gap = dates[i].timeIntervalSince(dates[i + 1])
            if gap > 0 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return 12 * 3600 }
        let avg = gaps.reduce(0, +) / Double(gaps.count)
        return max(4 * 3600, min(24 * 3600, avg * 0.5))
    }

    private func schedulePeriodicUpdateCheck() {
        updateCheckTimer?.cancel()
        updateCheckTimer = nil
        guard autoUpdate else { return }
        updateCheckTimer = Timer.publish(every: nextCheckInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkForUpdates() }
    }

    private func triggerAutoInstall() {
        guard let update = availableUpdate, update.downloadURL != nil else { return }
        let msg = String(format: String(localized: "v%@ found — installing in ~10s"), update.version)
        ToastWindowController.shared.show(
            title: String(localized: "Update available"),
            message: msg,
            icon: "arrow.down.circle.fill",
            iconColor: .green,
            duration: 12,
            permanent: false
        )
        Task {
            try? await Task.sleep(for: .seconds(10))
            downloadAndInstall()
        }
    }

    func downloadAndInstall() {
        guard let update = availableUpdate, let downloadURL = update.downloadURL else { return }
        guard case .idle = updateDownloadState else { return }
        updateDownloadState = .downloading

        let tmpBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeTrackerUpdate")

        Task {
            do {
                try? FileManager.default.removeItem(at: tmpBase)
                try FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)

                // Download ZIP
                let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
                let zipURL = tmpBase.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: tempURL, to: zipURL)

                // Extract on background thread (waitUntilExit blocks)
                let extractDir = tmpBase.appendingPathComponent("extracted")
                let appURL: URL = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
                            let unzip = Process()
                            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                            unzip.arguments = ["-o", zipURL.path, "-d", extractDir.path]
                            try unzip.run()
                            unzip.waitUntilExit()
                            guard unzip.terminationStatus == 0 else {
                                cont.resume(throwing: UpdateError.extractionFailed); return
                            }
                            let items = (try? FileManager.default.contentsOfDirectory(
                                at: extractDir, includingPropertiesForKeys: nil)) ?? []
                            if let app = items.first(where: { $0.pathExtension == "app" }) {
                                cont.resume(returning: app)
                            } else {
                                cont.resume(throwing: UpdateError.appNotFound)
                            }
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }

                updateDownloadState = .installing

                // Try direct install (works when sandbox is not enforced)
                let dest = URL(fileURLWithPath: "/Applications/ClaudeTracker.app")
                let directOK: Bool = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? FileManager.default.removeItem(at: dest)
                        cont.resume(returning: (try? FileManager.default.copyItem(at: appURL, to: dest)) != nil)
                    }
                }

                // Fail gracefully if copy was blocked (e.g. sandbox in signed dev builds).
                // Never open install.command or terminate without a successful install.
                guard directOK else { throw UpdateError.installationFailed }

                // Relaunch: try a detached shell script first (works in unsigned release builds).
                // Fall back to NSWorkspace.open when Process is sandbox-blocked.
                let relaunchScript = "#!/bin/bash\nsleep 1.5\nopen \"/Applications/ClaudeTracker.app\"\n"
                let scriptURL = tmpBase.appendingPathComponent("relaunch.sh")
                var usedScript = false
                if (try? relaunchScript.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/bash")
                    p.arguments = [scriptURL.path]
                    usedScript = (try? p.run()) != nil
                }
                try await Task.sleep(for: .milliseconds(300))
                if !usedScript {
                    NSWorkspace.shared.open(dest)
                    try await Task.sleep(for: .milliseconds(500))
                }
                NSApp.terminate(nil)
            } catch {
                AppLogger.shared.error("auto-update failed: \(error)")
                updateDownloadState = .failed(error.localizedDescription)
            }
        }
    }

    private enum UpdateError: LocalizedError {
        case extractionFailed, appNotFound, installationFailed
        var errorDescription: String? {
            switch self {
            case .extractionFailed:   return String(localized: "Failed to extract update")
            case .appNotFound:        return String(localized: "Update package is invalid")
            case .installationFailed: return String(localized: "Installation failed")
            }
        }
    }
}
