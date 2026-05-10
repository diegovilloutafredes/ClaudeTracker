import SwiftUI
import Charts

/// The popover content shown when the user clicks the menu bar icon.
struct MenuBarView: View {
    var viewModel: UsageViewModel
    @Environment(\.openSettings) private var openSettings

    @AppStorage("selectedTab") private var selectedTab = 0
    @State private var contentHeight: CGFloat = 0
    private let baseWidth: CGFloat = 312
    private var s: CGFloat { CGFloat(viewModel.popupScale) }
    private func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * s, weight: weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17 * s) {
            header
            if let update = viewModel.availableUpdate {
                updateBanner(update)
            }
            if viewModel.isAuthenticated && viewModel.showChartsTab {
                tabSelector
            }
            if selectedTab == 1 && viewModel.isAuthenticated && viewModel.showChartsTab {
                chartsContent
            } else {
                content
            }
            Divider()
            footer
        }
        .padding(19 * s)
        .frame(width: baseWidth * s)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            contentHeight = newHeight
        }
        .background(PopoverResizer(height: contentHeight))
        .onChange(of: viewModel.showChartsTab) { _, enabled in
            if !enabled { selectedTab = 0 }
        }
    }

    // MARK: - Update Banner

    @ViewBuilder
    private func updateBanner(_ update: UpdateInfo) -> some View {
        HStack(spacing: 8 * s) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.green)
                .font(sf(13))
                .accessibilityHidden(true)
            Text("v\(update.version) available")
                .font(sf(11, .semibold))
            Spacer()
            Group {
                switch viewModel.updateDownloadState {
                case .idle:
                    if update.downloadURL != nil {
                        Button("Install") { viewModel.downloadAndInstall() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.green)
                    } else {
                        Link("Download", destination: update.releaseURL)
                    }
                case .downloading:
                    HStack(spacing: 4 * s) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").foregroundStyle(.secondary)
                    }
                case .installing:
                    HStack(spacing: 4 * s) {
                        ProgressView().controlSize(.small)
                        Text("Installing…").foregroundStyle(.secondary)
                    }
                case .failed:
                    Link("Download", destination: update.releaseURL)
                }
            }
            .font(sf(11))
        }
        .padding(.horizontal, 10 * s)
        .padding(.vertical, 7 * s)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8 * s))
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Text("Claude Tracker")
                .font(sf(14, .semibold))
            Spacer()
            if viewModel.accounts.count >= 2 {
                accountPicker
            } else if let sub = viewModel.accountInfo?.subscriptionLabel {
                subscriptionBadge(sub)
            }
        }
    }

/// Multi-account chevron picker. Shown only when 2+ accounts exist; single-account users
    /// see the original subscription badge instead so the UI is unchanged for them.
    private var accountPicker: some View {
        Menu {
            ForEach(viewModel.accounts) { account in
                Button {
                    viewModel.switchAccount(to: account.id)
                } label: {
                    if account.id == viewModel.activeAccountID {
                        Label(account.label, systemImage: "checkmark")
                    } else {
                        Text(account.label)
                    }
                }
            }
            Divider()
            Button("Add account") {
                viewModel.openLoginForNewAccount()
            }
        } label: {
            HStack(spacing: 4 * s) {
                if let active = viewModel.accounts.first(where: { $0.id == viewModel.activeAccountID }) {
                    Text(active.label)
                        .font(sf(10, .semibold))
                        .lineLimit(1)
                }
                if let sub = viewModel.accountInfo?.subscriptionLabel {
                    Text(sub)
                        .font(sf(10, .semibold))
                        .padding(.horizontal, 6 * s)
                        .padding(.vertical, 2 * s)
                        .background(Color.purple.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.purple)
                }
                Image(systemName: "chevron.down")
                    .font(sf(9, .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func subscriptionBadge(_ label: String) -> some View {
        Text(label)
            .font(sf(10, .semibold))
            .padding(.horizontal, 6 * s)
            .padding(.vertical, 2 * s)
            .background(Color.purple.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.purple)
    }

    // MARK: - Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 1 * s) {
            tabButton("Usage", tag: 0)
            tabButton("Charts", tag: 1)
        }
        .padding(2 * s)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7 * s))
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ label: LocalizedStringKey, tag: Int) -> some View {
        Button { selectedTab = tag } label: {
            Text(label)
                .font(sf(11, selectedTab == tag ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4 * s)
                .background(
                    selectedTab == tag ? Color.primary.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5 * s)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !viewModel.isAuthenticated {
            emptyState
        } else if let usage = viewModel.usage {
            usageWindows(usage)
        } else if let error = viewModel.error {
            errorView(error)
        } else {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 11 * s) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(sf(23))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Not signed in")
                .font(sf(12))
                .foregroundStyle(.secondary)

            Button {
                viewModel.openLoginForNewAccount()
            } label: {
                Label("Add a Claude account", systemImage: "globe")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)

            Text("Opens Claude in a browser window.")
                .font(sf(11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8 * s)
    }

    @ViewBuilder
    private func usageWindows(_ usage: UsageResponse) -> some View {
        if viewModel.isDataStale {
            Label("Window reset — refreshing…", systemImage: "arrow.clockwise")
                .font(sf(11))
                .foregroundStyle(.secondary)
        } else if let error = viewModel.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(sf(11))
                .foregroundStyle(.orange)
        }

        VStack(alignment: .leading, spacing: 17 * s) {
            ForEach(usage.allWindows, id: \.0) { windowKey, window in
                windowRow(windowKey: windowKey, window: window)
            }
            if viewModel.showSonnetWindow, let sonnet = usage.sevenDaySonnet {
                let sonnetIsStale = viewModel.isWindowStale(sonnet)
                let suppressSonnetPace = sonnet.utilization >= 100 || sonnetIsStale
                let sonnetPace = (viewModel.showPace && !suppressSonnetPace)
                    ? viewModel.pace(for: "seven_day_sonnet") : nil
                UsageWindowView(
                    title: String(localized: "7-Day Sonnet"),
                    window: sonnet,
                    paceRate: sonnetPace?.rate,
                    projectedHours: sonnetPace?.projectedHours,
                    scale: s,
                    paceRateUnit: viewModel.paceRateUnit,
                    isStale: sonnetIsStale
                )
            }
        }

        if let extra = usage.extraUsage, extra.isEnabled {
            extraUsageView(extra)
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 8 * s) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(sf(12))

            Button("Sign in again") {
                if let svc = viewModel.apiService {
                    LoginWindowController.shared.open(
                        apiService: svc,
                        onSessionFound: viewModel.handleSessionFound
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8 * s)
    }

    @ViewBuilder
    private func extraUsageView(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 4 * s) {
            Text("Extra Usage")
                .font(sf(12, .bold))
            if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                Text(String(format: "$%.2f / $%.2f", used, limit))
                    .font(sf(11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func windowRow(windowKey: MenuBarWindow, window: UsageWindow) -> some View {
        let windowIsStale = viewModel.isWindowStale(window)
        let suppressPace = window.utilization >= 100 || windowIsStale
        let pace = (viewModel.showPace && !suppressPace) ? viewModel.pace(for: windowKey.rawValue) : nil
        return UsageWindowView(
            title: windowKey.label,
            window: window,
            paceRate: pace?.rate,
            projectedHours: pace?.projectedHours,
            scale: s,
            paceRateUnit: viewModel.paceRateUnit,
            isStale: windowIsStale
        )
    }

    // MARK: - Charts

    @AppStorage("chartTimeRange") private var chartTimeRange: ChartTimeRange = .oneDay
    @State private var selectedTime: Date?
    @State private var visibleHistory: [UsageDataPoint] = []
    @State private var chartXDomain: ClosedRange<Date> = Date()...Date()

    private func refreshVisibleHistory() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-chartTimeRange.hours * 3600)
        chartXDomain = cutoff...now
        visibleHistory = viewModel.usageHistory.filter { $0.timestamp >= cutoff }
    }

    @ViewBuilder
    private var chartsContent: some View {
        VStack(alignment: .leading, spacing: 16 * s) {
            timeRangePicker
            if visibleHistory.isEmpty {
                Text("No data for this period")
                    .font(sf(12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16 * s)
            } else {
                VStack(alignment: .leading, spacing: 22 * s) {
                    windowCharts(
                        title: "5-Hour", utilKeyPath: \.fiveHour, paceKeyPath: \.fiveHourPace,
                        history: visibleHistory, xDomain: chartXDomain, selectedTime: $selectedTime,
                        window: viewModel.usage?.fiveHour, windowDuration: 5 * 3600,
                        currentPaceRate: viewModel.pace(for: "five_hour")?.rate
                    )
                    Divider()
                    windowCharts(
                        title: "7-Day", utilKeyPath: \.sevenDay, paceKeyPath: \.sevenDayPace,
                        history: visibleHistory, xDomain: chartXDomain, selectedTime: $selectedTime,
                        window: viewModel.usage?.sevenDay, windowDuration: 7 * 24 * 3600,
                        currentPaceRate: viewModel.pace(for: "seven_day")?.rate
                    )
                }
            }
        }
        .onChange(of: chartTimeRange, initial: true) { refreshVisibleHistory() }
        .onChange(of: viewModel.usageHistory.last?.timestamp) { refreshVisibleHistory() }
    }

    private var timeRangePicker: some View {
        HStack(spacing: 1 * s) {
            ForEach(ChartTimeRange.allCases, id: \.self) { range in
                Button { chartTimeRange = range } label: {
                    Text(range.rawValue)
                        .font(sf(11, chartTimeRange == range ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4 * s)
                        .background(
                            chartTimeRange == range ? Color.primary.opacity(0.1) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5 * s)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2 * s)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7 * s))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func windowCharts(
        title: String,
        utilKeyPath: KeyPath<UsageDataPoint, Double?>,
        paceKeyPath: KeyPath<UsageDataPoint, Double?>,
        history: [UsageDataPoint],
        xDomain: ClosedRange<Date>,
        selectedTime: Binding<Date?>,
        window: UsageWindow? = nil,
        windowDuration: TimeInterval = 5 * 3600,
        currentPaceRate: Double? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            Text(LocalizedStringKey(title))
                .font(sf(11, .semibold))
            MiniChartView(
                label: "Utilization",
                filtered: history,
                keyPath: utilKeyPath,
                domain: 0...100,
                xDomain: xDomain,
                selectedTime: selectedTime,
                paceRateUnit: nil,
                scale: s
            )
            MiniChartView(
                label: "Pace",
                filtered: history,
                keyPath: paceKeyPath,
                domain: nil,
                xDomain: xDomain,
                selectedTime: selectedTime,
                paceRateUnit: viewModel.paceRateUnit,
                scale: s
            )
            if let w = window {
                projectionChart(
                    allHistory: viewModel.usageHistory,
                    utilKeyPath: utilKeyPath,
                    window: w,
                    paceRate: currentPaceRate,
                    windowDuration: windowDuration,
                    selectedTime: selectedTime
                )
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
        utilKeyPath: KeyPath<UsageDataPoint, Double?>,
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
                    guard let v = dp[keyPath: utilKeyPath] else { return nil }
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
            let xFmt: Date.FormatStyle = span < 25 * 3600
                ? .dateTime.hour().minute()
                : .dateTime.month(.abbreviated).day()
            let hovered: (Date, Double)? = selectedTime.wrappedValue.flatMap { t in
                (windowStart...xMax).contains(t)
                    ? pairs.min(by: { abs($0.0.timeIntervalSince(t)) < abs($1.0.timeIntervalSince(t)) })
                    : nil
            }
            let hoveredLabel: String? = hovered.map { t, v in
                let windowDurationSecs = resetDate.timeIntervalSince(windowStart)
                let expectedPct = windowDurationSecs > 0
                    ? min(max(t.timeIntervalSince(windowStart) / windowDurationSecs * 100, 0), 100)
                    : 0
                let timeStr = span < 25 * 3600
                    ? t.formatted(.dateTime.hour().minute())
                    : t.formatted(.dateTime.month(.abbreviated).day())
                return "actual \(Int(v))%  expected \(Int(expectedPct))%  \(timeStr)"
            }

            VStack(alignment: .leading, spacing: 7 * s) {
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
                        .frame(height: 60 * s)
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
            LineMark(x: .value("Time", windowStart), y: .value("Usage", 0.0), series: .value("s", "expected"))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            LineMark(x: .value("Time", resetDate), y: .value("Usage", 100.0), series: .value("s", "expected"))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(pairs, id: \.0) { pair in
                AreaMark(x: .value("Time", pair.0), y: .value("Usage", pair.1))
                    .foregroundStyle(Color.secondary.opacity(0.12))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", pair.0), y: .value("Usage", pair.1), series: .value("s", "actual"))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if let ld = lastDate, let pe = projEnd {
                LineMark(x: .value("Time", ld), y: .value("Usage", lastVal), series: .value("s", "extrapolated"))
                    .foregroundStyle(accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                LineMark(x: .value("Time", pe), y: .value("Usage", 100.0), series: .value("s", "extrapolated"))
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
                AxisValueLabel(format: xFmt).font(.system(size: 8 * s))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .stride(by: 25)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))%").font(.system(size: 8 * s))
                    }
                }
            }
        }
        .frame(height: 60 * s)
        .chartHoverSelection(selectedTime)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                openSettings()
                // openSettings() opens the Settings scene window but does NOT bring it forward
                // when it's already open. Manually find the existing Settings NSWindow and
                // order it front so re-clicking the button reliably surfaces it.
                DispatchQueue.main.async {
                    if let win = NSApp.windows.first(where: { $0.title.hasPrefix("Settings") }) {
                        NSApp.setActivationPolicy(.regular)
                        win.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            } label: {
                Text("Settings")
                    .font(sf(11))
            }
            .buttonStyle(.link)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
            .font(sf(11))
        }
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
                                selectedTime.wrappedValue = date
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
    let keyPath: KeyPath<UsageDataPoint, Double?>
    let domain: ClosedRange<Double>?
    let xDomain: ClosedRange<Date>
    @Binding var selectedTime: Date?
    let paceRateUnit: PaceRateUnit?
    let scale: CGFloat

    private func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    private func format(_ value: Double) -> String {
        paceRateUnit.map { $0.format(value) } ?? "\(Int(value))%"
    }

    var body: some View {
        let values: [Double] = filtered.compactMap { $0[keyPath: keyPath] }
        let peak = values.max() ?? 0
        let avg = values.isEmpty ? 0.0 : values.reduce(0, +) / Double(values.count)
        let color: Color = urgencyColor(min((values.last ?? 0) / 100.0, 1.0))
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        let xFormat: Date.FormatStyle = span < 25 * 3600
            ? .dateTime.hour().minute()
            : .dateTime.month(.abbreviated).day()
        let hovered: (Date, Double)? = {
            guard let t = selectedTime else { return nil }
            let pairs = filtered.compactMap { dp -> (Date, Double)? in
                guard let v = dp[keyPath: keyPath] else { return nil }
                return (dp.timestamp, v)
            }
            return pairs.min(by: { abs($0.0.timeIntervalSince(t)) < abs($1.0.timeIntervalSince(t)) })
        }()
        let displayValue = hovered?.1 ?? (values.last ?? 0)
        let nowLabel: String = {
            if let (t, v) = hovered {
                let timeStr = span < 25 * 3600
                    ? t.formatted(.dateTime.hour().minute())
                    : t.formatted(.dateTime.month(.abbreviated).day())
                return "@ \(format(v))  \(timeStr)"
            }
            return "now \(format(displayValue))"
        }()

        VStack(alignment: .leading, spacing: 7 * scale) {
            HStack {
                Text(LocalizedStringKey(label))
                    .font(sf(10))
                    .foregroundStyle(.secondary)
                Spacer()
                if !values.isEmpty {
                    Text("\(nowLabel)  pk \(format(peak))  avg \(format(avg.rounded()))")
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
                        if let v = dp[keyPath: keyPath] {
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
                    if let t = selectedTime, xDomain.contains(t) {
                        RuleMark(x: .value("Selected", t))
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
            }
        }
    }
}

// MARK: - Popover Resizer

/// Forces the MenuBarExtra NSPanel to match the SwiftUI content height whenever it changes,
/// and snaps the panel back to its first observed `(x, top-y)` on every move.
///
/// AppKit silently re-anchors the menu bar popover to the status item's frame whenever the
/// status item's image width changes. The image width changes constantly here — utilization
/// digits go from "5%" to "100%", the pace badge appears/disappears, and account switches
/// can trigger several rapid updates. Each anchor change drags the popover sideways even
/// though the user hasn't done anything to warrant it.
///
/// We can't easily prevent AppKit from moving the window, but we can listen for
/// `NSWindow.didMoveNotification` and immediately snap the frame back to the pinned spot.
/// The snap is fast enough to be visually invisible in practice.
private struct PopoverResizer: NSViewRepresentable {
    let height: CGFloat

    final class Coordinator {
        var pinnedX: CGFloat?
        var pinnedTop: CGFloat?
        var moveObserver: NSObjectProtocol?
        /// Reentrancy guard: our own `setFrame` triggers `didMoveNotification`, which would
        /// recurse into the snap-back path and cause an infinite ping-pong.
        var isSnapping = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let obs = coordinator.moveObserver {
            NotificationCenter.default.removeObserver(obs)
            coordinator.moveObserver = nil
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard height > 10 else { return }
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }

            // Capture the panel's natural anchor on first appearance.
            if context.coordinator.pinnedX == nil {
                context.coordinator.pinnedX = window.frame.origin.x
                context.coordinator.pinnedTop = window.frame.maxY
            }

            // Install the move observer once. It snaps the window back any time AppKit
            // (or a status-item resize) drags it away from the pinned position.
            if context.coordinator.moveObserver == nil {
                let coord = context.coordinator
                context.coordinator.moveObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { [weak window] _ in
                    guard let window else { return }
                    guard !coord.isSnapping,
                          let pinX = coord.pinnedX,
                          let pinTop = coord.pinnedTop else { return }
                    let dx = abs(window.frame.origin.x - pinX)
                    let dyTop = abs(window.frame.maxY - pinTop)
                    guard dx > 0.5 || dyTop > 0.5 else { return }
                    coord.isSnapping = true
                    var snap = window.frame
                    snap.origin.x = pinX
                    snap.origin.y = pinTop - snap.height
                    window.setFrame(snap, display: true, animate: false)
                    coord.isSnapping = false
                }
            }

            guard let pinX = context.coordinator.pinnedX,
                  let pinTop = context.coordinator.pinnedTop else { return }
            let needsResize = abs(window.frame.height - height) > 1
            let needsReposition = abs(window.frame.origin.x - pinX) > 1 || abs(window.frame.maxY - pinTop) > 1
            guard needsResize || needsReposition else { return }
            context.coordinator.isSnapping = true
            let newFrame = CGRect(x: pinX, y: pinTop - height, width: window.frame.width, height: height)
            window.setFrame(newFrame, display: true, animate: false)
            context.coordinator.isSnapping = false
        }
    }
}

// MARK: - Chart Time Range

private enum ChartTimeRange: String, CaseIterable {
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

// MARK: - Usage Window View

/// A single rate-limit window row: title, utilization percentage, progress bar, reset countdown, and pace.
struct UsageWindowView: View {
    let title: String
    let window: UsageWindow
    let paceRate: Double?
    let projectedHours: Double?
    let scale: CGFloat
    var paceRateUnit: PaceRateUnit = .perHour
    var isStale: Bool = false

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

            if let resetDate = window.resetsAtDate {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .accessibilityHidden(true)
                    Text("Resets \(resetDate, style: .relative)")
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
                HStack(spacing: 4) {
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

        if proj >= hoursToReset {
            let messages: [LocalizedStringKey] = [
                "On track — resets before limit",
                "You're good — resets in time",
                "All clear — window resets first",
                "Safe — usage resets before full",
                "No rush — plenty of time left",
            ]
            return ("checkmark.circle", messages[seed % messages.count], color)
        } else if proj >= hoursToReset * 0.8 {
            let messages: [LocalizedStringKey] = [
                "Getting close — may hit limit",
                "Pace is high — watch your usage",
                "Caution — cutting it close",
                "Almost at the edge — ease up",
                "Trending toward the limit",
            ]
            return ("exclamationmark.circle", messages[seed % messages.count], color)
        } else {
            let early = hoursToReset - proj
            let timeStr = early < 1
                ? "~\(max(1, Int(early * 60)))m"
                : "~\(Int(early.rounded()))h"
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

        return HStack(spacing: 4) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .accessibilityHidden(true)
            Text([rateText, projText].compactMap { $0 }.joined(separator: " "))
        }
        .font(sf(11))
        .foregroundStyle(color)
    }
}
