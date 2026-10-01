import Foundation
import Testing
@testable import CanopyMobile

struct MirrorRestartTests {
    @Test func attachDeclaresThatThePhoneReattachesAfterARestart() {
        let message = MirrorLink.attachMessage(sessionId: "s1", token: "tok")
        #expect(message["restart"] as? Bool == true)
    }

    @MainActor
    @Test func theRestartNoticeReachesOnRestartingAndNotThePage() {
        let link = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        var notices = 0
        var frames: [String] = []
        link.onRestarting = { notices += 1 }
        link.onFrame = { frames.append($0) }
        link.handleLine(Data(#"{"type":"daemon_restarting"}"#.utf8))
        #expect(notices == 1)
        #expect(frames.isEmpty)
    }

    @Test func retriesOnlyInsideTheWindowAfterANotice() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(!MirrorRestart.shouldRetry(until: nil, now: now))
        #expect(MirrorRestart.shouldRetry(until: now.addingTimeInterval(1), now: now))
        #expect(!MirrorRestart.shouldRetry(until: now, now: now))
    }

    @Test func aRestartReattachAsksTheNewServiceToResume() {
        let attached = MirrorLiveView.Attach(sessionId: "s1", open: nil, key: "old-key")
        let next = MirrorLiveView.afterRestart(attached)
        #expect(next.sessionId == "s1")
        #expect(next.open == .resume)
    }
}
