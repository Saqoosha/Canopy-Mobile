import Foundation
import Testing
@testable import CanopyMobile

/// The session name a push carries (`sessionTitle` in the payload, stored as
/// `sessionName`) names a History row once the roster no longer lists it.
@MainActor
struct HistorySessionNameTests {
    private func item(sessionName: String?, kind: String = "completed",
                      resumeId: String? = "r1") -> NotificationHistoryItem {
        NotificationHistoryItem(id: UUID().uuidString, receivedAt: Date(timeIntervalSince1970: 0),
                                title: "Canopy", body: "b", machine: "M",
                                sessionId: "s1", kind: kind, resumeId: resumeId,
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

    @Test func aSentRowAndAnOlderPushTakeTheNewestName() throws {
        let newestFirst = [item(sessionName: nil, kind: "sent", resumeId: nil),
                           item(sessionName: "Renamed"),
                           item(sessionName: "First")]
        let names = NotificationHistoryItem.pushedNames(newestFirst)
        let closed = try snapshots(paneTitle: nil)
        #expect(newestFirst.map { $0.sessionTitle(in: closed, names: names) } == ["Renamed", "Renamed", "Renamed"])
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
