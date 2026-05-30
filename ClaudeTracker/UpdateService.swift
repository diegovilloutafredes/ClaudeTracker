import Foundation
import AppKit
import Combine

/// Progress state for the in-app update download/install flow.
enum UpdateDownloadState {
    case idle
    case downloading
    case installing
    case failed(String)
}

/// Owns the in-app update flow: discovering newer GitHub releases, the adaptive
/// check schedule, the optional auto-install, and download/install progress.
///
/// Extracted from `UsageViewModel` so the view model stays focused on usage state.
/// `UsageViewModel` holds it as `let updates`; views read `viewModel.updates.<x>` and
/// SwiftUI's transitive `@Observable` tracking keeps them in sync. Side-effecting
/// startup happens in `start()` (called at app launch), never in an initializer.
@Observable @MainActor
final class UpdateService {
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

    @ObservationIgnored private var updateCheckTimer: AnyCancellable?
    @ObservationIgnored private var lastNotifiedUpdateVersion: String = ""
    /// Adaptive check interval (seconds), computed from release cadence. Clamped 4h–24h.
    private var nextCheckInterval: TimeInterval = 12 * 3600

    var updateCheckIntervalLabel: String {
        let h = (nextCheckInterval / 3600).rounded()
        if h < 24 { return "Checks every ~\(Int(h))h — on launch and wake" }
        return "Checks every ~\(max(1, Int((h / 24).rounded())))d — on launch and wake"
    }

    /// Loads persisted update preferences and kicks off the periodic timer plus a one-shot
    /// check 10 s after launch. Called from `UsageViewModel.start()`, not from `init`, so a
    /// bare `UsageViewModel()`/`UpdateService()` in a test does not hit the network.
    func start() {
        lastNotifiedUpdateVersion = UserDefaults.standard.string(forKey: "lastNotifiedUpdateVersion") ?? ""
        let savedCheckInterval = UserDefaults.standard.double(forKey: "updateCheckInterval")
        if savedCheckInterval >= 4 * 3600 { nextCheckInterval = savedCheckInterval }
        // Set autoUpdate last so its didSet fires with nextCheckInterval already correct.
        autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? false
        schedulePeriodicUpdateCheck()
        Task { try? await Task.sleep(for: .seconds(10)); checkForUpdates() }
    }

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

            // Parse release dates and derive the next adaptive check interval.
            let fmt = ISO8601DateFormatter()
            let dates = releases.compactMap { r -> Date? in
                guard let s = r["published_at"] as? String else { return nil }
                return fmt.date(from: s)
            }
            let computed = adaptiveCheckInterval(from: dates)
            if computed != nextCheckInterval {
                nextCheckInterval = computed
                UserDefaults.standard.set(computed, forKey: "updateCheckInterval")
                AppLogger.shared.info("update check interval adjusted to \(Int(computed / 3600))h based on release cadence")
                if autoUpdate { schedulePeriodicUpdateCheck() }
            }
        }
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
