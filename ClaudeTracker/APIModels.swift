import Foundation
import SwiftUI

// Codable types for the claude.ai API payloads (`/api/organizations/{id}/usage`,
// `/api/account`, `/api/organizations`), plus the tracked-window enumeration and the
// log signatures derived from them. App-side pure logic, preferences, and account types
// stay in Models.swift.

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
    /// Newer credit-spend object that mirrors `extraUsage` (observed 2026-09). Decoded
    /// so its relationship to `extraUsage` can be learned from the log — **never displayed**.
    let spend: Spend?
    /// Per-surface split of the weekly window (first populated 2026-09-21). Decoded and
    /// logged via `breakdownSignature` so its semantics can be learned — **never displayed**.
    let sevenDayBreakdown: SevenDayBreakdown?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
        case spend
        case sevenDayBreakdown = "seven_day_breakdown"
    }

    init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, sevenDayOpus: UsageWindow?,
         sevenDaySonnet: UsageWindow?, extraUsage: ExtraUsage?, limits: [UsageLimit]? = nil,
         spend: Spend? = nil, sevenDayBreakdown: SevenDayBreakdown? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.extraUsage = extraUsage
        self.limits = limits
        self.spend = spend
        self.sevenDayBreakdown = sevenDayBreakdown
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
        self.spend = (try? c.decodeIfPresent(Spend.self, forKey: .spend)) ?? nil
        self.sevenDayBreakdown = (try? c.decodeIfPresent(SevenDayBreakdown.self, forKey: .sevenDayBreakdown)) ?? nil
    }

    /// The two built-in windows (5-hour, 7-day) that are present, in display order — the
    /// windows the menu bar picker can show. Per-model windows (legacy Sonnet, scoped
    /// limits) are appended by `trackedWindows`.
    var allWindows: [(MenuBarWindow, UsageWindow)] {
        var result: [(MenuBarWindow, UsageWindow)] = []
        if let w = fiveHour { result.append((.fiveHour, w)) }
        if let w = sevenDay { result.append((.sevenDay, w)) }
        return result
    }

    /// Every window the app tracks, in display order: the built-in 5-hour and 7-day
    /// windows, the legacy Sonnet sub-window, then each model-scoped weekly limit.
    var trackedWindows: [TrackedWindow] {
        var result = allWindows.map {
            TrackedWindow(key: $0.rawValue, title: $0.label, window: $1, isModelScoped: false)
        }
        if let sonnet = sevenDaySonnet {
            result.append(TrackedWindow(key: "seven_day_sonnet", title: TrackedWindow.title(forKey: "seven_day_sonnet"),
                                        window: sonnet, isModelScoped: true))
        }
        for scoped in scopedModelWindows {
            result.append(TrackedWindow(key: scoped.paceKey, title: TrackedWindow.title(forKey: scoped.paceKey),
                                        window: scoped.window, isModelScoped: true))
        }
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
    /// Server-side urgency. Observed live: "normal", "warning" (from roughly 70% utilization),
    /// "critical" (from roughly 90%) — inferred from nine sightings, so the bands are approximate.
    /// Surfaced only in the severity log; the UI keeps its own continuous urgency gradient.
    let severity: String?
    /// Observed live but semantics unclear: a dormant 0% window can be `true` while a
    /// running one is `false` — it is NOT "currently binding". Decoded for the severity
    /// log (included only alongside a non-"normal" severity), never displayed.
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, percent, scope, severity
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    /// Per-field lenient decode: only `kind` is load-bearing. A wrong-typed value in any
    /// other field (this API has changed shape before) must degrade that one field to
    /// nil, not throw and make `FailableLimit` drop the whole entry — which would
    /// silently remove a model's row and pace bucket from the UI.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? nil
        resetsAt = (try? c.decodeIfPresent(String.self, forKey: .resetsAt)) ?? nil
        scope = (try? c.decodeIfPresent(UsageLimitScope.self, forKey: .scope)) ?? nil
        severity = (try? c.decodeIfPresent(String.self, forKey: .severity)) ?? nil
        isActive = (try? c.decodeIfPresent(Bool.self, forKey: .isActive)) ?? nil
    }
}

/// Signature of the non-"normal" entries in a `limits` array, for the severity log —
/// e.g. `"weekly_scoped(Fable)=warning(active=true)"`. Scoped entries carry the model
/// name (two abnormal scoped limits would otherwise be indistinguishable), and the
/// fragments are sorted so a server-side reorder of the same entries never looks like
/// a transition. Empty when every entry is "normal".
func abnormalSeverities(_ limits: [UsageLimit]?) -> String {
    (limits ?? [])
        .filter { ($0.severity ?? "normal") != "normal" }
        .map { limit in
            let model = limit.scope?.model?.displayName ?? ""
            let kind = model.isEmpty ? limit.kind : "\(limit.kind)(\(model))"
            return "\(kind)=\(limit.severity ?? "")(active=\(limit.isActive ?? false))"
        }
        .sorted()
        .joined(separator: " ")
}

/// The top-level `spend` object of the usage response — credit spend in minor currency
/// units. Only the disabled shape has been observed live; every field is lenient and
/// optional so a shape change can never nil the object or fail the response.
struct Spend: Codable, Sendable {
    let enabled: Bool?
    let percent: Double?
    let severity: String?
    let disabledReason: String?
    let used: SpendAmount?
    let canPurchaseCredits: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled, percent, severity, used
        case disabledReason = "disabled_reason"
        case canPurchaseCredits = "can_purchase_credits"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
        percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? nil
        severity = (try? c.decodeIfPresent(String.self, forKey: .severity)) ?? nil
        disabledReason = (try? c.decodeIfPresent(String.self, forKey: .disabledReason)) ?? nil
        used = (try? c.decodeIfPresent(SpendAmount.self, forKey: .used)) ?? nil
        canPurchaseCredits = (try? c.decodeIfPresent(Bool.self, forKey: .canPurchaseCredits)) ?? nil
    }
}

/// A money amount as the `spend` object reports it: `amount_minor` scaled by `10^exponent`.
struct SpendAmount: Codable, Sendable {
    let amountMinor: Int
    let currency: String
    let exponent: Int

    enum CodingKeys: String, CodingKey {
        case amountMinor = "amount_minor"
        case currency, exponent
    }
}

/// Signature of the not-yet-understood fields worth learning from the field, for the
/// diagnostics log: any window with a non-null `locked_reason`, and the `spend` object
/// whenever it is enabled, carries a non-"normal" severity, or disagrees with
/// `extra_usage.is_enabled`. Empty for the quiet shape observed live (everything
/// disabled/normal/unlocked), so the log stays silent until something changes.
func usageDiagnostics(_ r: UsageResponse) -> String {
    var parts: [String] = []
    let windows: [(String, UsageWindow?)] = [
        ("five_hour", r.fiveHour), ("seven_day", r.sevenDay),
        ("seven_day_opus", r.sevenDayOpus), ("seven_day_sonnet", r.sevenDaySonnet),
    ]
    for (key, window) in windows {
        if let reason = window?.lockedReason { parts.append("\(key).locked=\(reason)") }
    }
    if let spend = r.spend {
        let enabled = spend.enabled ?? false
        let extraEnabled = r.extraUsage?.isEnabled
        let abnormal = (spend.severity ?? "normal") != "normal"
        let disagrees = extraEnabled != nil && extraEnabled != enabled
        if enabled || abnormal || disagrees {
            let used = spend.used.map { "\($0.amountMinor) \($0.currency) e\($0.exponent)" } ?? "nil"
            parts.append("spend=\(enabled ? "enabled" : "disabled")"
                         + "(pct=\(spend.percent.map { "\($0)" } ?? "nil")"
                         + ",sev=\(spend.severity ?? "nil")"
                         + ",used=\(used)"
                         + ",reason=\(spend.disabledReason ?? "nil"))")
            if disagrees { parts.append("extra_usage.is_enabled=\(extraEnabled ?? false)") }
        }
    }
    return parts.joined(separator: " ")
}

/// The top-level `seven_day_breakdown` object: how the weekly window's usage splits across
/// surfaces (`claude_code`, `chat`, `cowork`, `other`). One live sample (100/0/0/0 while the
/// weekly window sat at 3%) reads as a *share* of usage, not a utilization. Every field is
/// lenient so a shape change can never nil the object or fail the response.
struct SevenDayBreakdown: Codable, Sendable {
    let asOf: String?
    let windowStartedAt: String?
    let rows: [BreakdownRow]?

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case windowStartedAt = "window_started_at"
        case rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asOf = (try? c.decodeIfPresent(String.self, forKey: .asOf)) ?? nil
        windowStartedAt = (try? c.decodeIfPresent(String.self, forKey: .windowStartedAt)) ?? nil
        rows = (try? c.decodeIfPresent([BreakdownRow].self, forKey: .rows)) ?? nil
    }
}

/// One surface row of `seven_day_breakdown`.
struct BreakdownRow: Codable, Sendable {
    let key: String?
    let displayName: String?
    let percent: Double?

    enum CodingKeys: String, CodingKey {
        case key, percent
        case displayName = "display_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? nil
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? nil
    }
}

/// Log signature of `seven_day_breakdown`: `key:percent` per row, sorted by key so a
/// server-side reorder never reads as a change. `as_of` is excluded (it changes on every
/// response) and so is `window_started_at` (resets are logged elsewhere). Empty when absent.
/// shortcut: on a mixed-surface account the shares shift by whole percents often; if the
/// log gets chatty, drop the percents and keep only the row keys.
func breakdownSignature(_ r: UsageResponse) -> String {
    (r.sevenDayBreakdown?.rows ?? [])
        .compactMap { row -> String? in
            guard let key = row.key else { return nil }
            return "\(key):\(row.percent.map { String(format: "%.0f", $0) } ?? "nil")"
        }
        .sorted()
        .joined(separator: ",")
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

/// One rate-limit window the app tracks: the key its pace/history buckets and
/// `previousResetsAt` entry use, its localized row title, and the window itself.
/// The single enumeration behind reset detection, pace history, pace alerts, chart
/// snapshots, and the popover rows — which used to each rebuild this list.
struct TrackedWindow: Identifiable, Sendable {
    /// "five_hour", "seven_day", "seven_day_sonnet", or "scoped.<model>".
    let key: String
    /// Localized, e.g. "5-Hour Window", "7-Day Window", "7-Day Sonnet", "7-Day Fable".
    let title: String
    let window: UsageWindow
    /// True for the legacy Sonnet sub-window and model-scoped limits: shown and alerted
    /// only under `showModelWindows`.
    let isModelScoped: Bool
    var id: String { key }
    /// Every window but the 5-hour one spans a week.
    var isSevenDay: Bool { key != MenuBarWindow.fiveHour.rawValue }

    /// The localized row title for a window key.
    static func title(forKey key: String) -> String {
        if let builtIn = MenuBarWindow(rawValue: key) { return builtIn.label }
        if key == "seven_day_sonnet" { return String(localized: "7-Day Sonnet") }
        let model = key.hasPrefix("scoped.") ? String(key.dropFirst("scoped.".count)) : key
        return String(format: String(localized: "7-Day %@"), model)
    }
}

extension TrackedWindow {
    /// A window that left the response, rebuilt from its key so its reset can still be
    /// titled and gated like the live one — the previous response may lack it too.
    init(vanishedKey key: String) {
        self.init(key: key, title: Self.title(forKey: key), window: UsageWindow(utilization: 0, resetsAt: nil),
                  isModelScoped: MenuBarWindow(rawValue: key) == nil)
    }
}

/// A single rate-limit window returned by the usage API.
struct UsageWindow: Codable, Sendable {
    /// Utilization as a percentage (0–100+; may slightly exceed 100 when overages are permitted).
    let utilization: Double
    /// ISO 8601 timestamp of the next reset. Nil immediately after a reset while the server
    /// is computing the new window — decoding must tolerate null here.
    let resetsAt: String?
    /// Why the window is locked, if the API says it is. Only `null` observed live so far —
    /// **logged (via `usageDiagnostics`), never displayed** until the vocabulary is known.
    let lockedReason: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
        case lockedReason = "locked_reason"
    }

    init(utilization: Double, resetsAt: String?, lockedReason: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.lockedReason = lockedReason
    }

    /// `lockedReason` is lenient: a wrong-typed value must not throw and nil the whole
    /// window (which would drop its row from the UI). `utilization`/`resetsAt` keep
    /// their strict semantics.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try c.decode(Double.self, forKey: .utilization)
        resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
        lockedReason = (try? c.decodeIfPresent(String.self, forKey: .lockedReason)) ?? nil
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
    /// Why extra usage is off, e.g. "out_of_credits". Only meaningful when `isEnabled` is false.
    let disabledReason: String?
    /// True when the user turned extra usage off themselves (as opposed to running out).
    let userDisabled: Bool?
    /// True when the account has ever had usage credits — distinguishes "ran out"
    /// from "never opted in", which should stay invisible.
    let creditsEverEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case disabledReason = "disabled_reason"
        case userDisabled = "user_disabled"
        case creditsEverEnabled = "credits_ever_enabled"
    }

    /// Per-field lenient decode: only `isEnabled` is load-bearing. A wrong-typed value
    /// in any other field must not throw and nil the whole `extraUsage` — that would
    /// silently hide the extra-usage section for a payload that still carries
    /// `is_enabled`/`used_credits` intact.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        monthlyLimit = (try? c.decodeIfPresent(Double.self, forKey: .monthlyLimit)) ?? nil
        usedCredits = (try? c.decodeIfPresent(Double.self, forKey: .usedCredits)) ?? nil
        utilization = (try? c.decodeIfPresent(Double.self, forKey: .utilization)) ?? nil
        disabledReason = (try? c.decodeIfPresent(String.self, forKey: .disabledReason)) ?? nil
        userDisabled = (try? c.decodeIfPresent(Bool.self, forKey: .userDisabled)) ?? nil
        creditsEverEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .creditsEverEnabled)) ?? nil
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
    /// (e.g. `"default_claude_max_5x"`). Returns `nil` for unrecognised accounts.
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
        // Free accounts: "chat" capability on the base tier. Keyed on these two fields
        // (not rate_limit_upsell, which differs between /api/account and
        // /api/organizations for the same org). `.contains` like every branch above —
        // exact set equality would silently kill the badge if free accounts ever gain
        // a second capability.
        if caps.contains("chat") && tier == "default_claude_ai" { return "Free" }
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
