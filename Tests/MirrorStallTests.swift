import Foundation
import Testing
@testable import CanopyMobile

struct MirrorStallTests {
    @Test func onlyANetworkFailureAfterReachingTheMacAndBeforeItsAnswerIsAStall() {
        #expect(MirrorStall.isStall(failedOnNetwork: true, reachedMac: true, answered: false))
        // A Mac never reached: asleep or off the tailnet, which a minute of retries does not fix.
        #expect(!MirrorStall.isStall(failedOnNetwork: true, reachedMac: false, answered: false))
        // A drop after the answer belongs to `BackgroundReturn`.
        #expect(!MirrorStall.isStall(failedOnNetwork: true, reachedMac: true, answered: true))
        // Something the Mac said (an empty page, an unreadable line).
        #expect(!MirrorStall.isStall(failedOnNetwork: false, reachedMac: true, answered: false))
    }

    @Test func theFirstStallStartsTheBudgetAndLaterOnesKeepItUntilItEnds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = MirrorStall.next(current: nil, now: now)
        #expect(first == now.addingTimeInterval(MirrorStall.budget))
        #expect(MirrorStall.next(current: first, now: now.addingTimeInterval(30)) == first)
        #expect(MirrorStall.next(current: first, now: now.addingTimeInterval(MirrorStall.budget)) == nil)
    }

    @Test func theBudgetLeavesRoomForSeveralTenSecondAttempts() {
        #expect(MirrorStall.budget >= 3 * (10 + MirrorStall.interval))
    }

    @MainActor
    @Test func eitherAnswerFromTheMacIsRecorded() {
        let accepted = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        #expect(!accepted.attachAnswered)
        accepted.handleLine(Data(#"{"type":"attach_ok","html":"<p>"}"#.utf8))
        #expect(accepted.attachAnswered)

        let refused = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        refused.handleLine(Data(#"{"type":"attach_error","message":"no such session"}"#.utf8))
        #expect(refused.attachAnswered)
    }
}
