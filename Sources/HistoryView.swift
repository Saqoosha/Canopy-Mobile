import SwiftUI

/// Every completion and permission ask this phone has received, across all
/// machines, newest first. The per-session view is the one people live in;
/// this one answers the other question — "what has happened anywhere" — which
/// no single session's stream can.
struct HistoryView: View {
    /// Fires when a row is tapped, with the item whose session to open. The
    /// row does not push anything itself: `CanopyMobileApp` owns the
    /// navigation path, so one type of destination is built in one place.
    let onSelect: (NotificationHistoryItem) -> Void
    /// The roster, for the names a row shows. The push itself carries only
    /// ids and a title that reads "Canopy" on every row.
    let snapshots: [String: MachineSnapshot]

    @State private var items: [NotificationHistoryItem] = []
    @State private var loadError: Error?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Could not load history", systemImage: "exclamationmark.triangle",
                                       description: Text(message(for: loadError)))
            } else if items.isEmpty {
                ContentUnavailableView("No notifications yet", systemImage: "clock",
                                       description: Text("Session updates and permission requests will appear here."))
            } else {
                List {
                    ForEach(days, id: \.self) { day in
                        Section {
                            ForEach(items.filter { Calendar.current.isDate($0.receivedAt, inSameDayAs: day) }) { item in
                                Button { onSelect(item) } label: { row(item) }
                                    .buttonStyle(.plain)
                            }
                        } header: {
                            Text(day, format: .dateTime.month(.abbreviated).day())
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: HistoryUpdateBridge.didUpdate)) { _ in
            load()
        }
    }

    private var days: [Date] {
        Array(Set(items.map { Calendar.current.startOfDay(for: $0.receivedAt) })).sorted(by: >)
    }

    private func row(_ item: NotificationHistoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == "asking" ? "hand.raised" : item.kind == "sent" ? "arrow.up.circle" : "checkmark.circle")
                .foregroundStyle(item.kind == "asking" ? Color.orange : Color.secondary)
                .frame(width: 22)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let sessionTitle = item.sessionTitle(in: snapshots) {
                    Text(sessionTitle).font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(item.listDisplayBody)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(Text(item.receivedAt, style: .time)) · \(item.machineName(in: snapshots))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let decision = item.decision {
                    Label(item.decisionDelivered == false
                          ? "Answered: \(decision) — not delivered" : "Answered: \(decision)",
                          systemImage: item.decisionDelivered == false ? "exclamationmark.triangle" : "checkmark")
                        .font(.caption)
                        .foregroundStyle(item.decisionDelivered == false ? .orange : .secondary)
                }
            }
            Spacer(minLength: 0)
            CanopyDisclosure().padding(.top, 5)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func load() {
        do {
            if CanopyDemo.isEnabled {
                items = CanopyDemo.history
            } else {
                items = try HistoryStore.loadAll()
            }
            loadError = nil
        } catch {
            loadError = error
        }
    }

    private func message(for error: Error) -> String {
        if let storeError = error as? HistoryStore.StoreError {
            switch storeError {
            case .containerUnavailable:
                return "History is unavailable — the app group container could not be reached."
            // Not reachable from this screen — `entryNotFound` is thrown by
            // `updateDecision`, and nothing here writes a decision — but
            // spelled out rather than defaulted, so a new case has to be
            // considered here too.
            case .entryNotFound(let requestId):
                return "That answer could not be recorded — no history entry for \(requestId)."
            case .partialUpdate(let written, let failed):
                return "That answer reached \(written) of \(written + failed) copies of the entry; \(failed) could not be written."
            }
        }
        return error.localizedDescription
    }
}

extension NotificationHistoryItem {
    /// The pane this notification came from, if the roster still lists it.
    /// `resumeId` first: `sessionId` is minted per Canopy process, so after a
    /// restart only `resumeId` still finds the session.
    func pane(in snapshots: [String: MachineSnapshot]) -> PaneRow? {
        guard let panes = snapshots[machine]?.panes else { return nil }
        if let resumeId, let pane = panes.first(where: { $0.resumeId == resumeId }) {
            return pane
        }
        return panes.first { $0.sessionId == sessionId }
    }

    /// The session's name from the roster. Nil once the session has closed:
    /// the push's own title is "Canopy" on every row, which names nothing.
    func sessionTitle(in snapshots: [String: MachineSnapshot]) -> String? {
        guard let title = pane(in: snapshots)?.title, !title.isEmpty else { return nil }
        return title
    }

    /// The roster's name for the machine. The raw id only when the machine is
    /// not in the roster at all.
    func machineName(in snapshots: [String: MachineSnapshot]) -> String {
        snapshots[machine]?.displayName ?? machine
    }
}
