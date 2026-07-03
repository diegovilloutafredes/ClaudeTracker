import SwiftUI

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
            if let update = viewModel.updates.availableUpdate {
                updateBanner(update)
            }
            if viewModel.isAuthenticated && viewModel.showChartsTab {
                tabSelector
            }
            if selectedTab == 1 && viewModel.isAuthenticated && viewModel.showChartsTab {
                MenuBarChartsView(viewModel: viewModel, scale: s)
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
                switch viewModel.updates.updateDownloadState {
                case .idle:
                    if update.downloadURL != nil {
                        Button("Install") { viewModel.updates.downloadAndInstall() }
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
                SubscriptionBadge(label: sub, scale: s)
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
                    SubscriptionBadge(label: sub, scale: s)
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

    // MARK: - Tab Selector

    private var tabSelector: some View {
        ScaledSegmentedPicker(selection: $selectedTab, options: [0, 1], scale: s) { tag in
            if tag == 0 {
                Text("Usage")
            } else {
                Text("Charts")
            }
        }
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
                    isStale: sonnetIsStale,
                    use24Hour: viewModel.use24HourTime,
                    includeResetDate: true
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
            isStale: windowIsStale,
            use24Hour: viewModel.use24HourTime,
            includeResetDate: windowKey == .sevenDay
        )
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
