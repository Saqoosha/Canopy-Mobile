import Foundation
import Testing
@testable import CanopyMobile

@MainActor
struct SessionEventStoreTests {
    private let mac = "M1"

    private func rec(_ seq: Int,
                     session: String = "s1",
                     resume: String? = nil,
                     text: String = "x") -> SessionEventRecord {
        SessionEventRecord(seq: seq, eventId: "e\(session)-\(seq)", sessionId: session,
                           resumeId: resume, kind: .assistant, text: text,
                           at: Date(timeIntervalSince1970: Double(seq)))
    }

    @Test("Events sort by seq however they arrive")
    func ordersBySeq() {
        let store = SessionEventStore()
        store.apply(rec(3), machine: mac)
        store.apply(rec(1), machine: mac)
        store.apply(rec(2), machine: mac)
        #expect(store.events(sessionId: "s1", resumeId: nil).map(\.seq) == [1, 2, 3])
    }

    // The backfill after a reconnect and the live fan-out routinely overlap,
    // so a repeat is the normal case rather than a fault.
    @Test("A repeated seq is dropped, and the first copy is the one kept")
    func dropsARepeatedSeq() {
        let store = SessionEventStore()
        store.apply(rec(1, text: "first"), machine: mac)
        store.apply(rec(1, text: "second"), machine: mac)
        let all = store.events(sessionId: "s1", resumeId: nil)
        #expect(all.count == 1)
        #expect(all.first?.text == "first")
    }

    @Test("lastSeq is the highest seen for that session, not the most recent")
    func tracksTheHighestSeq() {
        let store = SessionEventStore()
        store.apply(rec(5), machine: mac)
        store.apply(rec(2), machine: mac)
        #expect(store.lastSeq(sessionId: "s1") == 5)
    }

    @Test("One session's events stay out of another's")
    func separatesSessions() {
        let store = SessionEventStore()
        store.apply(rec(1, session: "s1"), machine: mac)
        store.apply(rec(2, session: "s2"), machine: mac)
        #expect(store.events(sessionId: "s1", resumeId: nil).count == 1)
        #expect(store.events(sessionId: "s2", resumeId: nil).count == 1)
    }

    // sessionId is minted per Canopy process, so after a Mac restart it
    // matches nothing stored earlier — resumeId is what survives.
    @Test("resumeId wins over sessionId when both sides have one")
    func prefersResumeId() {
        let store = SessionEventStore()
        store.apply(rec(1, session: "old-process", resume: "R"), machine: mac)
        #expect(store.events(sessionId: "new-process", resumeId: "R").count == 1)
        #expect(store.events(sessionId: "new-process", resumeId: nil).isEmpty)
    }

    // **Seq numbers are per Mac.** Two Macs both mint a seq 1. The first
    // version keyed on seq alone, so the second Mac's seq 1 was dropped as
    // "already seen" — one Mac's conversation silently missing every event
    // whose number the other Mac had used first.
    @Test("The same seq on two Macs is two events, not one")
    func seqIsScopedByMachine() {
        let store = SessionEventStore()
        store.apply(rec(1, session: "studio-s", text: "studio"), machine: "studio")
        store.apply(rec(1, session: "laptop-s", text: "laptop"), machine: "laptop")
        #expect(store.events(sessionId: "studio-s", resumeId: nil).first?.text == "studio")
        #expect(store.events(sessionId: "laptop-s", resumeId: nil).first?.text == "laptop")
    }

    // **Per session, not per Mac.** The relay answers `events_since` with
    // `WHERE session_id = ? AND seq > ?`, so asking with a Mac-wide mark
    // returns nothing for any session sitting below the busiest one — the
    // session opened second silently shows no history at all.
    @Test("lastSeq is per session, not per Mac")
    func lastSeqIsScopedBySession() {
        let store = SessionEventStore()
        store.apply(rec(40, session: "busy"), machine: mac)
        store.apply(rec(3, session: "quiet"), machine: mac)
        #expect(store.lastSeq(sessionId: "busy") == 40)
        #expect(store.lastSeq(sessionId: "quiet") == 3)
        #expect(store.lastSeq(sessionId: "never-heard-from") == 0)
    }

    // **The mark must use the identity the RELAY uses, which is sessionId
    // alone.** `events(sessionId:resumeId:)` is resumeId-first, and that is
    // right for what to DRAW — a Canopy restart mints a new sessionId and the
    // old rows still belong to this conversation. Taking the mark that way
    // returned a seq from records the relay would never count for the id
    // being asked about, so `events_since` came back empty. Found in the
    // verification round, on the fix for the per-Mac version of this bug.
    @Test("lastSeq ignores records the relay would not match on this sessionId")
    func lastSeqIgnoresOtherSessionIdsSharingAResumeId() {
        let store = SessionEventStore()
        store.apply(rec(90, session: "old-process", resume: "R"), machine: mac)
        store.apply(rec(4, session: "live-process", resume: "R"), machine: mac)
        // Both belong to the conversation…
        #expect(store.events(sessionId: "live-process", resumeId: "R").count == 2)
        // …but the relay only holds seq 4 under this session id.
        #expect(store.lastSeq(sessionId: "live-process") == 4)
    }

    @Test("A backfill that starts later than asked reports a gap")
    func reportsAGap() {
        let store = SessionEventStore()
        store.noteRequest(sessionId: "s1", machine: mac, since: 0)
        store.apply(backfill: [rec(10), rec(11)], oldestSeq: 10, sessionId: "s1", machine: mac)
        #expect(store.hasGap(sessionId: "s1", machine: mac))
    }

    @Test("A complete backfill reports no gap")
    func reportsNoGap() {
        let store = SessionEventStore()
        store.noteRequest(sessionId: "s1", machine: mac, since: 0)
        store.apply(backfill: [rec(1), rec(2)], oldestSeq: 1, sessionId: "s1", machine: mac)
        #expect(!store.hasGap(sessionId: "s1", machine: mac))
    }

    // The boundary, asserted from both sides on the comparison itself.
    // `events_since N` returns what comes AFTER N, so an oldest of exactly
    // N+1 is complete and N+2 is not. Comparing against N instead of N+1
    // reports a gap on every first connection — which is how the off-by-one
    // was found.
    @Test("The gap boundary sits at requested + 1")
    func gapBoundary() {
        #expect(!SessionEventStore.isGap(oldestHeld: 6, requestedFrom: 5))
        #expect(SessionEventStore.isGap(oldestHeld: 7, requestedFrom: 5))
    }

    // A session the relay holds nothing for answers `0`, and so does a
    // session that has never emitted anything. Nothing here can tell them
    // apart, so `0` must not be read as "it is all gone" — that verdict
    // would fire on every genuinely new session.
    //
    // **This pins the property, not the guard that expresses it — deleting
    // `isGap`'s `oldest > 0` line leaves this green, measured.** With a
    // non-negative mark the comparison already answers false on its own, so
    // there is no fixture that separates the two implementations. Said here
    // rather than left to read as coverage it does not provide.
    @Test("An oldest of zero is not a gap")
    func zeroOldestIsNotAGap() {
        #expect(!SessionEventStore.isGap(oldestHeld: 0, requestedFrom: 5))
    }

    // Never having asked is not the same as having been told nothing is
    // missing. A store with no answer yet must not claim a hole.
    @Test("A session that has had no backfill answer reports no gap")
    func noAnswerMeansNoGapClaim() {
        let store = SessionEventStore()
        store.noteRequest(sessionId: "s1", machine: mac, since: 0)
        store.apply(rec(9), machine: mac)
        #expect(!store.hasGap(sessionId: "s1", machine: mac))
    }

    // The other half of the pair. A live `event` frame sets `oldestHeld` for
    // nobody, but a backfill answer for a session this store never asked
    // about could still arrive — the relay answers on the shared socket.
    // Half a pair is not a verdict.
    @Test("An answer with no recorded request reports no gap")
    func answerWithoutRequestMeansNoGapClaim() {
        let store = SessionEventStore()
        store.apply(backfill: [rec(10)], oldestSeq: 10, sessionId: "s1", machine: mac)
        #expect(!store.hasGap(sessionId: "s1", machine: mac))
    }

    // **The reason the mark lives in the store rather than in the view that
    // asked.** Since #24 a reconnect re-asks from a higher mark, and the
    // view never sees that ask. Left in the view, its stale low number turns
    // `oldest > requested + 1` true on a session that missed nothing.
    @Test("A re-ask from a higher mark replaces the one the gap is judged against")
    func reAskReplacesTheRecordedMark() {
        let store = SessionEventStore()
        store.noteRequest(sessionId: "s1", machine: mac, since: 0)
        store.noteRequest(sessionId: "s1", machine: mac, since: 50)
        store.apply(backfill: [rec(51)], oldestSeq: 30, sessionId: "s1", machine: mac)
        #expect(!store.hasGap(sessionId: "s1", machine: mac))
    }

    // Marks are per machine as well as per session, for the reason every
    // other number here is: seq is minted per Durable Object.
    @Test("A request noted for one Mac does not answer for another")
    func requestMarksAreScopedToTheirMachine() {
        let store = SessionEventStore()
        store.noteRequest(sessionId: "s1", machine: mac, since: 0)
        store.apply(backfill: [rec(10)], oldestSeq: 10, sessionId: "s1", machine: "other-mac")
        #expect(!store.hasGap(sessionId: "s1", machine: "other-mac"))
        #expect(!store.hasGap(sessionId: "s1", machine: mac))
    }

    @Test("A backfill's own records land in the store")
    func backfillIsStored() {
        let store = SessionEventStore()
        store.apply(backfill: [rec(1), rec(2)], oldestSeq: 1, sessionId: "s1", machine: mac)
        #expect(store.events(sessionId: "s1", resumeId: nil).count == 2)
        #expect(store.lastSeq(sessionId: "s1") == 2)
    }

    // Mirrors the relay's own cap. A long foreground run receives live
    // events indefinitely; without this the store outgrows what a backfill
    // would ever have delivered.
    @Test("A session keeps only the newest events past the cap")
    func capsPerSession() {
        let store = SessionEventStore()
        let over = SessionEventStore.maxEventsPerSession + 5
        for seq in 1...over { store.apply(rec(seq), machine: mac) }
        let kept = store.events(sessionId: "s1", resumeId: nil)
        #expect(kept.count == SessionEventStore.maxEventsPerSession)
        #expect(kept.first?.seq == 6)
        #expect(kept.last?.seq == over)
    }

    @Test("The cap is per session, not per Mac")
    func capIsPerSession() {
        let store = SessionEventStore()
        let n = SessionEventStore.maxEventsPerSession
        for seq in 1...n { store.apply(rec(seq, session: "a"), machine: mac) }
        for seq in (n + 1)...(2 * n) { store.apply(rec(seq, session: "b"), machine: mac) }
        #expect(store.events(sessionId: "a", resumeId: nil).count == n)
        #expect(store.events(sessionId: "b", resumeId: nil).count == n)
    }

    // The relay writes `at` as the number Canopy's JSONEncoder produced, which
    // is seconds on Swift's 2001 reference date. Decoding must land back on
    // the same instant — a mismatch here shows up only as a wrongly ordered
    // conversation, never as an error.
    @Test("A record round-trips through JSON with its date intact")
    func roundTripsThroughJSON() throws {
        let original = rec(7)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(SessionEventRecord.self, from: data)
        #expect(back == original)
        #expect(back.at == original.at)
    }

    @Test("A record decodes from the relay's wire shape")
    func decodesTheWireShape() throws {
        let json = """
        {"type":"event","seq":4,"eventId":"abc","sessionId":"s1","resumeId":null,
         "kind":"tool","text":"Bash: npm test","at":778000000.5}
        """
        let record = try JSONDecoder().decode(SessionEventRecord.self, from: Data(json.utf8))
        #expect(record.seq == 4)
        #expect(record.kind == .tool)
        #expect(record.text == "Bash: npm test")
        #expect(record.resumeId == nil)
    }

    @Test("A kind this build does not know decodes rather than throwing")
    func unknownKindDecodes() throws {
        let json = """
        {"type":"event","seq":4,"eventId":"abc","sessionId":"s1","resumeId":null,
         "kind":"reasoning","text":"...","at":0}
        """
        let record = try JSONDecoder().decode(SessionEventRecord.self, from: Data(json.utf8))
        #expect(record.kind == .other("reasoning"))
        // The text survives, which is what makes the row worth drawing at
        // all rather than dropping.
        #expect(record.text == "...")
    }

    // **The defect the tolerant decode exists for, at its real scale.** A
    // backfill answer decodes as an array, so under the strict enum one
    // unrecognised kind threw and took every sibling event with it — the
    // phone drew a conversation missing the whole page the relay had just
    // sent. Asserting the single-record case alone would not have caught
    // that: it is the array that turns one row into two hundred.
    @Test("One unknown kind does not discard the rest of the page")
    func unknownKindDoesNotVoidThePage() throws {
        let json = """
        [{"seq":1,"eventId":"e1","sessionId":"s1","resumeId":null,
          "kind":"assistant","text":"one","at":0},
         {"seq":2,"eventId":"e2","sessionId":"s1","resumeId":null,
          "kind":"reasoning","text":"two","at":0},
         {"seq":3,"eventId":"e3","sessionId":"s1","resumeId":null,
          "kind":"tool","text":"three","at":0}]
        """
        let page = try JSONDecoder().decode([SessionEventRecord].self, from: Data(json.utf8))
        #expect(page.count == 3)
        #expect(page.map(\.kind) == [.assistant, .other("reasoning"), .tool])
    }

    // Encoding is the half nothing on the wire exercises, so it is the half
    // that can rot unnoticed: an `.other` that encoded as its case name
    // rather than its raw value would round-trip into a DIFFERENT unknown
    // kind and nothing would report it.
    @Test("An unknown kind round-trips under its own name")
    func unknownKindRoundTrips() throws {
        let original = SessionEventRecord(seq: 1, eventId: "e", sessionId: "s1", resumeId: nil,
                                          kind: .other("reasoning"), text: "t",
                                          at: Date(timeIntervalSince1970: 0))
        let back = try JSONDecoder().decode(SessionEventRecord.self,
                                            from: try JSONEncoder().encode(original))
        #expect(back == original)
        #expect(back.kind == .other("reasoning"))
    }

    // The five known spellings are the wire contract, not an internal
    // detail: renaming a case silently reclassifies every event of that kind
    // as `.other`, which still decodes and still draws — just wrongly, and
    // with no error anywhere. Pinned as raw strings on purpose.
    @Test("The known kinds keep their wire spellings")
    func knownKindSpellings() {
        let spellings = ["assistant", "user", "tool", "turnStart", "turnEnd"]
        for spelling in spellings {
            let kind = SessionEventRecord.Kind(rawValue: spelling)
            #expect(kind.rawValue == spelling)
            if case .other = kind { Issue.record("\(spelling) fell through to .other") }
        }
    }
}

/// The classifier is where a snapshot and an event could be confused, and the
/// confusion would be silent — an event read as a snapshot has no panes and
/// is simply dropped.
@MainActor
struct RosterSocketFrameTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test("A frame with no type is a roster snapshot")
    func untaggedIsASnapshot() {
        let json = """
        {"machineId":"M","displayName":"Studio","publishedAt":1,"sessionPct":0,
         "weeklyPct":0,"panes":[]}
        """
        guard case .snapshot(let snapshot)? = RosterSocket.decode(data(json)) else {
            Issue.record("expected a snapshot"); return
        }
        #expect(snapshot.machineId == "M")
    }

    @Test("A frame tagged event is an event")
    func taggedEvent() {
        let json = """
        {"type":"event","seq":2,"eventId":"e2","sessionId":"s1","resumeId":null,
         "kind":"assistant","text":"hi","at":0}
        """
        guard case .event(let record)? = RosterSocket.decode(data(json)) else {
            Issue.record("expected an event"); return
        }
        #expect(record.seq == 2)
    }

    @Test("A frame tagged events is a backfill page")
    func taggedBackfill() {
        let json = """
        {"type":"events","sessionId":"s1","oldestSeq":5,"events":[
          {"type":"event","seq":5,"eventId":"e5","sessionId":"s1","resumeId":null,
           "kind":"user","text":"go","at":0}]}
        """
        guard case .backfill(let page)? = RosterSocket.decode(data(json)) else {
            Issue.record("expected a backfill page"); return
        }
        #expect(page.oldestSeq == 5)
        #expect(page.events.count == 1)
    }

    // The same tolerance, asserted where production actually decodes. This
    // is `try?` — a throw here does not surface as a bad page, it returns
    // nil and the frame is dropped whole, which on the strict enum meant an
    // unknown kind anywhere in a page silently cost the entire backfill.
    @Test("A page carrying an unknown kind still classifies as a backfill")
    func backfillSurvivesAnUnknownKind() {
        let json = """
        {"type":"events","sessionId":"s1","oldestSeq":5,"events":[
          {"seq":5,"eventId":"e5","sessionId":"s1","resumeId":null,
           "kind":"user","text":"go","at":0},
          {"seq":6,"eventId":"e6","sessionId":"s1","resumeId":null,
           "kind":"reasoning","text":"hmm","at":0}]}
        """
        guard case .backfill(let page)? = RosterSocket.decode(data(json)) else {
            Issue.record("expected a backfill page"); return
        }
        #expect(page.events.count == 2)
        #expect(page.events[1].kind == .other("reasoning"))
    }

    // The relay may grow a message this build has never heard of. Forcing it
    // into one of the three would render it as a conversation entry.
    @Test("An unknown type is refused rather than guessed at")
    func unknownTypeIsRefused() {
        #expect(RosterSocket.decode(data(#"{"type":"whatever"}"#)) == nil)
    }

    @Test("Malformed JSON is refused")
    func malformedIsRefused() {
        #expect(RosterSocket.decode(data("not json")) == nil)
    }
}

@MainActor
struct ConversationMergeTests {
    private func item(_ id: String,
                      _ seconds: TimeInterval,
                      eventId: String? = nil,
                      kind: String = "completed") -> NotificationHistoryItem {
        NotificationHistoryItem(id: id, receivedAt: Date(timeIntervalSince1970: seconds),
                                title: "Canopy", body: "b", machine: "M",
                                sessionId: "s1", kind: kind, eventId: eventId)
    }

    private func event(_ seq: Int, _ seconds: TimeInterval, eventId: String,
                       kind: SessionEventRecord.Kind = .assistant) -> SessionEventRecord {
        SessionEventRecord(seq: seq, eventId: eventId, sessionId: "s1", resumeId: nil,
                           kind: kind, text: "e",
                           at: Date(timeIntervalSince1970: seconds))
    }

    @Test("Both sources interleave by time")
    func ordersByTime() {
        let rows = ConversationRow.merge(items: [item("i1", 30)],
                                         events: [event(1, 10, eventId: "e1")])
        #expect(rows.count == 2)
        guard case .event = rows[0] else { Issue.record("the older event should be first"); return }
    }

    @Test("A completed notification duplicating an event is dropped")
    func dropsTheDuplicate() {
        let rows = ConversationRow.merge(items: [item("i1", 30, eventId: "e1")],
                                         events: [event(1, 29, eventId: "e1")])
        #expect(rows.count == 1)
        if case .item = rows[0] { Issue.record("the notification duplicate should be dropped") }
    }

    // A reply typed on this phone is stored locally under replyId, and the
    // Mac stamps the streamed echo with the same id. Two rows for one message
    // was the symptom; this is the assertion that the local record yields.
    @Test("A sent record duplicating its own echo is dropped")
    func dropsTheSentDuplicate() {
        let rows = ConversationRow.merge(items: [item("i1", 30, eventId: "reply-1", kind: "sent")],
                                         events: [event(1, 31, eventId: "reply-1", kind: .user)])
        #expect(rows.count == 1)
        if case .item = rows[0] { Issue.record("the local sent record should yield to the echo") }
    }

    // An asking is the only answerable route; the event stream has no
    // equivalent, so it survives a same-text event.
    @Test("An asking notification survives even when an event matches")
    func keepsAsking() {
        let rows = ConversationRow.merge(items: [item("i1", 30, eventId: "e1", kind: "asking")],
                                         events: [event(1, 29, eventId: "e1")])
        #expect(rows.count == 2)
    }

    // What a build older than the field wrote. Reading nil as "duplicate"
    // would erase stored history rather than de-duplicate it.
    @Test("A notification with no eventId is kept")
    func keepsWithoutEventId() {
        let rows = ConversationRow.merge(items: [item("i1", 30)],
                                         events: [event(1, 29, eventId: "e1")])
        #expect(rows.count == 2)
    }

    // A sent record whose echo never came back (the Mac was offline, or the
    // buffer has since rolled past it) must stay — it is the only copy.
    @Test("A sent record with no matching echo is kept")
    func keepsUnechoedSent() {
        let rows = ConversationRow.merge(items: [item("i1", 30, eventId: "reply-1", kind: "sent")],
                                         events: [event(1, 29, eventId: "other", kind: .user)])
        #expect(rows.count == 2)
    }

    @Test("An unmatched eventId keeps its notification")
    func keepsUnmatched() {
        let rows = ConversationRow.merge(items: [item("i1", 30, eventId: "other")],
                                         events: [event(1, 29, eventId: "e1")])
        #expect(rows.count == 2)
    }

    @Test("Rows carry stable, source-distinct ids")
    func stableIds() {
        let rows = ConversationRow.merge(items: [item("x", 1)],
                                         events: [event(1, 2, eventId: "x")])
        #expect(Set(rows.map(\.id)).count == 2)
    }

    @Test("Merging nothing yields nothing")
    func emptyMerge() {
        #expect(ConversationRow.merge(items: [], events: []).isEmpty)
    }
}
