import SwiftUI
import Charts

/// Trailing space reserved inside the Charts tab's `ScrollView` for the macOS overlay
/// scroller, which is drawn at the scroll view's trailing edge and would otherwise cover
/// the charts' trailing y-axis labels (its resting track occupies the last ~10 pt of the
/// content width). `MenuBarView.baseWidth` adds the same amount, so the gutter costs the
/// charts no width — widening the popover alone would not help, since the charts fill the
/// scroll view and the scroller moves outward with them.
let chartsScrollGutter: CGFloat = 14

/// Hour:minute axis/hover labels for spans under ~a day; abbreviated month + day beyond.
/// The hour cycle is pinned to the Time format setting so chart times match the reset line.
private func chartAxisFormat(forSpan span: TimeInterval, use24Hour: Bool) -> Date.FormatStyle {
    span < 25 * 3600
        ? .dateTime.hour().minute().locale(pinnedHourCycleLocale(use24Hour: use24Hour))
        : .dateTime.month(.abbreviated).day()
}

/// The Charts tab of the popover: a time-range picker plus, per usage window,
/// utilization and pace mini-charts and the window-period forecast chart.
///
/// Extracted from `MenuBarView` as its own struct so the Usage tab's poll-driven
/// updates don't re-execute the chart builders, and hover state stays local.
struct MenuBarChartsView: View {
    var viewModel: UsageViewModel
    let scale: CGFloat

    @AppStorage(PrefKey.chartTimeRange) private var chartTimeRange: ChartTimeRange = .oneDay
    @AppStorage(PrefKey.chartHiddenSeries) private var hiddenSeriesRaw = ""
    @AppStorage(PrefKey.chartShowUtilization) private var showUtilizationChart = true
    @AppStorage(PrefKey.chartShowPace) private var showPaceChart = true
    @AppStorage(PrefKey.chartShowForecast) private var showForecastChart = true
    /// Shared across all charts: hovering any chart shows the rule mark on all of them.
    @State private var selectedTime: Date?

    private func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    /// Caps the scrolling section list so the popover can't grow past the screen: it has no
    /// scroll view of its own, and `PopoverResizer` pins the top edge, so an oversized
    /// popover runs off the bottom and clips silently. The subtrahend covers the popover
    /// chrome above and below this list (header, tabs, range picker, footer, padding).
    private var maxSectionsHeight: CGFloat {
        max((NSScreen.main?.visibleFrame.height ?? 900) - 250 * scale, 320 * scale)
    }

    var body: some View {
        // Computed inline (not cached in @State filled by onChange): this view is
        // recreated on every tab switch, and a state-cache starts empty — the first
        // committed frame would render the short "No data" layout and then the tall
        // charts one beat later, double-resizing the popover (visible shake). The
        // filter over ≤8640 points is trivial, and hover writes are minute-quantized.
        let now = Date()
        let cutoff = now.addingTimeInterval(-chartTimeRange.hours * 3600)
        let chartXDomain = cutoff...now
        let visibleHistory = viewModel.usageHistory.filter { $0.timestamp >= cutoff }
        let hidden = decodeHiddenKeys(hiddenSeriesRaw)
        let allSeries = chartSeries(for: viewModel.usage)
        let visibleSeries = allSeries.filter { !hidden.contains($0.key) }
        let anyKindShown = showUtilizationChart || showPaceChart || showForecastChart

        VStack(alignment: .leading, spacing: 16 * scale) {
            HStack(spacing: 8 * scale) {
                ScaledSegmentedPicker(selection: $chartTimeRange,
                                      options: ChartTimeRange.allCases,
                                      scale: scale) { range in
                    Text(range.rawValue)
                }
                filterMenu(allSeries)
            }
            if visibleSeries.isEmpty || !anyKindShown {
                message("Nothing selected")
            } else if visibleHistory.isEmpty {
                message("No data for this period")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22 * scale) {
                        ForEach(Array(visibleSeries.enumerated()), id: \.element.id) { index, series in
                            if index > 0 { Divider() }
                            windowCharts(series: series, history: visibleHistory,
                                         xDomain: chartXDomain, selectedTime: $selectedTime)
                        }
                    }
                    .padding(.trailing, chartsScrollGutter * scale)
                }
                .frame(maxHeight: maxSectionsHeight)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(sf(12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16 * scale)
    }

    // MARK: - Content Filter

    /// Checkmark menu selecting which windows and which chart kinds the tab renders.
    private func filterMenu(_ series: [ChartSeries]) -> some View {
        Menu {
            Section("Windows") {
                ForEach(series) { s in
                    Toggle(s.title, isOn: seriesVisibility(s.key))
                }
            }
            Section("Charts") {
                Toggle("Utilization", isOn: $showUtilizationChart)
                Toggle("Pace", isOn: $showPaceChart)
                Toggle("Forecast", isOn: $showForecastChart)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(sf(13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Chart content"))
    }

    /// Visibility is stored inverted (the hidden set) so a model window the API starts
    /// reporting appears without the user having to opt in.
    private func seriesVisibility(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !decodeHiddenKeys(hiddenSeriesRaw).contains(key) },
            set: { visible in
                var hidden = decodeHiddenKeys(hiddenSeriesRaw)
                if visible { hidden.remove(key) } else { hidden.insert(key) }
                hiddenSeriesRaw = encodeHiddenKeys(hidden)
            }
        )
    }

    @ViewBuilder
    private func windowCharts(
        series: ChartSeries,
        history: [UsageDataPoint],
        xDomain: ClosedRange<Date>,
        selectedTime: Binding<Date?>
    ) -> some View {
        let key = series.key
        // Same staleness gate as the Usage tab's rows: after a reset that passed while the
        // app wasn't polling, a forecast anchored to the expired window would present stale
        // data as current.
        let forecastWindow: UsageWindow? = showForecastChart
            ? series.window.flatMap { viewModel.isWindowStale($0) ? nil : $0 }
            : nil
        VStack(alignment: .leading, spacing: 14 * scale) {
            Text(series.title)
                .font(sf(11, .semibold))
            if showUtilizationChart {
                MiniChartView(
                    label: "Utilization",
                    filtered: history,
                    value: { $0.utilization(for: key) },
                    domain: 0...100,
                    xDomain: xDomain,
                    selectedTime: selectedTime,
                    paceRateUnit: nil,
                    scale: scale,
                    use24Hour: viewModel.use24HourTime
                )
            }
            if showPaceChart {
                MiniChartView(
                    label: "Pace",
                    filtered: history,
                    value: { $0.paceRate(for: key) },
                    domain: nil,
                    xDomain: xDomain,
                    selectedTime: selectedTime,
                    paceRateUnit: viewModel.paceRateUnit,
                    scale: scale,
                    use24Hour: viewModel.use24HourTime
                )
            }
            if let w = forecastWindow {
                projectionChart(
                    allHistory: viewModel.usageHistory,
                    value: { $0.utilization(for: key) },
                    window: w,
                    paceRate: viewModel.pace(for: key)?.rate,
                    windowDuration: series.duration,
                    selectedTime: selectedTime
                )
            }
            // Forecast alone, on a window with no live data (nothing fetched yet, or stale),
            // would leave the section as a bare title — which reads as broken, not as empty.
            if !showUtilizationChart, !showPaceChart, forecastWindow == nil {
                Text("Collecting…")
                    .font(sf(9))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 50 * scale)
            }
        }
    }

    private func forecastAccentColor(paceRate: Double?, lastVal: Double, lastDate: Date?, resetDate: Date) -> Color {
        guard let rate = paceRate, lastVal < 100, lastDate != nil else { return .secondary }
        return paceUrgencyColor(
            proj: (100.0 - lastVal) / rate,
            hoursToReset: resetDate.timeIntervalSinceNow / 3600
        )
    }

    @ViewBuilder
    private func projectionChart(
        allHistory: [UsageDataPoint],
        value: (UsageDataPoint) -> Double?,
        window: UsageWindow,
        paceRate: Double?,
        windowDuration: TimeInterval,
        selectedTime: Binding<Date?>
    ) -> some View {
        if let resetDate = window.resetsAtDate {
            let windowStart = resetDate.addingTimeInterval(-windowDuration)
            let pairs: [(Date, Double)] = allHistory
                .filter { $0.timestamp >= windowStart }
                .compactMap { dp in
                    guard let v = value(dp) else { return nil }
                    return (dp.timestamp, v)
                }
            let lastDate = pairs.last?.0
            let lastVal = pairs.last?.1 ?? window.utilization
            let projEnd: Date? = lastDate.flatMap { ld -> Date? in
                guard let rate = paceRate, lastVal < 100 else { return nil }
                return ld.addingTimeInterval((100.0 - lastVal) / rate * 3600)
            }
            let xMax = [resetDate, projEnd].compactMap { $0 }.max() ?? resetDate
            let accentColor = forecastAccentColor(paceRate: paceRate, lastVal: lastVal, lastDate: lastDate, resetDate: resetDate)
            let span = xMax.timeIntervalSince(windowStart)
            let xFmt = chartAxisFormat(forSpan: span, use24Hour: viewModel.use24HourTime)
            // Same gap cutoff as MiniChartView: only pair the cursor with a sample that
            // is actually near it (5% of the span, min 10 min).
            let hovered: (Date, Double)? = selectedTime.wrappedValue.flatMap { t in
                guard (windowStart...xMax).contains(t),
                      let nearest = pairs.min(by: { abs($0.0.timeIntervalSince(t)) < abs($1.0.timeIntervalSince(t)) }),
                      abs(nearest.0.timeIntervalSince(t)) <= max(span * 0.05, 600) else { return nil }
                return nearest
            }
            let hoveredLabel: String? = hovered.map { t, v in
                let windowDurationSecs = resetDate.timeIntervalSince(windowStart)
                let expectedPct = windowDurationSecs > 0
                    ? min(max(t.timeIntervalSince(windowStart) / windowDurationSecs * 100, 0), 100)
                    : 0
                let timeStr = t.formatted(xFmt)
                return String(format: String(localized: "actual %d%%  expected %d%%  %@"),
                              Int(v), Int(expectedPct), timeStr)
            }

            VStack(alignment: .leading, spacing: 7 * scale) {
                HStack {
                    Text("Forecast")
                        .font(sf(10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let label = hoveredLabel {
                        Text(label)
                            .font(sf(9))
                            .foregroundStyle(.secondary)
                    } else if let rate = paceRate {
                        Text("pace \(viewModel.paceRateUnit.format(rate))")
                            .font(sf(9))
                            .foregroundStyle(.secondary)
                    }
                }
                if pairs.count < 2 {
                    Text("Collecting…")
                        .font(sf(9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 60 * scale)
                } else {
                    forecastChartBody(
                        pairs: pairs, lastDate: lastDate, lastVal: lastVal, projEnd: projEnd,
                        windowStart: windowStart, resetDate: resetDate, xMax: xMax,
                        accentColor: accentColor, xFmt: xFmt, selectedTime: selectedTime
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func forecastChartBody(
        pairs: [(Date, Double)],
        lastDate: Date?,
        lastVal: Double,
        projEnd: Date?,
        windowStart: Date,
        resetDate: Date,
        xMax: Date,
        accentColor: Color,
        xFmt: Date.FormatStyle,
        selectedTime: Binding<Date?>
    ) -> some View {
        Chart {
            LineMark(x: .value("Time", windowStart), y: .value("Usage", 0.0), series: .value("Series", "expected"))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            LineMark(x: .value("Time", resetDate), y: .value("Usage", 100.0), series: .value("Series", "expected"))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(pairs, id: \.0) { pair in
                AreaMark(x: .value("Time", pair.0), y: .value("Usage", pair.1))
                    .foregroundStyle(Color.secondary.opacity(0.12))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", pair.0), y: .value("Usage", pair.1), series: .value("Series", "actual"))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if let ld = lastDate, let pe = projEnd {
                LineMark(x: .value("Time", ld), y: .value("Usage", lastVal), series: .value("Series", "extrapolated"))
                    .foregroundStyle(accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                LineMark(x: .value("Time", pe), y: .value("Usage", 100.0), series: .value("Series", "extrapolated"))
                    .foregroundStyle(accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            if let t = selectedTime.wrappedValue, (windowStart...xMax).contains(t) {
                RuleMark(x: .value("Selected", t))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: 0...105)
        .chartXScale(domain: windowStart...xMax)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel(format: xFmt).font(.system(size: 8 * scale))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .stride(by: 25)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))%").font(.system(size: 8 * scale))
                    }
                }
            }
        }
        .frame(height: 60 * scale)
        .chartHoverSelection(selectedTime)
        .accessibilityLabel(Text("Forecast chart"))
    }
}

// MARK: - Chart Hover

private struct ChartHoverModifier: ViewModifier {
    let selectedTime: Binding<Date?>

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geo[plotFrame]
                            let x = location.x - frame.origin.x
                            if let date = proxy.value(atX: x, as: Date.self) {
                                // Quantize to the minute and skip no-op writes: raw per-pixel
                                // dates are always distinct, so every mouse move would
                                // re-evaluate the entire charts subtree (history is sampled
                                // every 5 minutes — sub-minute hover precision buys nothing).
                                let secs = (date.timeIntervalSinceReferenceDate / 60).rounded() * 60
                                let quantized = Date(timeIntervalSinceReferenceDate: secs)
                                if selectedTime.wrappedValue != quantized {
                                    selectedTime.wrappedValue = quantized
                                }
                            }
                        case .ended:
                            selectedTime.wrappedValue = nil
                        }
                    }
            }
        }
    }
}

extension View {
    fileprivate func chartHoverSelection(_ selectedTime: Binding<Date?>) -> some View {
        modifier(ChartHoverModifier(selectedTime: selectedTime))
    }
}

// MARK: - Mini Chart View

private struct MiniChartView: View {
    let label: String
    let filtered: [UsageDataPoint]
    /// Extracts this chart's sample from a history point. A closure rather than a key path
    /// because model-scoped series live in `UsageDataPoint.models`, keyed by window.
    let value: (UsageDataPoint) -> Double?
    let domain: ClosedRange<Double>?
    let xDomain: ClosedRange<Date>
    @Binding var selectedTime: Date?
    let paceRateUnit: PaceRateUnit?
    let scale: CGFloat
    let use24Hour: Bool

    private func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    private func format(_ value: Double) -> String {
        paceRateUnit.map { $0.format(value) } ?? "\(Int(value))%"
    }

    var body: some View {
        let values: [Double] = filtered.compactMap(value)
        let peak = values.max() ?? 0
        let avg = values.isEmpty ? 0.0 : values.reduce(0, +) / Double(values.count)
        let color: Color = urgencyColor(min((values.last ?? 0) / 100.0, 1.0))
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        let xFormat = chartAxisFormat(forSpan: span, use24Hour: use24Hour)
        let hovered: (Date, Double)? = {
            guard let t = selectedTime else { return nil }
            let pairs = filtered.compactMap { dp -> (Date, Double)? in
                guard let v = value(dp) else { return nil }
                return (dp.timestamp, v)
            }
            // Only match a sample near the cursor (5% of the visible span, min 10 min):
            // inside a data gap (Mac asleep) there is no reading, and snapping to one
            // hours away would present it as belonging to the hovered instant.
            guard let nearest = pairs.min(by: { abs($0.0.timeIntervalSince(t)) < abs($1.0.timeIntervalSince(t)) }),
                  abs(nearest.0.timeIntervalSince(t)) <= max(span * 0.05, 600) else { return nil }
            return nearest
        }()
        let displayValue = hovered?.1 ?? (values.last ?? 0)
        let nowLabel: String = {
            if let (t, v) = hovered {
                return String(format: String(localized: "@ %@  %@"), format(v), t.formatted(xFormat))
            }
            return String(format: String(localized: "now %@"), format(displayValue))
        }()

        VStack(alignment: .leading, spacing: 7 * scale) {
            HStack {
                Text(LocalizedStringKey(label))
                    .font(sf(10))
                    .foregroundStyle(.secondary)
                Spacer()
                if !values.isEmpty {
                    Text(String(format: String(localized: "%@  pk %@  avg %@"),
                                nowLabel, format(peak), format(avg.rounded())))
                        .font(sf(9))
                        .foregroundStyle(.secondary)
                }
            }
            if values.count < 2 {
                Text("Collecting…")
                    .font(sf(9))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 50 * scale)
            } else {
                Chart {
                    ForEach(filtered) { dp in
                        if let v = value(dp) {
                            AreaMark(
                                x: .value("Time", dp.timestamp),
                                y: .value(label, v)
                            )
                            .foregroundStyle(color.opacity(0.15))
                            .interpolationMethod(.monotone)
                            LineMark(
                                x: .value("Time", dp.timestamp),
                                y: .value(label, v)
                            )
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                        }
                    }
                    // The crosshair marks the MATCHED sample's own timestamp, not the
                    // cursor time — asserting the reading belongs where it actually is.
                    if let (ht, _) = hovered, xDomain.contains(ht) {
                        RuleMark(x: .value("Selected", ht))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartYScale(domain: domain ?? (0...max(values.max().map { $0 * 1.2 } ?? 1, 1)))
                .chartXScale(domain: xDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel(format: xFormat)
                            .font(.system(size: 8 * scale))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.secondary.opacity(0.25))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(format(v)).font(.system(size: 8 * scale))
                            }
                        }
                    }
                }
                .frame(height: 60 * scale)
                .chartHoverSelection($selectedTime)
                .accessibilityLabel(Text(LocalizedStringKey(label)))
            }
        }
    }
}

// MARK: - Chart Time Range

/// How much history the Charts tab displays. Selection persists via `@AppStorage`.
enum ChartTimeRange: String, CaseIterable {
    case oneHour    = "1h"
    case fiveHours  = "5h"
    case oneDay     = "24h"
    case sevenDays  = "7d"
    case thirtyDays = "30d"

    var hours: Double {
        switch self {
        case .oneHour:    return 1
        case .fiveHours:  return 5
        case .oneDay:     return 24
        case .sevenDays:  return 168
        case .thirtyDays: return 720
        }
    }
}
