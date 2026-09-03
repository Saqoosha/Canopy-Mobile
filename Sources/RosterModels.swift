import Foundation

/// Mirrors `worker/src/types.ts`. The two are kept in step by hand; the
/// probe assertion in the Canopy repo pins the key names on the sending side.
struct PaneRow: Codable, Identifiable, Equatable {
    let sessionId: String
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
