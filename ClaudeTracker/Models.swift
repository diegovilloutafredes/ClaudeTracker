import Foundation
import SwiftUI

/// Maps a normalized urgency (0 = calm, 1 = critical) to a SwiftUI Color.
/// Hue interpolates continuously: green (0) → yellow → orange → red (1).
func urgencyColor(_ urgency: Double) -> Color {
    let t = max(0, min(1, urgency))
    return Color(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.9)
}

/// Shared 3-band color for pace UI (rate text, outlook message, chart projection line).
/// `proj` is projected hours to 100%; `hoursToReset` is time until window reset.
func paceUrgencyColor(proj: Double, hoursToReset: Double) -> Color {
    guard proj > 0, hoursToReset > 0 else { return .secondary }
    if proj >= hoursToReset { return .secondary }
    if proj >= hoursToReset * 0.8 { return urgencyColor(0.7) }
    return urgencyColor(1.0)
}

/// Returns true when `remote` is a higher semantic version than `current`.
/// Uses `.numeric` comparison so "1.10.0" > "1.9.0".
func isNewerVersion(_ remote: String, than current: String) -> Bool {
    remote.compare(current, options: .numeric) == .orderedDescending
}

/// Computes consumption rate and projected time-to-full from a utilization history.
///
/// Uses exponentially-weighted linear regression over all history points so that
/// recent consumption dominates the slope. Weight w_i = exp(λ · t_norm) where
/// t_norm ∈ [0,1] runs from oldest to newest. At the default λ=2 the newest point
/// is ~7× the oldest; higher λ (Reactive) narrows focus to the last few minutes,
/// lower λ (Stable) approaches a uniform average.
///
/// Requires at least 15 seconds of elapsed history and 2 data points.
/// Returns nil when the rate is negligible (≤ 0.1 %/hr) or data is insufficient.
func computePace(history: [(Date, Double)], lambda: Double = 2.0) -> (rate: Double, projectedHours: Double?)? {
    guard history.count >= 2 else { return nil }
    let oldest = history.first!
    let newest = history.last!
    let elapsedSeconds = newest.0.timeIntervalSince(oldest.0)
    guard elapsedSeconds >= 15.0 else { return nil }

    let λ = lambda
    var W = 0.0, Sx = 0.0, Sy = 0.0, Sxx = 0.0, Sxy = 0.0
    for (date, util) in history {
        let xi   = date.timeIntervalSince(oldest.0) / 3600.0   // hours from oldest
        let norm = date.timeIntervalSince(oldest.0) / elapsedSeconds  // [0, 1]
        let wi   = exp(λ * norm)
        W   += wi
        Sx  += wi * xi
        Sy  += wi * util
        Sxx += wi * xi * xi
        Sxy += wi * xi * util
    }

    let denom = W * Sxx - Sx * Sx
    guard abs(denom) > 1e-12 else { return nil }
    let rate = (W * Sxy - Sx * Sy) / denom  // %/hr

    guard rate > 0.1 else { return nil }
    let remaining = 100.0 - newest.1
    let projectedHours: Double? = remaining > 0 ? remaining / rate : nil
    return (rate, projectedHours)
}

/// Response payload from the `/api/organizations/{id}/usage` endpoint.
struct UsageResponse: Codable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }

    /// The windows shown in the UI, in display order.
    ///
    /// The Opus and Sonnet sub-windows are omitted — they are informational breakdowns
    /// of the 7-day total and do not represent independent rate limits the user can act on.
    var allWindows: [(MenuBarWindow, UsageWindow)] {
        var result: [(MenuBarWindow, UsageWindow)] = []
        if let w = fiveHour { result.append((.fiveHour, w)) }
        if let w = sevenDay { result.append((.sevenDay, w)) }
        return result
    }
}

/// A single rate-limit window returned by the usage API.
struct UsageWindow: Codable {
    /// Utilization as a percentage (0–100+; may slightly exceed 100 when overages are permitted).
    let utilization: Double
    /// ISO 8601 timestamp of the next reset. Nil immediately after a reset while the server
    /// is computing the new window — decoding must tolerate null here.
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    /// Parses `resetsAt` into a `Date`.
    ///
    /// The API returns timestamps both with and without fractional seconds depending on the
    /// server — two formatters are tried in order to handle both forms.
    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        return Self.formatterWithFractional.date(from: resetsAt)
            ?? Self.formatterWithout.date(from: resetsAt)
    }

    /// Utilization clamped to `[0, 1]` for use with `ProgressView`.
    var utilizationFraction: Double {
        min(utilization / 100.0, 1.0)
    }

    /// Continuous urgency gradient: green (low) → yellow → orange → red (high).
    var utilizationColor: Color {
        urgencyColor(utilization / 100.0)
    }

    private static let formatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let formatterWithout: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Pay-as-you-go credit usage, present when the account has extra usage enabled.
struct ExtraUsage: Codable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

/// A claude.ai organization, used only to extract the UUID for usage API calls.
struct Organization: Codable {
    let uuid: String
    let name: String
}

/// Account profile returned by `/api/account`.
struct AccountInfo: Codable {
    let fullName: String?
    let emailAddress: String
    /// Organization memberships; only the first entry is used to determine subscription tier.
    let memberships: [AccountMembership]?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case emailAddress = "email_address"
        case memberships
    }

    var displayName: String { fullName ?? emailAddress }

    /// Human-readable plan label derived from `capabilities` and `rate_limit_tier`.
    ///
    /// The API exposes no dedicated tier field. The tier is inferred by combining
    /// the capability set (e.g. `"claude_max"`) with the tier slug string
    /// (e.g. `"default_claude_max_5x"`). Returns `nil` for unrecognised or free accounts.
    var subscriptionLabel: String? {
        guard let org = memberships?.first?.organization else { return nil }
        let caps = Set(org.capabilities ?? [])
        let tier = org.rateLimitTier ?? ""
        if caps.contains("claude_max") {
            if tier.contains("20x") { return "Max 20×" }
            if tier.contains("5x")  { return "Max 5×" }
            return "Max"
        }
        if caps.contains("claude_pro") || tier.contains("_pro") { return "Pro" }
        if caps.contains("claude_team")       { return "Team" }
        if caps.contains("claude_enterprise") { return "Enterprise" }
        return nil
    }
}

struct AccountMembership: Codable {
    let organization: AccountOrganization
}

/// Organization-level fields used to infer subscription tier.
struct AccountOrganization: Codable {
    let capabilities: [String]?
    let rateLimitTier: String?

    enum CodingKeys: String, CodingKey {
        case capabilities
        case rateLimitTier = "rate_limit_tier"
    }
}

// MARK: - Usage History

/// A single timestamped utilization snapshot, stored persistently for the charts tab.
///
/// Sampled at most once every 5 minutes regardless of poll rate, so a 2016-entry cap
/// covers exactly 7 days — the full 7-day window at this resolution.
struct UsageDataPoint: Codable, Identifiable {
    let timestamp: Date
    let fiveHour: Double?
    let sevenDay: Double?
    /// Consumption rate in %/hr at snapshot time; nil when history was insufficient.
    let fiveHourPace: Double?
    let sevenDayPace: Double?
    var id: Date { timestamp }
}

// MARK: - Pace Rate Unit

/// The time unit used to display the consumption rate in the UI.
enum PaceRateUnit: String, CaseIterable, Identifiable {
    case perHour
    case perMinute
    case perSecond

    var id: String { rawValue }

    var label: String {
        switch self {
        case .perHour:   return String(localized: "Per Hour")
        case .perMinute: return String(localized: "Per Minute")
        case .perSecond: return String(localized: "Per Second")
        }
    }

    /// Format a rate (expressed internally as %/hr) for display.
    /// - Parameters:
    ///   - ratePerHour: Raw rate from `computePace`, always in %/hr.
    ///   - prefix: When `true`, prepends "+" (for live pace lines and menu bar).
    ///   - short: When `true`, uses single-char time abbreviations for the menu bar.
    func format(_ ratePerHour: Double, prefix: Bool = false, short: Bool = false) -> String {
        let sign = prefix ? "+" : ""
        switch self {
        case .perHour:
            let unit = short ? "/h" : "/hr"
            return ratePerHour < 10
                ? String(format: "\(sign)%.1f%%\(unit)", ratePerHour)
                : String(format: "\(sign)%d%%\(unit)", Int(ratePerHour.rounded()))
        case .perMinute:
            let unit = short ? "/m" : "/min"
            let v = ratePerHour / 60.0
            return v < 1
                ? String(format: "\(sign)%.3f%%\(unit)", v)
                : String(format: "\(sign)%.2f%%\(unit)", v)
        case .perSecond:
            let unit = "/s"
            let v = ratePerHour / 3600.0
            return String(format: "\(sign)%.4f%%\(unit)", v)
        }
    }
}

// MARK: - Menu Bar Display Option

/// The rate-limit window whose utilization the menu bar label tracks.
enum MenuBarWindow: String, CaseIterable, Identifiable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveHour: return String(localized: "5-Hour Window")
        case .sevenDay: return String(localized: "7-Day Window")
        }
    }
}

// MARK: - Multi-Account

/// A locally tracked Claude account. Each account is backed by its own
/// `WKWebsiteDataStore(forIdentifier:)` so cookies (including `sessionKey`) never collide.
///
/// `label`, `email`, and `subscriptionLabel` are populated from `/api/account` after
/// the first successful fetch and may be `nil` immediately after the account is added.
struct Account: Codable, Identifiable, Hashable {
    let id: UUID
    var label: String
    var email: String?
    var subscriptionLabel: String?
    var orgName: String?
    let dataStoreIdentifier: UUID
    let addedAt: Date

    init(id: UUID = UUID(),
         label: String,
         email: String? = nil,
         subscriptionLabel: String? = nil,
         orgName: String? = nil,
         dataStoreIdentifier: UUID = UUID(),
         addedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.email = email
        self.subscriptionLabel = subscriptionLabel
        self.orgName = orgName
        self.dataStoreIdentifier = dataStoreIdentifier
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.email = try c.decodeIfPresent(String.self, forKey: .email)
        self.subscriptionLabel = try c.decodeIfPresent(String.self, forKey: .subscriptionLabel)
        self.orgName = try c.decodeIfPresent(String.self, forKey: .orgName)
        self.dataStoreIdentifier = try c.decode(UUID.self, forKey: .dataStoreIdentifier)
        self.addedAt = try c.decode(Date.self, forKey: .addedAt)
    }
}

/// All per-account runtime state. The view model keeps a `[UUID: AccountState]` indexed by
/// account id, so a fetch that captures its `accountID` at start always lands its result in the
/// correct bucket — even if the user switches accounts mid-fetch. Not `Codable`: the fields
/// that need persisting (`usageHistory`, account roster) are saved through dedicated paths.
struct AccountState {
    var usage: UsageResponse?
    var error: String?
    var lastUpdated: Date?
    var accountInfo: AccountInfo?
    /// Tracks the parsed `resetsAt` per window key. A reset is inferred when the new date is
    /// > 1 hour later AND utilization drops below 5%.
    var previousResetsAt: [String: Date] = [:]
    /// Rolling 5-minute utilization history per window key, used by `computePace`.
    var utilizationHistory: [String: [(Date, Double)]] = [:]
    /// Window keys for which a pace alert has already fired in the current window period.
    var paceWarned: Set<String> = []
    /// Active pace-alert toast IDs keyed by window key, so they can be dismissed when pace
    /// improves past the warning threshold.
    var paceToastIDs: [String: UUID] = [:]
    /// Throttles `usageHistory` snapshots to ≤1 every 5 minutes.
    var lastHistoryTimestamp: Date? = nil
    /// Persisted chart-history snapshots; survives relaunch via the `usageHistory.<id>` key.
    var usageHistory: [UsageDataPoint] = []
    /// Increments on every failed fetch; drives backoff in `scheduleNextPoll()`.
    var consecutiveErrors: Int = 0
    /// True after a 401 retry confirms the session is no longer valid; drives the empty-state
    /// "sign in again" UX without forcing the user to remove and re-add the account.
    var sessionExpired: Bool = false
}

/// UserDefaults-backed persistence for the account roster and the active selection.
///
/// `accounts` is stored as JSON-encoded `[Account]` under `"accounts"`.
/// `activeAccountID` is stored as a UUID string under `"activeAccountID"` (or absent when nil).
enum AccountStore {
    static let accountsKey = "accounts"
    static let activeAccountIDKey = "activeAccountID"

    static func loadAccounts() -> [Account] {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else { return [] }
        return decoded
    }

    static func saveAccounts(_ accounts: [Account]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }

    static func loadActiveID() -> UUID? {
        guard let s = UserDefaults.standard.string(forKey: activeAccountIDKey) else { return nil }
        return UUID(uuidString: s)
    }

    static func saveActiveID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: activeAccountIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeAccountIDKey)
        }
    }

    /// UserDefaults key used to persist a single account's chart-history snapshots.
    static func usageHistoryKey(for accountID: UUID) -> String {
        "usageHistory.\(accountID.uuidString)"
    }
}

/// A newer version discovered via the GitHub Releases API.
struct UpdateInfo {
    let version: String
    let releaseURL: URL
    /// Direct ZIP download URL from the GitHub release assets, if present.
    let downloadURL: URL?
}
