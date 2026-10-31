import Foundation
import Testing
@testable import CanopyMobile

struct SessionHeaderTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func pane(project: String) -> PaneRow {
        PaneRow(sessionId: "s", resumeId: "r", paneIndex: 0, title: "T", project: project, state: "working",
                stateSince: 820, contextPct: 0, model: "", messageCount: 0, live: true)
    }

    @Test func theStateLeadsAndTheRosterProjectReplacesTheSubtitle() {
        let parts = SessionHeader.statusParts(pane: pane(project: "Canopy · main"), subtitle: "Mac Studio", now: now)
        #expect(parts.state == "Working 3m")
        #expect(parts.rest == "Canopy · main")
    }

    @Test func anEmptyRosterProjectFallsBackToTheSubtitle() {
        let parts = SessionHeader.statusParts(pane: pane(project: ""), subtitle: "Mac Studio", now: now)
        #expect(parts.rest == "Mac Studio")
    }

    @Test func noPaneShowsNoStateRatherThanGuessing() {
        let parts = SessionHeader.statusParts(pane: nil, subtitle: "Mac Studio", now: now)
        #expect(parts.state == nil)
        #expect(parts.rest == "Mac Studio")
    }
}

struct SessionMenuTests {
    @Test func anEmptyMenuDrawsNoButton() {
        #expect(SessionMenu.items(hasSlack: false, showingLive: false, canAttach: false).isEmpty)
    }

    @Test func slackIsOfferedWithoutAttaching() {
        #expect(SessionMenu.items(hasSlack: true, showingLive: false, canAttach: false) == [.slack])
    }

    @Test func theOfflineViewOffersLiveOnlyWhenItCanAttach() {
        #expect(SessionMenu.items(hasSlack: false, showingLive: false, canAttach: true) == [.openLive])
    }

    @Test func theLiveViewOffersTheOfflineView() {
        #expect(SessionMenu.items(hasSlack: false, showingLive: true, canAttach: true) == [.showOffline])
        #expect(SessionMenu.items(hasSlack: true, showingLive: true, canAttach: true) == [.slack, .showOffline])
    }
}
