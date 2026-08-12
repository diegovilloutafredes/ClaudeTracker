import Foundation
import WebKit

extension HTTPCookie {
    /// True for cookies set by the claude.ai / anthropic.com session domains.
    var isClaudeDomain: Bool {
        domain.contains("claude.ai") || domain.contains("anthropic.com")
    }
}

/// Fetches usage and account data from the unofficial claude.ai web API.
///
/// Direct `URLSession` requests to claude.ai are blocked by Cloudflare's bot-detection layer.
/// This service loads `claude.ai` in a hidden `WKWebView` and issues all API calls via
/// `callAsyncJavaScript`, so requests originate from a real browser context with the correct
/// cookies, headers, and TLS fingerprint — exactly as the web app does.
@MainActor
final class ClaudeAPIService: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// The underlying web view, exposed so `LoginView` can embed it directly for in-app sign-in.
    let webView: WKWebView
    /// Identifier of the `WKWebsiteDataStore` backing this service's cookie jar.
    let dataStoreIdentifier: UUID

    private var isPageReady = false
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var isLoadingPage = false
    /// Fails all pending waiters if the page never becomes ready (e.g. a Cloudflare
    /// challenge that never clears). Without this, a stuck page would suspend every
    /// caller forever and silently stop the polling loop.
    private var readinessTimeoutTask: Task<Void, Never>?
    private var cachedOrgId: String?
    private(set) var cachedOrgName: String?
    private var cookieTask: Task<Void, Never>?
    private var popupWebView: WKWebView?
    var onPopupRequested: ((WKWebView, WKWindowFeatures) -> Void)?
    var onPopupDismissed: (() -> Void)?

    /// Builds an API service backed by a per-identifier `WKWebsiteDataStore` so each account
    /// keeps its cookies (and `sessionKey`) isolated from every other account.
    init(dataStoreIdentifier: UUID) {
        self.dataStoreIdentifier = dataStoreIdentifier
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
    }

    /// Releases pollers and closes the popup. Call before dropping the service so the
    /// embedded `WKWebView` is no longer using the data store (required before
    /// `WKWebsiteDataStore.remove(forIdentifier:)`).
    func tearDown() {
        stopCookiePolling()
        failAllWaiters(with: APIError.networkError("torn down"))
        popupWebView = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: - Login Support

    /// Loads the claude.ai login page into the web view for in-app sign-in.
    func loadLoginPage() {
        isPageReady = false
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    /// Polls the shared cookie store every second until a `sessionKey` cookie appears.
    ///
    /// Cookie inspection requires an asynchronous round-trip into the cookie store; a
    /// poll loop is more reliable here than a navigation-delegate approach because
    /// sign-in involves multiple redirects before the final authenticated page sets the
    /// session cookie. A MainActor task loop (rather than a `Timer`) keeps the whole
    /// poll on the main actor — no nonisolated timer closure touching actor state.
    ///
    /// - Parameter onFound: Called on the main thread with the session key value.
    func startCookiePolling(onFound: @escaping (String) -> Void) {
        cookieTask?.cancel()
        cookieTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let cookies = await self.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                let claudeCookies = cookies.filter(\.isClaudeDomain)
                #if DEBUG
                if !claudeCookies.isEmpty {
                    let names = claudeCookies.map(\.name).joined(separator: ", ")
                    print("[ClaudeTracker] Cookies visible during login poll: \(names)")
                }
                #endif
                if let session = claudeCookies.first(where: { $0.name == "sessionKey" }) {
                    guard !Task.isCancelled else { return }
                    self.cookieTask = nil
                    onFound(session.value)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stops an in-progress cookie poll without invoking the callback.
    func stopCookiePolling() {
        cookieTask?.cancel()
        cookieTask = nil
    }

    // MARK: - Page Readiness

    /// Ensures the web view has finished loading `claude.ai` so `fetch()` calls run with
    /// the correct origin and session cookies.
    ///
    /// All concurrent callers share a single page load — each call appends a continuation
    /// that is resumed together once the page is ready, preventing duplicate navigation requests.
    ///
    /// - Throws: `APIError.networkError` if the page fails to load or never becomes ready
    ///   within 30 s; `CancellationError` if the calling task is cancelled while waiting.
    func ensureReady() async throws {
        if isPageReady { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyWaiters[waiterID] = continuation
                armReadinessTimeout()
                guard !isLoadingPage else { return }
                isLoadingPage = true
                if let host = webView.url?.host, host.contains("claude.ai"),
                   webView.url?.path != "/login" {
                    checkPageReady()
                } else {
                    webView.load(URLRequest(url: URL(string: "https://claude.ai")!))
                }
            }
        } onCancel: {
            // A cancelled fetch must not leave its continuation suspended in
            // `readyWaiters` — that would leak the task and, before the timeout existed,
            // suspend it forever.
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        readyWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        // The last cancelled waiter must release the load-in-flight flag and the shared
        // timeout: `didFinish` skips `checkPageReady` when no waiters exist, so a stale
        // `isLoadingPage` would park the next caller until the 30 s timeout fires a
        // spurious "Page load timed out".
        if readyWaiters.isEmpty {
            isLoadingPage = false
            readinessTimeoutTask?.cancel()
            readinessTimeoutTask = nil
        }
    }

    /// One shared timeout per load attempt; armed when the first waiter queues up,
    /// cleared when the waiters drain (ready, failure, or teardown).
    private func armReadinessTimeout() {
        guard readinessTimeoutTask == nil else { return }
        readinessTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            self.readinessTimeoutTask = nil
            guard !self.readyWaiters.isEmpty else { return }
            AppLogger.shared.error("page readiness timed out — failing \(self.readyWaiters.count) waiter(s)")
            self.failAllWaiters(with: APIError.networkError(String(localized: "Page load timed out")))
        }
    }

    private func checkPageReady() {
        webView.evaluateJavaScript("document.title") { [weak self] result, error in
            guard let self else { return }
            if let error {
                // The page is unusable (e.g. the web content process died). Fail fast so
                // the next poll reloads — marking a dead page "ready" would turn every
                // subsequent fetch into an opaque network error.
                self.isPageReady = false
                self.failAllWaiters(with: APIError.networkError(error.localizedDescription))
                return
            }
            let title = (result as? String) ?? ""
            if title.lowercased().contains("just a moment") {
                // Still on the Cloudflare challenge page — wait for the next didFinish event.
                return
            }
            self.isPageReady = true
            self.isLoadingPage = false
            self.resumeAllWaiters()
        }
    }

    private func resumeAllWaiters() {
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        let waiters = readyWaiters
        readyWaiters = [:]
        waiters.values.forEach { $0.resume() }
    }

    private func failAllWaiters(with error: Error) {
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        let waiters = readyWaiters
        readyWaiters = [:]
        isLoadingPage = false
        waiters.values.forEach { $0.resume(throwing: error) }
    }

    // MARK: - API Calls via WebView fetch()

    /// Fetches the authenticated user's account profile.
    ///
    /// - Returns: An `AccountInfo` value containing name, email, and membership details.
    /// - Throws: `APIError` on network failure, HTTP error, or JSON decode failure.
    func fetchAccountInfo() async throws -> AccountInfo {
        try await ensureReady()
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                """
                const r = await fetch('/api/account', { credentials: 'include' });
                if (!r.ok) throw new Error('HTTP_' + r.status);
                return JSON.stringify(await r.json());
                """,
                contentWorld: .defaultClient
            )
        } catch {
            throw mapJSError(error)
        }
        guard let str = result as? String, let data = str.data(using: .utf8) else {
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode(AccountInfo.self, from: data)
    }

    /// Fetches current usage windows for the user's organisation.
    ///
    /// - Returns: A `UsageResponse` containing utilization percentages and reset timestamps.
    /// - Throws: `APIError` on network failure, HTTP error, or JSON decode failure.
    func fetchUsage() async throws -> UsageResponse {
        try await ensureReady()

        let orgId = try await resolveOrgId()
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                """
                const r = await fetch('/api/organizations/' + orgId + '/usage', { credentials: 'include' });
                if (!r.ok) throw new Error('HTTP_' + r.status);
                return JSON.stringify(await r.json());
                """,
                arguments: ["orgId": orgId],
                contentWorld: .defaultClient
            )
        } catch {
            throw mapJSError(error)
        }

        guard let str = result as? String, let data = str.data(using: .utf8) else {
            throw APIError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            // Log the payload head so an API format change is diagnosable from the log file.
            AppLogger.shared.error("usage decode failed: \(error) — payload: \(str.prefix(500))")
            throw error
        }
    }

    // MARK: - Private

    private func resolveOrgId() async throws -> String {
        if let cached = cachedOrgId { return cached }

        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                """
                const r = await fetch('/api/organizations', { credentials: 'include' });
                if (!r.ok) throw new Error('HTTP_' + r.status);
                return JSON.stringify(await r.json());
                """,
                contentWorld: .defaultClient
            )
        } catch {
            throw mapJSError(error)
        }

        guard let str = result as? String, let data = str.data(using: .utf8) else {
            throw APIError.invalidResponse
        }
        let orgs = try JSONDecoder().decode([Organization].self, from: data)
        guard let org = orgs.first else { throw APIError.noOrganization }
        cachedOrgId = org.uuid
        cachedOrgName = org.name
        return org.uuid
    }

    /// Translates JavaScript `Error` messages from `callAsyncJavaScript` into typed `APIError` values.
    ///
    /// `callAsyncJavaScript` propagates JS `throw` as a generic `NSError` whose description contains
    /// the thrown string — e.g. `"HTTP_401"`. Status codes are matched by substring to handle
    /// any wrapper text the WebKit runtime may add around the original message.
    private func mapJSError(_ error: Error) -> APIError {
        let msg = error.localizedDescription
        if msg.contains("HTTP_401") || msg.contains("HTTP_403") {
            isPageReady = false
            cachedOrgId = nil
            cachedOrgName = nil
            return .unauthorized
        }
        if msg.contains("HTTP_429") { return .rateLimited }
        if msg.contains("HTTP_404") {
            // The cached org may no longer exist for this user (membership change,
            // server-side migration) — drop the memo so the next fetch re-resolves
            // the org list instead of failing on the stale UUID until app restart.
            cachedOrgId = nil
            cachedOrgName = nil
            return .httpError(msg)
        }
        if msg.contains("HTTP_") { return .httpError(msg) }
        return .networkError(msg)
    }

    // MARK: - WKUIDelegate

    /// Creates a popup WKWebView for OAuth flows (e.g. "Continue with Google").
    ///
    /// WebKit passes the window-opener's configuration so the popup shares the same data store
    /// and cookies. Returning a real WKWebView wires `window.opener` correctly so the OAuth
    /// provider can post a message back to the login page after authentication completes.
    /// Only `uiDelegate` is set on the popup — setting `navigationDelegate` would cause
    /// `failAllWaiters`/`checkPageReady` to misfire for popup navigations.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        popupWebView = popup
        onPopupRequested?(popup, windowFeatures)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView {
            popupWebView = nil
            onPopupDismissed?()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only check readiness when callers are waiting; routine background navigations are ignored.
        if !readyWaiters.isEmpty {
            checkPageReady()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // A failed navigation leaves the page broken; without resetting readiness,
        // ensureReady keeps short-circuiting and every fetch runs against the dead
        // page until a 401 or a WebKit process crash happens to clear the flag.
        isPageReady = false
        isLoadingPage = false
        failAllWaiters(with: APIError.networkError(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // NSURLErrorCancelled fires on every redirect — safe to ignore.
        if (error as NSError).code == NSURLErrorCancelled { return }
        isPageReady = false
        isLoadingPage = false
        failAllWaiters(with: APIError.networkError(error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Without this, a killed WebKit process leaves `isPageReady` stale and polling
        // degrades into a permanent error loop until a 401 happens to clear it.
        AppLogger.shared.error("web content process terminated — reloading claude.ai")
        isPageReady = false
        isLoadingPage = false
        failAllWaiters(with: APIError.networkError(String(localized: "Browser engine restarted")))
        webView.reload()
    }

    // MARK: - Errors

    /// Errors that can be thrown by API calls.
    enum APIError: LocalizedError {
        case noOrganization
        case invalidResponse
        case unauthorized
        case rateLimited
        case httpError(String)
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .noOrganization: return String(localized: "No organization found")
            case .invalidResponse: return String(localized: "Invalid API response")
            case .unauthorized: return String(localized: "Session expired — please sign in again")
            case .rateLimited: return String(localized: "Rate limited — retrying shortly")
            case .httpError(let s): return String(localized: "Server error: \(s)")
            case .networkError(let s): return String(localized: "Network error: \(s)")
            }
        }
    }
}
