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

    @State private var items: [NotificationHistoryItem] = []
    @State private var loadError: Error?

    var body: some View {
        Group {
            if let loadError {
                Text(message(for: loadError))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text("No notifications yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    Button { onSelect(item) } label: {
                        row(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: HistoryUpdateBridge.didUpdate)) { _ in
            load()
        }
    }

    private func row(_ item: NotificationHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title).font(.body)
                Spacer()
                Text(item.receivedAt, style: .relative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(item.listDisplayBody)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let decision = item.decision {
                Text(item.decisionDelivered == false
                     ? "Answered: \(decision) — not delivered"
                     : "Answered: \(decision)")
                    .font(.caption2)
                    .foregroundStyle(item.decisionDelivered == false ? .orange : .secondary)
            }
        }
    }

    private func load() {
        do {
            items = try CanopyDemo.isEnabled ? CanopyDemo.history : HistoryStore.loadAll()
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
            }
        }
        return error.localizedDescription
    }
}
