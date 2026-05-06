import Foundation

/// One-shot migration that runs the first time ClaudeTracker launches without
/// the App Sandbox entitlement.
///
/// Removing `com.apple.security.app-sandbox` moves the app's data root from
/// `~/Library/Containers/com.claudetracker.app/Data/...` to the standard
/// per-user locations (`~/Library/Preferences`, etc.). Without this migration
/// existing users would see their `accounts`, per-account `usageHistory`,
/// settings (popupScale, toggles, autoUpdate, paceWarned state, etc.) all
/// reset to defaults on upgrade.
///
/// We migrate two things:
/// 1. **UserDefaults** — read the container plist directly and import keys that
///    don't already exist in the new location.
/// 2. **WKWebsiteDataStore directories** — copy any per-identifier data stores
///    (cookies, IndexedDB, LocalStorage) from the container WebKit dir into
///    the non-sandboxed location. This is a plain file copy; WKWebKit doesn't
///    care which absolute path a `WKWebsiteDataStore(forIdentifier:)` directory
///    lives at, only that the structure is intact.
enum SandboxMigration {
    private static let doneKey = "sandboxMigrationCompleted"
    private static let bundleID = "com.claudetracker.app"

    /// Runs at most once. Subsequent launches no-op via the `doneKey` marker.
    /// Must run before any code reads UserDefaults or instantiates a
    /// `WKWebsiteDataStore` — call from app init.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        migrateUserDefaults(into: defaults)
        migrateWebKitDataStores()
    }

    private static func migrateUserDefaults(into defaults: UserDefaults) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let containerPlist = home.appendingPathComponent(
            "Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist"
        )

        guard FileManager.default.fileExists(atPath: containerPlist.path),
              let data = try? Data(contentsOf: containerPlist),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return }

        var imported = 0
        for (key, value) in plist {
            // Don't clobber values that already exist (matters on partial re-runs
            // or when the user has already done some setup post-migration).
            if defaults.object(forKey: key) != nil { continue }
            defaults.set(value, forKey: key)
            imported += 1
        }
        AppLogger.shared.info("Sandbox migration: imported \(imported) UserDefaults keys from container")
    }

    private static func migrateWebKitDataStores() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let containerStores = home.appendingPathComponent(
            "Library/Containers/\(bundleID)/Data/Library/WebKit/WebsiteDataStore"
        )
        let targetStores = home.appendingPathComponent(
            "Library/WebKit/\(bundleID)/WebsiteDataStore"
        )

        guard let entries = try? fm.contentsOfDirectory(at: containerStores,
                                                       includingPropertiesForKeys: nil) else {
            return
        }

        // Make sure the destination parent exists. Subdirectories are copied
        // wholesale by FileManager.copyItem, which preserves cookies and
        // IndexedDB intact.
        try? fm.createDirectory(at: targetStores, withIntermediateDirectories: true)

        var copied = 0
        for src in entries {
            let dst = targetStores.appendingPathComponent(src.lastPathComponent)
            // The migration runs exactly once (gated by `doneKey`), so if a
            // destination already exists it's stale — from a prior non-sandboxed
            // run before the app was ever sandboxed. The container is the
            // canonical source of truth, so always overwrite.
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            do {
                try fm.copyItem(at: src, to: dst)
                copied += 1
            } catch {
                AppLogger.shared.error("WebKit migration copy failed for \(src.lastPathComponent): \(error)")
            }
        }
        AppLogger.shared.info("Sandbox migration: copied \(copied) WebKit data stores from container")
    }
}
