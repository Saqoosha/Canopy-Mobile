import SwiftUI

struct RosterView: View {
    let machineIds: [String]
    let snapshots: [String: MachineSnapshot]
    let errors: [String: Error]
    let directoryError: Error?
    /// Tapping a row asks to reply to it. Threaded in from `CanopyMobileApp`
    /// rather than owned here — the reply sheet's presentation state lives
    /// at the app level so a notification tap can drive the same sheet.
    var onSelectPane: (String, PaneRow) -> Void = { _, _ in }

    var body: some View {
        // Ticks once a second so elapsed-time labels advance, and so `now`
        // is always the current moment — never a launch-time value a fresh
        // `stateSince` from a later refresh could land ahead of.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                if let accountQuotaText {
                    Text(accountQuotaText)
                        .font(.subheadline.weight(.semibold))
                }
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

    /// Rate limits are per-account, not per-Mac (`SharedRateLimitData`'s own
    /// doc comment on the Canopy side) — two Macs signed into the same
    /// account report identical figures, so showing it under every
    /// machine's header only doubled the number and let a stale Mac's
    /// event make it look like the two disagreed. Shown once here, taken
    /// from the freshest loaded snapshot (`accountQuotaText`) so a Mac that
    /// hasn't reported in a while can't supply it.
    private var accountQuotaText: String? {
        guard let newest = snapshots.values.max(by: { $0.publishedAt < $1.publishedAt }) else { return nil }
        return "5h \(newest.sessionPct)% · wk \(newest.weeklyPct)%"
    }

    /// Sorted by `displayName` so the list doesn't reorder itself as each
    /// header's elapsed-time text ticks. A machine with no snapshot yet
    /// sorts by its raw id instead.
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
                    paneRow(pane, machineId: id, now: now)
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
            Text(headerText(id: id, snapshot: snapshot, now: now))
        }
        // Canopy publishes on every state change, so silence past the
        // threshold means the Mac went to sleep or is gone — not that
        // nothing happened. Greyed out so a shut-down Mac can't be
        // mistaken for one that's merely idle.
        .opacity(isStale(snapshot: snapshot, now: now) ? 0.35 : 1)
    }

    private func headerText(id: String, snapshot: MachineSnapshot?, now: Date) -> String {
        guard let snapshot else { return id }
        return "\(snapshot.displayName) — \(elapsed(since: snapshot.publishedAt, now: now)) ago"
    }

    /// A Mac is presumed asleep or gone once its last publish is older than
    /// this. Canopy republishes on every pane state change, so five minutes
    /// of silence is not a quiet Mac — it is one that stopped publishing.
    private static let staleThreshold: TimeInterval = 5 * 60

    private func isStale(snapshot: MachineSnapshot?, now: Date) -> Bool {
        guard let snapshot else { return false }
        return TimeInterval(now.timeIntervalSince1970 - Double(snapshot.publishedAt)) >= Self.staleThreshold
    }

    private func paneRow(_ pane: PaneRow, machineId: String, now: Date) -> some View {
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
        .contentShape(Rectangle())
        .onTapGesture { onSelectPane(machineId, pane) }
    }

    /// Never renders the secret itself, even on the unauthorized branch —
    /// `RosterError.message` already keeps that promise; this only extends
    /// it to non-`RosterError` failures (transport, decode-of-directory).
    private func message(for error: Error) -> String {
        if let rosterError = error as? RosterError {
            return rosterError.message
        }
        if let socketError = error as? RosterSocketError {
            return socketError.message
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
