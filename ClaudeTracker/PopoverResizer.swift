import SwiftUI

/// Forces the MenuBarExtra NSPanel to match the SwiftUI content height whenever it changes,
/// and keeps the panel pinned to its first observed `(x, top-y)` across moves AND resizes.
///
/// AppKit silently re-anchors the menu bar popover to the status item's frame whenever the
/// status item's image width changes. The image width changes constantly here — utilization
/// digits go from "5%" to "100%", the pace badge appears/disappears, and account switches
/// can trigger several rapid updates. Each anchor change drags the popover sideways even
/// though the user hasn't done anything to warrant it.
///
/// Two observers keep the panel still, both snapping synchronously inside the notification:
/// - `didMoveNotification` — AppKit dragged the panel (status-item re-anchor).
/// - `didResizeNotification` — SwiftUI auto-sized the panel for new content (e.g. switching
///   the Usage/Charts tab). NSWindow frames are bottom-left anchored, so a size-only change
///   keeps `origin.y` and visibly moves the *top* edge — and it does NOT post
///   `didMoveNotification`, so without this observer the top correction would wait for the
///   next deferred `updateNSView` pass, rendering a visible jump-then-snap ("shake").
struct PopoverResizer: NSViewRepresentable {
    let height: CGFloat

    @MainActor final class Coordinator {
        var pinnedX: CGFloat?
        var pinnedTop: CGFloat?
        var moveObserver: NSObjectProtocol?
        var resizeObserver: NSObjectProtocol?
        /// Reentrancy guard: our own `setFrame` triggers move/resize notifications, which
        /// would recurse into the snap-back path and cause an infinite ping-pong.
        var isSnapping = false

        /// Re-pins the panel's top-left to the captured anchor, preserving the window's
        /// current height (the height itself is owned by SwiftUI layout + `updateNSView`).
        func snapToPin(_ window: NSWindow) {
            guard !isSnapping, let pinX = pinnedX, let pinTop = pinnedTop else { return }
            let dx = abs(window.frame.origin.x - pinX)
            let dyTop = abs(window.frame.maxY - pinTop)
            guard dx > 0.5 || dyTop > 0.5 else { return }
            isSnapping = true
            var snap = window.frame
            snap.origin.x = pinX
            snap.origin.y = pinTop - snap.height
            window.setFrame(snap, display: true, animate: false)
            isSnapping = false
        }

        func removeObservers() {
            if let obs = moveObserver {
                NotificationCenter.default.removeObserver(obs)
                moveObserver = nil
            }
            if let obs = resizeObserver {
                NotificationCenter.default.removeObserver(obs)
                resizeObserver = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeObservers()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard height > 10 else { return }
        let coordinator = context.coordinator
        let height = height
        Task<Void, Never> { @MainActor in
            guard let window = nsView.window else { return }

            // Capture the panel's natural anchor on first appearance.
            if coordinator.pinnedX == nil {
                coordinator.pinnedX = window.frame.origin.x
                coordinator.pinnedTop = window.frame.maxY
            }

            // Install the observers once. They snap the window back any time AppKit
            // drags it (status-item re-anchor) or resizes it bottom-anchored (SwiftUI
            // auto-sizing for new content). Both run synchronously inside the
            // notification so the wrong position is never rendered.
            if coordinator.moveObserver == nil {
                let coord = coordinator
                coordinator.moveObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { [weak window] _ in
                    // Delivered on `.main` (the observer's queue); assumeIsolated makes
                    // that visible to strict concurrency without a redundant hop.
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        coord.snapToPin(window)
                    }
                }
                coordinator.resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        coord.snapToPin(window)
                    }
                }
            }

            guard let pinX = coordinator.pinnedX,
                  let pinTop = coordinator.pinnedTop else { return }
            let needsResize = abs(window.frame.height - height) > 1
            let needsReposition = abs(window.frame.origin.x - pinX) > 1 || abs(window.frame.maxY - pinTop) > 1
            guard needsResize || needsReposition else { return }
            coordinator.isSnapping = true
            let newFrame = CGRect(x: pinX, y: pinTop - height, width: window.frame.width, height: height)
            window.setFrame(newFrame, display: true, animate: false)
            coordinator.isSnapping = false
        }
    }
}
