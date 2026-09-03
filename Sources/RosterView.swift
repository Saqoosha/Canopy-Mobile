import SwiftUI

struct RosterView: View {
    let machineIds: [String]
    let snapshots: [String: MachineSnapshot]
    let errors: [String: Error]
    let directoryError: Error?

    var body: some View {
        // Ticks once a second so elapsed-time labels advance, and so `now`
        // is always the current moment — never a launch-time value a fresh
        // `stateSince` from a later refresh could land ahead of.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                if let directoryError {
                    Section {
                        Text(message(for: directoryError))
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Machine list")
                    }
                }
                if machineIds.isEmpty {
                    if directoryError == nil {
                        Text("No machines yet").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(sortedMachineIds, id: \.self) { id in
                        machineSection(id: id, now: context.date)
                    }
                }
            }
        }
    }

    /// Sorted by `displayName` — a Mac at 95% quota and one at 2% are
    /// different places to start work, and the header is where that shows.
    /// A machine with no snapshot yet sorts by its raw id instead.
    private var sortedMachineIds: [String] {
        machineIds.sorted { lhs, rhs in
            let lname = snapshots[lhs]?.displayName ?? lhs
            let rname = snapshots[rhs]?.displayName ?? rhs
            return lname.localizedStandardCompare(rname) == .orderedAscending
        }
    }

    /// A machine's section renders whatever snapshot it last had — even
    /// stale — AND its latest error, if any, rather than letting a failed
    /// refresh silently keep showing old rows with nothing to explain them.
    @ViewBuilder
    private func machineSection(id: String, now: Date) -> some View {
        let snapshot = snapshots[id]
        let error = errors[id]
        Section {
            if let snapshot {
                ForEach(snapshot.panes) { pane in
                    paneRow(pane, now: now)
                }
            } else if error == nil {
                Text("Loading…").foregroundStyle(.secondary)
            }
            if let error {
                Text(message(for: error))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(headerText(id: id, snapshot: snapshot))
        }
    }

    private func headerText(id: String, snapshot: MachineSnapshot?) -> String {
        guard let snapshot else { return id }
        return "\(snapshot.displayName) — 5h \(snapshot.sessionPct)% · wk \(snapshot.weeklyPct)%"
    }

    private func paneRow(_ pane: PaneRow, now: Date) -> some View {
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
            Text(elapsed(since: pane.stateSince, now: now))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Never renders the secret itself, even on the unauthorized branch —
    /// `RosterError.message` already keeps that promise; this only extends
    /// it to non-`RosterError` failures (transport, decode-of-directory).
    private func message(for error: Error) -> String {
        if let rosterError = error as? RosterError {
            return rosterError.message
        }
        return error.localizedDescription
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
