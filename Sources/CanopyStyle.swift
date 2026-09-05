import SwiftUI

/// Small shared details; navigation, list geometry and colors stay system-owned.
struct CanopyDisclosure: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

struct CanopyUsageMeter: View {
    let title: String
    let percentage: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text("\(percentage)%").monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            ProgressView(value: Double(min(100, max(0, percentage))), total: 100)
                .tint(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(percentage) percent")
    }
}
