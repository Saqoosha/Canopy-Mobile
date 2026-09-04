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

    var id: String { sessionId }
}

struct MachineSnapshot: Codable, Equatable {
    let machineId: String
    let displayName: String
    let publishedAt: Int
    let sessionPct: Int
    let weeklyPct: Int
    let panes: [PaneRow]
}
