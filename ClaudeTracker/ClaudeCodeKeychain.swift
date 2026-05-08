import Foundation
import Security

/// Bridges ClaudeTracker accounts to the Claude Code CLI's OAuth token,
/// which lives in the macOS login Keychain under the service name
/// `"Claude Code-credentials"` (a single global slot — last `/login` wins).
///
/// The CLI reads exactly one entry. To support multiple accounts we keep
/// per-account copies under `"Claude Code-account-<UUID>"` and copy the
/// chosen one onto the active slot to switch.
///
/// - Linking: `saveActiveTokenAs(id:)` reads the current active token
///   (whatever the user just `/login`'d as) and saves a copy under the
///   given account UUID.
/// - Switching: `switchTo(id:)` copies the saved token onto the active
///   slot. Subsequent Claude Code CLI invocations pick up the new account.
/// - Unlinking: `remove(id:)` deletes only the saved copy; the active slot
///   is untouched.
enum ClaudeCodeKeychain {
    static let activeService = "Claude Code-credentials"
    static let savedPrefix = "Claude Code-account-"

    enum Failure: Error, CustomStringConvertible {
        case noActiveToken
        case notLinked
        case osStatus(OSStatus)

        var description: String {
            switch self {
            case .noActiveToken:
                return "No active Claude Code credentials found. Run `claude` and `/login` first."
            case .notLinked:
                return "This account is not linked to Claude Code yet."
            case .osStatus(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "Keychain error: \(msg)"
            }
        }
    }

    /// Saves a copy of the currently-active CLI token under this account UUID.
    /// Throws `.noActiveToken` if the user hasn't `/login`'d yet.
    static func saveActiveTokenAs(id: UUID) throws {
        guard let token = readToken(service: activeService) else { throw Failure.noActiveToken }
        try writeToken(service: savedPrefix + id.uuidString, data: token)
    }

    /// Snapshots the current active token back into `outgoingID`'s saved slot,
    /// then copies `incomingID`'s saved token onto the active slot.
    ///
    /// The snapshot step is critical: Claude Code refreshes its OAuth token
    /// in-place inside `Claude Code-credentials` during normal operation. Without
    /// snapshotting, switching away and back discards those refreshes and leaves
    /// the returning account with a stale token (lost session). Silent no-op if
    /// no active token exists (nothing to snapshot).
    static func switchTo(incoming: UUID, savingCurrentAs outgoing: UUID?) throws {
        // 1. Save whatever is currently in the active slot back to the outgoing account.
        if let outgoing, let current = readToken(service: activeService) {
            try? writeToken(service: savedPrefix + outgoing.uuidString, data: current)
        }
        // 2. Activate the incoming account's saved token.
        guard let token = readToken(service: savedPrefix + incoming.uuidString) else { throw Failure.notLinked }
        try writeToken(service: activeService, data: token)
    }

    /// Deletes the saved per-account token. Silent no-op if not present.
    /// The active slot is left untouched.
    static func remove(id: UUID) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: savedPrefix + id.uuidString
        ]
        _ = SecItemDelete(q as CFDictionary)
    }

    // MARK: - Internals

    private static func readToken(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func writeToken(service: String, data: Data) throws {
        // Build an open ACL (nil trusted-apps list = any application may read
        // without a password prompt). This is the same policy that
        // `security add-generic-password -T ""` applies from the shell, and it
        // prevents macOS from re-prompting on every new build of ClaudeTracker.
        // SecAccessCreate is deprecated but is the only API that creates an
        // open-ACL entry (nil trusted apps = any process reads without a
        // password prompt). kSecAttrAccessible controls unlock-state policy,
        // not which processes are trusted — no non-deprecated equivalent exists.
        var access: SecAccess?
        SecAccessCreate("Claude Code account" as CFString, nil, &access)

        // Try update first — overwrite data AND replace the ACL so that an
        // item originally created by the Claude Code CLI (which restricts reads
        // to the claude binary) becomes readable by any app going forward.
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        var updateAttrs: [String: Any] = [kSecValueData as String: data]
        if let access { updateAttrs[kSecAttrAccess as String] = access }
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw Failure.osStatus(updateStatus) }

        // No existing entry — create one with an open ACL from the start.
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if let access { addQuery[kSecAttrAccess as String] = access }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess { throw Failure.osStatus(addStatus) }
    }
}
