import Foundation
import Testing
@testable import CanopyMobile

struct MirrorStallTests {
    @Test func aStallStartsOnlyAfterReachingTheMacAndBeforeItsAnswer() {
        let lost = MirrorStall.Failure(onNetwork: true, reachedMac: true, answered: false)
        #expect(MirrorStall.isStall(lost, stalling: false))
        // A Mac never reached: asleep or off the tailnet, which a minute of retries does not fix.
        let unreached = MirrorStall.Failure(onNetwork: true, reachedMac: false, answered: false)
        #expect(!MirrorStall.isStall(unreached, stalling: false))
        // A drop after the answer belongs to `BackgroundReturn`.
        #expect(!MirrorStall.isStall(MirrorStall.Failure(onNetwork: true, reachedMac: true, answered: true), stalling: true))
        // Something the Mac said (an empty page, an unreadable line).
        #expect(!MirrorStall.isStall(MirrorStall.Failure(onNetwork: false, reachedMac: true, answered: false), stalling: true))
    }

    @Test func anUnreachableAttemptKeepsAStallThatHasStarted() {
        let unreached = MirrorStall.Failure(onNetwork: true, reachedMac: false, answered: false)
        #expect(MirrorStall.isStall(unreached, stalling: true))
    }

    @Test func theFirstStallStartsTheBudgetAndLaterOnesKeepItUntilItEnds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = MirrorStall.next(current: nil, now: now)
        #expect(first == now.addingTimeInterval(MirrorStall.budget))
        #expect(MirrorStall.next(current: first, now: now.addingTimeInterval(30)) == first)
        #expect(MirrorStall.next(current: first, now: now.addingTimeInterval(MirrorStall.budget)) == nil)
    }

    @Test func theBudgetLeavesRoomForSeveralAttempts() {
        // One attempt is up to 20 s: 10 s to connect, 10 s for the answer.
        #expect(MirrorStall.budget >= 3 * (20 + MirrorStall.interval))
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
