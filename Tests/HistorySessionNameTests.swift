import Foundation
import Testing
@testable import CanopyMobile

/// The session name a push carries (`sessionTitle` in the payload, stored as
/// `sessionName`) names a History row once the roster no longer lists it.
@MainActor
struct HistorySessionNameTests {
    private func item(sessionName: String?) -> NotificationHistoryItem {
        NotificationHistoryItem(id: "h1", receivedAt: Date(timeIntervalSince1970: 0),
                                title: "Canopy", body: "b", machine: "M",
                                sessionId: "s1", kind: "completed", resumeId: "r1",
                                sessionName: sessionName)
    }

    private func snapshots(paneTitle: String?) throws -> [String: MachineSnapshot] {
        let panes = paneTitle.map {
            #"[{"sessionId":"s1","resumeId":"r1","paneIndex":0,"title":"\#($0)","project":"p","state":"idle","stateSince":0,"contextPct":0,"model":"m","messageCount":0}]"#
        } ?? "[]"
        let json = #"{"machineId":"M","displayName":"Mac","publishedAt":0,"sessionPct":0,"weeklyPct":0,"panes":\#(panes)}"#
        return ["M": try JSONDecoder().decode(MachineSnapshot.self, from: Data(json.utf8))]
    }

    @Test func rosterNameWinsWhileListed() throws {
        #expect(item(sessionName: "Pushed").sessionTitle(in: try snapshots(paneTitle: "Live")) == "Live")
    }

    @Test func pushedNameNamesAClosedSession() throws {
        #expect(item(sessionName: "Pushed").sessionTitle(in: try snapshots(paneTitle: nil)) == "Pushed")
        #expect(item(sessionName: nil).sessionTitle(in: try snapshots(paneTitle: nil)) == nil)
    }

    @Test func anItemStoredBeforeTheFieldStillDecodes() throws {
        let stored = try JSONEncoder().encode(item(sessionName: nil))
        var object = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        object.removeValue(forKey: "sessionName")
        let old = try JSONDecoder().decode(NotificationHistoryItem.self,
                                           from: JSONSerialization.data(withJSONObject: object))
        #expect(old.sessionName == nil)
    }
}
