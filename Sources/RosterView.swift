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

    /// Quota belongs to the Mac that reported it, not to the roster.
    ///
    /// This used to be one line at the top of the list, on the argument that
    /// rate limits are per-ACCOUNT and two Macs would only print the same
    /// number twice. **That premise is false for more than one account** —
    /// with an mbp and a Studio signed in as different users, the single line
    /// showed whichever Mac published most recently, so it flipped between
    /// two unrelated quotas with nothing on screen saying which one it was.
    /// Two Macs on one account do print the same figure twice, which is
    /// merely redundant; the old shape was wrong.
    private func quotaText(_ snapshot: MachineSnapshot?) -> String? {
        guard let snapshot else { return nil }
        return "5h \(snapshot.sessionPct)% · wk \(snapshot.weeklyPct)%"
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
        let head = "\(snapshot.displayName) — \(elapsed(since: snapshot.publishedAt, now: now)) ago"
        guard let quota = quotaText(snapshot) else { return head }
        return "\(head)  ·  \(quota)"
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

    /// The exact values `SessionActivity.dotRGB` uses on the Mac, copied
    /// rather than approximated with SwiftUI's stock `.cyan` / `.purple`.
    /// A dot means the same thing on both screens, so it has to look the
    /// same: those constants were tuned against the MacroPad's LEDs (see
    /// Canopy's "Key Learnings (MacroPad)"), and `.cyan` is far brighter
    /// than the working teal while `.purple` is magenta-ward of the
    /// background blue-violet. Same origin, same drift risk as every other
    /// copied file here — diff against `SessionActivity.swift` when either
    /// side is retuned.
    private func color(for state: String) -> Color {
        switch state {
        case "working": return Color(red: 0.00, green: 0.62, blue: 0.72)
        case "background": return Color(red: 0.30, green: 0.24, blue: 0.90)
        case "asking": return Color(red: 0.98, green: 0.52, blue: 0.11)
        case "unread": return Color(red: 0.20, green: 0.66, blue: 0.13)
        case "error": return Color(red: 0.88, green: 0.24, blue: 0.22)
        default: return Color(red: 0.62, green: 0.62, blue: 0.62)
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
