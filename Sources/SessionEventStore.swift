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

    /// What the event is.
    ///
    /// **Decoding is deliberately total: an unrecognised value becomes
    /// `.other` rather than throwing.** A backfill answer decodes as an
    /// ARRAY, so a strict enum turned one unknown kind into the loss of the
    /// whole page — up to `maxEventsPerSession` events — and the phone drew
    /// a conversation missing everything the relay had just sent. The blast
    /// radius was wildly out of proportion to the cause, and the cause is
    /// the ordinary one: Canopy ships before this app does, so a kind this
    /// build has never heard of is the expected steady state after a Mac
    /// update, not a corruption.
    ///
    /// The relay is deliberately NOT the place this is handled. It is a
    /// pipe; validating there would make a relay deploy a prerequisite for
    /// Canopy emitting anything new, which is the wrong way round — the Mac
    /// is what ships first. See Canopy-Mobile#25.
    enum Kind: Codable, Sendable, Hashable {
        case assistant, user, tool, turnStart, turnEnd
        /// A kind this build does not know, carried verbatim. It still has
        /// `text`, so it can be drawn as a neutral one-liner; what it must
        /// never do is borrow another kind's presentation and claim the Mac
        /// said something it did not.
        case other(String)

        var rawValue: String {
            switch self {
            case .assistant: return "assistant"
            case .user: return "user"
            case .tool: return "tool"
            case .turnStart: return "turnStart"
            case .turnEnd: return "turnEnd"
            case .other(let raw): return raw
            }
        }

        init(rawValue: String) {
            switch rawValue {
            case "assistant": self = .assistant
            case "user": self = .user
            case "tool": self = .tool
            case "turnStart": self = .turnStart
            case "turnEnd": self = .turnEnd
            default: self = .other(rawValue)
            }
        }

        init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
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
        /// The seq the most recent `events_since` for that session asked
        /// from. Half of the gap comparison, and it has to be stored beside
        /// the other half rather than held by the view that asked: since
        /// Canopy-Mobile#24 a session is re-asked for whenever its socket
        /// opens, so the view's own number goes stale the moment a reconnect
        /// asks again from a higher mark — and a stale LOW number makes
        /// `oldest > requested + 1` fire on a session that missed nothing.
        var requestedFrom: [String: Int] = [:]
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

    /// Record that an `events_since` for this session went out from `seq`.
    ///
    /// Called on every ask, including one the app could not deliver because
    /// no socket was up. That costs nothing and keeps this at one call site
    /// per ask: a request with no answer leaves `oldestHeld` unset, and
    /// `hasGap` needs both halves, so an undelivered ask cannot produce a
    /// verdict on its own.
    func noteRequest(sessionId: String, machine: String, since seq: Int) {
        var slice = byMachine[machine] ?? MachineEvents()
        slice.requestedFrom[sessionId] = seq
        byMachine[machine] = slice
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
    ///
    /// **The one state it cannot report is a session evicted in full, and
    /// that is a limit of the data rather than an omission.** The relay
    /// answers with the oldest seq it still holds FOR THAT SESSION, so a
    /// session with no rows left reports `0` — the same answer as a session
    /// that has never emitted anything. Nothing distinguishes them from
    /// here, so this returns `false` and the view falls through to its empty
    /// state. Reporting a gap on `0` would be a claim the store cannot back:
    /// it would fire on every genuinely new session.
    /// A store that has asked but not yet been answered — or been answered
    /// without having asked, which a live `event` frame does — reports no
    /// gap: both halves have to be present before there is a comparison to
    /// make.
    func hasGap(sessionId: String, machine: String) -> Bool {
        guard let slice = byMachine[machine],
              let oldest = slice.oldestHeld[sessionId],
              let requested = slice.requestedFrom[sessionId]
        else { return false }
        return Self.isGap(oldestHeld: oldest, requestedFrom: requested)
    }

    /// The comparison itself, separated from where the two numbers are kept
    /// so it can be asserted on directly. Everything the doc above argues
    /// about — the `+ 1`, and `0` meaning "cannot tell" rather than "gone" —
    /// is decided here.
    ///
    /// **The zero guard is unreachable given every caller today, and is kept
    /// as a statement rather than as a check.** Marks come from `lastSeq`,
    /// which is never negative, and `0 > requested + 1` is already false for
    /// every non-negative `requested` — so deleting the guard changes no
    /// answer, and a mutation run confirmed it: the suite stays green
    /// without it. It stays because the alternative is a rule that holds
    /// only by arithmetic coincidence, and the next edit to the comparison
    /// would silently take "0 means cannot tell" with it.
    static func isGap(oldestHeld oldest: Int, requestedFrom requested: Int) -> Bool {
        guard oldest > 0 else { return false }
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
