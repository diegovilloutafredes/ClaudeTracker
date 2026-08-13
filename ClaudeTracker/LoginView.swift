import SwiftUI
import WebKit

// MARK: - Login Window Controller

/// Manages the lifecycle of the browser-based sign-in window.
///
/// Reuses a single `NSWindow` across calls — clicking "Sign in" while the window is already
/// open brings it to front rather than creating a duplicate.
@MainActor
final class LoginWindowController {
    static let shared = LoginWindowController()
    private var window: NSWindow?
    private var popupWindow: NSWindow?
    private var popupWindowObserver: NSObjectProtocol?
    private var loginWindowObserver: NSObjectProtocol?
    private var sessionFound = false
    private var onCancel: (() -> Void)?
    /// The 1.5 s success-state auto-close. Cancellable: a stale timer from a previous
    /// attempt firing into a reused window would close it mid-flow for the *next*
    /// account and run the wrong rollback.
    private var autoCloseTask: Task<Void, Never>?

    /// Opens the sign-in window, or focuses it if already visible.
    ///
    /// - Parameters:
    ///   - apiService: Provides the `WKWebView` to embed and the cookie-polling API. The web
    ///     view's data store determines which account's cookie jar receives the new session.
    ///   - onSessionFound: Called on the main thread once a session cookie is detected.
    ///     The window closes automatically 1.5 s after this callback fires to let the
    ///     user see the success state before it disappears.
    ///   - onCancel: Called if the user closes the window before any session was captured.
    ///     Used by `addAccount` to roll back the placeholder account row.
    func open(
        apiService: ClaudeAPIService,
        onSessionFound: @escaping (String) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        apiService.onPopupRequested = { [weak self] popupView, _ in
            self?.showPopup(webView: popupView)
        }
        apiService.onPopupDismissed = { [weak self] in
            self?.closePopup()
        }

        // A second `open` while the window is already visible abandons the previous
        // sign-in attempt (e.g. "Add account" clicked twice): run its rollback so the
        // earlier placeholder account doesn't linger in the roster.
        let isReuse = window?.isVisible == true
        if isReuse, !sessionFound { self.onCancel?() }

        autoCloseTask?.cancel()
        autoCloseTask = nil
        sessionFound = false
        self.onCancel = onCancel

        let loginView = LoginView(
            apiService: apiService,
            onSessionFound: { [weak self] key in
                self?.sessionFound = true
                onSessionFound(key)
                self?.autoCloseTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    self?.close()
                }
            }
        )

        if isReuse, let existing = window {
            // Rebind the window to the new apiService and callbacks. Keeping the old
            // content view would capture the session into the wrong account's data
            // store and fire the wrong onSessionFound. Swapping the hosting view runs
            // the old LoginView's onDisappear (stops its cookie polling) and the new
            // one's onAppear (loads the login page on the new web view).
            existing.contentView = NSHostingView(rootView: loginView)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Sign in to Claude")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: loginView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window

        // If the user closes the window without ever capturing a session, run the rollback.
        // Cleanup must run SYNCHRONOUSLY inside the notification: deferring it to a Task
        // let a rapid close→reopen interleave, where the stale task read the replaced
        // properties — removing the new window's observer and firing the new attempt's
        // onCancel (rolling back the account the user was actively signing in to).
        loginWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.sessionFound { self.onCancel?() }
                self.sessionFound = false
                self.onCancel = nil
                if let observer = self.loginWindowObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.loginWindowObserver = nil
                }
            }
        }
    }

    func close() {
        autoCloseTask?.cancel()
        autoCloseTask = nil
        closePopup()
        window?.close()
        window = nil
    }

    private func showPopup(webView: WKWebView) {
        // A second popup request (nested OAuth, e.g. an account picker opening another
        // window) replaces the first. Close the old one through the normal path so its
        // observer is unregistered — an orphaned popup's willClose would otherwise fire
        // closePopup() against the CURRENT popup and kill the active sign-in flow.
        closePopup()
        let popup = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popup.title = String(localized: "Sign in")
        popup.isReleasedWhenClosed = false
        popup.contentView = webView
        if let parent = window {
            popup.center()
            parent.addChildWindow(popup, ordered: .above)
        } else {
            popup.center()
        }
        popup.makeKeyAndOrderFront(nil)
        self.popupWindow = popup

        popupWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: popup,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePopup() }
        }
    }

    private func closePopup() {
        if let observer = popupWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            popupWindowObserver = nil
        }
        popupWindow?.close()
        popupWindow = nil
    }
}

// MARK: - Login View

/// Hosts the embedded web view and a status banner during and after sign-in.
struct LoginView: View {
    let apiService: ClaudeAPIService
    let onSessionFound: (String) -> Void
    @State private var found = false

    var body: some View {
        VStack(spacing: 0) {
            if found {
                successBanner
            } else {
                infoBanner
            }
            WebViewWrapper(webView: apiService.webView)
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            apiService.loadLoginPage()
            apiService.startCookiePolling { key in
                found = true
                onSessionFound(key)
            }
        }
        .onDisappear {
            apiService.stopCookiePolling()
        }
    }

    private var infoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text("Sign in to your Claude account. The session will be captured automatically.")
                .font(.subheadline)
            Spacer()
        }
        .padding(10)
        .background(.blue.opacity(0.1))
    }

    private var successBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Signed in! Closing…")
                .font(.subheadline.bold())
            Spacer()
        }
        .padding(10)
        .background(.green.opacity(0.1))
    }
}

// MARK: - WebView Wrapper

/// Embeds the `ClaudeAPIService` web view into a SwiftUI view hierarchy.
///
/// The web view is owned by `ClaudeAPIService` and shared between the login window and the
/// hidden API context — this wrapper avoids creating a second instance.
struct WebViewWrapper: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
