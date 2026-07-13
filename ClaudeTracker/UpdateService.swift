import Foundation
import AppKit

/// Parses the GitHub `releases?per_page=N` JSON payload.
///
/// Returns the newest release as an `UpdateInfo` when it is strictly newer than
/// `currentVersion` (nil otherwise), plus all `published_at` dates for the adaptive
/// check-interval computation. Malformed payloads (e.g. a rate-limit error dict
/// instead of an array) yield `(nil, [])`.
func parseGitHubReleases(_ data: Data, currentVersion: String) -> (update: UpdateInfo?, releaseDates: [Date]) {
    guard let releases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        return (nil, [])
    }

    let fmt = ISO8601DateFormatter()
    let dates = releases.compactMap { r -> Date? in
        guard let s = r["published_at"] as? String else { return nil }
        return fmt.date(from: s)
    }

    // Pre-releases and drafts must never reach auto-update users — a beta published
    // for testing would otherwise install itself into /Applications within a day.
    let stable = releases.filter {
        ($0["prerelease"] as? Bool) != true && ($0["draft"] as? Bool) != true
    }
    guard let latest = stable.first,
          let tag = latest["tag_name"] as? String,
          let htmlUrl = latest["html_url"] as? String,
          let releaseUrl = URL(string: htmlUrl) else { return (nil, dates) }

    let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    guard isNewerVersion(remote, than: currentVersion) else { return (nil, dates) }

    let assets = latest["assets"] as? [[String: Any]]
    let zipAsset = assets?.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
    let downloadURL = (zipAsset?["browser_download_url"] as? String).flatMap(URL.init)
    return (UpdateInfo(version: remote, releaseURL: releaseUrl, downloadURL: downloadURL), dates)
}

/// Atomically replaces the item at `dest` with a copy of `source`.
///
/// Stages the copy as a sibling of `dest` (same volume), moves the old item aside,
/// swaps the staged copy in, and only then deletes the old item — so a failure at any
/// step leaves either the original or the new item at `dest`, never nothing.
func atomicReplaceItem(at dest: URL, with source: URL) throws {
    let fm = FileManager.default
    let parent = dest.deletingLastPathComponent()
    let staging = parent.appendingPathComponent(".\(dest.lastPathComponent).staging-\(UUID().uuidString)")
    let backup = parent.appendingPathComponent(".\(dest.lastPathComponent).old-\(UUID().uuidString)")

    // 1. Copy onto the destination volume first — the only slow/likely-to-fail step,
    //    and it happens while the original is still intact.
    try fm.copyItem(at: source, to: staging)

    // 2. Move the original aside (fast same-volume rename). Skipped when dest doesn't exist.
    let hadExisting = fm.fileExists(atPath: dest.path)
    if hadExisting {
        do {
            try fm.moveItem(at: dest, to: backup)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // 3. Swap the staged copy in; roll the original back if the rename fails.
    do {
        try fm.moveItem(at: staging, to: dest)
    } catch {
        if hadExisting { try? fm.moveItem(at: backup, to: dest) }
        try? fm.removeItem(at: staging)
        throw error
    }

    // 4. Only now is the old copy disposable.
    if hadExisting { try? fm.removeItem(at: backup) }
}

/// Reads `CFBundleShortVersionString` from an app bundle's Info.plist without loading it.
func bundleShortVersion(at appURL: URL) -> String? {
    let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return plist["CFBundleShortVersionString"] as? String
}

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
            UserDefaults.standard.set(autoUpdate, forKey: PrefKey.autoUpdate)
            schedulePeriodicUpdateCheck()
        }
    }

    @ObservationIgnored private var updateCheckTask: Task<Void, Never>?
    @ObservationIgnored private var lastNotifiedUpdateVersion: String = ""
    /// Adaptive check interval (seconds), computed from release cadence. Clamped 4h–24h.
    private var nextCheckInterval: TimeInterval = 12 * 3600

    var updateCheckIntervalLabel: String {
        let h = (nextCheckInterval / 3600).rounded()
        if h < 24 {
            return String(format: String(localized: "Checks every ~%dh — on launch and wake"), Int(h))
        }
        return String(format: String(localized: "Checks every ~%dd — on launch and wake"),
                      max(1, Int((h / 24).rounded())))
    }

    /// Loads persisted update preferences and kicks off the periodic timer plus a one-shot
    /// check 10 s after launch. Called from `UsageViewModel.start()`, not from `init`, so a
    /// bare `UsageViewModel()`/`UpdateService()` in a test does not hit the network.
    func start() {
        lastNotifiedUpdateVersion = UserDefaults.standard.string(forKey: PrefKey.lastNotifiedUpdateVersion) ?? ""
        let savedCheckInterval = UserDefaults.standard.double(forKey: PrefKey.updateCheckInterval)
        if savedCheckInterval >= 4 * 3600 { nextCheckInterval = savedCheckInterval }
        // Set autoUpdate last so its didSet fires with nextCheckInterval already correct.
        autoUpdate = UserDefaults.standard.object(forKey: PrefKey.autoUpdate) as? Bool ?? false
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
            let data: Data
            do {
                let (d, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    AppLogger.shared.error("update check failed: HTTP \(http.statusCode)")
                    return
                }
                data = d
            } catch {
                AppLogger.shared.error("update check failed: \(error.localizedDescription)")
                return
            }

            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let (update, dates) = parseGitHubReleases(data, currentVersion: current)

            if let update {
                availableUpdate = update

                // Only notify once per discovered version (persisted across restarts)
                if lastNotifiedUpdateVersion != update.version {
                    lastNotifiedUpdateVersion = update.version
                    UserDefaults.standard.set(update.version, forKey: PrefKey.lastNotifiedUpdateVersion)
                    if autoUpdate, update.downloadURL != nil {
                        if case .idle = updateDownloadState { triggerAutoInstall() }
                    } else {
                        ToastWindowController.shared.show(
                            title: String(localized: "Update available"),
                            message: String(format: String(localized: "v%@ is ready — open Settings to install"), update.version),
                            icon: "arrow.up.circle.fill",
                            iconColor: .green,
                            duration: 12,
                            permanent: false
                        )
                    }
                }
            }

            // Derive the next adaptive check interval from the release cadence.
            let computed = adaptiveCheckInterval(from: dates)
            if computed != nextCheckInterval {
                nextCheckInterval = computed
                UserDefaults.standard.set(computed, forKey: PrefKey.updateCheckInterval)
                AppLogger.shared.info("update check interval adjusted to \(Int(computed / 3600))h based on release cadence")
                if autoUpdate { schedulePeriodicUpdateCheck() }
            }
        }
    }

    /// MainActor sleep loop (rather than a Combine timer) so the periodic check never
    /// runs in a nonisolated closure — Swift 6 strict-concurrency clean.
    private func schedulePeriodicUpdateCheck() {
        updateCheckTask?.cancel()
        updateCheckTask = nil
        guard autoUpdate else { return }
        let interval = nextCheckInterval
        updateCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.checkForUpdates()
            }
        }
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
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            // Re-check: the user may have flipped auto-install off during the countdown.
            guard let self, self.autoUpdate else { return }
            self.downloadAndInstall()
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

                // Verify the extracted bundle is actually the promised newer version before
                // touching /Applications — the download URL was discovered up to 24 h earlier
                // and the release asset could have changed since.
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                guard let extractedVersion = bundleShortVersion(at: appURL),
                      isNewerVersion(extractedVersion, than: current) else {
                    throw UpdateError.versionMismatch
                }

                // Atomic stage-and-swap: a failure at any step leaves either the old or the
                // new bundle at the destination — never an empty /Applications slot. The old
                // bundle path is fully replaced (new inode), so Launch Services can't serve
                // a stale cached binary.
                let dest = URL(fileURLWithPath: "/Applications/ClaudeTracker.app")
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try atomicReplaceItem(at: dest, with: appURL)
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }

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
        case extractionFailed, appNotFound, installationFailed, versionMismatch
        var errorDescription: String? {
            switch self {
            case .extractionFailed:   return String(localized: "Failed to extract update")
            case .appNotFound:        return String(localized: "Update package is invalid")
            case .installationFailed: return String(localized: "Installation failed")
            case .versionMismatch:    return String(localized: "Update package version mismatch")
            }
        }
    }
}
