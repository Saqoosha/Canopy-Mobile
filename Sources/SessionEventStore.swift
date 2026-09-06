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
        /// Whether the last backfill answer for that session said something
        /// inside the asked-for range had been thrown away.
        ///
        /// **A verdict, not the numbers behind it.** The relay decides this
        /// from facts only it has, and both halves arrive in the same
        /// message, so there is nothing here to pair up wrongly — an earlier
        /// design kept the "asked from" mark on this side and could compare
        /// it against a different exchange's answer.
        var gapReported: [String: Bool] = [:]
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

    /// Take a backfill answer: its records, and the relay's verdict on
    /// whether anything inside the asked-for range was thrown away.
    ///
    /// `since` and `evictedThrough` are optional because a relay deployed
    /// before they existed sends neither; two nils record no gap, which is
    /// the behaviour that preceded them.
    func apply(backfill: [SessionEventRecord], since: Int?, evictedThrough: Int?,
               sessionId: String, machine: String) {
        var slice = byMachine[machine] ?? MachineEvents()
        slice.gapReported[sessionId] = Self.isGap(evictedThrough: evictedThrough, since: since)
        byMachine[machine] = slice
        for record in backfill { apply(record, machine: machine) }
    }

    /// Whether the relay has told this store that part of what it asked for
    /// is gone for good.
    ///
    /// **Splicing a partial range on silently is the failure this exists to
    /// prevent** — the phone would render a conversation with a hole in it as
    /// though it were continuous. A store that has received no backfill
    /// answer for the session reports no gap: it has not been told.
    func hasGap(sessionId: String, machine: String) -> Bool {
        byMachine[machine]?.gapReported[sessionId] ?? false
    }

    /// The verdict, from the two numbers the relay sends with every answer.
    ///
    /// **`evictedThrough` is the highest seq of THIS SESSION the relay has
    /// deleted, so `> since` is exact rather than inferred**: that event
    /// belonged to this session, sat inside the range asked for, and is
    /// gone. The comparison this replaced comes with a cautionary tale — it
    /// used the oldest seq still held and asked whether it exceeded
    /// `since + 1`, which reads as an off-by-one puzzle and is really a
    /// category error. `seq` is one counter for the whole Mac, so a
    /// session's own events are not consecutive, and a session that merely
    /// started after another one reports an oldest seq well above what was
    /// asked for while having lost nothing. Nearly every session would have
    /// been told its history was missing. Caught in review before it
    /// reached a phone; the relay states the fact now instead.
    ///
    /// Either number missing means the relay predates the fact and cannot
    /// answer, which is not the same as answering no — but silence is the
    /// only honest rendering, and it is what the phone did before.
    static func isGap(evictedThrough: Int?, since: Int?) -> Bool {
        guard let evictedThrough, let since else { return false }
        return evictedThrough > since
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
