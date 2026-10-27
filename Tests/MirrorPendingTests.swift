import Foundation
import Testing
@testable import CanopyMobile

struct MirrorPendingTests {
    @Test func onlyAnAttachThatOpensASessionAsksForPending() {
        #expect(MirrorLink.attachMessage(sessionId: "s", token: "t", open: .resume)["pending"] as? Bool == true)
        #expect(MirrorLink.attachMessage(sessionId: "s", token: "t", open: .new(cwd: "/tmp"))["pending"] as? Bool == true)
        #expect(MirrorLink.attachMessage(sessionId: "s", token: "t")["pending"] == nil)
    }

    @MainActor
    @Test func pendingIsRecordedAndNotPostedToThePage() {
        let link = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        var frames: [String] = []
        link.onFrame = { frames.append($0) }
        link.handleLine(Data(#"{"type":"attach_pending"}"#.utf8))
        #expect(link.sawAttachPending)
        #expect(!link.attachAnswered)
        #expect(frames.isEmpty)
    }

    @MainActor
    @Test func pendingAfterTheAnswerChangesNothing() {
        let link = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        link.handleLine(Data(#"{"type":"attach_ok","html":"<p>"}"#.utf8))
        link.handleLine(Data(#"{"type":"attach_pending"}"#.utf8))
        #expect(!link.sawAttachPending)
    }
}
