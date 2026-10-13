import Foundation
import Testing
@testable import CanopyMobile

struct MirrorStallTests {
    @Test func theFirstStallStartsTheBudgetAndLaterOnesKeepIt() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = MirrorStall.deadline(current: nil, now: now)
        #expect(first == now.addingTimeInterval(MirrorStall.budget))
        #expect(MirrorStall.deadline(current: first, now: now.addingTimeInterval(30)) == first)
    }

    @MainActor
    @Test func anAnswerFromTheMacIsNeverAStall() {
        let accepted = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        #expect(!accepted.attachAnswered)
        accepted.handleLine(Data(#"{"type":"attach_ok","html":"<p>"}"#.utf8))
        #expect(accepted.attachAnswered)
        #expect(!accepted.stalledBeforeAttach)

        let refused = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        refused.handleLine(Data(#"{"type":"attach_error","message":"no such session"}"#.utf8))
        #expect(refused.attachAnswered)
        #expect(!refused.stalledBeforeAttach)
    }
}
