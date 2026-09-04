import SwiftUI

/// The notification history list — every completion and permission ask this
/// phone has received, newest first. Exists so the reply sheet has
/// something to show as context instead of just a session title (see
/// `ReplySheet.context`).
struct HistoryView: View {
    /// Wired to a no-op by the caller for now — the route that carries a
    /// decision back to the Mac doesn't exist yet. Passed through to
    /// `HistoryDetailView` unchanged.
    var onDecision: (NotificationHistoryItem, String) -> Void = { _, _ in }
    /// Curried `(machine, sessionId, text)` — shared with the roster-driven
    /// reply flow in `CanopyMobileApp` rather than each view owning its own
    /// `RosterClient`.
    let sendReply: (String, String, String) async throws -> Void

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
                    NavigationLink {
                        HistoryDetailView(item: item, onDecision: onDecision, sendReply: sendReply)
                    } label: {
                        row(item)
                    }
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
                Text("Answered: \(decision)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() {
        do {
            items = try HistoryStore.loadAll()
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
