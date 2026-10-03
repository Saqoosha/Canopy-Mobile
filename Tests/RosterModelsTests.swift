import Foundation
import Testing
@testable import CanopyMobile

struct RosterModelsTests {
    @Test func missingLiveDefaultsToTrue() throws {
        let json = Data(#"{"sessionId":"s","paneIndex":0,"title":"","project":"","state":"idle","stateSince":0,"contextPct":0,"model":"","messageCount":0}"#.utf8)
        let row = try JSONDecoder().decode(PaneRow.self, from: json)
        #expect(row.isLive == true)
    }

    @Test func liveFalseIsNotLive() throws {
        let json = Data(#"{"sessionId":"s","paneIndex":0,"title":"","project":"","state":"idle","stateSince":0,"contextPct":0,"model":"","messageCount":0,"live":false}"#.utf8)
        let row = try JSONDecoder().decode(PaneRow.self, from: json)
        #expect(row.isLive == false)
    }
}

@Suite struct StopConfirmationTests {
    private func pane(_ state: String) -> PaneRow {
        PaneRow(sessionId: "s", resumeId: "r", paneIndex: 0, title: "T", project: "P", state: state,
                stateSince: 0, contextPct: 0, model: "", messageCount: 0, live: true)
    }

    @Test func workInFlightNeedsConfirmation() {
        for state in ["working", "background", "asking"] {
            #expect(RosterView.stopNeedsConfirmation(pane(state)), "\(state)")
        }
    }

    @Test func idleSessionsStopAtOnce() {
        for state in ["idle", "unread", "error", ""] {
            #expect(!RosterView.stopNeedsConfirmation(pane(state)), "\(state)")
        }
    }
}
