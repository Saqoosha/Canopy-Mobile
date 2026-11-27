import Foundation

/// Mirrors `worker/src/types.ts`. The two are kept in step by hand; the
/// probe assertion in the Canopy repo pins the key names on the sending side.
struct PaneRow: Codable, Identifiable, Equatable {
    let sessionId: String
    /// The CLI's own session id, stable across Canopy restarts. Optional: it
    /// is backfilled a moment after spawn, so a pane published in that window
    /// has none and the phone falls back to `sessionId`.
    let resumeId: String?
    let paneIndex: Int
    let title: String
    let project: String
    let state: String
    let stateSince: Int
    let contextPct: Int
    let model: String
    let messageCount: Int
    /// Whether the Mac can accept a live attach for this session right now.
    /// Nil from a Mac older than the flag, read as true so nothing changes there.
    let live: Bool?
    var isLive: Bool { live ?? true }
    /// What the session last asked for or said, one line, as the Mac sidebar shows it.
    /// Nil from a Mac older than the field (before 2026-11-21) and while there is none.
    var attentionLine: String? = nil
    /// The session's registered long job, measured on the Mac. Nil while none.
    var job: PaneJob? = nil

    var id: String { sessionId }
}

/// `worker/src/types.ts` `PaneJob`; Canopy's `JobSnapshot`. Times are unix seconds.
struct PaneJob: Codable, Equatable {
    let label: String
    let done: Int
    let total: Int
    /// Present only while `state` is "running".
    var etaAt: Int? = nil
    /// "measuring", "running", "stalled", "unknown" or "done".
    let state: String
    /// Present only while `state` is "stalled".
    var stalledSince: Int? = nil
    var note: String? = nil
}

struct MachineSnapshot: Codable, Equatable {
    let machineId: String
    let displayName: String
    let publishedAt: Int
    let sessionPct: Int
    let weeklyPct: Int
    let panes: [PaneRow]
    /// False when the Mac's account has no 5-hour window (verified Ultra).
    /// Nil from a Mac older than the field, read as true.
    var hasSessionWindow: Bool? = nil
}
