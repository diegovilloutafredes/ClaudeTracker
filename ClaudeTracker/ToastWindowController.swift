import AppKit
import SwiftUI

/// Displays floating toast notifications stacked near the top-right corner of the screen.
///
/// Each call to `show()` appends a new `NSPanel` below any already-visible toasts.
/// When a toast is dismissed (by timer or by the user tapping the close button), it fades
/// out; remaining toasts then slide up to fill the gap.
///
/// Using `NSPanel` with `[.borderless, .nonactivatingPanel]` prevents the notification
/// from stealing keyboard focus or appearing in the application switcher.
///
/// Exact positioning at the menu bar icon is not possible through the `MenuBarExtra` API —
/// panels are placed at a fixed offset from the screen's top-right corner instead.
@MainActor
final class ToastWindowController {
    static let shared = ToastWindowController()

    private struct Entry {
        let id: UUID
        let panel: NSPanel
        var dismissTask: Task<Void, Never>?
    }

    private var entries: [Entry] = []
    private let toastWidth: CGFloat  = 300
    private let toastHeight: CGFloat = 76
    private let gap: CGFloat         = 8

    /// Presents a new toast below any currently visible ones.
    ///
    /// - Parameters:
    ///   - title: Bold headline text.
    ///   - message: Supporting detail shown below the title.
    ///   - icon: SF Symbol name for the leading icon. Defaults to `checkmark.circle.fill`.
    ///   - iconColor: Color applied to the icon. Defaults to `.green`.
    ///   - duration: Total visible time in seconds before the toast fades out. Ignored when `permanent` is `true`.
    ///   - permanent: When `true`, the toast stays on screen until the user taps the close button.
    @discardableResult
    func show(title: String, message: String, icon: String = "checkmark.circle.fill", iconColor: Color = .green, duration: Double, permanent: Bool) -> UUID {
        let id = UUID()
        let panel = makePanel()

        let view = ToastView(title: title, message: message, icon: icon, iconColor: iconColor, onDismiss: { [weak self] in
            self?.dismiss(id: id)
        })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight)
        panel.contentView = hosting
        panel.setFrame(frameForIndex(entries.count), display: false)
        panel.alphaValue = 0
        panel.orderFront(nil)

        entries.append(Entry(id: id, panel: panel))

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }

        guard !permanent else { return id }

        let fadeDuration = 0.3
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, duration - fadeDuration)))
            guard !Task.isCancelled else { return }
            self?.fadeAndClose(id: id, over: fadeDuration)
        }
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].dismissTask = task
        }
        return id
    }

    func dismiss(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].dismissTask?.cancel()
        fadeAndClose(id: id, over: 0.2)
    }

    private func fadeAndClose(id: UUID, over fadeDuration: Double) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let panel = entries[idx].panel
        // Remove immediately so duplicate fade calls are no-ops.
        entries.remove(at: idx)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // AppKit invokes the completion on the main thread; assumeIsolated makes
            // that visible to strict concurrency.
            MainActor.assumeIsolated {
                panel.close()
            }
            // Shift remaining toasts up after the dismissed one disappears.
            Task { @MainActor [weak self] in
                self?.shiftAllToCorrectPositions()
            }
        })
    }

    private func shiftAllToCorrectPositions() {
        for i in entries.indices {
            let target = frameForIndex(i)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                entries[i].panel.animator().setFrame(target, display: true)
            }
        }
    }

    private func frameForIndex(_ index: Int) -> NSRect {
        let menuBarH   = NSStatusBar.system.thickness
        let screenFrame = NSScreen.main?.frame ?? .zero
        let x = screenFrame.maxX - toastWidth - 24
        let y = screenFrame.maxY - menuBarH - toastHeight - 6 - CGFloat(index) * (toastHeight + gap)
        return NSRect(x: x, y: y, width: toastWidth, height: toastHeight)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Same double-free hazard as the login/OAuth windows: close() would autorelease
        // the panel while ARC also releases it, crashing in a later CA transaction flush.
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        return panel
    }
}

private struct ToastView: View {
    let title: String
    let message: String
    let icon: String
    let iconColor: Color
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(4)
    }
}
