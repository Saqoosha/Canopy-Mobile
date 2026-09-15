import Foundation

/// The Mac's status bar for the attached session, as the Mac's `status` line carries it.
///
/// Display-ready: the percentage and level are the Mac's own, computed from the CLI's
/// thresholds there. Only a Mac told `"status": true` at attach sends it; from an
/// older Mac the line never arrives and the bar stays hidden.
///
/// The line's raw context numbers are for a Mac's mirror pane and are not read here.
struct MirrorStatus: Equatable {
    enum ContextLevel: String {
        case unknown, ok, warn, compact, blocked
    }

    var branch: String
    /// "git", "jj" or "" when the Mac could not tell.
    var vcs: String
    var contextUsed: Int
    /// The CLI's compact level; 0 while the Mac has no window yet, which is when it hides the meter too.
    var contextWindow: Int
    var contextPct: Int
    var contextLevel: ContextLevel
    var didCompact: Bool
    var remoteHost: String?

    /// nil for a frame missing the fields every Mac that sends the line writes.
    init?(frame: [String: Any]) {
        guard frame["type"] as? String == "status",
              let branch = frame["branch"] as? String,
              let contextUsed = frame["contextUsed"] as? Int,
              let contextWindow = frame["contextWindow"] as? Int,
              let contextPct = frame["contextPct"] as? Int
        else { return nil }
        self.branch = branch
        self.vcs = frame["vcs"] as? String ?? ""
        self.contextUsed = contextUsed
        self.contextWindow = contextWindow
        self.contextPct = contextPct
        // A level this build does not know reads as `.unknown`, whose tint falls back to the percentage.
        self.contextLevel = ContextLevel(rawValue: frame["contextLevel"] as? String ?? "") ?? .unknown
        self.didCompact = frame["didCompact"] as? Bool ?? false
        self.remoteHost = frame["remoteHost"] as? String
    }

    var hasContext: Bool { contextWindow > 0 }

    /// True when the bar would draw nothing: no branch, no meter, no remote host.
    var isEmpty: Bool { branch.isEmpty && !hasContext && remoteHost == nil }

    /// How the meter reads, without the view's colour names.
    enum Tint { case calm, warn, alert }

    /// `.unknown` falls back to the percentage cutoffs, as the Mac's `StatusBarData.tint(for:pct:)` does.
    var tint: Tint {
        switch contextLevel {
        case .unknown: contextPct >= 80 ? .alert : (contextPct >= 50 ? .warn : .calm)
        case .ok: .calm
        case .warn: .warn
        case .compact, .blocked: .alert
        }
    }

    /// Fill for a fixed-width track. `contextPct` is unclamped (it can pass 100), so the clamp is here.
    static func barFillWidth(pct: Int, track: CGFloat, minimum: CGFloat) -> CGFloat {
        let fill = track * CGFloat(min(pct, 100)) / 100
        return fill > 0 ? min(track, max(minimum, fill)) : 0
    }

    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
