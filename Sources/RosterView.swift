import SwiftUI

struct RosterView: View {
    let snapshot: MachineSnapshot?
    let now: Date

    var body: some View {
        List {
            if let snapshot {
                Section {
                    ForEach(snapshot.panes) { pane in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(color(for: pane.state))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pane.title).font(.body)
                                Text(pane.project).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(elapsed(since: pane.stateSince))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(snapshot.displayName) — 5h \(snapshot.sessionPct)% · wk \(snapshot.weeklyPct)%")
                }
            } else {
                Text("No roster yet").foregroundStyle(.secondary)
            }
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "working": return .cyan
        case "background": return .purple
        case "asking": return .orange
        case "unread": return .green
        case "error": return .red
        default: return .gray
        }
    }

    /// Time in state. "40m asking" and "asking" mean entirely different
    /// things, which is why the snapshot carries a stamp rather than a flag.
    private func elapsed(since unix: Int) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970) - unix)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
