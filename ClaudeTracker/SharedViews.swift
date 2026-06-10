import SwiftUI

// MARK: - Subscription Badge

/// Purple capsule showing the subscription tier (e.g. "Max 5×"). Used in the popover
/// header, the multi-account picker label, and the Settings account rows.
struct SubscriptionBadge: View {
    let label: String
    var scale: CGFloat = 1

    var body: some View {
        Text(label)
            .font(.system(size: 10 * scale, weight: .semibold))
            .padding(.horizontal, 6 * scale)
            .padding(.vertical, 2 * scale)
            .background(Color.purple.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.purple)
    }
}

// MARK: - Scaled Segmented Picker

/// The popover's capsule-row segmented control, scaled by the popup-size preference.
/// Backs both the Usage/Charts tab selector and the chart time-range picker.
struct ScaledSegmentedPicker<T: Hashable, Label: View>: View {
    @Binding var selection: T
    let options: [T]
    let scale: CGFloat
    @ViewBuilder let label: (T) -> Label

    var body: some View {
        HStack(spacing: 1 * scale) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    label(option)
                        .font(.system(size: 11 * scale,
                                      weight: selection == option ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4 * scale)
                        .background(
                            selection == option ? Color.primary.opacity(0.1) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5 * scale)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2 * scale)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7 * scale))
        .frame(maxWidth: .infinity)
    }
}
