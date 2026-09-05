import Foundation
import Observation

/// One thing that happened in a session, as the relay delivered it.
///
/// `id` is the `eventId`, **not the `seq`**. The two identify different
/// things: `seq` is the relay's ordering number, used for sorting and for
/// asking "everything after this"; `eventId` is minted by Canopy and also
/// rides on the `completed` push, which makes it the only key that can say a
/// notification and an event are the same turn.
struct SessionEventRecord: Codable, Identifiable, Hashable, Sendable {
    let seq: Int
    let eventId: String
    let sessionId: String
    let resumeId: String?
    let kind: Kind
    let text: String
    let at: Date

    var id: String { eventId }

    enum Kind: String, Codable, Sendable {
        case assistant, user, tool, turnStart, turnEnd
    }
}

/// Holds the events received over the watch socket.
///
/// **This is not a durable store, and must never be used as one.** It lives
/// for the app's lifetime and holds only what the relay's ring buffer still
/// had; `HistoryStore` is the durable record, survives a relaunch, and is
/// readable offline. Neither replaces the other — the conversation view draws
/// both, merged.
@Observable
@MainActor
final class SessionEventStore {
    /// Keyed by `seq`, so a record arriving twice cannot appear twice. The
    /// backfill after a reconnect and the live fan-out routinely overlap.
    private var bySeq: [Int: SessionEventRecord] = [:]

    /// The oldest seq the relay reported holding, per session. Only a
    /// backfill answer carries this, so it stays nil until one arrives.
    private var oldestHeld: [String: Int] = [:]

    /// The highest seq seen. Sent as `events_since` on the next request, so
    /// the relay returns only what this store is missing.
    private(set) var lastSeq: Int = 0

    func apply(_ record: SessionEventRecord) {
        // First writer wins. A second copy of one seq is the relay repeating
        // itself, not a new fact.
        if bySeq[record.seq] == nil { bySeq[record.seq] = record }
        lastSeq = max(lastSeq, record.seq)
    }

    func apply(backfill: [SessionEventRecord], oldestSeq: Int, sessionId: String) {
        oldestHeld[sessionId] = oldestSeq
        for record in backfill { apply(record) }
    }

    /// Whether everything between what was asked for and what came back is
    /// gone for good.
    ///
    /// **Splicing a partial range on silently is the failure this exists to
    /// prevent** — the phone would render a conversation with a hole in it as
    /// though it were continuous. A store that has never received a backfill
    /// answer reports no gap: it has not asked, so it has not been told.
    /// The comparison is against `requested + 1`, not `requested`, and the
    /// off-by-one is the whole content of this function: `events_since N`
    /// means "everything AFTER N", so an oldest held seq of exactly `N + 1`
    /// is a complete answer with nothing missing. Comparing against
    /// `requested` reports a gap on every first connection.
    func hasGap(sessionId: String, requestedFrom requested: Int) -> Bool {
        guard let oldest = oldestHeld[sessionId], oldest > 0 else { return false }
        return oldest > requested + 1
    }

    /// One session's events in relay order.
    ///
    /// Matched on `resumeId` when both sides have one, exactly as the
    /// notification history is: `sessionId` is minted per Canopy process, so
    /// a Mac restart orphans everything stored under the old one.
    func events(sessionId: String, resumeId: String?) -> [SessionEventRecord] {
        bySeq.values
            .filter { record in
                if let resumeId, let theirs = record.resumeId { return theirs == resumeId }
                return record.sessionId == sessionId
            }
            .sorted { $0.seq < $1.seq }
    }
}
