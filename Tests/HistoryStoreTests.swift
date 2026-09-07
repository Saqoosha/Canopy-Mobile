import Foundation
import Testing
@testable import CanopyMobile

/// The first coverage `HistoryStore` has had.
///
/// It had none because `containerURL()` asks the system for an App Group
/// container this bundle is not entitled to, so every function was unreachable
/// from here. The `in dir:` forms are that seam; these run against a temporary
/// directory and touch no container.
///
/// The cases below are the ones the file's own comments make claims about —
/// the duplicate-file loop, the per-file isolation, the tolerance in
/// `loadAll`, the prune order. Those claims were true and held by nothing.
struct HistoryStoreTests {
    /// A fresh directory per test. `HistoryStore` never creates it in the
    /// `in dir:` forms — that is `historyDirectory()`'s job — so this does.
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func item(id: String,
                      requestId: String? = nil,
                      at seconds: TimeInterval = 0,
                      kind: String = "asking") -> NotificationHistoryItem {
        NotificationHistoryItem(
            id: id, receivedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            title: "t", body: "b", machine: "m", sessionId: "s", kind: kind,
            requestId: requestId ?? id)
    }

    /// Write bytes that are not an item, under a filename `updateDecision` and
    /// `loadAll` will both pick up.
    private func writeCorrupt(id: String, at millis: Int64, in dir: URL) throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(millis)-\(id).json"))
    }

    /// Write an entry straight to a chosen filename, bypassing `append`.
    ///
    /// **`append` upserts, so it can no longer produce the duplicate files
    /// these tests are about.** History written before it did is still on
    /// disk, and `updateDecision` and `delete` still have to handle it — this
    /// is how that state gets built now.
    private func writeLegacyDuplicate(_ item: NotificationHistoryItem,
                                      at millis: Int64, in dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(item)
            .write(to: dir.appendingPathComponent("\(millis)-\(item.id).json"))
    }

    @Test("An appended item comes back")
    func appendRoundTrips() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "a"), in: dir)
        let loaded = try HistoryStore.loadAll(in: dir)
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == "a")
        #expect(loaded.first?.kind == "asking")
    }

    @Test("Entries load newest first, however they were written")
    func sortsNewestFirst() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "b", at: 20), in: dir)
        try HistoryStore.append(item(id: "a", at: 10), in: dir)
        try HistoryStore.append(item(id: "c", at: 30), in: dir)
        #expect(try HistoryStore.loadAll(in: dir).map(\.id) == ["c", "b", "a"])
    }

    // The asymmetry the file names: a reader that dies on one bad entry loses
    // the history it could have shown.
    @Test("An unreadable entry is skipped, not fatal")
    func loadAllSkipsUnreadable() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "a"), in: dir)
        try writeCorrupt(id: "bad", at: 1_700_000_001_000, in: dir)
        #expect(try HistoryStore.loadAll(in: dir).map(\.id) == ["a"])
    }

    @Test("A non-JSON file in the directory is ignored")
    func ignoresNonJSON() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "a"), in: dir)
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        #expect(try HistoryStore.loadAll(in: dir).count == 1)
    }

    @Test("An item is findable by id, and an unknown id is nil")
    func findsById() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "a"), in: dir)
        #expect(try HistoryStore.item(withId: "a", in: dir)?.id == "a")
        #expect(try HistoryStore.item(withId: "nope", in: dir) == nil)
    }

    // Legacy state: two files for one id, from before `append` upserted.
    @Test("Delete removes every file carrying the id")
    func deleteRemovesEveryCopy() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "dup", at: 10), in: dir)
        try writeLegacyDuplicate(item(id: "dup", at: 20), at: 1_700_000_020_000, in: dir)
        try HistoryStore.append(item(id: "other"), in: dir)
        #expect(try HistoryStore.loadAll(in: dir).count == 3)
        try HistoryStore.delete(id: "dup", in: dir)
        #expect(try HistoryStore.loadAll(in: dir).map(\.id) == ["other"])
    }

    @Test("Delete-all empties the directory")
    func deleteAllEmpties() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "a"), in: dir)
        try HistoryStore.append(item(id: "b"), in: dir)
        try HistoryStore.deleteAll(in: dir)
        #expect(try HistoryStore.loadAll(in: dir).isEmpty)
    }

    @Test("A decision is recorded")
    func recordsADecision() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "r1"), in: dir)
        let at = Date(timeIntervalSince1970: 1_700_000_100)
        try HistoryStore.updateDecision(requestId: "r1", decision: "Allow", decidedAt: at,
                                        delivered: true, in: dir)
        let stored = try #require(try HistoryStore.item(withId: "r1", in: dir))
        #expect(stored.decision == "Allow")
        #expect(stored.decisionDelivered == true)
        #expect(stored.decidedAt == at)
    }

    // **The bug four reviewers found by reading.** Updating only the first
    // match left the other at `decision == nil`, which draws as an unanswered
    // ask — and threw nothing, because one file WAS found.
    @Test("Every file with the requestId is updated, not just the first")
    func updatesEveryDuplicate() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "r1", at: 10), in: dir)
        try writeLegacyDuplicate(item(id: "r1", at: 20), at: 1_700_000_020_000, in: dir)
        try HistoryStore.updateDecision(requestId: "r1", decision: "Deny",
                                        decidedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                        delivered: false, in: dir)
        let loaded = try HistoryStore.loadAll(in: dir)
        #expect(loaded.count == 2)
        #expect(loaded.allSatisfy { $0.decision == "Deny" })
    }

    // Thrown rather than a silent no-op: a decision that went nowhere must not
    // leave the ask drawn as unanswered with nothing said about it.
    @Test("A requestId with no file behind it throws")
    func throwsWhenNothingMatches() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "other"), in: dir)
        #expect(throws: HistoryStore.StoreError.self) {
            try HistoryStore.updateDecision(requestId: "missing", decision: "Allow",
                                            decidedAt: Date(), delivered: true, in: dir)
        }
    }

    // The per-file `do/catch`. A `try` straight through the loop aborted on
    // the first unreadable duplicate, leaving the rest at `decision == nil`
    // and — the broadcast sitting after the loop — nothing told to reload.
    @Test("One unreadable duplicate does not stop the others being updated")
    func oneBadDuplicateDoesNotStopTheRest() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "r1", at: 10), in: dir)
        try writeCorrupt(id: "r1", at: 1_700_000_020_000, in: dir)
        try HistoryStore.updateDecision(requestId: "r1", decision: "Allow",
                                        decidedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                        delivered: true, in: dir)
        let loaded = try HistoryStore.loadAll(in: dir)
        #expect(loaded.count == 1)
        #expect(loaded.first?.decision == "Allow")
    }

    // Current behaviour, pinned so that changing it is a decision rather than
    // a side effect: a partial failure returns NORMALLY and the caller is not
    // told. The survivor keeps `decision == nil` and is still drawn as an
    // unanswered ask. Closing that needs a case carrying the counts (#28).
    @Test("A partial failure returns without throwing")
    func partialFailureIsSilent() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "r1", at: 10), in: dir)
        try writeCorrupt(id: "r1", at: 1_700_000_020_000, in: dir)
        // No throw, and no signal that one of the two files was not written.
        try HistoryStore.updateDecision(requestId: "r1", decision: "Allow",
                                        decidedAt: Date(), delivered: true, in: dir)
    }

    @Test("When no file can be updated the failure is thrown")
    func throwsWhenEveryWriteFails() throws {
        let dir = try makeDir()
        try writeCorrupt(id: "r1", at: 1_700_000_010_000, in: dir)
        try writeCorrupt(id: "r1", at: 1_700_000_020_000, in: dir)
        #expect(throws: (any Error).self) {
            try HistoryStore.updateDecision(requestId: "r1", decision: "Allow",
                                            decidedAt: Date(), delivered: true, in: dir)
        }
    }

    // `filename(for:)` is `<millis>-<id>.json`, so lexicographic order is
    // chronological order — which is what the prune sorts on.
    @Test("Appending past the cap drops the oldest entries")
    func prunesToTheCap() throws {
        let dir = try makeDir()
        let overflow = 3
        for i in 0..<(HistoryStore.maxItems + overflow) {
            try HistoryStore.append(item(id: String(format: "i%03d", i),
                                         at: TimeInterval(i)), in: dir)
        }
        let loaded = try HistoryStore.loadAll(in: dir)
        #expect(loaded.count == HistoryStore.maxItems)
        // The newest survives and the oldest `overflow` are gone.
        #expect(loaded.first?.id == String(format: "i%03d", HistoryStore.maxItems + overflow - 1))
        #expect(loaded.last?.id == String(format: "i%03d", overflow))
    }

    // MARK: - Upsert

    // One ask delivered twice used to become two files: a decision written to
    // one left the other drawn as unanswered, and two rows carrying the same
    // `ConversationRow.id` collide in the `ForEach` that renders them.
    @Test("Appending the same id twice leaves one entry")
    func appendUpsertsById() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "r1", at: 10), in: dir)
        try HistoryStore.append(item(id: "r1", at: 20), in: dir)
        #expect(try HistoryStore.files(for: "r1", in: dir).count == 1)
        #expect(try HistoryStore.loadAll(in: dir).count == 1)
    }

    // The first arrival is the one kept, and this is why: overwriting would
    // clear a decision already recorded here, redrawing an answered ask as
    // unanswered — the symptom the upsert exists to remove, by its own route.
    @Test("A recorded decision survives a re-delivery")
    func redeliveryDoesNotClearADecision() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "r1", at: 10), in: dir)
        try HistoryStore.updateDecision(requestId: "r1", decision: "Allow",
                                        decidedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                        delivered: true, in: dir)
        try HistoryStore.append(item(id: "r1", at: 20), in: dir)
        let stored = try #require(try HistoryStore.item(withId: "r1", in: dir))
        #expect(stored.decision == "Allow")
        #expect(stored.decisionDelivered == true)
    }

    @Test("The first arrival's time is the one kept")
    func keepsTheFirstArrivalTime() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "r1", at: 10), in: dir)
        try HistoryStore.append(item(id: "r1", at: 20), in: dir)
        #expect(try HistoryStore.item(withId: "r1", in: dir)?.receivedAt
            == Date(timeIntervalSince1970: 1_700_000_010))
    }

    // Closes the id collision for history already on disk. A delivery is the
    // only moment anything looks at those files.
    @Test("A delivery collapses duplicates left by an older build")
    func collapsesLegacyDuplicates() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "r1", at: 10), in: dir)
        try writeLegacyDuplicate(item(id: "r1", at: 20), at: 1_700_000_020_000, in: dir)
        try writeLegacyDuplicate(item(id: "r1", at: 30), at: 1_700_000_030_000, in: dir)
        #expect(try HistoryStore.files(for: "r1", in: dir).count == 3)

        try HistoryStore.append(item(id: "r1", at: 40), in: dir)
        let remaining = try HistoryStore.files(for: "r1", in: dir)
        #expect(remaining.count == 1)
        // The oldest is the survivor.
        #expect(remaining.first?.lastPathComponent == "1700000010000-r1.json")
    }

    // An entry nothing can read is not an entry: `loadAll` skips it forever.
    // A delivery is a chance to put a readable one back.
    @Test("A delivery repairs an entry that cannot be decoded")
    func repairsAnUnreadableEntry() throws {
        let dir = try makeDir()
        try writeCorrupt(id: "r1", at: 1_700_000_010_000, in: dir)
        #expect(try HistoryStore.loadAll(in: dir).isEmpty)
        try HistoryStore.append(item(id: "r1", at: 10), in: dir)
        #expect(try HistoryStore.loadAll(in: dir).map(\.id) == ["r1"])
        #expect(try HistoryStore.files(for: "r1", in: dir).count == 1)
    }

    @Test("Different ids still get their own entries")
    func distinctIdsAreNotCollapsed() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "a"), in: dir)
        try HistoryStore.append(item(id: "b"), in: dir)
        #expect(try HistoryStore.loadAll(in: dir).count == 2)
    }

    // A suffix match, not a substring one: `-r1.json` must not take `-xr1.json`.
    @Test("An id that ends with another id is a different entry")
    func doesNotMatchOnASuffixOfTheId() throws {
        let dir = try makeDir()
        try HistoryStore.append(item(id: "r1", at: 10), in: dir)
        try HistoryStore.append(item(id: "xr1", at: 20), in: dir)
        #expect(try HistoryStore.files(for: "r1", in: dir).count == 1)
        #expect(try HistoryStore.loadAll(in: dir).count == 2)
    }
}
