import Foundation
import Testing
@testable import CanopyMobile

struct MachineControlTests {
    @Test func recentSessionListSkipsMissingResumeId() {
        let result: [String: Any] = [
            "sessions": [
                ["resumeId": "a", "title": "Alpha", "project": "p", "cwd": "/a", "lastActiveAt": 1_700_000_000.0],
                ["title": "No id", "project": "p", "cwd": "/b", "lastActiveAt": 1_700_000_001.0],
                ["resumeId": "", "title": "Empty id", "project": "p", "cwd": "/c", "lastActiveAt": 1_700_000_002.0],
                ["resumeId": "b", "project": "q", "cwd": "/d", "lastActiveAt": 1_700_000_003],
            ],
        ]
        let sessions = RecentSession.list(from: result)
        #expect(sessions.count == 2)
        #expect(sessions[0].resumeId == "a")
        #expect(sessions[0].title == "Alpha")
        #expect(sessions[0].lastActiveAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(sessions[1].resumeId == "b")
        #expect(sessions[1].title == "Untitled")
        #expect(sessions[1].project == "q")
        #expect(sessions[1].lastActiveAt == Date(timeIntervalSince1970: 1_700_000_003))
    }

    @Test func recentSessionListEmptyTitleIsUntitled() {
        let result: [String: Any] = [
            "sessions": [
                ["resumeId": "x", "title": "", "project": "", "cwd": "", "lastActiveAt": 0],
            ],
        ]
        #expect(RecentSession.list(from: result).first?.title == "Untitled")
    }

    @Test func recentSessionListMissingSessionsKey() {
        #expect(RecentSession.list(from: [:]).isEmpty)
    }

    @Test func dirEntryList() {
        let result: [String: Any] = [
            "entries": [
                ["name": "src", "isDirectory": true],
                ["name": "README.md", "isDirectory": false],
                ["isDirectory": true],
                ["name": ""],
            ],
        ]
        let entries = DirEntry.list(from: result)
        #expect(entries == [
            DirEntry(name: "src", isDirectory: true),
            DirEntry(name: "README.md", isDirectory: false),
        ])
    }

    @Test func openRequestWireResume() throws {
        let wire = OpenRequest.resume.wire
        let data = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
        let roundTrip = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(roundTrip["kind"] as? String == "resume")
        #expect(roundTrip.count == 1)
    }

    @Test func openRequestWireNew() throws {
        let wire = OpenRequest.new(cwd: "/Users/me/proj").wire
        let data = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
        let roundTrip = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(roundTrip["kind"] as? String == "new")
        #expect(roundTrip["cwd"] as? String == "/Users/me/proj")
        let options = try #require(roundTrip["options"] as? [String: Any])
        #expect(options.isEmpty)
    }

    @Test func attachMessageOmitsOpenWhenNil() {
        let message = MirrorLink.attachMessage(sessionId: "s1", token: "tok")
        #expect(message["type"] as? String == "attach")
        #expect(message["sessionId"] as? String == "s1")
        #expect(message["token"] as? String == "tok")
        #expect(message["prefetch"] as? Bool == true)
        #expect(message["status"] as? Bool == true)
        #expect(message["compress"] as? String == MirrorWire.compressionName)
        #expect(!message.keys.contains("open"))
    }

    @Test func attachMessageIncludesOpenWhenSet() throws {
        let message = MirrorLink.attachMessage(sessionId: "s1", token: "tok", open: .resume)
        let open = try #require(message["open"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: open, options: [.sortedKeys])
        let roundTrip = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(roundTrip["kind"] as? String == "resume")

        let newMessage = MirrorLink.attachMessage(sessionId: "s2", token: "tok", open: .new(cwd: "/tmp"))
        let newOpen = try #require(newMessage["open"] as? [String: Any])
        #expect(newOpen["kind"] as? String == "new")
        #expect(newOpen["cwd"] as? String == "/tmp")
    }

    @Test func helloErrorsNameTheirCause() {
        #expect(MachineControl.helloError("unauthorized").message == "Password rejected")
        #expect(MachineControl.helloError("no control API here").message.contains("background service"))
        #expect(MachineControl.helloError("protocol version 2 is not 1").message.contains("different versions"))
        #expect(MachineControl.helloError("something else").message == "something else")
    }
}
