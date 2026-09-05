import Foundation
import Testing
@testable import CanopyMobile

@MainActor
struct SessionEventStoreTests {
    private func rec(_ seq: Int,
                     session: String = "s1",
                     resume: String? = nil,
                     text: String = "x") -> SessionEventRecord {
        SessionEventRecord(seq: seq, eventId: "e\(seq)", sessionId: session,
                           resumeId: resume, kind: .assistant, text: text,
                           at: Date(timeIntervalSince1970: Double(seq)))
    }

    @Test("Events sort by seq however they arrive")
    func ordersBySeq() {
        let store = SessionEventStore()
        store.apply(rec(3))
        store.apply(rec(1))
        store.apply(rec(2))
        #expect(store.events(sessionId: "s1", resumeId: nil).map(\.seq) == [1, 2, 3])
    }

    // The backfill after a reconnect and the live fan-out routinely overlap,
    // so a repeat is the normal case rather than a fault.
    @Test("A repeated seq is dropped, and the first copy is the one kept")
    func dropsARepeatedSeq() {
        let store = SessionEventStore()
        store.apply(rec(1, text: "first"))
        store.apply(rec(1, text: "second"))
        let all = store.events(sessionId: "s1", resumeId: nil)
        #expect(all.count == 1)
        #expect(all.first?.text == "first")
    }

    @Test("lastSeq is the highest seen, not the most recent")
    func tracksTheHighestSeq() {
        let store = SessionEventStore()
        store.apply(rec(5))
        store.apply(rec(2))
        #expect(store.lastSeq == 5)
    }

    @Test("One session's events stay out of another's")
    func separatesSessions() {
        let store = SessionEventStore()
        store.apply(rec(1, session: "s1"))
        store.apply(rec(2, session: "s2"))
        #expect(store.events(sessionId: "s1", resumeId: nil).count == 1)
        #expect(store.events(sessionId: "s2", resumeId: nil).count == 1)
    }

    // sessionId is minted per Canopy process, so after a Mac restart it
    // matches nothing stored earlier — resumeId is what survives.
    @Test("resumeId wins over sessionId when both sides have one")
    func prefersResumeId() {
        let store = SessionEventStore()
        store.apply(rec(1, session: "old-process", resume: "R"))
        #expect(store.events(sessionId: "new-process", resumeId: "R").count == 1)
        #expect(store.events(sessionId: "new-process", resumeId: nil).isEmpty)
    }

    @Test("A backfill that starts later than asked reports a gap")
    func reportsAGap() {
        let store = SessionEventStore()
        store.apply(backfill: [rec(10), rec(11)], oldestSeq: 10, sessionId: "s1")
        #expect(store.hasGap(sessionId: "s1", requestedFrom: 0))
    }

    @Test("A complete backfill reports no gap")
    func reportsNoGap() {
        let store = SessionEventStore()
        store.apply(backfill: [rec(1), rec(2)], oldestSeq: 1, sessionId: "s1")
        #expect(!store.hasGap(sessionId: "s1", requestedFrom: 0))
    }

    // The boundary, asserted from both sides. `events_since N` returns what
    // comes AFTER N, so an oldest of exactly N+1 is complete and N+2 is not.
    // Comparing against N instead of N+1 reports a gap on every first
    // connection — which is how the off-by-one was found.
    @Test("The gap boundary sits at requested + 1")
    func gapBoundary() {
        let flush = SessionEventStore()
        flush.apply(backfill: [rec(6)], oldestSeq: 6, sessionId: "s1")
        #expect(!flush.hasGap(sessionId: "s1", requestedFrom: 5))

        let missing = SessionEventStore()
        missing.apply(backfill: [rec(7)], oldestSeq: 7, sessionId: "s1")
        #expect(missing.hasGap(sessionId: "s1", requestedFrom: 5))
    }

    // Never having asked is not the same as having been told nothing is
    // missing. A store with no answer yet must not claim a hole.
    @Test("A session that has had no backfill answer reports no gap")
    func noAnswerMeansNoGapClaim() {
        let store = SessionEventStore()
        store.apply(rec(9))
        #expect(!store.hasGap(sessionId: "s1", requestedFrom: 0))
    }

    @Test("A backfill's own records land in the store")
    func backfillIsStored() {
        let store = SessionEventStore()
        store.apply(backfill: [rec(1), rec(2)], oldestSeq: 1, sessionId: "s1")
        #expect(store.events(sessionId: "s1", resumeId: nil).count == 2)
        #expect(store.lastSeq == 2)
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
