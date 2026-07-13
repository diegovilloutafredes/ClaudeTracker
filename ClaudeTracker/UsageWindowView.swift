import SwiftUI

/// A single rate-limit window row: title, utilization percentage, progress bar, reset countdown, and pace.
struct UsageWindowView: View {
    let title: String
    let window: UsageWindow
    let paceRate: Double?
    let projectedHours: Double?
    let scale: CGFloat
    var paceRateUnit: PaceRateUnit = .perHour
    var isStale: Bool = false
    // No defaults: a call site that forgot these would silently ignore the Time format setting.
    let use24Hour: Bool
    /// 7-day windows include month + day in the absolute reset time; 5-hour windows don't.
    let includeResetDate: Bool

    private func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack {
                Text(title)
                    .font(sf(12, .bold))
                Spacer()
                Text(isStale ? "0%" : "\(Int(window.utilization))%")
                    .font(.system(size: 12 * scale, weight: .bold).monospacedDigit())
                    .foregroundStyle(isStale ? Color.secondary : window.utilizationColor)
            }

            ProgressView(value: isStale ? 0.0 : window.utilizationFraction)
                .tint(isStale ? Color.secondary : window.utilizationColor)

            // Hidden when stale: the reset already passed, and the relative style would
            // count upward from it, rendering "Resets in" directionally wrong.
            if let resetDate = window.resetsAtDate, !isStale {
                let absolute = resetTimeText(reset: resetDate, now: Date(),
                                             use24Hour: use24Hour, includeDate: includeResetDate)
                HStack(spacing: 4 * scale) {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                    Text("Resets in \(resetDate, style: .relative) · \(absolute)")
                }
                .font(sf(11))
                .foregroundStyle(.secondary)
            }

            if let rate = paceRate {
                paceLine(rate: rate)
                paceOutlookLine()
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func paceOutlookLine() -> some View {
        if let proj = projectedHours, proj > 0,
           let resetDate = window.resetsAtDate {
            let hrs = resetDate.timeIntervalSinceNow / 3600
            if hrs > 0 {
                let (icon, text, color) = paceOutlook(proj: proj, hoursToReset: hrs)
                HStack(spacing: 4 * scale) {
                    Image(systemName: icon).accessibilityHidden(true)
                    Text(text)
                }
                .font(sf(11))
                .foregroundStyle(color)
            }
        }
    }

    private func paceOutlook(proj: Double, hoursToReset: Double) -> (String, LocalizedStringKey, Color) {
        let seed = abs(Int(window.resetsAtDate?.timeIntervalSince1970 ?? 0))
        let color = paceUrgencyColor(proj: proj, hoursToReset: hoursToReset)

        switch PaceBand(projectedHours: proj, hoursToReset: hoursToReset) {
        case .safe:
            let messages: [LocalizedStringKey] = [
                "On track — resets before limit",
                "You're good — resets in time",
                "All clear — window resets first",
                "Safe — usage resets before full",
                "No rush — plenty of time left",
            ]
            return ("checkmark.circle", messages[seed % messages.count], color)
        case .close:
            let messages: [LocalizedStringKey] = [
                "Getting close — may hit limit",
                "Pace is high — watch your usage",
                "Caution — cutting it close",
                "Almost at the edge — ease up",
                "Trending toward the limit",
            ]
            return ("exclamationmark.circle", messages[seed % messages.count], color)
        case .over:
            let early = hoursToReset - proj
            // Localized: the unit abbreviation differs per language (es: "min", not "m").
            let timeStr = early < 1
                ? String(format: String(localized: "~%dm"), max(1, Int(early * 60)))
                : String(format: String(localized: "~%dh"), Int(early.rounded()))
            let messages: [LocalizedStringKey] = [
                "Will hit limit \(timeStr) before reset",
                "Runs out \(timeStr) before reset",
                "On pace to fill \(timeStr) early",
                "Full \(timeStr) before window resets",
            ]
            return ("exclamationmark.triangle.fill", messages[seed % messages.count], color)
        }
    }

    private func paceLine(rate: Double) -> some View {
        let color: Color = {
            guard let proj = projectedHours,
                  let resetDate = window.resetsAtDate else { return .secondary }
            return paceUrgencyColor(proj: proj, hoursToReset: resetDate.timeIntervalSinceNow / 3600)
        }()

        let rateText = paceRateUnit.format(rate, prefix: true)
        let projText: String? = projectedHours.flatMap { h in
            guard h < 24 else { return nil }
            if h < 1 { return String(format: String(localized: "· full in %dm"), max(1, Int(h * 60))) }
            let hrs = Int(h)
            let mins = Int((h - Double(hrs)) * 60)
            return mins > 0
                ? String(format: String(localized: "· full in %dh %dm"), hrs, mins)
                : String(format: String(localized: "· full in %dh"), hrs)
        }

        return HStack(spacing: 4 * scale) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .accessibilityHidden(true)
            Text([rateText, projText].compactMap { $0 }.joined(separator: " "))
        }
        .font(sf(11))
        .foregroundStyle(color)
    }
}
