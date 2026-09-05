import SwiftUI

/// How a session's activity is drawn — one definition, used by the roster
/// list and by a conversation's header.
///
/// It lived inside `RosterView` as a private function until the conversation
/// header needed the same dot. Two copies of a colour table drift, and the
/// whole point of these values is that a state looks the same everywhere it
/// is shown — including on the Mac, whose `SessionActivity.dotRGB` these are
/// copied from digit for digit (they were tuned against the MacroPad's LEDs;
/// see Canopy's "Key Learnings (MacroPad)"). Diff against that file when
/// either side is retuned.
enum SessionActivityStyle {
    /// The wire's `state` string, straight off `PaneRow.state`.
    static func color(for state: String) -> Color {
        switch state {
        case "working": Color(red: 0.00, green: 0.62, blue: 0.72)
        case "background": Color(red: 0.30, green: 0.24, blue: 0.90)
        case "asking": Color(red: 0.98, green: 0.52, blue: 0.11)
        case "unread": Color(red: 0.20, green: 0.66, blue: 0.13)
        case "error": Color(red: 0.88, green: 0.24, blue: 0.22)
        default: Color(red: 0.62, green: 0.62, blue: 0.62)
        }
    }

    /// Time in a state. "40m asking" and "asking" mean entirely different
    /// things, which is why the snapshot carries a stamp rather than a flag.
    /// `max(0, …)` stays for genuine clock skew between a Mac and a phone.
    static func elapsed(since unix: Int, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970) - unix)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    /// How long ago a Mac last published, for the section header.
    ///
    /// **No seconds.** The header sits over a `TimelineView` that ticks once
    /// a second, and with `elapsed` in it the line re-read "5s ago", "6s ago",
    /// "7s ago" — a counter running in the corner of a screen you are trying
    /// to read, reporting a fact nobody acts on at that resolution. Under a
    /// minute it is "just now"; from there it steps by the minute, which is
    /// also the coarsest unit `elapsed` already uses for a session's state.
    static func published(since unix: Int, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970) - unix)
        return seconds < 60 ? "just now" : "\(elapsed(since: unix, now: now)) ago"
    }
}
