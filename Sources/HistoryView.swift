import SwiftUI

/// The notification history list — every completion and permission ask this
/// phone has received, newest first. Exists so the reply sheet has
/// something to show as context instead of just a session title (see
/// `ReplySheet.context`).
struct HistoryView: View {
    /// Wired by `CanopyMobileApp` to `sendDecision(item:decision:)`. Passed
    /// through to `HistoryDetailView` unchanged.
    var onDecision: (NotificationHistoryItem, String) -> Void = { _, _ in }
    /// Fires when the user taps Reply in `HistoryDetailView`. Passed through
    /// unchanged so `CanopyMobileApp` can populate its single shared
    /// `replyTarget` — routing every reply through one `.sheet(item:)`
    /// instead of each view presenting its own is what keeps a
    /// notification-tap-driven reply and a history-driven reply from ever
    /// racing as two competing sheet presentations.
    let onReply: (NotificationHistoryItem) -> Void

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
                        HistoryDetailView(item: item, onDecision: onDecision, onReply: onReply)
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
