import Foundation
import SwiftUI

/// Maps a normalized urgency (0 = calm, 1 = critical) to a SwiftUI Color.
/// Hue interpolates continuously: green (0) → yellow → orange → red (1).
func urgencyColor(_ urgency: Double) -> Color {
    let t = max(0, min(1, urgency))
    return Color(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.9)
}

/// AppKit twin of `urgencyColor` for the menu bar image. Same formula; the unit test
/// `testUrgencyNSColorMatchesSwiftUIGradient` pins both to the same sRGB components so the
/// menu bar and the popover can never drift apart in hue.
func urgencyNSColor(_ urgency: Double) -> NSColor {
    let t = max(0, min(1, urgency))
    return NSColor(hue: 0.33 * (1 - t), saturation: 0.85, brightness: 0.9, alpha: 1.0)
}

/// Reference backgrounds for text contrast: the popover's light and dark window material,
/// roughly #ECECEC and #2B2B2B.
func popoverBackground(isDark: Bool) -> NSColor {
    let v: CGFloat = isDark ? 0x2B / 255.0 : 0xEC / 255.0
    return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
}

/// WCAG 2 contrast ratio between two opaque colors, from 1 to 21.
func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
    func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> Double {
            v <= 0.04045 ? Double(v) / 12.92 : pow((Double(v) + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// `urgencyNSColor` for text: mixed toward black on a light popover, or white on a dark
/// one, just far enough to reach WCAG AA (4.5:1) against it. The mix keeps the hue. The
/// raw gradient stays for bars, charts, and the menu bar icon; as text it read at 1.2–2.4:1
/// on a light popover from green to orange, and red at ~3:1 on a dark one.
func urgencyTextNSColor(_ urgency: Double, isDark: Bool) -> NSColor {
    guard let base = urgencyNSColor(urgency).usingColorSpace(.sRGB) else { return urgencyNSColor(urgency) }
    let background = popoverBackground(isDark: isDark)
    let target: CGFloat = isDark ? 1 : 0
    var color = base
    for step in 0...50 {
        let f = CGFloat(step) / 50
        color = NSColor(srgbRed: base.redComponent + (target - base.redComponent) * f,
                        green: base.greenComponent + (target - base.greenComponent) * f,
                        blue: base.blueComponent + (target - base.blueComponent) * f, alpha: 1)
        if contrastRatio(color, background) >= 4.5 { break }
    }
    return color
}

/// SwiftUI twin of `urgencyTextNSColor`.
func urgencyTextColor(_ urgency: Double, isDark: Bool) -> Color {
    Color(nsColor: urgencyTextNSColor(urgency, isDark: isDark))
}

/// Pace state as an urgency value on the same 0…1 scale as utilization, so the menu bar
/// can take `max(utilization, pace)` and still agree with the popover's `PaceBand`:
/// safe → 0, close → 0.7, over → 1.0. The single source for every pace color.
func paceUrgency(projectedHours: Double, hoursToReset: Double) -> Double {
    switch PaceBand(projectedHours: projectedHours, hoursToReset: hoursToReset) {
    case .safe:  return 0
    case .close: return 0.7
    case .over:  return 1.0
    }
}

/// Shared 3-band color for pace UI (rate text, outlook message, chart projection line).
/// `proj` is projected hours to 100%; `hoursToReset` is time until window reset. Pass the
/// color scheme for text, which takes the legible `urgencyTextColor` variant.
func paceUrgencyColor(proj: Double, hoursToReset: Double, forTextIn scheme: ColorScheme? = nil) -> Color {
    let urgency = paceUrgency(projectedHours: proj, hoursToReset: hoursToReset)
    guard urgency > 0 else { return .secondary }
    return scheme.map { urgencyTextColor(urgency, isDark: $0 == .dark) } ?? urgencyColor(urgency)
}

/// Pace accent for a window's row and its charts: neutral unless there is a projection,
/// a reset to measure it against, and the window is still live. One helper so the pace
/// rate text, the pace chart, and the forecast line can never disagree on the band.
func paceAccentColor(projectedHours: Double?, resetsAt: Date?, isStale: Bool,
                     forTextIn scheme: ColorScheme? = nil, now: Date = Date()) -> Color {
    guard !isStale, let proj = projectedHours, let reset = resetsAt else { return .secondary }
    return paceUrgencyColor(proj: proj, hoursToReset: reset.timeIntervalSince(now) / 3600, forTextIn: scheme)
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

/// One poll's reset bookkeeping: the keys of the windows that reset since `stored` (the last
/// known reset time per window key), in `windows` order, and the reset times to keep.
///
/// A window whose `resets_at` comes back null, or that is missing from the response (Team
/// orgs drop an idle `five_hour`), has reset once its stored time has passed at under 5 %
/// — the forward jump `isWindowReset` looks for only arrives once usage resumes, possibly
/// hours later. Its entry is then dropped, so that later date reads as a baseline instead
/// of a second reset.
func detectResets(stored: [String: Date], windows: [TrackedWindow], now: Date) -> (reset: [String], stored: [String: Date]) {
    var reset: [String] = []
    var next = stored
    for tracked in windows {
        let utilization = tracked.window.utilization
        if let date = tracked.window.resetsAtDate {
            if let previous = stored[tracked.key], isWindowReset(previous: previous, next: date, utilization: utilization) {
                reset.append(tracked.key)
            }
            next[tracked.key] = date
        } else if let previous = stored[tracked.key], previous <= now, utilization < 5 {
            reset.append(tracked.key)
            next[tracked.key] = nil
        }
    }
    let present = Set(windows.map(\.key))
    for (key, previous) in stored.sorted(by: { $0.key < $1.key }) where !present.contains(key) && previous <= now {
        reset.append(key)
        next[key] = nil
    }
    return (reset, next)
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
    /// Charts tab content filter. Series visibility is stored as the *hidden* set so a
    /// model-scoped window the API starts reporting shows up without the user opting in.
    static let chartHiddenSeries = "chartHiddenSeries"
    static let chartShowUtilization = "chartShowUtilization"
    static let chartShowPace = "chartShowPace"
    static let chartShowForecast = "chartShowForecast"
    /// Gates the per-model rows of the **Usage tab** (legacy Sonnet + scoped limits) and
    /// their reset/pace alerts. The Charts tab is deliberately exempt — it has its own
    /// content filter (`chartHiddenSeries`), so the two controls never fight over the same
    /// series. The stored key name predates the scoped rows and is kept for persistence
    /// compatibility.
    static let showModelWindows = "showSonnetWindow"
    static let use24HourTime = "use24HourTime"
    static let notificationDefaultsVersion = "notificationDefaultsVersion"
    static let accountsMigrationVersion = "accountsMigrationVersion"
    static let autoUpdate = "autoUpdate"
    static let launchAtLogin = "launchAtLogin"
    static let lastNotifiedUpdateVersion = "lastNotifiedUpdateVersion"
    static let updateCheckInterval = "updateCheckInterval"
    /// The release whose install last failed, and how many times in a row (auto-install retry cap).
    static let failedInstallVersion = "failedInstallVersion"
    static let failedInstallCount = "failedInstallCount"
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
    // resets_at lands a fraction of a second either side of the real boundary from poll to poll,
    // and the formatter truncates seconds — snap to the nearest minute (before the same-day check)
    // so the shown time doesn't flip between e.g. 17:59 and 18:00.
    let reset = Date(timeIntervalSinceReferenceDate: (reset.timeIntervalSinceReferenceDate / 60).rounded() * 60)
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

/// Index into a rotating message list that stays fixed for a whole window cycle.
///
/// Resets land on 10-minute marks, but `resets_at` comes in a fraction of a second either
/// side of the mark from poll to poll. Counting whole 10-minute slots (rounded) keeps the pick
/// stable under that jitter while still varying between windows; counting seconds picked
/// message 0 for every on-the-mark reset and switched phrasing whenever one came in early.
func outlookMessageIndex(reset: Date, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return abs(Int((reset.timeIntervalSince1970 / 600).rounded())) % count
}

/// How far ahead of its reset a window projected to fill early runs out, for the "over"
/// outlook line. Truncated to whole minutes, never rounded up: a rounded-up "~2h" once sat
/// under "Resets in 1 hr, 34 min". At least one minute, so the line never reads "~0m".
func earlyFillLead(hours early: Double) -> (hours: Int, minutes: Int) {
    let totalMinutes = max(1, Int(early * 60))
    return (totalMinutes / 60, totalMinutes % 60)
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
    /// Per-model utilization keyed by the window's history key ("seven_day_sonnet",
    /// "scoped.<Model>"). Nil on points recorded before per-model charts existed and on
    /// accounts whose response carries no model-scoped limits.
    let models: [String: Double]?
    /// Per-model consumption rate in %/hr, keyed like `models`.
    let modelPaces: [String: Double]?
    var id: Date { timestamp }

    init(timestamp: Date, fiveHour: Double?, sevenDay: Double?,
         fiveHourPace: Double?, sevenDayPace: Double?,
         models: [String: Double]? = nil, modelPaces: [String: Double]? = nil) {
        self.timestamp = timestamp
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fiveHourPace = fiveHourPace
        self.sevenDayPace = sevenDayPace
        self.models = models
        self.modelPaces = modelPaces
    }

    /// Utilization for a chart series, routing the two built-in windows to their dedicated
    /// fields and every model-scoped window to the dictionary.
    func utilization(for key: String) -> Double? {
        switch key {
        case MenuBarWindow.fiveHour.rawValue: return fiveHour
        case MenuBarWindow.sevenDay.rawValue: return sevenDay
        default: return models?[key]
        }
    }

    /// Consumption rate in %/hr for a chart series, keyed like `utilization(for:)`.
    func paceRate(for key: String) -> Double? {
        switch key {
        case MenuBarWindow.fiveHour.rawValue: return fiveHourPace
        case MenuBarWindow.sevenDay.rawValue: return sevenDayPace
        default: return modelPaces?[key]
        }
    }
}

// MARK: - Chart Series

/// One section of the Charts tab: a usage window plus the key its history samples are
/// stored under (shared with the pace buckets).
struct ChartSeries: Identifiable, Sendable {
    let key: String
    /// Already-localized section title, e.g. "5-Hour" or "7-Day Fable".
    let title: String
    /// The live window, used for the forecast chart. Nil before the first fetch — the
    /// utilization and pace charts still render from persisted history.
    let window: UsageWindow?
    /// Window length, used to anchor the forecast chart's start.
    let duration: TimeInterval
    var id: String { key }
}

/// The chart sections available for a usage response, in display order.
///
/// The two built-in windows are always listed, with or without a response: the Charts tab
/// renders them from persisted history, so dropping them when `usage` is nil (fresh launch,
/// failing fetch) would blank charts that have 30 days of data behind them. Model-scoped
/// series exist only while the response reports them.
func chartSeries(for response: UsageResponse?) -> [ChartSeries] {
    let week: TimeInterval = 7 * 24 * 3600
    var result: [ChartSeries] = [
        ChartSeries(key: MenuBarWindow.fiveHour.rawValue, title: MenuBarWindow.fiveHour.shortLabel,
                    window: response?.fiveHour, duration: 5 * 3600),
        ChartSeries(key: MenuBarWindow.sevenDay.rawValue, title: MenuBarWindow.sevenDay.shortLabel,
                    window: response?.sevenDay, duration: week),
    ]
    for tracked in response?.trackedWindows ?? [] where tracked.isModelScoped {
        result.append(ChartSeries(key: tracked.key, title: tracked.title,
                                  window: tracked.window, duration: week))
    }
    return result
}

/// Serializes the Charts tab's hidden-series set for `@AppStorage`.
///
/// Newline-separated because keys embed API-supplied model names, and sorted so rebuilding
/// an unchanged set can't churn the stored string.
func encodeHiddenKeys(_ keys: Set<String>) -> String {
    keys.sorted().joined(separator: "\n")
}

func decodeHiddenKeys(_ raw: String) -> Set<String> {
    Set(raw.split(separator: "\n").map(String.init))
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

    /// Compact title for the Charts tab sections, where the "Window" suffix is noise.
    var shortLabel: String {
        switch self {
        case .fiveHour: return String(localized: "5-Hour")
        case .sevenDay: return String(localized: "7-Day")
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
    /// True while the account is a placeholder awaiting its first sign-in. Cleared when a
    /// session is captured; rows still `true` at launch were abandoned by a quit/crash
    /// with the login window open and are reclaimed by `loadAccountsAndStartActive()`.
    var pending: Bool?

    init(id: UUID = UUID(),
         label: String,
         email: String? = nil,
         subscriptionLabel: String? = nil,
         orgName: String? = nil,
         dataStoreIdentifier: UUID = UUID(),
         addedAt: Date = Date(),
         pending: Bool? = nil) {
        self.id = id
        self.label = label
        self.email = email
        self.subscriptionLabel = subscriptionLabel
        self.orgName = orgName
        self.dataStoreIdentifier = dataStoreIdentifier
        self.addedAt = addedAt
        self.pending = pending
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
        self.pending = try c.decodeIfPresent(Bool.self, forKey: .pending)
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
    /// When `/api/account` was last requested; throttles the retry while `accountInfo` is nil.
    var accountInfoAttemptedAt: Date?
    /// Tracks the parsed `resetsAt` per window key; `detectResets` reads and rewrites it.
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
    /// Counts only consecutive 401s — kept separate from `consecutiveErrors` so a
    /// transient network/decode error right before the first 401 can't skip the
    /// documented one-poll silent retry and force a spurious re-login.
    var consecutive401s: Int = 0
    /// True after a 401 retry confirms the session is no longer valid; drives the popover's
    /// "Session expired" state, whose "Sign in again" reopens login on this same account
    /// (`signInAgain()`) so the user never has to remove and re-add it.
    var sessionExpired: Bool = false
}

/// UserDefaults-backed persistence for the account roster and the active selection.
///
/// `accounts` is stored as JSON-encoded `[Account]` under `"accounts"`.
/// `activeAccountID` is stored as a UUID string under `"activeAccountID"` (or absent when nil).
enum AccountStore {
    static let accountsKey = "accounts"
    /// Where an undecodable roster blob is preserved for manual recovery.
    static let corruptAccountsKey = accountsKey + ".corrupt"
    static let activeAccountIDKey = "activeAccountID"

    static func loadAccounts(from defaults: UserDefaults = .standard) -> [Account] {
        guard let data = defaults.data(forKey: accountsKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            // Preserve the undecodable blob under a sibling key before the empty
            // roster's first save overwrites it — corruption must stay recoverable
            // (via `defaults read` + manual repair), never silently fatal.
            defaults.set(data, forKey: corruptAccountsKey)
            AppLogger.shared.error("accounts decode failed — raw blob preserved under \(corruptAccountsKey)")
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

/// The WebKit data stores in `existing` that no roster entry owns, in `existing` order —
/// left behind when a removal ran while a web view still held its store (WebKit refuses to
/// delete a store in use). A pending placeholder is in the roster, so its store is kept.
func orphanedDataStoreIDs(existing: [UUID], roster: [Account]) -> [UUID] {
    let owned = Set(roster.map(\.dataStoreIdentifier))
    return existing.filter { !owned.contains($0) }
}

/// A newer version discovered via the GitHub Releases API.
struct UpdateInfo: Sendable {
    let version: String
    let releaseURL: URL
    /// Direct ZIP download URL from the GitHub release assets, if present.
    let downloadURL: URL?
}
