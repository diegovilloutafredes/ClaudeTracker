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

    /// True iff a Claude Code CLI token currently exists in the Keychain.
    static func isClaudeCodeInstalled() -> Bool {
        return readToken(service: activeService) != nil
    }

    /// True iff a saved per-account token exists for this id.
    static func isLinked(id: UUID) -> Bool {
        return readToken(service: savedPrefix + id.uuidString) != nil
    }

    /// Saves a copy of the currently-active CLI token under this account UUID.
    /// Throws `.noActiveToken` if the user hasn't `/login`'d yet.
    static func saveActiveTokenAs(id: UUID) throws {
        guard let token = readToken(service: activeService) else { throw Failure.noActiveToken }
        try writeToken(service: savedPrefix + id.uuidString, data: token)
    }

    /// Copies this account's saved token onto the active slot, so the next
    /// Claude Code CLI invocation uses it. Throws `.notLinked` if the
    /// account hasn't been linked yet.
    static func switchTo(id: UUID) throws {
        guard let token = readToken(service: savedPrefix + id.uuidString) else { throw Failure.notLinked }
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

    /// Returns true if the active CLI token equals this account's saved copy
    /// (i.e. the CLI is currently using this account). False if not linked,
    /// not active, or no active token at all.
    static func isCurrentlyActive(id: UUID) -> Bool {
        guard let active = readToken(service: activeService),
              let saved = readToken(service: savedPrefix + id.uuidString) else { return false }
        return active == saved
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
        // Try update first — preserves the original ACL on the active entry,
        // so Claude Code CLI keeps reading it without re-prompting the user.
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw Failure.osStatus(updateStatus) }

        // No existing entry — create one. This path runs the first time we
        // save a per-account copy under a new UUID.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess { throw Failure.osStatus(addStatus) }
    }
}
