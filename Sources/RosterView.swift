import SwiftUI

struct RosterView: View {
    let machineIds: [String]
    let snapshots: [String: MachineSnapshot]
    let errors: [String: Error]
    let directoryError: Error?
    var onSelectPane: (String, PaneRow) -> Void = { _, _ in }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                if !machineIds.isEmpty {
                    let asking = attentionPanes(now: context.date)
                    if !asking.isEmpty {
                        Section {
                            Button {
                                if let first = asking.first { onSelectPane(first.machine, first.pane) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "hand.raised.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Needs your attention")
                                            .font(.body.weight(.medium))
                                        Text("\(asking.count) session\(asking.count == 1 ? "" : "s") waiting for you")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    CanopyDisclosure()
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let directoryError {
                    Section("Machine list") {
                        Label(message(for: directoryError), systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                if machineIds.isEmpty && directoryError == nil {
                    ContentUnavailableView("No machines yet", systemImage: "desktopcomputer",
                                           description: Text("Your Macs will appear here when they connect to Canopy."))
                        .listRowBackground(Color.clear)
                }
                ForEach(sortedMachineIds, id: \.self) { id in
                    machineSection(id: id, now: context.date)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            // Breathing room under the large title. The summary line that
            // used to sit here was doing this job by accident; without it the
            // first card butted against the title.
            .contentMargins(.top, 12, for: .scrollContent)
        }
    }

    private var sortedMachineIds: [String] {
        machineIds.sorted {
            (snapshots[$0]?.displayName ?? $0).localizedStandardCompare(snapshots[$1]?.displayName ?? $1) == .orderedAscending
        }
    }

    private func attentionPanes(now: Date) -> [(machine: String, pane: PaneRow)] {
        sortedMachineIds.flatMap { id -> [(machine: String, pane: PaneRow)] in
            guard let snapshot = snapshots[id], errors[id] == nil,
                  !isStale(snapshot: snapshot, now: now) else { return [] }
            return snapshot.panes.filter { $0.state == "asking" }.map { (id, $0) }
        }
    }

    private func machineSection(id: String, now: Date) -> some View {
        let snapshot = snapshots[id]
        let stale = isStale(snapshot: snapshot, now: now)
        return Section {
            if let snapshot {
                if snapshot.panes.isEmpty {
                    Text("No sessions").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(snapshot.panes) { pane in
                    paneRow(pane, machineId: id, now: now)
                        .opacity(stale ? 0.5 : 1)
                }
                // Quota belongs to the reporting Mac, which may use a different account.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { quotaMeters(snapshot) }
                    VStack(spacing: 12) { quotaMeters(snapshot) }
                }
                .padding(.vertical, 5)
                .opacity(stale ? 0.5 : 1)
            } else if errors[id] == nil {
                ProgressView("Loading…")
            }
            if let error = errors[id] {
                Label(message(for: error), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(snapshot?.displayName ?? id)
                    Spacer(minLength: 8)
                    updateLabel(snapshot, stale: stale, now: now)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot?.displayName ?? id)
                    updateLabel(snapshot, stale: stale, now: now)
                }
            }
            .textCase(nil)
        }
    }

    @ViewBuilder private func updateLabel(_ snapshot: MachineSnapshot?, stale: Bool, now: Date) -> some View {
        if let snapshot {
            Text("\(stale ? "Offline · " : "Updated ")\(SessionActivityStyle.published(since: snapshot.publishedAt, now: now))")
                .font(.caption2)
        }
    }

    @ViewBuilder private func quotaMeters(_ snapshot: MachineSnapshot) -> some View {
        CanopyUsageMeter(title: "5h usage", percentage: snapshot.sessionPct)
        CanopyUsageMeter(title: "Weekly usage", percentage: snapshot.weeklyPct)
    }

    private static let staleThreshold: TimeInterval = 5 * 60

    private func isStale(snapshot: MachineSnapshot?, now: Date) -> Bool {
        guard let snapshot else { return false }
        return now.timeIntervalSince1970 - Double(snapshot.publishedAt) >= Self.staleThreshold
    }

    private func paneRow(_ pane: PaneRow, machineId: String, now: Date) -> some View {
        Button { onSelectPane(machineId, pane) } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(SessionActivityStyle.color(for: pane.state))
                    .frame(width: 7, height: 7)
                    .padding(.top, 7)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pane.title).font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    (Text("\(pane.project) · ").foregroundStyle(.secondary)
                     + Text(pane.state.capitalized).foregroundStyle(SessionActivityStyle.color(for: pane.state)))
                        .font(.caption)
                }
                Spacer(minLength: 4)
                Text(SessionActivityStyle.elapsed(since: pane.stateSince, now: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.top, 3)
                CanopyDisclosure().padding(.top, 5)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func message(for error: Error) -> String {
        if let error = error as? RosterError { return error.message }
        if let error = error as? RosterSocketError { return error.message }
        return error.localizedDescription
    }
}
