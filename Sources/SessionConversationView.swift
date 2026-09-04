import MarkdownUI
import SwiftUI

/// One session, as a conversation: everything that session has notified about,
/// oldest at the top, with a composer pinned at the bottom.
///
/// This is the app's single destination. A roster row, a History row and a
/// notification tap all land here, so there is one place that answers "what is
/// this session doing and what do I want to say about it" — and, since an
/// unanswered permission ask renders its Allow/Deny inline in the stream, one
/// place that can answer it too.
///
/// **The transcript is deliberately not here.** The rows are the session's
/// notifications, and a completion notification carries the assistant's own
/// final message, so a session's stream already reads as a sparse
/// conversation. Fetching the real JSONL would need a new transport, a paging
/// contract and a size policy; it was scoped out because recent notifications
/// were measured to be enough for the thing this app is for — deciding what to
/// do next from a phone.
struct SessionConversationView: View {
    let machine: String
    let sessionId: String
    let title: String
    /// Second header line — the machine, or "machine · project" when the
    /// roster knew a project for this pane. Never the body of anything.
    let subtitle: String
    let onDecision: (NotificationHistoryItem, String) -> Void
    let onSend: (String) async throws -> Void

    @State private var items: [NotificationHistoryItem] = []
    @State private var loadError: Error?
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @FocusState private var composerFocused: Bool

    /// Anchor for the scroll-to-bottom that runs on open and after every
    /// append. A fixed id on an empty view beats scrolling to the last item:
    /// the last item can be tall enough that `.bottom` anchoring on it still
    /// leaves the composer covering text.
    private let bottomAnchor = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let loadError {
                            Label("Could not read the history: \(loadError.localizedDescription)",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        } else if items.isEmpty {
                            Text("Nothing from this session yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if shouldShowDaySeparator(at: index) {
                                DaySeparator(date: item.receivedAt)
                            }
                            MessageBlock(item: item, onDecision: onDecision)
                        }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                .onAppear {
                    load()
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                // The Notification Service Extension appends while the app is
                // open, so a push arriving on this screen has to land in it —
                // that is the case this whole view exists for.
                .onReceive(NotificationCenter.default.publisher(for: HistoryUpdateBridge.didUpdate)) { _ in
                    load()
                    withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                }
                .onChange(of: composerFocused) { _, focused in
                    if focused { withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) } }
                }
            }
            composer
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let sendError {
                Text(sendError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Reply to this session…", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .textFieldStyle(.plain)
                    .focused($composerFocused)
                Button {
                    Task { await send() }
                } label: {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                // Whitespace-only is not a reply: it would inject a blank user
                // turn into a real conversation, which the relay also refuses.
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        sendError = nil
        do {
            try await onSend(text)
            // Cleared only on success, so a failed send leaves the text where
            // the user can retry it rather than making them retype it.
            draft = ""
        } catch {
            sendError = "Could not send: \(error.localizedDescription)"
        }
        sending = false
    }

    private func load() {
        do {
            // `loadAll()` is newest-first; a conversation reads oldest-first.
            loadError = nil
            items = try HistoryStore.loadAll()
                .filter { $0.machine == machine && $0.sessionId == sessionId }
                .reversed()
        } catch {
            // Surfaced, never swallowed: an unreadable store looks exactly
            // like a session that has never notified, which is the one thing
            // this screen must not claim falsely.
            loadError = error
            items = []
        }
    }

    private func shouldShowDaySeparator(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(items[index].receivedAt,
                                        inSameDayAs: items[index - 1].receivedAt)
    }
}

/// One notification in the stream. A permission ask nobody has answered gets
/// Allow/Deny right here rather than behind another tap — the whole point of
/// the push was that the session is blocked.
private struct MessageBlock: View {
    let item: NotificationHistoryItem
    let onDecision: (NotificationHistoryItem, String) -> Void

    private var isUnansweredAsk: Bool {
        item.kind == "asking" && item.decision == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: item.kind == "asking" ? "hand.raised.fill" : "checkmark.circle")
                    .font(.caption2)
                Text(item.title)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(item.receivedAt, style: .time)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)

            Markdown(NotificationHistoryItem.displayableBody(item.body))
                .markdownTextStyle(\.code) {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.92))
                }

            if isUnansweredAsk {
                HStack(spacing: 12) {
                    Button("Allow") { onDecision(item, "allow") }
                        .buttonStyle(.borderedProminent)
                    Button("Deny", role: .destructive) { onDecision(item, "deny") }
                        .buttonStyle(.bordered)
                }
            } else if let decision = item.decision {
                Label(item.decisionDelivered == false
                      ? "\(decision) — not delivered"
                      : "Answered: \(decision)",
                      systemImage: item.decisionDelivered == false
                      ? "exclamationmark.triangle.fill"
                      : "checkmark")
                    .font(.caption2)
                    .foregroundStyle(item.decisionDelivered == false ? .orange : .secondary)
            }
        }
    }
}

private struct DaySeparator: View {
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            Text(date, format: .dateTime.month(.abbreviated).day().year())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
        }
    }
}
