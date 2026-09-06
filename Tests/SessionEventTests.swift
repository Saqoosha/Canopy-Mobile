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

    @Test("lastSeq is the highest seen, not the most recent")
    func tracksTheHighestSeq() {
        let store = SessionEventStore()
        store.apply(rec(5), machine: mac)
        store.apply(rec(2), machine: mac)
        #expect(store.lastSeq(for: mac) == 5)
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

    // Asking a Mac's relay to resume from ANOTHER Mac's high-water mark
    // skips everything below it, or reports a gap that is not there.
    @Test("lastSeq is per Mac")
    func lastSeqIsScopedByMachine() {
        let store = SessionEventStore()
        store.apply(rec(40, session: "studio-s"), machine: "studio")
        store.apply(rec(3, session: "laptop-s"), machine: "laptop")
        #expect(store.lastSeq(for: "studio") == 40)
        #expect(store.lastSeq(for: "laptop") == 3)
        #expect(store.lastSeq(for: "never-heard-from") == 0)
    }

    @Test("A backfill that starts later than asked reports a gap")
    func reportsAGap() {
        let store = SessionEventStore()
        store.apply(backfill: [rec(10), rec(11)], oldestSeq: 10, sessionId: "s1", machine: mac)
        #expect(store.hasGap(sessionId: "s1", machine: mac, requestedFrom: 0))
    }

    @Test("A complete backfill reports no gap")
    func reportsNoGap() {
        let store = SessionEventStore()
        store.apply(backfill: [rec(1), rec(2)], oldestSeq: 1, sessionId: "s1", machine: mac)
        #expect(!store.hasGap(sessionId: "s1", machine: mac, requestedFrom: 0))
    }

    // The boundary, asserted from both sides. `events_since N` returns what
    // comes AFTER N, so an oldest of exactly N+1 is complete and N+2 is not.
    // Comparing against N instead of N+1 reports a gap on every first
    // connection — which is how the off-by-one was found.
    @Test("The gap boundary sits at requested + 1")
    func gapBoundary() {
        let flush = SessionEventStore()
        flush.apply(backfill: [rec(6)], oldestSeq: 6, sessionId: "s1", machine: mac)
        #expect(!flush.hasGap(sessionId: "s1", machine: mac, requestedFrom: 5))

        let missing = SessionEventStore()
        missing.apply(backfill: [rec(7)], oldestSeq: 7, sessionId: "s1", machine: mac)
        #expect(missing.hasGap(sessionId: "s1", machine: mac, requestedFrom: 5))
    }

    // Never having asked is not the same as having been told nothing is
    // missing. A store with no answer yet must not claim a hole.
    @Test("A session that has had no backfill answer reports no gap")
    func noAnswerMeansNoGapClaim() {
        let store = SessionEventStore()
        store.apply(rec(9), machine: mac)
        #expect(!store.hasGap(sessionId: "s1", machine: mac, requestedFrom: 0))
    }

    @Test("A backfill's own records land in the store")
    func backfillIsStored() {
        let store = SessionEventStore()
        store.apply(backfill: [rec(1), rec(2)], oldestSeq: 1, sessionId: "s1", machine: mac)
        #expect(store.events(sessionId: "s1", resumeId: nil).count == 2)
        #expect(store.lastSeq(for: mac) == 2)
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
