import SwiftUI

/// The Mac's status bar, drawn under the live page: branch and context meter.
/// A port of Canopy's `StatusBarView` without its model pill and message count — the page's
/// composer already names the model, and the count is not worth the width on a phone.
/// The numbers come from the Mac, so this only draws.
struct MirrorStatusBar: View {
    let status: MirrorStatus

    var body: some View {
        // Each separator checks whether anything was drawn to its left, so an empty branch
        // never leaves a doubled or leading rule.
        let hasRemote = status.remoteHost != nil
        let hasBranch = !status.branch.isEmpty
        let hasContext = status.hasContext
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let remote = status.remoteHost {
                pill(remote, icon: "network", color: .orange)
            }
            if hasBranch {
                if hasRemote { separator }
                branchPill
            }
            if hasContext {
                if hasRemote || hasBranch { separator }
                HStack(spacing: 5) {
                    Text("\(MirrorStatus.formatTokens(status.contextUsed))/\(MirrorStatus.formatTokens(status.contextWindow))")
                        .fixedSize()
                    contextBar
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Context")
                .accessibilityValue("\(status.contextPct) percent")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }

    private var branchPill: some View {
        // The one item that can be long; it yields width before anything else does.
        pill("\(status.vcs == "jj" ? "🥋" : "🌿")\u{2009}\(status.branch)", color: .green)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(-1)
    }

    private var contextBar: some View {
        let pct = status.contextPct
        let color = tintColor
        return HStack(spacing: 5) {
            thinBar(pct: pct, color: color)
            Text("\(pct)%")
                .foregroundStyle(color)
                .fontWeight(status.contextLevel == .blocked ? .bold : .regular)
                .monospacedDigit()
                .frame(minWidth: 30, alignment: .trailing)
            // One reserved slot, always laid out, so the bar does not shift at the compact→blocked edge.
            Group {
                if status.contextLevel == .blocked {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if status.contextLevel == .unknown, pct >= 50 {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(color)
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 9))
            .frame(width: 10)
            if status.didCompact {
                Text("↻")
                    .foregroundStyle(.blue)
            }
        }
        .fixedSize()
    }

    private var tintColor: Color {
        switch status.tint {
        case .calm: .secondary
        case .warn: .orange
        case .alert: .red
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 12)
            .padding(.horizontal, 8)
    }

    private func pill(_ text: String, icon: String? = nil, color: Color) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }

    private func thinBar(pct: Int, color: Color, width: CGFloat = 40) -> some View {
        let barHeight: CGFloat = 4
        let fill = MirrorStatus.barFillWidth(pct: pct, track: width, minimum: barHeight)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: width, height: barHeight)
            if fill > 0 {
                Capsule()
                    .fill(color)
                    .frame(width: fill, height: barHeight)
            }
        }
    }
}
