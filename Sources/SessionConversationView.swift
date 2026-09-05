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
    /// The LIVE session's id, minted per Canopy process. Replies and decisions
    /// are addressed with it, because only it can name a running session.
    let sessionId: String
    /// The CLI's own session id, which survives a Canopy restart. Grouping
    /// uses this when both sides have one; `sessionId` is the fallback.
    let resumeId: String?
    let title: String
    /// Second header line — the machine, or "machine · project" when the
    /// roster knew a project for this pane. Never the body of anything.
    let subtitle: String
    /// The roster's live row for this session, or nil when it does not list
    /// one. Not captured at push time: a session opened BECAUSE it raised its
    /// hand can finish while you read, and a frozen dot would still say
    /// "asking". A nil pane draws no dot — grey means idle in this palette,
    /// and "the roster doesn't list it" is not idle.
    let pane: PaneRow?
    let onDecision: (NotificationHistoryItem, String) -> Void
    let onSend: (String) async throws -> Void

    @State private var items: [NotificationHistoryItem] = []
    @State private var totalCount = 0
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
        ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if let loadError {
                            // Never a bare icon: "the store would not open" and
                            // "this session has said nothing" look identical on
                            // screen unless the reason is written out.
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Could not read the history", systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote.weight(.medium))
                                Text(loadError.localizedDescription)
                                    .font(.caption)
                            }
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 40)
                        } else if items.isEmpty {
                            VStack(spacing: 8) {
                                Text("Nothing from this session yet")
                                    .font(.footnote)
                                // The count is the whole diagnosis when this is
                                // wrong: a full history with nothing matching
                                // means the ids disagree, not that the phone
                                // has received nothing.
                                Text("\(totalCount) notification\(totalCount == 1 ? "" : "s") in history, none from this session")
                                    .font(.caption2)
                                Text(sessionId)
                                    .font(.system(.caption2, design: .monospaced))
                            }
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
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
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }
                // Drag anywhere to push the keyboard away, and a plain tap on
                // the transcript does the same. `simultaneousGesture` rather
                // than `onTapGesture`: a plain tap gesture on the container
                // swallows the Allow/Deny buttons inside it, which are the one
                // thing on this screen that must never stop responding.
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                // Start at the newest message. `scrollTo` in `onAppear` did
                // not do this: it ran in the same pass as `load()`, before
                // SwiftUI had laid out a single row, so it scrolled an empty
                // list and the screen opened at the TOP — on a long session
                // that is the oldest thing it knows, which is the opposite of
                // what you opened it for. `defaultScrollAnchor` is resolved
                // during layout instead, so it does not race the load.
                .defaultScrollAnchor(.bottom)
                .onAppear { load() }
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
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Ticks so the elapsed figure advances while you read. Only
                // the header is inside it — wrapping the transcript would
                // re-evaluate every rendered Markdown block once a second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 1) {
                        HStack(spacing: 5) {
                            if let pane {
                                Circle()
                                    .fill(SessionActivityStyle.color(for: pane.state))
                                    .frame(width: 7, height: 7)
                            }
                            Text(title)
                                .font(.headline)
                                .lineLimit(1)
                        }
                        Text(statusLine(now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// "asking 2m · Canopy · main" — what the session is doing and for how
    /// long, then the project the header already carried.
    ///
    /// **The state leads because the line truncates from the end.** With the
    /// project first, a long "host · project" tail-truncated away exactly the
    /// text this header was added to show, leaving the part that was already
    /// there — the feature defeating itself on the sessions with the longest
    /// names. Losing the project to truncation costs nothing: it is on the
    /// row you tapped to get here.
    ///
    /// The state is dropped rather than guessed when the roster does not list
    /// this session, so the line shortens instead of claiming something.
    private func statusLine(now: Date) -> String {
        guard let pane else { return subtitle }
        let age = SessionActivityStyle.elapsed(since: pane.stateSince, now: now)
        return "\(pane.state) \(age) · \(subtitle)"
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
        // Down before the request, not after: the reply is gone from the
        // user's hands either way, and leaving the keyboard up over a stream
        // that is about to gain their message hides the thing they just sent.
        composerFocused = false
        do {
            try await onSend(text)
            // Record it locally. Nothing on the wire brings a reply back —
            // the relay forwards it to the Mac and the Mac answers in its own
            // time — so without this the message you just sent vanishes and
            // the stream reads as though you never spoke. It is the one item
            // in here the phone itself authored, which is why `kind` says so.
            do {
                try HistoryStore.append(NotificationHistoryItem(
                    id: UUID().uuidString,
                    receivedAt: Date(),
                    title: "You",
                    body: text,
                    machine: machine,
                    sessionId: sessionId,
                    kind: "sent",
                    resumeId: resumeId
                ))
            } catch {
                print("HistoryStore.append(sent) failed: \(error.localizedDescription)")
            }
            load()
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
            let all = try HistoryStore.loadAll()
            totalCount = all.count
            // Prefer the durable id. `sessionId` is minted per Canopy process,
            // so after a restart it matches nothing stored earlier and this
            // screen came up empty on a session that had notified all day —
            // which reads as "the push never arrived" rather than as an id
            // mismatch. An item or a target with no resumeId (backfilled a
            // moment after spawn) still matches on `sessionId`, so nothing
            // written by an older build becomes unreachable.
            items = all
                .filter { item in
                    guard item.machine == machine else { return false }
                    if let resumeId, let itemResume = item.resumeId {
                        return itemResume == resumeId
                    }
                    return item.sessionId == sessionId
                }
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
        // `answerable == false` is an AskUserQuestion: its answer is text the
        // model asked for, so Allow/Deny cannot resolve it and Canopy refuses
        // one anyway. Show the ask, offer nothing that would not work.
        item.kind == "asking" && item.decision == nil && item.answerable != false
    }

    private var icon: String {
        switch item.kind {
        case "asking": "hand.raised.fill"
        case "sent": "arrow.up.circle.fill"
        default: "checkmark.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
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
                // A shell command is the one body that must not be wrapped OR
                // clipped: wrapping it makes a pipeline unreadable, and the
                // default block silently cut a `curl` line mid-flag at phone
                // width (measured on device 2026-09-04) — you could not see
                // what you were being asked to approve. Scroll it instead.
                .markdownBlockStyle(\.codeBlock) { configuration in
                    ScrollView(.horizontal, showsIndicators: false) {
                        configuration.label
                            .fixedSize(horizontal: true, vertical: false)
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.88))
                            }
                            .padding(12)
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .markdownMargin(top: .em(0.4), bottom: .em(0.4))
                }

            if isUnansweredAsk {
                HStack(spacing: 12) {
                    Button("Allow") { onDecision(item, "allow") }
                        .buttonStyle(.borderedProminent)
                    // Offered only when the CLI actually proposed a rule.
                    // Canopy echoes that proposal back rather than composing
                    // one, so with nothing proposed there is nothing this
                    // button could write and it must not appear.
                    if item.allowAlways == true {
                        Button("Always") { onDecision(item, "allowAlways") }
                            .buttonStyle(.bordered)
                    }
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
