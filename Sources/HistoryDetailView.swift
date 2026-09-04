import SwiftUI

/// The full record behind one `HistoryView` row: the whole body (never
/// truncated — that's the content the user came here for), which machine
/// and session it belongs to, and — for a still-unanswered permission ask —
/// Allow/Deny.
struct HistoryDetailView: View {
    let item: NotificationHistoryItem
    /// See `HistoryView.onDecision` — inert until the decision route exists.
    var onDecision: (NotificationHistoryItem, String) -> Void = { _, _ in }
    let sendReply: (String, String, String) async throws -> Void

    @State private var showingReply = false

    /// Allow/Deny only make sense for a permission ask nobody has answered
    /// yet. An already-decided one, or an ordinary completion, gets no
    /// buttons at all rather than disabled ones.
    private var isUnansweredAsk: Bool {
        item.kind == "asking" && item.decision == nil
    }

    var body: some View {
        Form {
            Section {
                Text(NotificationHistoryItem.displayableBody(item.body))
            } header: {
                Text(item.title)
            }
            Section("Session") {
                LabeledContent("Machine", value: item.machine)
                LabeledContent("Session", value: item.sessionId)
                if let decision = item.decision {
                    LabeledContent("Decision", value: decision)
                }
            }
            if isUnansweredAsk {
                Section {
                    HStack {
                        Button("Allow") { onDecision(item, "allow") }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Deny", role: .destructive) { onDecision(item, "deny") }
                            .buttonStyle(.bordered)
                    }
                }
            }
            Section {
                Button("Reply") { showingReply = true }
            }
        }
        .navigationTitle("Notification")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReply) {
            ReplySheet(
                machine: item.machine,
                sessionId: item.sessionId,
                sessionTitle: item.title,
                context: NotificationHistoryItem.displayableBody(item.body)
            ) { text in
                try await sendReply(item.machine, item.sessionId, text)
            }
        }
    }
}
