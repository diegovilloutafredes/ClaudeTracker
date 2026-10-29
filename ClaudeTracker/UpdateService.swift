import Foundation
import AppKit
import CryptoKit

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

    let assets = latest["assets"] as? [[String: Any]] ?? []
    func assetURL(_ matches: (String) -> Bool) -> (name: String, url: URL)? {
        for asset in assets {
            if let name = asset["name"] as? String, matches(name),
               let url = (asset["browser_download_url"] as? String).flatMap(URL.init) { return (name, url) }
        }
        return nil
    }
    // In-app install needs the zip's signature; without one the release page is the only path.
    guard let zip = assetURL({ $0.hasSuffix(".zip") }),
          let signature = assetURL({ $0 == zip.name + ".sig" }) else {
        return (UpdateInfo(version: remote, releaseURL: releaseUrl, downloadURL: nil), dates)
    }
    return (UpdateInfo(version: remote, releaseURL: releaseUrl, downloadURL: zip.url, signatureURL: signature.url), dates)
}

/// Public half of the release-signing key, whose private half lives only in the maintainer's
/// Keychain (`scripts/update-signing.swift`). Compiled in rather than read from Info.plist:
/// a tampered bundle is exactly what it defends against. Rotating it means a release whose
/// users then install by hand once.
let updateSigningPublicKey = Data(base64Encoded: "rnHlUrHGhtrUIQAgZxvIHG5vO1kvTZNxRDR+KTFmcIg=") ?? Data()

/// `update` without its in-app install when it is the release whose signature was rejected
/// this session: Install would only fail the same way, so the UI falls back to the release
/// page's Download link.
func installableUpdate(_ update: UpdateInfo, signatureRejectedVersion: String?) -> UpdateInfo {
    guard update.version == signatureRejectedVersion else { return update }
    return UpdateInfo(version: update.version, releaseURL: update.releaseURL, downloadURL: nil)
}

/// True when `signature` is a valid Ed25519 signature of `data` by the raw 32-byte
/// `publicKey`. Malformed keys or signatures are simply invalid.
func verifyUpdateSignature(_ data: Data, signature: Data, publicKey: Data) -> Bool {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
    return key.isValidSignature(signature, for: data)
}

/// Atomically replaces the item at `dest` with a copy of `source`.
///
/// Stages the copy as a sibling of `dest` (same volume), moves the old item aside,
/// swaps the staged copy in, and only then deletes the old item — so a failure at any
/// step leaves either the original or the new item at `dest`. In the double-failure
/// case (swap fails AND the rollback fails), `dest` can end up empty; the staged copy
/// is then deliberately left on disk as the only surviving intact bundle.
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
        if hadExisting, (try? fm.moveItem(at: backup, to: dest)) == nil {
            // Rollback failed too — dest is empty. Retry the staged copy once; if that
            // also fails, the staged copy is the only intact bundle left.
            try? fm.moveItem(at: staging, to: dest)
        }
        // The staged copy is disposable only once dest is occupied again (or never
        // was); deleting it while dest is empty would leave nothing at all.
        if !hadExisting || fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: staging)
        }
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

/// Where an update installs: over the running bundle when its folder is writable (e.g.
/// `~/Applications` for a standard user, who can't write `/Applications`), else `fallback`
/// — a translocated or disk-image launch runs from a read-only folder.
func installDestination(runningBundle: URL, fallback: URL) -> URL {
    FileManager.default.isWritableFile(atPath: runningBundle.deletingLastPathComponent().path) ? runningBundle : fallback
}

/// Automatic installs of one release that auto-install sets off before it stops trying it by
/// itself. Counted when they start, so one that is cut short counts too.
let maxAutoInstallAttempts = 3

/// The count after one more automatic install of `version` is set off, given the persisted
/// record: counting restarts when a different release is tried. (The name is from when the
/// count was of failures.)
func installFailureCount(version: String, failedVersion: String, previousCount: Int) -> Int {
    (version == failedVersion ? previousCount : 0) + 1
}

/// How many automatic installs of `version` have been set off, from the saved record. The
/// record holds one release at a time: another release starts from nothing, or three tries of
/// one release would keep every later one from installing itself.
func installAttempts(version: String, attemptedVersion: String, attemptedCount: Int) -> Int {
    version == attemptedVersion ? max(attemptedCount, 0) : 0
}

/// Whether the next update check should start the install again by itself. Past the cap a
/// failure is treated as permanent (e.g. an unwritable destination): retrying would show a
/// toast and redownload on every check and wake, forever.
func shouldRetryAutoInstall(failures: Int) -> Bool {
    failures < maxAutoInstallAttempts
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
/// `UsageViewModel` holds it as `var updates` (reference-writable for `@Bindable`); views read `viewModel.updates.<x>` and
/// SwiftUI's transitive `@Observable` tracking keeps them in sync. Side-effecting
/// startup happens in `start()` (called at app launch), never in an initializer.
@Observable @MainActor
final class UpdateService {
    var availableUpdate: UpdateInfo? = nil
    var isCheckingForUpdates = false
    var updateDownloadState: UpdateDownloadState = .idle
    // Default ON — installs stay current with zero interaction; opt out in Settings.
    var autoUpdate: Bool = true {
        didSet {
            guard autoUpdate != oldValue else { return }
            UserDefaults.standard.set(autoUpdate, forKey: PrefKey.autoUpdate)
            schedulePeriodicUpdateCheck()
        }
    }

    @ObservationIgnored private var updateCheckTask: Task<Void, Never>?
    /// The release last announced for an install by hand: a toast says so once per version.
    @ObservationIgnored private var lastNotifiedUpdateVersion: String = ""
    /// The release whose automatic install was last set off, and how many times. Saved under
    /// `PrefKey.failedInstallVersion`/`failedInstallCount`, names from when failures were counted.
    @ObservationIgnored private var attemptedInstallVersion: String = ""
    @ObservationIgnored private var attemptedInstallCount = 0
    /// True during the ten seconds between announcing an automatic install and starting it.
    @ObservationIgnored private var countingDown = false
    /// The release whose signature failed verification this session (`installableUpdate`).
    @ObservationIgnored private var signatureRejectedVersion: String?
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
        attemptedInstallVersion = UserDefaults.standard.string(forKey: PrefKey.failedInstallVersion) ?? ""
        attemptedInstallCount = UserDefaults.standard.integer(forKey: PrefKey.failedInstallCount)
        let savedCheckInterval = UserDefaults.standard.double(forKey: PrefKey.updateCheckInterval)
        if savedCheckInterval >= 4 * 3600 { nextCheckInterval = savedCheckInterval }
        // Set autoUpdate last so its didSet fires with nextCheckInterval already correct.
        autoUpdate = UserDefaults.standard.object(forKey: PrefKey.autoUpdate) as? Bool ?? true
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

            if let update = update.map({ installableUpdate($0, signatureRejectedVersion: signatureRejectedVersion) }) {
                availableUpdate = update
                if shouldAutoInstall(update) {
                    if case .idle = updateDownloadState, !countingDown { triggerAutoInstall(update) }
                } else if !isBusy {
                    announce(update)
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

    /// True while a download or an install is under way.
    private var isBusy: Bool {
        switch updateDownloadState {
        case .downloading, .installing: return true
        case .idle, .failed: return false
        }
    }

    /// Whether a check sets the update's install off by itself: auto-install is on, the release
    /// can be installed in-app, and it has not already been started `maxAutoInstallAttempts` times.
    private func shouldAutoInstall(_ update: UpdateInfo) -> Bool {
        let attempts = installAttempts(version: update.version, attemptedVersion: attemptedInstallVersion,
                                       attemptedCount: attemptedInstallCount)
        return autoUpdate && update.downloadURL != nil && shouldRetryAutoInstall(failures: attempts)
    }

    /// Says, once per version and across restarts, that an update is there to be installed by hand.
    private func announce(_ update: UpdateInfo) {
        guard lastNotifiedUpdateVersion != update.version else { return }
        lastNotifiedUpdateVersion = update.version
        UserDefaults.standard.set(update.version, forKey: PrefKey.lastNotifiedUpdateVersion)
        AppLogger.shared.info("update: v\(update.version) is available" + (update.downloadURL == nil ? " (as a download only)" : ""))
        ToastWindowController.shared.show(
            title: String(localized: "Update available"),
            message: String(format: String(localized: "v%@ is ready — open Settings to install"), update.version),
            icon: "arrow.up.circle.fill",
            iconColor: .green,
            duration: 12,
            permanent: false
        )
    }

    /// Counted before it starts, and saved before it is counted on. Counted only when it failed,
    /// an install that never got to fail — the Mac shut down, the app quit during the countdown
    /// or the download — was never tried again, because the version was already marked as
    /// announced. Switching auto-install off during the countdown still uses up one of the three.
    private func triggerAutoInstall(_ update: UpdateInfo) {
        let attempt = installFailureCount(version: update.version, failedVersion: attemptedInstallVersion,
                                          previousCount: attemptedInstallCount)
        attemptedInstallVersion = update.version
        attemptedInstallCount = attempt
        UserDefaults.standard.set(update.version, forKey: PrefKey.failedInstallVersion)
        UserDefaults.standard.set(attempt, forKey: PrefKey.failedInstallCount)
        AppLogger.shared.info("update: v\(update.version) is available; installing it (automatic attempt \(attempt) of \(maxAutoInstallAttempts))")
        let msg = String(format: String(localized: "v%@ found — installing in ~10s"), update.version)
        ToastWindowController.shared.show(
            title: String(localized: "Update available"),
            message: msg,
            icon: "arrow.down.circle.fill",
            iconColor: .green,
            duration: 12,
            permanent: false
        )
        countingDown = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            // Re-check: the user may have flipped auto-install off during the countdown.
            guard let self else { return }
            self.countingDown = false
            guard self.autoUpdate else { return }
            self.downloadAndInstall(automatic: true)
        }
    }

    /// Downloads, verifies and installs `availableUpdate`. `automatic` is for the log: a try by
    /// hand ("Install", also after a failure) is not one of the three automatic ones.
    func downloadAndInstall(automatic: Bool = false) {
        guard let update = availableUpdate, let downloadURL = update.downloadURL,
              let signatureURL = update.signatureURL, !isBusy else { return }
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

                // Nothing is unzipped until the zip verifies against the embedded key: HTTPS
                // only proves the bytes came from GitHub, not from the maintainer.
                let (signature, _) = try await URLSession.shared.data(from: signatureURL)
                guard verifyUpdateSignature(try Data(contentsOf: zipURL), signature: signature,
                                            publicKey: updateSigningPublicKey) else {
                    throw UpdateError.signatureInvalid
                }

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
                // touching the installed app — the download URL was discovered up to 24 h earlier
                // and the release asset could have changed since.
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                guard let extractedVersion = bundleShortVersion(at: appURL),
                      isNewerVersion(extractedVersion, than: current) else {
                    throw UpdateError.versionMismatch
                }

                // Atomic stage-and-swap: a failure at any step leaves either the old or the
                // new bundle at the destination — never an empty slot. The old bundle path is
                // fully replaced (new inode), so Launch Services can't serve a stale cached
                // binary.
                let dest = installDestination(runningBundle: Bundle.main.bundleURL,
                                              fallback: URL(fileURLWithPath: "/Applications/ClaudeTracker.app"))
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
                // The script waits for the old process to actually exit (up to ~10 s, then
                // pkill as a last resort) before `open` — a fixed sleep raced slow teardowns,
                // where `open` re-activated the dying instance and the app never came back.
                let relaunchScript = """
                #!/bin/bash
                for _ in $(seq 1 20); do
                  pgrep -x ClaudeTracker >/dev/null || break
                  sleep 0.5
                done
                pkill -x ClaudeTracker 2>/dev/null
                sleep 0.3
                open "$1"

                """
                let scriptURL = tmpBase.appendingPathComponent("relaunch.sh")
                var usedScript = false
                if (try? relaunchScript.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/bash")
                    // The destination travels as an argument, never spliced into the script.
                    p.arguments = [scriptURL.path, dest.path]
                    usedScript = (try? p.run()) != nil
                }
                try await Task.sleep(for: .milliseconds(300))
                if !usedScript {
                    NSWorkspace.shared.open(dest)
                    try await Task.sleep(for: .milliseconds(500))
                }
                NSApp.terminate(nil)
            } catch {
                updateDownloadState = .failed(error.localizedDescription)
                if case UpdateError.signatureInvalid = error {
                    signatureRejectedVersion = update.version
                    availableUpdate = installableUpdate(update, signatureRejectedVersion: update.version)
                }
                recordInstallFailure(version: update.version, error: error, automatic: automatic)
            }
        }
    }

    /// Logs an install that failed. An automatic one was counted when it was set off, so the
    /// next check starts it again while it is under `maxAutoInstallAttempts`. When it was the
    /// last one this release is allowed, one toast points at the manual way and stands as the
    /// announcement, so later checks add nothing to it.
    private func recordInstallFailure(version: String, error: Error, automatic: Bool) {
        let attempts = installAttempts(version: version, attemptedVersion: attemptedInstallVersion,
                                       attemptedCount: attemptedInstallCount)
        let which = automatic ? "automatic attempt \(attempts) of \(maxAutoInstallAttempts)" : "asked for by hand"
        AppLogger.shared.error("update failed (v\(version), \(which)): \(error)")
        if automatic, !shouldRetryAutoInstall(failures: attempts) {
            lastNotifiedUpdateVersion = version
            UserDefaults.standard.set(version, forKey: PrefKey.lastNotifiedUpdateVersion)
            ToastWindowController.shared.show(
                title: String(localized: "Update failed"),
                message: String(format: String(localized: "Couldn't install v%@ automatically — open Settings to install it"), version),
                icon: "exclamationmark.triangle.fill",
                iconColor: .orange,
                duration: 12,
                permanent: false
            )
        }
    }

    private enum UpdateError: LocalizedError {
        case extractionFailed, appNotFound, versionMismatch, signatureInvalid
        var errorDescription: String? {
            switch self {
            case .signatureInvalid:   return String(localized: "Update signature is invalid")
            case .extractionFailed:   return String(localized: "Failed to extract update")
            case .appNotFound:        return String(localized: "Update package is invalid")
            case .versionMismatch:    return String(localized: "Update package version mismatch")
            }
        }
    }
}
