import SwiftUI

/// The preferences window, opened via the Settings menu item or the "Settings" link in the popover.
struct SettingsView: View {
    @Bindable var viewModel: UsageViewModel

    @State private var pendingRemoval: Account? = nil
    @State private var pendingRename: Account? = nil
    @State private var renameDraft: String = ""

    var body: some View {
        let sf = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w  = (sf.width / 3).rounded()

        Form {
            accountSection
            if viewModel.isAuthenticated {
                displaySection
                resetSection
                paceSection
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: w, idealWidth: w, maxWidth: w)
        .fixedSize(horizontal: false, vertical: !viewModel.isAuthenticated)
        .background(SettingsWindowPositioner(targetWidth: w, isAuthenticated: viewModel.isAuthenticated))
        .alert(
            Text("Remove this account?"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { account in
            Button("Remove", role: .destructive) {
                viewModel.removeAccount(account.id)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { account in
            Text("Removes \(account.label) from this app and signs it out. The account itself is unaffected.")
        }
        .alert(
            Text("Rename account"),
            isPresented: Binding(
                get: { pendingRename != nil },
                set: { if !$0 { pendingRename = nil } }
            ),
            presenting: pendingRename
        ) { account in
            TextField("Name", text: $renameDraft)
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    viewModel.renameAccount(account.id, to: trimmed)
                }
                pendingRename = nil
            }
            Button("Cancel", role: .cancel) { pendingRename = nil }
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            if viewModel.accounts.isEmpty {
                emptyAccountRow
            } else {
                ForEach(viewModel.accounts) { account in
                    // Compute isActive in the parent body so the @Observable read of
                    // `activeAccountID` happens here. Passing the bool as a parameter
                    // makes the row depend on its inputs rather than relying on
                    // SwiftUI's tracking to flow through an extracted method —
                    // otherwise the open Settings window doesn't redraw on switch
                    // until you close + reopen it.
                    accountRow(account, isActive: account.id == viewModel.activeAccountID)
                }
            }

            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            updateRow

            Toggle("Auto-install updates", isOn: $viewModel.updates.autoUpdate)
                .toggleStyle(GreenSwitchStyle())
            if viewModel.updates.autoUpdate {
                Text(viewModel.updates.updateCheckIntervalLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }

            HStack(spacing: 10) {
                Button("Open Logs") {
                    if let url = AppLogger.shared.logFileURL?.deletingLastPathComponent() {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("Error and API logs for debugging")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Unofficial tool — not affiliated with or endorsed by Anthropic. May break if Anthropic changes their web API.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            HStack {
                Text("Account")
                Spacer()
                if !viewModel.accounts.isEmpty {
                    Button {
                        viewModel.openLoginForNewAccount()
                    } label: {
                        Label("Add account", systemImage: "plus.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .textCase(nil)
                }
            }
        }
    }

    private var emptyAccountRow: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 8, height: 8).accessibilityHidden(true)
            Text("Not signed in").font(.subheadline)
            Spacer()
            Button("Sign in") {
                viewModel.openLoginForNewAccount()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func accountRow(_ account: Account, isActive: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.label)
                        .font(.subheadline)
                    if let sub = account.subscriptionLabel {
                        SubscriptionBadge(label: sub)
                    }
                }
                if let email = account.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let org = account.orgName,
                   account.subscriptionLabel == "Team" || account.subscriptionLabel == "Enterprise" {
                    Label(org, systemImage: "building.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !isActive {
                Button("Switch") { viewModel.switchAccount(to: account.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button {
                renameDraft = account.label
                pendingRename = account
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Text("Rename account"))
            .accessibilityLabel(Text("Rename account"))
            Button {
                pendingRemoval = account
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(Text("Sign out & remove"))
            .accessibilityLabel(Text("Sign out & remove account"))
        }
    }

    @ViewBuilder
    private var updateRow: some View {
        if let update = viewModel.updates.availableUpdate {
            updateAvailableContent(update)
        } else {
            Button(viewModel.updates.isCheckingForUpdates ? "Checking…" : "Check for Updates") {
                viewModel.updates.checkForUpdates()
            }
            .disabled(viewModel.updates.isCheckingForUpdates)
        }
    }

    @ViewBuilder
    private func updateAvailableContent(_ update: UpdateInfo) -> some View {
        switch viewModel.updates.updateDownloadState {
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("v\(update.version) available")
                    .font(.subheadline)
                Spacer()
                if update.downloadURL != nil {
                    Button("Install") { viewModel.updates.downloadAndInstall() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Link("Download", destination: update.releaseURL)
                        .font(.subheadline)
                }
            }
        case .downloading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading…").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing…").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
        case .failed(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Link("Download", destination: update.releaseURL)
                    .font(.caption)
            }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section("Display") {
            Picker("Menu bar window", selection: $viewModel.menuBarWindow) {
                ForEach(MenuBarWindow.allCases) { window in
                    Text(window.label).tag(window)
                }
            }

            HStack(spacing: 10) {
                Text("Popup size")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Slider(value: $viewModel.popupScale, in: 0.75...1.5, step: 0.05)
                Text("\(Int((viewModel.popupScale * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            Toggle("Show charts tab", isOn: $viewModel.showChartsTab)
                .toggleStyle(GreenSwitchStyle())

            Toggle("Show Sonnet usage", isOn: $viewModel.showSonnetWindow)
                .toggleStyle(GreenSwitchStyle())

            Toggle("Show pace in usage tab", isOn: $viewModel.showPace)
                .toggleStyle(GreenSwitchStyle())

            Toggle("Show pace in menu bar", isOn: $viewModel.showPaceMenuBar)
                .toggleStyle(GreenSwitchStyle())

            if viewModel.showPace || viewModel.showPaceMenuBar || viewModel.notifyPace {
                HStack(spacing: 10) {
                    Text("Rate unit")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Picker("", selection: $viewModel.paceRateUnit) {
                        ForEach(PaceRateUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.leading, 20)
            }

            HStack(spacing: 10) {
                Text("Time format")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Picker("", selection: $viewModel.use24HourTime) {
                    Text("AM/PM").tag(false)
                    Text("24-hour").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    // MARK: - Window Reset Notifications

    private var resetSection: some View {
        Section("Window Resets") {
            Toggle("5-Hour window resets", isOn: $viewModel.notify5Hour)
                .toggleStyle(GreenSwitchStyle())
            Toggle("7-Day window resets", isOn: $viewModel.notify7Day)
                .toggleStyle(GreenSwitchStyle())

            Divider().listRowInsets(EdgeInsets())

            Toggle("Toast near menu bar", isOn: $viewModel.notifyToast)
                .toggleStyle(GreenSwitchStyle())

            if viewModel.notifyToast {
                ToastDurationControls(duration: $viewModel.toastDuration,
                                      permanent: $viewModel.toastPermanent)
            }

            Toggle("Sound (Hero)", isOn: $viewModel.resetSoundEnabled)
                .toggleStyle(GreenSwitchStyle())

            Divider().listRowInsets(EdgeInsets())

            HStack(spacing: 10) {
                Button("Test") { viewModel.sendTestNotification() }
                    .disabled(!viewModel.notifyToast && !viewModel.resetSoundEnabled)
                Text("Simulates a window reset through all enabled channels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pace Alert Notifications

    private var paceSection: some View {
        Section("Pace Alerts") {
            Toggle("Notify when approaching limit", isOn: $viewModel.notifyPace)
                .toggleStyle(GreenSwitchStyle())

            if viewModel.notifyPace {
                HStack(spacing: 10) {
                    Text("Warn with less than")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Slider(value: $viewModel.paceWarningMinutes, in: 5...60, step: 5)
                    Text("\(Int(viewModel.paceWarningMinutes))m")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                Divider().listRowInsets(EdgeInsets())

                Toggle("Toast near menu bar", isOn: $viewModel.paceToastEnabled)
                    .toggleStyle(GreenSwitchStyle())

                if viewModel.paceToastEnabled {
                    ToastDurationControls(duration: $viewModel.paceToastDuration,
                                          permanent: $viewModel.paceToastPermanent)
                }

                Toggle("Sound (Basso)", isOn: $viewModel.paceSoundEnabled)
                    .toggleStyle(GreenSwitchStyle())

                Divider().listRowInsets(EdgeInsets())

                HStack(spacing: 10) {
                    Button("Test") { viewModel.sendTestPaceNotification() }
                        .disabled(!viewModel.paceToastEnabled && !viewModel.paceSoundEnabled)
                    Text("Simulates a pace alert through all enabled channels")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Fires when a watched window is projected to fill before it resets, based on your current consumption rate.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

// MARK: - Green Switch Toggle Style

/// Custom toggle style that renders an always-green switch regardless of the system
/// accent color or SwiftUI environment tint. Uses a drawn capsule+circle so no
/// native NSSwitch environment plumbing is involved — immune to Form cell isolation.
///
/// The drawn control is wrapped in a plain `Button` (not a tap gesture) so it gets
/// keyboard focus and Space activation, and `accessibilityRepresentation` exposes
/// real toggle semantics (state + label) to VoiceOver.
private struct GreenSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer()
                ZStack {
                    Capsule()
                        .fill(configuration.isOn ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 38, height: 22)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)
                        .frame(width: 18, height: 18)
                        .offset(x: configuration.isOn ? 8 : -8)
                }
                .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: - Toast Duration Controls

/// Duration slider + "stay until dismissed" toggle, shared by the reset-toast and
/// pace-toast settings blocks.
private struct ToastDurationControls: View {
    @Binding var duration: Double
    @Binding var permanent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Duration")
                    .font(.callout)
                    .foregroundStyle(permanent ? .tertiary : .secondary)
                Slider(value: $duration, in: 1...30, step: 1)
                    .disabled(permanent)
                Text(permanent ? "∞" : "\(Int(duration))s")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(permanent ? .tertiary : .secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            Toggle("Stay until dismissed", isOn: $permanent)
                .font(.callout)
                .toggleStyle(GreenSwitchStyle())
        }
        .padding(.leading, 20)
    }
}

// MARK: - Window Positioner

/// Captures the exact NSWindow that hosts SettingsView so we can position it
/// relative to the screen without relying on NSApp.keyWindow, which could be
/// any window (e.g. the Login window) if focus changed between onAppear and the
/// async dispatch.
private struct SettingsWindowPositioner: NSViewRepresentable {
    let targetWidth: CGFloat
    let isAuthenticated: Bool

    final class Coordinator {
        var closeObserver: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        let targetWidth = targetWidth
        let isAuthenticated = isAuthenticated
        // Deferred one main-actor turn so `view.window` is populated.
        Task<Void, Never> { @MainActor in
            guard let window = view.window, let screen = NSScreen.main else { return }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            window.title = String(format: String(localized: "Settings · v%@"), version)
            Self.reframe(window: window, screen: screen, targetWidth: targetWidth, isAuthenticated: isAuthenticated)
            // Promote the menu bar app to .regular while Settings is visible so Cmd+Tab finds
            // the app and the window can be brought to front. A dock icon appears as a side
            // effect — unavoidable; macOS has no "Cmd+Tab only" activation policy.
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            if coordinator.closeObserver == nil {
                coordinator.closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    // Delivered on `.main`; assumeIsolated satisfies strict concurrency.
                    MainActor.assumeIsolated {
                        _ = NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let targetWidth = targetWidth
        let isAuthenticated = isAuthenticated
        Task<Void, Never> { @MainActor in
            guard let window = nsView.window, let screen = NSScreen.main else { return }
            Self.reframe(window: window, screen: screen, targetWidth: targetWidth, isAuthenticated: isAuthenticated)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let obs = coordinator.closeObserver {
            NotificationCenter.default.removeObserver(obs)
            coordinator.closeObserver = nil
        }
    }

    private static func reframe(window: NSWindow, screen: NSScreen, targetWidth: CGFloat, isAuthenticated: Bool) {
        let sf  = screen.frame
        let mbh = sf.maxY - screen.visibleFrame.maxY
        let x   = (sf.midX - targetWidth / 2).rounded()
        let h   = isAuthenticated ? (sf.height - mbh).rounded() : window.frame.height
        let y   = (sf.maxY - mbh - h).rounded()
        let newFrame = CGRect(x: x, y: y, width: targetWidth, height: h)
        guard window.frame != newFrame else { return }
        window.setFrame(newFrame, display: true, animate: false)
    }
}
