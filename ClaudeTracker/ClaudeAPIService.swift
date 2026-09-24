import Foundation
import WebKit

extension HTTPCookie {
    /// True for cookies set by the claude.ai / anthropic.com session domains.
    var isClaudeDomain: Bool {
        domain.contains("claude.ai") || domain.contains("anthropic.com")
    }
}

/// What a failed in-page `fetch` means, read from the token the fetch script throws.
/// The message comes from `jsExceptionMessage` — the thrown error's `name: message`
/// (e.g. `"Error: HTTP_401"`) — so tokens match by substring.
enum FetchFailure: Equatable {
    /// Cloudflare answered with a challenge page (`cf-mitigated: challenge`). Says nothing
    /// about the session, so it must never count toward expiry; only a real reload passes it.
    case challenge
    /// HTTP 401 or 403.
    case unauthorized
    case rateLimited
    case notFound
    /// Any other HTTP status.
    case http
    /// No HTTP status at all: a transport or script failure.
    case network

    init(message: String) {
        if message.contains("CF_CHALLENGE") {
            self = .challenge
        } else if message.contains("HTTP_401") || message.contains("HTTP_403") {
            self = .unauthorized
        } else if message.contains("HTTP_429") {
            self = .rateLimited
        } else if message.contains("HTTP_404") {
            self = .notFound
        } else if message.contains("HTTP_") {
            self = .http
        } else {
            self = .network
        }
    }
}

/// The message of the JavaScript error a `callAsyncJavaScript` script threw, e.g.
/// `"Error: HTTP_401"`. WebKit's `localizedDescription` is only "A JavaScript exception
/// occurred"; the thrown message travels under the `WKJavaScriptExceptionMessage` userInfo
/// key, which WebKit doesn't export as a constant. Other errors fall back to their description.
func jsExceptionMessage(_ error: Error) -> String {
    (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
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
    private var isPageReady = false
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var isLoadingPage = false
    /// Fails all pending waiters if the page never becomes ready (e.g. a Cloudflare
    /// challenge that never clears). Without this, a stuck page would suspend every
    /// caller forever and silently stop the polling loop.
    private var readinessTimeoutTask: Task<Void, Never>?
    /// Set when the loaded document can't be trusted for the next fetch: after a 401/403, a
    /// Cloudflare-challenged fetch, a readiness timeout, or a failed navigation. `ensureReady`
    /// then does a real top-level load instead of re-reading that same document's title,
    /// which would hand the retry straight back to the page that just failed.
    private var needsReload = false
    private var cachedOrgId: String?
    private(set) var cachedOrgName: String?
    private var cookieTask: Task<Void, Never>?
    private var popupWebView: WKWebView?
    var onPopupRequested: ((WKWebView) -> Void)?
    var onPopupDismissed: (() -> Void)?

    /// Builds an API service backed by a per-identifier `WKWebsiteDataStore` so each account
    /// keeps its cookies (and `sessionKey`) isolated from every other account.
    init(dataStoreIdentifier: UUID) {
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

    /// True while the login window's cookie poll runs. The window shows this service's web
    /// view, so usage fetches must wait: `ensureReady` would navigate it off the sign-in page.
    var isLoginInProgress: Bool { cookieTask != nil }

    /// Polls the shared cookie store every second until a new `sessionKey` cookie appears.
    ///
    /// Cookie inspection requires an asynchronous round-trip into the cookie store; a
    /// poll loop is more reliable here than a navigation-delegate approach because
    /// sign-in involves multiple redirects before the final authenticated page sets the
    /// session cookie. A MainActor task loop (rather than a `Timer`) keeps the whole
    /// poll on the main actor — no nonisolated timer closure touching actor state.
    ///
    /// Only a `sessionKey` that differs from the one present when polling starts counts:
    /// signing an expired account back in reuses its own store, which may still hold the
    /// rejected cookie — accepting that one would report success before the user signed in.
    ///
    /// - Parameter onFound: Called on the main thread with the session key value.
    func startCookiePolling(onFound: @escaping (String) -> Void) {
        cookieTask?.cancel()
        cookieTask = Task { [weak self] in
            let baseline = await self?.sessionKeyValue()
            while !Task.isCancelled {
                guard let self else { return }
                if let session = await self.sessionKeyValue(), session != baseline {
                    guard !Task.isCancelled else { return }
                    self.cookieTask = nil
                    onFound(session)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The claude.ai `sessionKey` cookie currently in this service's data store, if any.
    private func sessionKeyValue() async -> String? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let claudeCookies = cookies.filter(\.isClaudeDomain)
        #if DEBUG
        if !claudeCookies.isEmpty {
            let names = claudeCookies.map(\.name).joined(separator: ", ")
            print("[ClaudeTracker] Cookies visible during login poll: \(names)")
        }
        #endif
        return claudeCookies.first(where: { $0.name == "sessionKey" })?.value
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
                if !needsReload, let host = webView.url?.host, host.contains("claude.ai"),
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
            // A challenge that never cleared stays loaded; only a fresh load retries it.
            self.needsReload = true
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
                self.needsReload = true
                self.failAllWaiters(with: APIError.networkError(error.localizedDescription))
                return
            }
            let title = (result as? String) ?? ""
            // Known limit: matches Cloudflare's English interstitial title only.
            if title.lowercased().contains("just a moment") {
                // Still on the Cloudflare challenge page — wait for the next didFinish event.
                return
            }
            self.isPageReady = true
            self.needsReload = false
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
        let json = try await fetchJSONString("/api/account")
        return try JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8))
    }

    /// Fetches current usage windows for the user's organisation.
    ///
    /// - Returns: A `UsageResponse` containing utilization percentages and reset timestamps.
    /// - Throws: `APIError` on network failure, HTTP error, or JSON decode failure.
    func fetchUsage() async throws -> UsageResponse {
        try await ensureReady()

        let orgId = try await resolveOrgId()
        let json = try await fetchJSONString("/api/organizations/\(orgId)/usage")
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        } catch {
            // Log the payload head so an API format change is diagnosable from the log file.
            AppLogger.shared.error("usage decode failed: \(error) — payload: \(json.prefix(500))")
            throw error
        }
    }

    // MARK: - Private

    private func resolveOrgId() async throws -> String {
        if let cached = cachedOrgId { return cached }

        let json = try await fetchJSONString("/api/organizations")
        let orgs = try JSONDecoder().decode([Organization].self, from: Data(json.utf8))
        guard let org = orgs.first else { throw APIError.noOrganization }
        cachedOrgId = org.uuid
        cachedOrgName = org.name
        return org.uuid
    }

    /// Runs `fetch(path)` inside the page and returns the response body as a JSON string.
    ///
    /// A Cloudflare challenge page (`cf-mitigated: challenge`, checked before the status)
    /// throws `CF_CHALLENGE`; any other non-2xx throws `HTTP_<status>`. `mapJSError` turns
    /// both into `APIError`. The path travels as a script argument, never spliced into code.
    ///
    /// The 30 s abort is the only timeout on this path: `callAsyncJavaScript` doesn't observe
    /// Swift task cancellation, so a stalled fetch would leave the poll suspended forever
    /// (`fetchTask?.cancel()` can't reach it). The abort surfaces as a network error.
    private func fetchJSONString(_ path: String) async throws -> String {
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                """
                const r = await fetch(path, { credentials: 'include', signal: AbortSignal.timeout(30000) });
                if (r.headers.get('cf-mitigated') === 'challenge') throw new Error('CF_CHALLENGE');
                if (!r.ok) throw new Error('HTTP_' + r.status);
                return JSON.stringify(await r.json());
                """,
                arguments: ["path": path],
                contentWorld: .defaultClient
            )
        } catch {
            throw mapJSError(error)
        }
        guard let json = result as? String else { throw APIError.invalidResponse }
        return json
    }

    /// Translates JavaScript `Error` messages from `callAsyncJavaScript` into typed `APIError`
    /// values (classification in `FetchFailure`), applying each failure's side effects.
    private func mapJSError(_ error: Error) -> APIError {
        // Reading `localizedDescription` here classified every failure as `.network`: 401s
        // never counted toward expiry, and challenges and 404s skipped their recovery.
        let msg = jsExceptionMessage(error)
        switch FetchFailure(message: msg) {
        case .challenge:
            // Not a session problem — mapped to a network error so it never counts toward
            // expiry. Only a top-level load passes the challenge.
            isPageReady = false
            needsReload = true
            return .networkError(String(localized: "Cloudflare check — retrying"))
        case .unauthorized:
            // The retry must come from a freshly loaded page, not the document that just
            // failed (a re-read of its title would hand it straight back).
            isPageReady = false
            needsReload = true
            cachedOrgId = nil
            cachedOrgName = nil
            return .unauthorized
        case .rateLimited:
            return .rateLimited
        case .notFound:
            // The cached org may no longer exist for this user (membership change,
            // server-side migration) — drop the memo so the next fetch re-resolves
            // the org list instead of failing on the stale UUID until app restart.
            cachedOrgId = nil
            cachedOrgName = nil
            return .httpError(msg)
        case .http:
            return .httpError(msg)
        case .network:
            return .networkError(msg)
        }
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
        onPopupRequested?(popup)
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
        // needsReload: the URL may still be a claude.ai route, and a title re-read of the
        // broken document would pass readiness without reloading anything.
        isPageReady = false
        needsReload = true
        isLoadingPage = false
        failAllWaiters(with: APIError.networkError(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // NSURLErrorCancelled fires on every redirect — safe to ignore.
        if (error as NSError).code == NSURLErrorCancelled { return }
        isPageReady = false
        needsReload = true
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
