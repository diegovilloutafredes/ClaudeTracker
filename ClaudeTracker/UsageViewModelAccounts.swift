import SwiftUI
import WebKit

// MARK: - Multi-Account Lifecycle

/// Account roster management: load/switch/add/remove/rename, the legacy single-account
/// migration, and per-account chart-history persistence. Extracted from
/// `UsageViewModel.swift` to keep each file focused on one responsibility.
extension UsageViewModel {

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

        if accounts.isEmpty, UserDefaults.standard.integer(forKey: PrefKey.accountsMigrationVersion) < 1 {
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
        invalidateMenuBarImage()
    }

    /// Dismisses any on-screen pace toasts owned by the given account — an outgoing
    /// account's toasts must not linger over the incoming account's data.
    func dismissPaceToasts(for id: UUID?) {
        guard let id, let state = statesByAccount[id] else { return }
        for tid in state.paceToastIDs.values {
            ToastWindowController.shared.dismiss(id: tid)
        }
        statesByAccount[id]?.paceToastIDs.removeAll()
    }

    /// Called by the login flow once a session cookie has been detected for the active account.
    func handleSessionFound(_ key: String) {
        guard let id = activeAccountID else { return }
        statesByAccount[id, default: .init()].error = nil
        statesByAccount[id, default: .init()].sessionExpired = false
        startSession()
    }

    /// Loads account info for the active account and starts polling.
    ///
    /// The service and account id are captured *at call time* (not when the task body
    /// runs) and the task is stored so `cancelInFlightWork()` covers it — otherwise an
    /// account switch mid-await would attribute the result to the new account and fire
    /// a redundant competing poll loop.
    func startSession() {
        guard let svc = apiService, let id = activeAccountID else { return }
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            if let info = try? await svc.fetchAccountInfo() {
                guard !Task.isCancelled else { return }
                statesByAccount[id, default: .init()].accountInfo = info
                applyAccountInfoToRoster(id: id, info: info)
            }
            guard !Task.isCancelled, id == activeAccountID else { return }
            startPolling()
        }
    }

    /// Switches the active account: cancels in-flight work, dismisses any toasts that
    /// belonged to the outgoing account, persists the new selection, and starts polling
    /// against the new account's data store.
    func switchAccount(to id: UUID) {
        guard id != activeAccountID, let acct = accounts.first(where: { $0.id == id }) else { return }

        cancelInFlightWork()
        dismissPaceToasts(for: activeAccountID)
        activeAccountID = id
        AccountStore.saveActiveID(id)
        buildActiveService(for: acct)
        AppLogger.shared.info("switched active account to \(acct.label) (\(id.uuidString.prefix(8)))")
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
        dismissPaceToasts(for: activeAccountID)
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
                invalidateMenuBarImage()
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

    // MARK: - Migration

    /// One-shot migration from the legacy single-account model: copies any `sessionKey` and
    /// related cookies from `WKWebsiteDataStore.default()` into a freshly created
    /// per-identifier store, registers the corresponding `Account`, and migrates the legacy
    /// `usageHistory` UserDefaults key into the per-account namespace.
    private func migrateLegacySessionIfPresent() async {
        defer { isMigrating = false }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let claudeCookies = cookies.filter(\.isClaudeDomain)
        let hasSession = claudeCookies.contains { $0.name == "sessionKey" }

        guard hasSession else {
            UserDefaults.standard.set(1, forKey: PrefKey.accountsMigrationVersion)
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
        let migrated = copiedCookies.contains { $0.name == "sessionKey" && $0.isClaudeDomain }
        guard migrated else {
            // Do NOT set the migration version: the copy is idempotent, so a transient
            // failure (e.g. the store initializing slowly) is retried next launch instead
            // of permanently abandoning the legacy session — same contract as SandboxMigration.
            AppLogger.shared.error("migration: cookie copy failed — will retry next launch")
            return
        }

        let acct = Account(id: newID, label: String(localized: "Claude account"), dataStoreIdentifier: dataStoreID)
        accounts = [acct]
        AccountStore.saveAccounts(accounts)
        activeAccountID = newID
        AccountStore.saveActiveID(newID)

        // Move legacy usageHistory blob into the per-account namespace.
        if let legacyData = UserDefaults.standard.data(forKey: PrefKey.legacyUsageHistory) {
            UserDefaults.standard.set(legacyData, forKey: AccountStore.usageHistoryKey(for: newID))
            UserDefaults.standard.removeObject(forKey: PrefKey.legacyUsageHistory)
            if let decoded = try? JSONDecoder().decode([UsageDataPoint].self, from: legacyData) {
                statesByAccount[newID, default: .init()].usageHistory = decoded
            }
        } else {
            statesByAccount[newID, default: .init()].usageHistory = []
        }

        UserDefaults.standard.set(1, forKey: PrefKey.accountsMigrationVersion)
        AppLogger.shared.info("migration: imported legacy session as account \(newID.uuidString.prefix(8))")

        buildActiveService(for: acct)
        startSession()
    }

    // MARK: - Chart History Persistence

    /// Persists per-account chart history to the namespaced UserDefaults key.
    func saveUsageHistory(_ history: [UsageDataPoint], for accountID: UUID) {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: AccountStore.usageHistoryKey(for: accountID))
        } else {
            AppLogger.shared.error("usageHistory encode failed — chart history not persisted")
        }
    }

    /// Loads per-account chart history from the namespaced UserDefaults key.
    private func loadUsageHistory(for accountID: UUID) -> [UsageDataPoint] {
        let key = AccountStore.usageHistoryKey(for: accountID)
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        guard let decoded = try? JSONDecoder().decode([UsageDataPoint].self, from: data) else {
            // Same decode-or-wipe guard as AccountStore.loadAccounts: preserve the blob
            // before the next appendDataPoint save overwrites 30 days of history.
            UserDefaults.standard.set(data, forKey: key + ".corrupt")
            AppLogger.shared.error("usageHistory decode failed — raw blob preserved under \(key).corrupt")
            return []
        }
        return decoded
    }

    // MARK: - Roster Write-Back

    /// Writes API-derived account info back into the persisted roster (display name when the
    /// label is still the placeholder, plus email and subscription badge).
    func applyAccountInfoToRoster(id: UUID, info: AccountInfo) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        // Copy-mutate-reassign (same rule as renameAccount): direct subscript mutation
        // can fail to fire @Observable redraws for views reading accounts.first(where:).
        var copy = accounts
        if copy[idx].label == String(localized: "Claude account") || copy[idx].label.isEmpty {
            copy[idx].label = info.displayName
        }
        copy[idx].email = info.emailAddress
        copy[idx].subscriptionLabel = info.subscriptionLabel
        accounts = copy
        AccountStore.saveAccounts(accounts)
    }

    func applyOrgNameToRoster(id: UUID, orgName: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }),
              accounts[idx].orgName != orgName else { return }
        var copy = accounts
        copy[idx].orgName = orgName
        accounts = copy
        AccountStore.saveAccounts(accounts)
    }
}
