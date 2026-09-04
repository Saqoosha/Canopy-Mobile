import SwiftUI

/// The full record behind one `HistoryView` row: the whole body (never
/// truncated — that's the content the user came here for), which machine
/// and session it belongs to, and — for a still-unanswered permission ask —
/// Allow/Deny.
struct HistoryDetailView: View {
    let item: NotificationHistoryItem
    /// Wired by `CanopyMobileApp` to `sendDecision(item:decision:)`, which
    /// calls `RosterClient.sendDecision` — the same method the lock-screen
    /// and Apple Watch Allow/Deny action calls in `PushRegistrar`, so this
    /// button and that action can't answer the same ask two different ways.
    var onDecision: (NotificationHistoryItem, String) -> Void = { _, _ in }
    /// See `HistoryView.onReply` — Reply does NOT present its own sheet.
    /// `CanopyMobileApp` owns the single `replyTarget`/`.sheet(item:)` that
    /// every reply path (roster tap, notification tap, this button) shares,
    /// so a notification-tap-driven sheet and a history-driven one can
    /// never become two competing `.sheet` presentations at once.
    let onReply: (NotificationHistoryItem) -> Void

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
                Button("Reply") { onReply(item) }
            }
        }
        .navigationTitle("Notification")
        .navigationBarTitleDisplayMode(.inline)
    }
}
