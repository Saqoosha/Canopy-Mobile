import Foundation

/// How a job looks on a roster row. Its strings match Canopy's `JobDisplay` (Sources/Canopy/Jobs/JobDisplay.swift);
/// diff the two when either changes. Unlike the Mac, a finished job keeps showing 完了.
/// A display-level override only: `PaneRow.state` keeps its meaning everywhere else.
enum JobDisplay {
    /// `H:mm` today, `明日 H:mm` tomorrow, `M/d H:mm` after that.
    static func timeLabel(_ eta: Date, now: Date, calendar: Calendar = .current) -> String {
        let clock = String(format: "%d:%02d", calendar.component(.hour, from: eta), calendar.component(.minute, from: eta))
        if calendar.isDate(eta, inSameDayAs: now) { return clock }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(eta, inSameDayAs: tomorrow) {
            return "明日 \(clock)"
        }
        return "\(calendar.component(.month, from: eta))/\(calendar.component(.day, from: eta)) \(clock)"
    }

    static func trailing(_ job: PaneJob, now: Date, calendar: Calendar = .current)
        -> (top: String, bottom: String?, isAlert: Bool) {
        switch job.state {
        case "running":
            let top = job.etaAt.map { timeLabel(Date(timeIntervalSince1970: TimeInterval($0)), now: now, calendar: calendar) }
            return (top ?? "計測中", percent(job), false)
        case "measuring":
            return ("計測中", percent(job), false)
        case "stalled":
            return ("停止", job.stalledSince.map { SessionActivityStyle.elapsed(since: $0, now: now) }, true)
        case "done":
            return ("完了", nil, false)
        default:
            return ("—", nil, false)
        }
    }

    static func stalledLine(_ job: PaneJob) -> String {
        "\(job.done)/\(job.total) で止まっている"
    }

    static func fraction(_ job: PaneJob) -> Double {
        job.total > 0 ? min(1, Double(job.done) / Double(job.total)) : 0
    }

    static func drawsRing(_ job: PaneJob?) -> Bool {
        guard let job else { return false }
        return job.state != "done"
    }

    /// The wire state the dot and ring are drawn in: asking and error keep their own color,
    /// a stall reads as error, and a job behind an idle session reads as background.
    static func ringState(_ state: String, job: PaneJob?) -> String {
        guard let job, drawsRing(job) else { return state }
        if state == "asking" || state == "error" { return state }
        if job.state == "stalled" { return "error" }
        return ["idle", "unread", "empty", ""].contains(state) ? "background" : state
    }

    /// A stalled job puts the row with the ones that need the user.
    static func needsAttention(_ pane: PaneRow) -> Bool {
        pane.job?.state == "stalled"
    }

    private static func percent(_ job: PaneJob) -> String? {
        job.total > 0 ? "\(Int(fraction(job) * 100))%" : nil
    }
}
