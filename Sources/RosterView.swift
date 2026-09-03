import SwiftUI

struct RosterView: View {
    let snapshot: MachineSnapshot?
    let error: Error?

    var body: some View {
        // Ticks once a second so elapsed-time labels advance, and so `now`
        // is always the current moment — never a launch-time value a fresh
        // `stateSince` from a later refresh could land ahead of.
        TimelineView(.periodic(from: .now, by: 1)) { context in
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
                                Text(elapsed(since: pane.stateSince, now: context.date))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("\(snapshot.displayName) — 5h \(snapshot.sessionPct)% · wk \(snapshot.weeklyPct)%")
                    }
                } else {
                    Text(emptyMessage).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "No roster yet" collapsed unauthorized, not-found, transport failure
    /// and decode mismatch into one message. This names which one it was —
    /// never the secret itself, even on the unauthorized branch.
    private var emptyMessage: String {
        guard let error else { return "No roster yet" }
        if let rosterError = error as? RosterError {
            return rosterError.message
        }
        return "No roster yet — \(error.localizedDescription)"
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
    /// `max(0, …)` stays for genuine clock skew between a Mac and a phone —
    /// `now` here is always the current tick, never a stale launch-time value.
    private func elapsed(since unix: Int, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970) - unix)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
