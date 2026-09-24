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
        var loaded = AccountStore.loadAccounts()
        // Reclaim placeholders abandoned by a quit/crash while the login window was open:
        // they were persisted before sign-in and their willClose rollback never fired.
        // Their data stores hold no session — a surviving row could only 401.
        let abandoned = loaded.filter { $0.pending == true }
        if !abandoned.isEmpty {
            loaded.removeAll { $0.pending == true }
            AccountStore.saveAccounts(loaded)
            for acct in abandoned {
                purgeAccountStorage(id: acct.id, dataStoreID: acct.dataStoreIdentifier, context: "abandoned")
                AppLogger.shared.info("reclaimed abandoned pending account \(acct.id.uuidString.prefix(8))")
            }
        }
        accounts = loaded
        activeAccountID = AccountStore.loadActiveID()

        // Bootstrap state buckets for every known account; load each account's chart history.
        for acct in accounts {
            var s = statesByAccount[acct.id] ?? AccountState()
            s.usageHistory = loadUsageHistory(for: acct.id)
            s.accountInfo = nil  // will be refreshed on next /api/account fetch
            statesByAccount[acct.id] = s
        }

        let migrationVersion = UserDefaults.standard.integer(forKey: PrefKey.accountsMigrationVersion)
        // The migration's no-session branch never cleared the pre-multi-account history blob;
        // once the migration has run, it belongs to no account.
        if migrationVersion >= 1, UserDefaults.standard.object(forKey: PrefKey.legacyUsageHistory) != nil {
            UserDefaults.standard.removeObject(forKey: PrefKey.legacyUsageHistory)
            AppLogger.shared.info("removed the orphaned legacy usageHistory blob")
        }

        if accounts.isEmpty, migrationVersion < 1 {
            isMigrating = true
            Task { [weak self] in await self?.migrateLegacySessionIfPresent() }
            return
        }

        // Roster exists but the stored active id is invalid — fall back to the first.
        let acct = accounts.first { $0.id == activeAccountID } ?? accounts.first
        if let acct {
            activate(acct)
        } else if activeAccountID != nil {
            // Every row was reclaimed (or the roster failed to decode): forget the stale
            // selection so the popover offers sign-in instead of an endless "Loading…".
            activeAccountID = nil
            AccountStore.saveActiveID(nil)
        }
        sweepOrphanedDataStores()
    }

    /// Deletes per-account WebKit stores that no roster entry owns. A removal that raced a
    /// live web view fails (WebKit only deletes a store nothing uses) and could leave a
    /// removed account's cookies on disk indefinitely. Only called once the roster is
    /// final — never mid-migration, which creates its store before registering the account.
    private func sweepOrphanedDataStores() {
        // An undecodable roster loads as [] with its blob preserved for manual recovery: every
        // store would look orphaned, and deleting them would leave that recovery without its
        // sessions. Paused until the blob is repaired or removed.
        guard UserDefaults.standard.object(forKey: AccountStore.corruptAccountsKey) == nil else {
            AppLogger.shared.info("orphan sweep skipped: a corrupt roster blob is preserved")
            return
        }
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { [weak self] ids in
            guard let self, !self.isMigrating else { return }
            for id in orphanedDataStoreIDs(existing: ids, roster: self.accounts) {
                WKWebsiteDataStore.remove(forIdentifier: id) { err in
                    let short = id.uuidString.prefix(8)
                    if let err {
                        AppLogger.shared.error("orphaned data store \(short) remove failed: \(err.localizedDescription)")
                    } else {
                        AppLogger.shared.info("removed orphaned data store \(short)")
                    }
                }
            }
        }
    }

    /// Makes `account` the active one (persisting the selection), rebuilds the API service
    /// against its data store, and starts its session.
    private func activate(_ account: Account) {
        activeAccountID = account.id
        AccountStore.saveActiveID(account.id)
        buildActiveService(for: account)
        startSession()
    }

    /// Removes an account's persisted chart history and its `WKWebsiteDataStore`.
    ///
    /// WebKit only deletes a store once no web view uses it, and callers can run while one is
    /// still alive (the closing login window, a poll suspended in `callAsyncJavaScript`), so a
    /// failed removal is retried once a few seconds later. Anything that survives both is
    /// deleted by the launch-time orphan sweep.
    private func purgeAccountStorage(id: UUID, dataStoreID: UUID, context: String) {
        UserDefaults.standard.removeObject(forKey: AccountStore.usageHistoryKey(for: id))
        WKWebsiteDataStore.remove(forIdentifier: dataStoreID) { err in
            guard err != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                WKWebsiteDataStore.remove(forIdentifier: dataStoreID) { err in
                    guard let err else { return }
                    AppLogger.shared.error("\(context) data store remove failed twice (left for the launch sweep): "
                                           + err.localizedDescription)
                }
            }
        }
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
        // A new session starts the 401 count over; a leftover count would expire it on its
        // first transient 401 instead of allowing the usual silent retry.
        statesByAccount[id, default: .init()].consecutive401s = 0
        accountBeforePendingAdd = nil
        // The account is real now — clear the pending flag so a later launch doesn't
        // reclaim it as an abandoned placeholder. (Array reassign: see renameAccount.)
        if let idx = accounts.firstIndex(where: { $0.id == id }), accounts[idx].pending == true {
            var copy = accounts
            copy[idx].pending = nil
            accounts = copy
            AccountStore.saveAccounts(accounts)
        }
        startSession()
    }

    /// Reopens the login window on the active account's own service, so a rejected session
    /// signs back into the same account (same roster row, same chart history). Cancelling
    /// resumes polling — `fetchUsage` paused while the window owned the web view — unless
    /// another flow (e.g. "Add account" reusing the window) changed the active account.
    func signInAgain() {
        guard let svc = apiService, let id = activeAccountID else { return }
        LoginWindowController.shared.open(
            apiService: svc,
            onSessionFound: handleSessionFound,
            onCancel: { [weak self] in
                // willClose runs this before LoginView.onDisappear stops the cookie poll, and
                // fetchUsage waits while that poll runs — stop it first, or polling stays dead.
                svc.stopCookiePolling()
                guard let self, self.activeAccountID == id else { return }
                self.startPolling()
            }
        )
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
            await refreshAccountInfo(id: id, svc: svc)
            guard !Task.isCancelled, id == activeAccountID else { return }
            startPolling()
        }
    }

    /// Fetches `/api/account` into `id`'s bucket and roster row. A failure is logged and left
    /// to `retryAccountInfoIfMissing` — it used to be swallowed with no retry, so a launch
    /// before the network was up lost the plan badge and email for the whole session.
    func refreshAccountInfo(id: UUID, svc: ClaudeAPIService) async {
        statesByAccount[id, default: .init()].accountInfoAttemptedAt = Date()
        do {
            let info = try await svc.fetchAccountInfo()
            guard !Task.isCancelled else { return }
            statesByAccount[id, default: .init()].accountInfo = info
            applyAccountInfoToRoster(id: id, info: info)
        } catch {
            // A switch cancels the session task (and tears the service down): not a failure.
            if !Task.isCancelled { AppLogger.shared.error("account info fetch failed: \(error.localizedDescription)") }
        }
    }

    /// Re-fetches account info after a successful poll while it is still missing — at most every
    /// 5 minutes, so a persistently failing `/api/account` can't double the request rate.
    func retryAccountInfoIfMissing(id: UUID, svc: ClaudeAPIService) {
        guard let state = statesByAccount[id], state.accountInfo == nil,
              Date().timeIntervalSince(state.accountInfoAttemptedAt ?? .distantPast) > 300 else { return }
        statesByAccount[id]?.accountInfoAttemptedAt = Date()
        Task { [weak self] in await self?.refreshAccountInfo(id: id, svc: svc) }
    }

    /// Switches the active account: cancels in-flight work, dismisses any toasts that
    /// belonged to the outgoing account, persists the new selection, and starts polling
    /// against the new account's data store.
    func switchAccount(to id: UUID) {
        guard id != activeAccountID, let acct = accounts.first(where: { $0.id == id }) else { return }

        // Abandon any in-progress sign-in first: `buildActiveService` below tears down
        // the service whose webview the login window is displaying, which would leave a
        // dead window and a lingering placeholder. Closing fires the pending-add
        // rollback synchronously through the willClose path.
        LoginWindowController.shared.close()
        cancelInFlightWork()
        dismissPaceToasts(for: activeAccountID)
        AppLogger.shared.info("switched active account to \(acct.label) (\(id.uuidString.prefix(8)))")
        activate(acct)
    }

    /// Adds a new account record (with a placeholder label until `/api/account` resolves),
    /// makes it active, and opens the login window against its fresh per-identifier data store.
    /// If the user closes the login window without signing in, call `cancelPendingAdd(_:)` to
    /// roll back the empty account and remove its data store.
    @discardableResult
    func addAccount(label: String? = nil) -> Account {
        let placeholder = label ?? String(localized: "Claude account")
        let acct = Account(label: placeholder, pending: true)
        accounts.append(acct)
        statesByAccount[acct.id] = AccountState()
        AccountStore.saveAccounts(accounts)
        // Mark the new one active so the freshly built service is the live one.
        // Cancel any in-flight work tied to the previous account.
        cancelInFlightWork()
        dismissPaceToasts(for: activeAccountID)
        // A second "Add account" while a placeholder is active keeps the original to return to.
        if accounts.first(where: { $0.id == activeAccountID })?.pending != true {
            accountBeforePendingAdd = activeAccountID
        }
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
        // Only the active placeholder's rollback consumes the saved account; an earlier
        // placeholder rolled back when the login window is reused must leave it in place.
        let wasActive = activeAccountID == acct.id
        removeAccount(acct.id, preferring: accountBeforePendingAdd)
        if wasActive { accountBeforePendingAdd = nil }
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
    /// store, removes its namespaced UserDefaults entries, and switches to `preferredNext` when
    /// it still exists (a cancelled add returns to the account the user was on), otherwise to
    /// the first account (or the empty state if none remains).
    func removeAccount(_ id: UUID, preferring preferredNext: UUID? = nil) {
        let wasActive = (activeAccountID == id)
        if wasActive {
            cancelInFlightWork()
            apiService?.tearDown()
            apiService = nil
        }
        // Dismiss any of this account's toasts before dropping its state.
        dismissPaceToasts(for: id)
        let dataStoreID = accounts.first(where: { $0.id == id })?.dataStoreIdentifier
        accounts.removeAll { $0.id == id }
        statesByAccount.removeValue(forKey: id)
        AccountStore.saveAccounts(accounts)
        if let dataStoreID {
            purgeAccountStorage(id: id, dataStoreID: dataStoreID, context: "removed")
        } else {
            UserDefaults.standard.removeObject(forKey: AccountStore.usageHistoryKey(for: id))
        }
        if wasActive {
            if let next = accounts.first(where: { $0.id == preferredNext }) ?? accounts.first {
                activate(next)
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
        defer {
            isMigrating = false
            // The roster is final now. A failed attempt's half-copied store is an orphan too:
            // the retry on the next launch copies into a fresh store.
            sweepOrphanedDataStores()
        }
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

        activate(acct)
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
