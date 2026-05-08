import SwiftUI

/// Application entry point.
///
/// The app runs as a menu bar extra with no Dock icon (`LSUIElement` in Info.plist).
/// `MenuBarExtra` uses `.window` style so the popover is a proper borderless window
/// rather than a native menu — required for SwiftUI interactive controls to work correctly inside it.
@main
struct ClaudeTrackerApp: App {
    @State private var viewModel: UsageViewModel

    init() {
        // Must run before UsageViewModel reads any UserDefaults. Imports legacy
        // per-account data from the sandbox container path on first launch
        // after the App Sandbox entitlement was removed.
        SandboxMigration.runIfNeeded()
        _viewModel = State(initialValue: UsageViewModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            Image(nsImage: viewModel.menuBarImage)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)
    }
}
