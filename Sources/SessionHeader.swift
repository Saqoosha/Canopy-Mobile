import SwiftUI

/// A conversation's navigation-bar header: the dot and title, then
/// "Working 3m · Canopy · main" — the roster row's facts, on the screen the
/// row opens. Shared by the live view and the offline view so a session reads
/// the same whichever one is on screen.
struct SessionHeader: ToolbarContent {
    let title: String
    /// Shown when the roster does not list the session — the machine, or
    /// "machine · project" frozen into the route.
    let subtitle: String
    /// The roster's live row, or nil when it does not list one. A nil pane
    /// draws no dot and no state — grey means idle in this palette, and "the
    /// roster doesn't list it" is not idle.
    let pane: PaneRow?

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // Ticks so the elapsed figure advances while you read. Only the
            // header is inside it — wrapping the transcript would re-evaluate
            // every rendered Markdown block once a second.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 1) {
                    HStack(spacing: 5) {
                        if let pane {
                            Circle()
                                .fill(SessionActivityStyle.color(for: pane.state))
                                .frame(width: 7, height: 7)
                        }
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    statusLine(now: context.date)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    /// **The state leads because the line truncates from the end.** With the
    /// project first, a long "project · branch" tail-truncated away the state,
    /// which is the part that changes while you read. Losing the project to
    /// truncation costs little: it is on the row you tapped to get here.
    ///
    /// The project comes from the roster when it lists the session, so a
    /// branch switch shows here; the route's subtitle is the fallback.
    private func statusLine(now: Date) -> Text {
        guard let pane else { return Text(subtitle).foregroundStyle(.secondary) }
        let age = SessionActivityStyle.elapsed(since: pane.stateSince, now: now)
        let project = pane.project.isEmpty ? subtitle : pane.project
        return Text("\(pane.state.capitalized) \(age)")
            .foregroundStyle(SessionActivityStyle.color(for: pane.state))
            + Text(" · \(project)").foregroundStyle(.secondary)
    }
}
