import Foundation
import Observation

/// One thing that happened in a session, as the relay delivered it.
///
/// `id` is the `eventId`, **not the `seq`**. The two identify different
/// things: `seq` is the relay's ordering number, used for sorting and for
/// asking "everything after this"; `eventId` is minted by Canopy — or, for a
/// reply typed on this phone, by this phone — and also rides on the push or
/// the local record, which makes it the only key that can say two rows are
/// the same turn.
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

/// Holds the events received over the watch sockets.
///
/// **This is not a durable store, and must never be used as one.** It lives
/// for the app's lifetime and holds only what the relay's ring buffer still
/// had; `HistoryStore` is the durable record, survives a relaunch, and is
/// readable offline. Neither replaces the other — the conversation view draws
/// both, merged.
///
/// **Everything here is keyed by machine as well as seq.** A `seq` is minted
/// per Durable Object, and there is one object per Mac, so two Macs both
/// produce a seq 1, a seq 2, and so on. The first version keyed on seq alone
/// and would have let a Studio event overwrite a MacBook event that happened
/// to share its number — and would have asked the MacBook's relay to resume
/// from the Studio's high-water mark.
@Observable
@MainActor
final class SessionEventStore {
    /// One Mac's slice of the store.
    private struct MachineEvents {
        /// Keyed by `seq`, so a record arriving twice cannot appear twice.
        /// The backfill after a reconnect and the live fan-out overlap.
        var bySeq: [Int: SessionEventRecord] = [:]
        /// The oldest seq the relay reported holding, per session.
        var oldestHeld: [String: Int] = [:]
        // **No per-Mac high-water mark lives here on purpose.** There was
        // one, and it is the exact notion `lastSeq(sessionId:)` replaced: the
        // relay resumes per session, so a Mac-wide maximum asks one session
        // to resume from another session's progress. A correctly-maintained
        // field of that shape is a loaded gun — the next reader finds it,
        // uses it, and reintroduces the bug with a comment vouching for it.
        // Two reviewers said so independently.
    }

    /// How many events one session keeps on the phone. Mirrors the relay's
    /// own cap so a long foreground run cannot grow past what a backfill
    /// would have delivered anyway; older ones are dropped, newest kept.
    static let maxEventsPerSession = 200

    private var byMachine: [String: MachineEvents] = [:]

    /// The highest seq seen for ONE SESSION on one Mac — what to send as
    /// `events_since` when opening that session. Zero when nothing has
    /// arrived for it yet, which asks for everything the buffer holds.
    ///
    /// **Per session, not per Mac, because the relay filters per session.**
    /// `seq` is minted per Durable Object — one per Mac — so a Mac-wide high
    /// water mark is a number from whichever session happened to be busiest.
    /// Asking `events_since` with it returns `WHERE session_id = ? AND seq >
    /// ?`, so a session whose events all sit below that mark comes back
    /// empty and its history never arrives. Found by three reviewers on the
    /// first version, which did exactly that.
    ///
    /// **And matched on `sessionId` EXACTLY — deliberately not through
    /// `events(sessionId:resumeId:)`.** That reader is resumeId-first, which
    /// is right for deciding what to DRAW (a Canopy restart mints a new
    /// sessionId and the old rows still belong to this conversation) and
    /// wrong for deciding what to ASK, because the relay answers
    /// `WHERE session_id = ? AND seq > ?` and knows nothing about resumeId.
    /// Taking the mark across both ids returned a seq the relay would never
    /// have counted for the id being asked about, so the request came back
    /// empty. Found in the verification round, on the fix for the per-Mac
    /// version of this same mismatch.
    func lastSeq(sessionId: String, resumeId _: String? = nil) -> Int {
        byMachine.values
            .flatMap { $0.bySeq.values }
            .filter { $0.sessionId == sessionId }
            .map(\.seq)
            .max() ?? 0
    }

    func apply(_ record: SessionEventRecord, machine: String) {
        var slice = byMachine[machine] ?? MachineEvents()
        // First writer wins. A second copy of one seq is the relay repeating
        // itself, not a new fact.
        if slice.bySeq[record.seq] == nil {
            slice.bySeq[record.seq] = record
            Self.trim(&slice, sessionId: record.sessionId)
        }
        byMachine[machine] = slice
    }

    func apply(backfill: [SessionEventRecord], oldestSeq: Int, sessionId: String, machine: String) {
        var slice = byMachine[machine] ?? MachineEvents()
        slice.oldestHeld[sessionId] = oldestSeq
        byMachine[machine] = slice
        for record in backfill { apply(record, machine: machine) }
    }

    /// Whether everything between what was asked for and what came back is
    /// gone for good.
    ///
    /// **Splicing a partial range on silently is the failure this exists to
    /// prevent** — the phone would render a conversation with a hole in it as
    /// though it were continuous. A store that has never received a backfill
    /// answer reports no gap: it has not asked, so it has not been told.
    ///
    /// The comparison is against `requested + 1`, not `requested`, and the
    /// off-by-one is the whole content of this function: `events_since N`
    /// means "everything AFTER N", so an oldest held seq of exactly `N + 1`
    /// is a complete answer with nothing missing. Comparing against
    /// `requested` reports a gap on every first connection.
    func hasGap(sessionId: String, machine: String, requestedFrom requested: Int) -> Bool {
        guard let oldest = byMachine[machine]?.oldestHeld[sessionId], oldest > 0 else { return false }
        return oldest > requested + 1
    }

    /// One session's events in relay order.
    ///
    /// Not scoped by machine: a session id is a UUID and belongs to exactly
    /// one Mac, so filtering by session already selects the machine. Matched
    /// on `resumeId` when both sides have one, exactly as the notification
    /// history is: `sessionId` is minted per Canopy process, so a Mac restart
    /// orphans everything stored under the old one.
    func events(sessionId: String, resumeId: String?) -> [SessionEventRecord] {
        byMachine.values
            .flatMap { $0.bySeq.values }
            .filter { record in
                if let resumeId, let theirs = record.resumeId { return theirs == resumeId }
                return record.sessionId == sessionId
            }
            .sorted { $0.seq < $1.seq }
    }

    /// Drop the oldest of one session once it passes the cap. Runs on every
    /// insert, so the slice is never more than one over.
    private static func trim(_ slice: inout MachineEvents, sessionId: String) {
        let mine = slice.bySeq.values.filter { $0.sessionId == sessionId }
        guard mine.count > maxEventsPerSession else { return }
        let excess = mine.sorted { $0.seq < $1.seq }.prefix(mine.count - maxEventsPerSession)
        for record in excess { slice.bySeq.removeValue(forKey: record.seq) }
    }
}
