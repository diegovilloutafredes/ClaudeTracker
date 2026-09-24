import SwiftUI

/// Application entry point.
///
/// The app runs as a menu bar extra with no Dock icon (`LSUIElement` in Info.plist).
/// `MenuBarExtra` uses `.window` style so the popover is a proper borderless window
/// rather than a native menu — required for SwiftUI interactive controls to work correctly inside it.
@main
struct ClaudeTrackerApp: App {
    @State private var viewModel: UsageViewModel

    /// True when this process was launched as the host of the unit tests. The test host is
    /// this app itself (same bundle id, same preferences), so live startup must not run
    /// there: no polling with the user's sessions, no migration, no login-item changes.
    /// `nonisolated`: it only reads the process environment, which needs no actor.
    nonisolated static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        let isTestHost = Self.isRunningUnitTests
        // Must run before UsageViewModel reads any UserDefaults. Imports legacy
        // per-account data from the sandbox container path on first launch
        // after the App Sandbox entitlement was removed.
        if !isTestHost { SandboxMigration.runIfNeeded() }
        let viewModel = UsageViewModel()
        if !isTestHost { viewModel.start() }
        _viewModel = State(initialValue: viewModel)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            Image(nsImage: viewModel.menuBarImage)
                .accessibilityLabel(Text(viewModel.menuBarAccessibilityLabel))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }
}
