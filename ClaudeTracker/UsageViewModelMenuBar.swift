import AppKit

// MARK: - Menu Bar Image

/// Composed `NSImage` shown as the menu bar label. Extracted from `UsageViewModel.swift`
/// to keep the main view-model file under the SwiftLint length limits — this is purely
/// AppKit drawing code with no view-model logic of its own.
extension UsageViewModel {
    private var menuBarPaceText: String? {
        guard showPaceMenuBar, isAuthenticated, usage != nil, !isDataStale else { return nil }
        guard displayedUtilization < 100 else { return nil }
        let key: String
        switch menuBarWindow {
        case .fiveHour: key = "five_hour"
        case .sevenDay:  key = "seven_day"
        }
        guard let paceData = pace(for: key) else { return nil }
        return paceRateUnit.format(paceData.rate, prefix: true, short: true)
    }

    private var menuBarPaceColor: NSColor {
        urgencyNSColor(displayedWindowPaceUrgency())
    }

    var menuBarImage: NSImage {
        // Observed read: invalidateMenuBarImage() bumps this to force a label redraw
        // (the caches themselves are @ObservationIgnored — a view body must not write
        // observed state).
        _ = menuBarImageVersion
        let icon = statusIcon
        let text = statusText
        let color = statusColor
        let paceText = menuBarPaceText
        let paceColor = menuBarPaceColor
        let appearance = NSApp.effectiveAppearance.name.rawValue
        let paceKey = paceText.map { $0 + paceColor.description } ?? ""
        let key = icon + text + color.description + paceKey + appearance
        if key == cachedMenuBarKey { return cachedMenuBarImage }
        cachedMenuBarKey = key
        cachedMenuBarImage = buildMenuBarImage(iconName: icon, text: text, color: color, paceText: paceText, paceColor: paceColor)
        return cachedMenuBarImage
    }

    private func buildMenuBarImage(iconName: String, text: String, color: NSColor, paceText: String? = nil, paceColor: NSColor = .labelColor) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color, .labelColor]))
        let symbolImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage()
        let symbolSize = symbolImage.size
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let paceAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: paceColor]
        let paceSize = paceText.map { ($0 as NSString).size(withAttributes: paceAttrs) } ?? .zero
        let spacing: CGFloat = 3
        let paceSpacing: CGFloat = paceText != nil ? 4 : 0
        let totalWidth = symbolSize.width + spacing + textSize.width + paceSpacing + paceSize.width
        let height = max(symbolSize.height, textSize.height)
        let composed = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            let iconY = (rect.height - symbolSize.height) / 2
            symbolImage.draw(in: NSRect(x: 0, y: iconY, width: symbolSize.width, height: symbolSize.height))
            let textY = (rect.height - textSize.height) / 2
            (text as NSString).draw(at: NSPoint(x: symbolSize.width + spacing, y: textY), withAttributes: attrs)
            if let paceText {
                let paceX = symbolSize.width + spacing + textSize.width + paceSpacing
                let paceY = (rect.height - paceSize.height) / 2
                (paceText as NSString).draw(at: NSPoint(x: paceX, y: paceY), withAttributes: paceAttrs)
            }
            return true
        }
        return composed
    }
}
