import MarkdownUI
import SwiftUI

/// One row of the conversation, from either of the two sources that feed it.
///
/// The two are not interchangeable and neither replaces the other. A
/// notification is durable, arrives with the app closed, and — when it is an
/// `asking` — can be answered. A streamed event is live, reaches only a
/// foregrounded app, holds no answer path, and survives only as long as the
/// relay's ring buffer.
enum ConversationRow: Identifiable {
    case item(NotificationHistoryItem)
    case event(SessionEventRecord)

    var id: String {
        switch self {
        case .item(let item): return "i-\(item.id)"
        case .event(let event): return "e-\(event.eventId)"
        }
    }

    var at: Date {
        switch self {
        case .item(let item): return item.receivedAt
        case .event(let event): return event.at
        }
    }

    /// The kinds whose text also arrives as a streamed event, and so may be
    /// drawn from the event instead: the assistant's final message (a
    /// `completed` push carries it; the stream carries it as `assistant`),
    /// and a reply typed on this phone (stored locally as `sent`; the Mac
    /// echoes it and the stream carries it as `user`). Both share an id with
    /// their event by construction, which is the only reason they can go.
    static let kindsAnEventCanStandInFor: Set<String> = ["completed", "sent"]

    /// Interleave the two sources by time, dropping a notification that says
    /// the same thing as an event already present.
    ///
    /// **Only the kinds above are ever dropped.** An `asking` is the one route
    /// that can be answered — Allow, Deny, or a chosen option — and the event
    /// stream has no equivalent, so it stays even when an event carries the
    /// same words.
    ///
    /// **A notification with no `eventId` also stays.** That is what a build
    /// older than the field wrote, and reading `nil` as "duplicate" would
    /// erase the stored history rather than de-duplicate it.
    static func merge(items: [NotificationHistoryItem],
                      events: [SessionEventRecord]) -> [ConversationRow] {
        let streamed = Set(events.map(\.eventId))
        let kept = items.filter { item in
            guard kindsAnEventCanStandInFor.contains(item.kind),
                  let eventId = item.eventId else { return true }
            return !streamed.contains(eventId)
        }
        return (kept.map(ConversationRow.item) + events.map(ConversationRow.event))
            .sorted { $0.at < $1.at }
    }
}

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
    let onAnswer: (NotificationHistoryItem, [String: String]) -> Void
    /// Text, then the id this view stored its local copy under. The id is
    /// minted HERE, before the request leaves, so the local record and the
    /// echo the Mac stamps can never disagree about it.
    let onSend: (String, String) async throws -> Void
    /// Live events for every session on every machine. Filtered to this one at
    /// render time rather than handed a pre-filtered slice, so an event that
    /// arrives while this view is open lands without a re-plumb.
    let eventStore: SessionEventStore
    /// Ask the relay for what this store is missing. Called once when the view
    /// appears; the socket answers on its own connection.
    let onRequestBackfill: (String, Int) -> Void

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
    /// Whether the one-time open-at-the-newest scroll has run.
    @State private var didInitialScroll = false

    var body: some View {
        ScrollViewReader { proxy in
                ScrollView {
                    // **`VStack`, not `LazyVStack`, and that is the fix.**
                    // A lazy stack estimates the height of rows it has not
                    // measured, so anchoring to the bottom anchors the bottom
                    // of a GUESS. Measured on device twice, on the two
                    // DIFFERENT paths that position this view — which is what
                    // makes the stack itself the culprit rather than either of
                    // them. Opening a conversation landed on blank space below
                    // the transcript; and, on a screen left open while a push
                    // arrived, the `onReceive` re-scroll landed PAST the end,
                    // transcript clipped at the top and blank filling the rest.
                    // Same defect both times: the offset was right for the
                    // estimate and wrong for the content, which measured
                    // shorter once it was really laid out.
                    //
                    // Nothing that positions a scroll view can be correct
                    // while the heights are guesses, so the guessing goes
                    // rather than gaining a correction on top of it. These
                    // rows are one session's notifications — bounded, and
                    // small in every conversation seen so far — so measuring
                    // them all up front is affordable. If a very long history
                    // ever makes opening slow, that is visible and fixable;
                    // a scroll position that is silently wrong is neither.
                    VStack(alignment: .leading, spacing: 28) {
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
                        // Keyed on the DRAWN rows, not on the notifications:
                        // a session whose content arrived only over the
                        // stream drew "Nothing from this session yet"
                        // stacked on top of its own conversation.
                        } else if rows.isEmpty {
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
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if shouldShowDaySeparator(in: rows, at: index) {
                                DaySeparator(date: row.at)
                            }
                            switch row {
                            case .item(let item):
                                MessageBlock(item: item, onDecision: onDecision, onAnswer: onAnswer)
                            case .event(let event):
                                SessionEventBlock(event: event)
                            }
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
                .onAppear {
                    load()
                    // Asked from THIS SESSION's high-water mark. The relay
                    // filters `WHERE session_id = ? AND seq > ?`, so asking
                    // with a Mac-wide mark — which is what the first version
                    // did — returns nothing for any session whose events all
                    // sit below whatever the busiest session reached.
                    onRequestBackfill(sessionId, eventStore.lastSeq(sessionId: sessionId, resumeId: resumeId))
                }
                // **The anchor alone is not enough, and the comment above
                // says why without following it through.** It resolves during
                // the FIRST layout — which happens before `onAppear` runs
                // `load()`, so it anchors an empty list. The rows then arrive
                // into a `LazyVStack`, whose height is estimated for anything
                // not yet measured, and the anchor lands past the real
                // content: the screen opens on blank space, and scrolling
                // down both reveals the transcript and collapses the blank as
                // the rows get measured for real (reported from the device
                // 2026-09-05).
                //
                // So the scroll is redone once the items are actually in.
                // `scrollTo` works on an id that is not yet materialised —
                // that is what it is for — which is why this succeeds where
                // the `onAppear` attempt recorded above failed: not because
                // `scrollTo` was wrong, but because it ran a step too early.
                //
                // Once, and only on the first load: re-running it would yank
                // the view back down while the user is reading older
                // messages, and `onReceive` below already handles the case
                // where a NEW message should pull them to the bottom.
                // Also keyed on the drawn rows. Gating this on `items` left
                // `didInitialScroll` false forever on an events-only session,
                // and the arrival scroll below is guarded on it — so that
                // session never scrolled at all.
                .onChange(of: rows.count) { _, count in
                    guard !didInitialScroll, count > 0 else { return }
                    didInitialScroll = true
                    // One hop, so the rows this load produced have been laid
                    // out before the offset is computed against them.
                    DispatchQueue.main.async {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                // The Notification Service Extension appends while the app is
                // open, so a push arriving on this screen has to land in it —
                // that is the case this whole view exists for.
                .onReceive(NotificationCenter.default.publisher(for: HistoryUpdateBridge.didUpdate)) { _ in
                    // The event fires for EVERY session, and it cannot say
                    // which one: it is re-posted from a Darwin notification,
                    // and Darwin notifications carry no userInfo at all. So
                    // this only reloads; whether anything for THIS session
                    // arrived is decided by `rows.last?.id` below, which the
                    // reload feeds. Scrolling on the bare event here yanked
                    // the reader to the bottom on somebody else's push.
                    load()
                }
                // **One rule for every arrival.** The newest DRAWN row changed
                // — a push for this session, the local record of a reply just
                // sent, a streamed event — so pull to the bottom. Keyed on the
                // merged rows rather than on `items`, because two of the three
                // routes never touch `items`: a streamed event lands in
                // `eventStore`, and before this the reply you had just typed
                // sat below the fold until you scrolled to find it (seen on
                // device). Same one-hop deferral as the initial scroll, for
                // the same reason: the row must be laid out before its offset
                // exists.
                .onChange(of: rows.last?.id) { _, newest in
                    guard didInitialScroll, newest != nil else { return }
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                    }
                }
                .onChange(of: composerFocused) { _, focused in
                    if focused { withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) } }
                }
        }
        .background(Color(.systemGroupedBackground))
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
                    // A vertical-axis field treats Return as a newline, which
                    // is right for the on-screen keyboard (it has a separate
                    // send button and no Shift worth speaking of) and wrong
                    // for a hardware one — under iPhone Mirroring, Return
                    // did nothing but add a line. Return sends; Shift+Return
                    // keeps the newline, so a multi-line reply is still
                    // typeable from a real keyboard.
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        guard !sending,
                              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { return .handled }
                        Task { await send() }
                        return .handled
                    }
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
        // Minted before the send, and stored on the local record below, so
        // the Mac can stamp the streamed echo of this text with the same id
        // and the merge draws the two as one row. Once the stream existed,
        // every reply typed here appeared twice — the local record and the
        // echo — until the two shared a key (measured on device).
        let replyId = UUID().uuidString
        do {
            try await onSend(text, replyId)
            // Record it locally. The stream DOES now bring the echo back, but
            // only while this app is foregrounded and only for as long as
            // the relay's ring buffer holds it; this record is the durable
            // copy, readable offline, and the one item in here the phone
            // itself authored — which is why `kind` says so.
            let sentItem = NotificationHistoryItem(
                id: UUID().uuidString,
                receivedAt: Date(),
                title: "You",
                body: text,
                machine: machine,
                sessionId: sessionId,
                kind: "sent",
                resumeId: resumeId,
                eventId: replyId
            )
            if CanopyDemo.isEnabled {
                // Into the fixtures, never the App Group: a demo run must not
                // leave anything in the store the real app reads.
                CanopyDemo.append(sentItem)
            } else {
                do {
                    try HistoryStore.append(sentItem)
                } catch {
                    print("HistoryStore.append(sent) failed: \(error.localizedDescription)")
                }
            }
            load()
            // Cleared only on success, so a failed send leaves the text where
            // the user can retry it rather than making them retype it.
            draft = ""
        } catch let error as RosterError {
            // The relay's own words when it has them. `localizedDescription`
            // on a plain Swift enum is the useless "The operation couldn't be
            // completed", which is what the user used to see for every
            // failure including the ones the Mac explained.
            sendError = error.message
        } catch {
            sendError = "Could not send: \(error.localizedDescription)"
        }
        sending = false
    }

    private func load() {
        do {
            // `loadAll()` is newest-first; a conversation reads oldest-first.
            loadError = nil
            let all: [NotificationHistoryItem]
            if CanopyDemo.isEnabled {
                all = CanopyDemo.history
            } else {
                all = try HistoryStore.loadAll()
            }
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

    /// The rows actually drawn: stored notifications and live events in one
    /// timeline, with a notification dropped when an event already says it.
    private var rows: [ConversationRow] {
        ConversationRow.merge(items: items,
                              events: eventStore.events(sessionId: sessionId, resumeId: resumeId))
    }

    /// Takes the row list rather than reading `items`, because the separators
    /// belong to what is DRAWN. Reading the notifications while rendering the
    /// merged list put the day breaks at the wrong places as soon as an event
    /// sat between two notifications.
    private func shouldShowDaySeparator(in rows: [ConversationRow], at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(rows[index].at, inSameDayAs: rows[index - 1].at)
    }
}

/// One streamed event.
///
/// A tool is a thin single line — it exists to say "not stuck, still working",
/// and giving it a card would make the busiest thing on screen the least
/// informative. The turn boundaries draw nothing at all: they carry no content
/// and only break up the flow.
private struct SessionEventBlock: View {
    let event: SessionEventRecord

    var body: some View {
        switch event.kind {
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                Text(event.text)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .turnStart, .turnEnd:
            EmptyView()
        case .assistant, .user:
            // The same card as a notification: header, then body, through the
            // same two shared views. The first version drew the body alone,
            // and a streamed message sat headerless beside a notification of
            // the same shape with "Canopy 9:49" on it — the row read as a
            // different kind of thing, not as the same conversation arriving
            // a different way (seen on device).
            VStack(alignment: .leading, spacing: 10) {
                ConversationHeader(
                    icon: event.kind == .user ? "arrow.up.circle.fill" : "checkmark.circle",
                    title: event.kind == .user ? "You" : "Canopy",
                    at: event.at)
                ConversationMarkdown(text: event.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// The one header for a conversation card, whichever route the row arrived
/// by. Icon, who, when. Shared for the same reason `ConversationMarkdown` is:
/// a notification and a streamed event of the same message must look like
/// the same message.
struct ConversationHeader: View {
    let icon: String
    let title: String
    let at: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
            Text(at, style: .time)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
    }
}

/// The one Markdown renderer for conversation text, whichever route the text
/// arrived by. A notification body and a streamed event are the same words
/// from the same session and must look the same; keeping this in one place
/// is what stops the two from drifting.
struct ConversationMarkdown: View {
    let text: String

    var body: some View {
        Markdown(CJKEmphasis.normalized(text))
            // Matches Canopy's own inline-code rule
            // (Resources/canopy-overrides.css): the same dark red on the
            // same 4% black. **The border and the 1x4 padding are not
            // reproducible** — MarkdownUI's `\.code` is a text style, and
            // SwiftUI has no inline box to pad or stroke — so this is the
            // chip's colour without the chip's shape, deliberately, not
            // an oversight to be "finished" with a background view.
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                ForegroundColor(Color(red: 138 / 255, green: 36 / 255, blue: 36 / 255))
                BackgroundColor(Color.black.opacity(0.04))
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
    }
}

/// One notification in the stream. A permission ask nobody has answered gets
/// Allow/Deny right here rather than behind another tap — the whole point of
/// the push was that the session is blocked.
private struct MessageBlock: View {
    let item: NotificationHistoryItem
    let onDecision: (NotificationHistoryItem, String) -> Void
    let onAnswer: (NotificationHistoryItem, [String: String]) -> Void

    /// An ask Allow/Deny can resolve. `answerable == false` is an
    /// AskUserQuestion, which is answered by picking an option instead —
    /// Canopy refuses an allow/deny for one, so offering the buttons would be
    /// offering something that cannot work.
    private var isUnansweredAsk: Bool {
        item.kind == "asking" && item.decision == nil && item.answerable != false
    }

    /// An unanswered AskUserQuestion whose form came through. Without one
    /// the ask renders as it used to: legible, and unanswerable from here.
    /// The rules live on the model so they can be tested without a view —
    /// see `NotificationHistoryItem.answerableForm`.
    private var unansweredForm: [AskChoice]? { item.answerableForm }

    private var icon: String {
        switch item.kind {
        case "asking": "hand.raised.fill"
        case "sent": "arrow.up.circle.fill"
        default: "checkmark.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConversationHeader(icon: icon, title: item.title, at: item.receivedAt)

            // Normalised on the way in: Japanese bold whose closing `**`
            // sits between punctuation and a letter is not emphasis to
            // CommonMark, and rendered as literal asterisks.
            if item.showsBody {
            ConversationMarkdown(text: NotificationHistoryItem.displayableBody(item.body))
            }

            if isUnansweredAsk {
                HStack(spacing: 12) {
                    Button("Allow") { onDecision(item, "allow") }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                    // Offered only when the CLI actually proposed a rule.
                    // Canopy echoes that proposal back rather than composing
                    // one, so with nothing proposed there is nothing this
                    // button could write and it must not appear.
                    if item.allowAlways == true {
                        Button("Always") { onDecision(item, "allowAlways") }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                    }
                    Button("Deny", role: .destructive) { onDecision(item, "deny") }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                }
            } else if let form = unansweredForm {
                AskFormView(form: form) { answers in onAnswer(item, answers) }
            } else if let decision = item.decision {
                // An answered form keeps its questions on screen: the record
                // below is a bare list of labels, and without the questions
                // there is nothing on screen saying what they answered.
                if let asked = item.choices, !asked.isEmpty {
                    ForEach(asked, id: \.question) { AskQuestionHeading(choice: $0) }
                }
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The buttons for an `AskUserQuestion`.
///
/// **Select then Send, always — never send on the first tap.** A form can
/// carry several questions and a question can be multi-select, so there is no
/// shape where one tap is always the whole answer, and a control that
/// sometimes commits immediately and sometimes does not is worse than one
/// that never does. It also means the same code path answers every form.
///
/// Nothing is sent until every question has a selection: the Mac refuses a
/// partial answer anyway (see `AskUserQuestionForm.merged`), so letting the
/// button be pressed would only produce a refusal the user cannot act on.
/// A question's header and text. One definition, so the answered card and
/// the answerable one cannot describe the same question differently.
///
/// The question text is shown even when a header stands in for it above,
/// because the header is a label the model chose for a column and the
/// question is what the answer is keyed by — see `AskChoice`.
private struct AskQuestionHeading: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let choice: AskChoice
    /// Show "Select one" / "Select one or more" beside the header. On for the
    /// live form, where it is the only thing telling the user a multi-select
    /// question takes several answers; off on the answered card, where the
    /// instruction would be stale.
    var showsSelectHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // At accessibility sizes the hint wraps under the header rather
            // than fighting it for one line.
            let headingLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            headingLayout {
                if let header = choice.header {
                    Text(header).font(.subheadline.weight(.semibold))
                }
                if showsSelectHint {
                    Text(choice.multiSelect ? "Select one or more" : "Select one")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(choice.question)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AskFormView: View {
    let form: [AskChoice]
    let onSend: ([String: String]) -> Void

    @State private var picked: [String: Set<String>] = [:]
    @State private var sent = false

    private var complete: Bool { AskChoice.isComplete(form: form, picked: picked) }
    private var answers: [String: String] { AskChoice.answers(for: form, picked: picked) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(form, id: \.question) { choice in
                VStack(alignment: .leading, spacing: 6) {
                    AskQuestionHeading(choice: choice, showsSelectHint: true)
                    // One inset group per question, control on the trailing
                    // edge — the shape iOS uses for a choice list, so the
                    // radio / checkbox glyphs read as what they are without
                    // a legend.
                    VStack(spacing: 0) {
                        ForEach(Array(choice.options.enumerated()), id: \.offset) { index, option in
                            if index > 0 { Divider().padding(.horizontal, 12) }
                            let on = picked[choice.question]?.contains(option.label) == true
                            Button {
                                toggle(option.label, in: choice)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        // The description is why one option
                                        // is not the other; the raw tool
                                        // input that used to carry it is no
                                        // longer shown.
                                        if let description = option.description {
                                            Text(description)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: symbol(for: option.label, in: choice))
                                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                                        .accessibilityHidden(true)
                                }
                                .font(.body)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(on ? "Selected" : "Not selected")
                            .accessibilityAddTraits(on ? .isSelected : [])
                            .disabled(sent)
                        }
                    }
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Button {
                sent = true
                onSend(answers)
            } label: {
                Text(sent ? "Sending…" : "Send answer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!complete || sent)
        }
        .padding(.top, 2)
    }

    private func symbol(for option: String, in choice: AskChoice) -> String {
        let on = picked[choice.question]?.contains(option) == true
        if choice.multiSelect { return on ? "checkmark.square.fill" : "square" }
        return on ? "largecircle.fill.circle" : "circle"
    }

    private func toggle(_ option: String, in choice: AskChoice) {
        var current = picked[choice.question] ?? []
        if choice.multiSelect {
            if current.contains(option) { current.remove(option) } else { current.insert(option) }
        } else {
            // Single-select re-tap deselects rather than latching, so a
            // mis-tap is recoverable without leaving the card.
            current = current.contains(option) ? [] : [option]
        }
        picked[choice.question] = current
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
