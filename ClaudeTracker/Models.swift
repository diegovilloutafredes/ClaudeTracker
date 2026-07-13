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
    switch PaceBand(projectedHours: proj, hoursToReset: hoursToReset) {
    case .safe:  return .secondary
    case .close: return urgencyColor(0.7)
    case .over:  return urgencyColor(1.0)
    }
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

/// Derives an adaptive update-check interval from recent release dates: half the average
/// gap between releases, clamped to [4h, 24h]. Falls back to 12h with fewer than two
/// dates or no positive gaps.
func adaptiveCheckInterval(from dates: [Date]) -> TimeInterval {
    let sorted = dates.sorted(by: >)
    guard sorted.count >= 2 else { return 12 * 3600 }
    var gaps: [TimeInterval] = []
    for i in 0..<(sorted.count - 1) {
        let gap = sorted[i].timeIntervalSince(sorted[i + 1])
        if gap > 0 { gaps.append(gap) }
    }
    guard !gaps.isEmpty else { return 12 * 3600 }
    let avg = gaps.reduce(0, +) / Double(gaps.count)
    return max(4 * 3600, min(24 * 3600, avg * 0.5))
}

/// True when a window's reset timestamp jumped forward by more than an hour AND utilization
/// dropped below 5% — the signature of a real reset, not a rolling-expiry timestamp refresh.
func isWindowReset(previous: Date, next: Date, utilization: Double) -> Bool {
    next.timeIntervalSince(previous) > 3600 && utilization < 5
}

/// True when stored usage belongs to a window cycle that has since reset: the reset time has
/// passed AND the last fetch predates it, so the displayed utilization is definitively stale.
func windowIsStale(resetsAt: Date?, lastUpdated: Date?, now: Date) -> Bool {
    guard let resetsAt, let lastUpdated else { return false }
    return resetsAt < now && lastUpdated < resetsAt
}

// MARK: - UserDefaults Keys

/// UserDefaults keys for all persisted preferences. Every key is written in a `didSet`
/// and read back in startup loading — a single namespace prevents a typo from silently
/// desyncing the write and read sides.
enum PrefKey {
    static let menuBarWindow = "menuBarWindow"
    static let notify5Hour = "notify5Hour"
    static let notify7Day = "notify7Day"
    static let notifyToast = "notifyToast"
    static let notifySound = "notifySound"
    static let toastDuration = "toastDuration"
    static let toastPermanent = "toastPermanent"
    static let showPace = "showPace"
    static let showPaceMenuBar = "showPaceMenuBar"
    static let paceRateUnit = "paceRateUnit"
    static let notifyPace = "notifyPace"
    static let paceWarningMinutes = "paceWarningMinutes"
    static let paceToastEnabled = "paceToastEnabled"
    static let paceToastDuration = "paceToastDuration"
    static let paceToastPermanent = "paceToastPermanent"
    static let paceSoundEnabled = "paceSoundEnabled"
    static let popupScale = "popupScale"
    static let popupScaleRebased = "popupScaleRebased"
    static let showChartsTab = "showChartsTab"
    static let selectedTab = "selectedTab"
    static let chartTimeRange = "chartTimeRange"
    /// Gates all per-model usage rows (legacy Sonnet + scoped limits). The stored key name
    /// predates the scoped rows and is kept for persistence compatibility.
    static let showModelWindows = "showSonnetWindow"
    static let use24HourTime = "use24HourTime"
    static let notificationDefaultsVersion = "notificationDefaultsVersion"
    static let accountsMigrationVersion = "accountsMigrationVersion"
    static let autoUpdate = "autoUpdate"
    static let lastNotifiedUpdateVersion = "lastNotifiedUpdateVersion"
    static let updateCheckInterval = "updateCheckInterval"
    /// Pre-multi-account chart history blob; migrated to `usageHistory.<accountID>`.
    static let legacyUsageHistory = "usageHistory"
}

// MARK: - Reset Time Display

/// Whether a locale's hour cycle conventionally uses a 24-hour clock — seeds the
/// Time format setting on first launch.
func prefers24HourClock(_ locale: Locale) -> Bool {
    locale.hourCycle == .zeroToTwentyThree || locale.hourCycle == .oneToTwentyFour
}

/// A copy of `base` with its hour cycle pinned to the user's 12/24-hour choice, so time
/// formatting honors the Time format setting over the locale's convention while weekday
/// and month names stay localized. Shared by `resetTimeText` and the chart axis labels.
func pinnedHourCycleLocale(use24Hour: Bool, base: Locale = .current) -> Locale {
    var components = Locale.Components(locale: base)
    components.hourCycle = use24Hour ? .zeroToTwentyThree : .oneToTwelve
    return Locale(components: components)
}

/// Formats the absolute wall-clock time of a window reset for display next to the countdown.
///
/// The hour cycle is pinned via `pinnedHourCycleLocale` so the user's 12/24-hour choice
/// wins over the locale's preference while weekday/month names stay localized. When the reset
/// is not on the same calendar day as `now`, an abbreviated weekday is prepended; `includeDate`
/// additionally adds the abbreviated month + day (used by the 7-day windows — a weekday alone
/// reads ambiguous when the reset lands on today's weekday next week).
func resetTimeText(reset: Date, now: Date, use24Hour: Bool, includeDate: Bool = false,
                   calendar: Calendar = .current, locale: Locale = .current) -> String {
    let pinned = pinnedHourCycleLocale(use24Hour: use24Hour, base: locale)

    var style = Date.FormatStyle(locale: pinned, calendar: calendar, timeZone: calendar.timeZone)
        .hour(.defaultDigits(amPM: use24Hour ? .omitted : .abbreviated))
        .minute()
    if !calendar.isDate(reset, inSameDayAs: now) {
        style = style.weekday(.abbreviated)
        if includeDate {
            style = style.month(.abbreviated).day()
        }
    }
    return reset.formatted(style)
}

// MARK: - Polling Tuning

/// Computes the adaptive polling interval for a single usage window.
///
/// Mirrors the documented tiers:
///   - Window stale (reset already passed): 2 s — catch the new window fast
///   - Utilization ≥ 99.9% with known reset: 10–300 s based on time until reset (30 s if unknown)
///   - Active with pace available: 1–10 s based on projected minutes to full
///   - Active without pace: 3–10 s based on utilization level
func pollInterval(utilization: Double, resetsAt: Date?, projectedMinutes: Double?, now: Date = Date()) -> TimeInterval {
    // Stale: reset already passed — poll aggressively to catch the new window
    if let resetsAt, resetsAt < now {
        return 2
    }

    // At 100%: only need to catch the upcoming reset
    if utilization >= 99.9 {
        guard let resetsAt else { return 30 }
        let secs = max(0, resetsAt.timeIntervalSince(now))
        switch secs {
        case 1800...: return 300
        case 600...:  return 120
        case 120...:  return 30
        default:      return 10
        }
    }

    // Active: use projected minutes to full when pace is available
    if let projectedMinutes {
        return pollIntervalForProjectedMinutes(projectedMinutes)
    }

    // Fallback: utilization-based steps when no pace signal yet
    switch utilization {
    case 95...: return 3
    case 80...: return 5
    case 50...: return 8
    default:    return 10
    }
}

/// Poll interval tier for a window that is actively filling, from projected minutes to full.
func pollIntervalForProjectedMinutes(_ projMins: Double) -> TimeInterval {
    switch projMins {
    case 60...: return 10
    case 30...: return 8
    case 15...: return 5
    case 5...:  return 3
    case 2...:  return 2
    default:    return 1
    }
}

/// Additional poll delay after consecutive fetch errors: 10 s per error, capped at 60 s.
func errorBackoff(consecutiveErrors: Int) -> TimeInterval {
    consecutiveErrors > 0 ? min(Double(consecutiveErrors) * 10, 60) : 0
}

// MARK: - Pace History Maintenance

/// True when the rolling pace history must be cleared because the window reset.
///
/// A reset shows up either as a drop of more than 20 percentage points, or as utilization
/// falling below 5% from at or above 5% — the latter catches resets from low utilization
/// that the drop threshold would miss.
func shouldResetPaceHistory(last: Double, current: Double) -> Bool {
    last - current > 20 || (current < 5 && last >= 5)
}

/// Appends a chart snapshot to persistent history, enforcing the sampling contract:
/// at most one point per `minInterval` (returns nil when throttled — caller keeps the old
/// history), entries older than `maxAge` pruned, and the result capped to the newest `cap`.
func appendPrunedDataPoint(_ point: UsageDataPoint,
                           to history: [UsageDataPoint],
                           lastTimestamp: Date?,
                           minInterval: TimeInterval = 300,
                           maxAge: TimeInterval = 30 * 24 * 3600,
                           cap: Int = 8640) -> [UsageDataPoint]? {
    if let lastTimestamp, point.timestamp.timeIntervalSince(lastTimestamp) < minInterval { return nil }
    let cutoff = point.timestamp.addingTimeInterval(-maxAge)
    var result = history.filter { $0.timestamp >= cutoff }
    result.append(point)
    if result.count > cap { result = Array(result.suffix(cap)) }
    return result
}

// MARK: - Pace Band

/// The shared 3-band classification for all pace UI (rate text color, outlook message,
/// chart projection line). Keeps the 0.8× threshold in exactly one place.
enum PaceBand: Equatable, Sendable {
    /// Projected fill time is at or beyond the reset — consumption is sustainable.
    case safe
    /// Projected fill lands within 80–100% of the time to reset — cutting it close.
    case close
    /// Projected to fill before the window resets.
    case over

    init(projectedHours: Double, hoursToReset: Double) {
        guard projectedHours > 0, hoursToReset > 0 else { self = .safe; return }
        if projectedHours >= hoursToReset {
            self = .safe
        } else if projectedHours >= hoursToReset * 0.8 {
            self = .close
        } else {
            self = .over
        }
    }
}

/// Response payload from the `/api/organizations/{id}/usage` endpoint.
struct UsageResponse: Codable, Sendable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let extraUsage: ExtraUsage?
    /// The newer, generalized limit list. Model-scoped weekly limits (e.g. Fable) only
    /// appear here — the legacy `seven_day_*` fields are null on Fable-era accounts.
    let limits: [UsageLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
    }

    init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, sevenDayOpus: UsageWindow?,
         sevenDaySonnet: UsageWindow?, extraUsage: ExtraUsage?, limits: [UsageLimit]? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.extraUsage = extraUsage
        self.limits = limits
    }

    /// Fail-soft decoding: a malformed sub-window (e.g. the API ships `"utilization": null`
    /// in `seven_day_opus`, which the UI doesn't even display) must not poison the whole
    /// response. Each window decodes independently; a failed one becomes nil. `limits`
    /// entries are additionally fail-soft per element so one unexpected entry can't hide
    /// the model-scoped rows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fiveHour = (try? c.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)) ?? nil
        self.sevenDay = (try? c.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)) ?? nil
        self.sevenDayOpus = (try? c.decodeIfPresent(UsageWindow.self, forKey: .sevenDayOpus)) ?? nil
        self.sevenDaySonnet = (try? c.decodeIfPresent(UsageWindow.self, forKey: .sevenDaySonnet)) ?? nil
        self.extraUsage = (try? c.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)) ?? nil
        self.limits = ((try? c.decodeIfPresent([FailableLimit].self, forKey: .limits)) ?? nil)
            .map { $0.compactMap(\.limit) }
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

    /// Model-scoped weekly limits (e.g. "Fable") from the `limits` array, as displayable
    /// windows. A model that already renders via its legacy sub-window (Sonnet) is skipped
    /// so it can't show as a duplicate row. Duplicate labels (the scope object also has a
    /// `surface` axis, so same-model entries are plausible) are collapsed to the
    /// max-percent entry — a duplicate would collide on ForEach identity and interleave
    /// two series into one pace-history bucket.
    var scopedModelWindows: [ScopedModelWindow] {
        var result: [ScopedModelWindow] = []
        var indexByLabel: [String: Int] = [:]
        for limit in limits ?? [] {
            guard limit.kind == "weekly_scoped",
                  let label = limit.scope?.model?.displayName, !label.isEmpty,
                  let percent = limit.percent else { continue }
            if sevenDaySonnet != nil && label == "Sonnet" { continue }
            let window = ScopedModelWindow(label: label,
                                           window: UsageWindow(utilization: percent, resetsAt: limit.resetsAt))
            if let idx = indexByLabel[label] {
                if percent > result[idx].window.utilization { result[idx] = window }
            } else {
                indexByLabel[label] = result.count
                result.append(window)
            }
        }
        return result
    }
}

/// A single entry in the usage response's `limits` array.
struct UsageLimit: Codable, Sendable {
    let kind: String
    let percent: Double?
    let resetsAt: String?
    let scope: UsageLimitScope?

    enum CodingKeys: String, CodingKey {
        case kind, percent, scope
        case resetsAt = "resets_at"
    }
}

/// The `scope` object of a `weekly_scoped` limit entry.
struct UsageLimitScope: Codable, Sendable {
    let model: UsageLimitModel?
}

/// The model a scoped limit applies to.
struct UsageLimitModel: Codable, Sendable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

/// Per-element fail-soft wrapper: a malformed `limits` entry decodes to nil instead of
/// failing the whole array.
private struct FailableLimit: Decodable {
    let limit: UsageLimit?

    init(from decoder: Decoder) {
        limit = try? UsageLimit(from: decoder)
    }
}

/// A model-scoped weekly limit surfaced as a displayable usage window.
struct ScopedModelWindow: Sendable {
    /// The model's display name as reported by the API (e.g. "Fable").
    let label: String
    let window: UsageWindow
    /// History-bucket key for pace tracking, distinct from the legacy window keys.
    var paceKey: String { "scoped." + label }
}

/// A single rate-limit window returned by the usage API.
struct UsageWindow: Codable, Sendable {
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

    // ISO8601DateFormatter is documented thread-safe; `nonisolated(unsafe)` only papers
    // over the missing Sendable annotation on the type.
    private nonisolated(unsafe) static let formatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let formatterWithout: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// Pay-as-you-go credit usage, present when the account has extra usage enabled.
struct ExtraUsage: Codable, Sendable {
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
struct Organization: Codable, Sendable {
    let uuid: String
    let name: String
}

/// Account profile returned by `/api/account`.
struct AccountInfo: Codable, Sendable {
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
        // Team/Enterprise orgs report the "raven" capability (tier "default_raven");
        // raven_type distinguishes the plan ("team" observed live, "enterprise" assumed).
        if caps.contains("raven") {
            if org.ravenType?.contains("enterprise") == true { return "Enterprise" }
            return "Team"
        }
        return nil
    }
}

struct AccountMembership: Codable, Sendable {
    let organization: AccountOrganization
}

/// Organization-level fields used to infer subscription tier.
struct AccountOrganization: Codable, Sendable {
    let capabilities: [String]?
    let rateLimitTier: String?
    /// Plan flavor for "raven" (Team/Enterprise) orgs, e.g. "team".
    let ravenType: String?

    enum CodingKeys: String, CodingKey {
        case capabilities
        case rateLimitTier = "rate_limit_tier"
        case ravenType = "raven_type"
    }
}

// MARK: - Usage History

/// A single timestamped utilization snapshot, stored persistently for the charts tab.
///
/// Sampled at most once every 5 minutes regardless of poll rate; capped at 8640 entries
/// (30 days at this resolution) and pruned to a 30-day window.
struct UsageDataPoint: Codable, Identifiable, Sendable {
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
enum PaceRateUnit: String, CaseIterable, Identifiable, Sendable {
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
enum MenuBarWindow: String, CaseIterable, Identifiable, Sendable {
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
struct Account: Codable, Identifiable, Hashable, Sendable {
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
struct AccountState: Sendable {
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

    static func loadAccounts(from defaults: UserDefaults = .standard) -> [Account] {
        guard let data = defaults.data(forKey: accountsKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            // Distinguish corruption from a fresh install: the next save overwrites the
            // blob permanently, so this line is the only trace of the lost roster.
            AppLogger.shared.error("accounts decode failed — starting with empty roster")
            return []
        }
        return decoded
    }

    static func saveAccounts(_ accounts: [Account], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: accountsKey)
        } else {
            AppLogger.shared.error("accounts encode failed — roster not persisted")
        }
    }

    static func loadActiveID(from defaults: UserDefaults = .standard) -> UUID? {
        guard let s = defaults.string(forKey: activeAccountIDKey) else { return nil }
        return UUID(uuidString: s)
    }

    static func saveActiveID(_ id: UUID?, to defaults: UserDefaults = .standard) {
        if let id {
            defaults.set(id.uuidString, forKey: activeAccountIDKey)
        } else {
            defaults.removeObject(forKey: activeAccountIDKey)
        }
    }

    /// UserDefaults key used to persist a single account's chart-history snapshots.
    static func usageHistoryKey(for accountID: UUID) -> String {
        "usageHistory.\(accountID.uuidString)"
    }
}

/// A newer version discovered via the GitHub Releases API.
struct UpdateInfo: Sendable {
    let version: String
    let releaseURL: URL
    /// Direct ZIP download URL from the GitHub release assets, if present.
    let downloadURL: URL?
}
