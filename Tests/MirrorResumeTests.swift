import Foundation
import Testing
@testable import CanopyMobile

struct MirrorResumeTests {
    private func ready() -> MirrorResumeTracker {
        var tracker = MirrorResumeTracker()
        tracker.noteAttached(["epoch": "e", "seq": 3], resumed: false)
        tracker.noteSent(["type": "launch_claude", "channelId": "c1"])
        tracker.noteTranscriptDelivered()
        return tracker
    }

    @Test func aPageWithItsTranscriptAndChannelHasAPoint() {
        #expect(ready().point == MirrorResumePoint(epoch: "e", seq: 3, channelId: "c1"))
    }

    @Test func deliveredFramesAdvanceTheSeqAndNeverMoveItBack() {
        var tracker = ready()
        tracker.noteDelivered(["type": "from-extension", "seq": 9])
        tracker.noteDelivered(["type": "from-extension", "seq": 7])
        tracker.noteDelivered(["type": "from-extension"])
        #expect(tracker.point?.seq == 9)
    }

    @Test func theLatestLaunchNamesTheChannel() {
        var tracker = ready()
        tracker.noteSent(["type": "launch_claude", "channelId": "c2"])
        #expect(tracker.point?.channelId == "c2")
    }

    @Test func aRequestWaitingOnTheOldLinkBlocksTheResumeUntilAnswered() {
        var tracker = ready()
        tracker.noteSent(["type": "request", "requestId": "r1"])
        #expect(tracker.point == nil)
        tracker.noteDelivered(["type": "from-extension", "message": ["type": "response", "requestId": "r1"]])
        #expect(tracker.point != nil)
    }

    @Test func noPointBeforeTheTranscriptAChannelOrAnEpoch() {
        var noTranscript = MirrorResumeTracker()
        noTranscript.noteAttached(["epoch": "e", "seq": 3], resumed: false)
        noTranscript.noteSent(["type": "launch_claude", "channelId": "c1"])
        #expect(noTranscript.point == nil)

        var noChannel = MirrorResumeTracker()
        noChannel.noteAttached(["epoch": "e", "seq": 3], resumed: false)
        noChannel.noteTranscriptDelivered()
        #expect(noChannel.point == nil)

        // A Mac older than Canopy PR #321 sends neither field.
        var olderMac = MirrorResumeTracker()
        olderMac.noteAttached([:], resumed: false)
        olderMac.noteSent(["type": "launch_claude", "channelId": "c1"])
        olderMac.noteTranscriptDelivered()
        #expect(olderMac.point == nil)
    }

    @Test func aResumedAttachAlreadyHoldsItsTranscript() {
        var tracker = MirrorResumeTracker()
        tracker.noteAttached(["epoch": "e", "seq": 3], resumed: true)
        tracker.noteSent(["type": "launch_claude", "channelId": "c1"])
        #expect(tracker.point?.seq == 3)
    }

    @Test func aBooleanSeqIsNotASeq() {
        var tracker = MirrorResumeTracker()
        tracker.noteAttached(["epoch": "e", "seq": true], resumed: false)
        #expect(tracker.seq == nil)
    }

    @Test func attachAsksForBufferingAndSendsTheCursorOnlyWhenGiven() {
        let fresh = MirrorLink.attachMessage(sessionId: "s1", token: "tok")
        #expect(fresh["resume"] as? Bool == true)
        #expect(fresh["since"] == nil && fresh["channelId"] == nil)

        let resuming = MirrorLink.attachMessage(sessionId: "s1", token: "tok",
                                                since: MirrorResumePoint(epoch: "e", seq: 42, channelId: "c1"))
        let since = resuming["since"] as? [String: Any]
        #expect(since?["epoch"] as? String == "e" && since?["seq"] as? Int == 42)
        #expect(resuming["channelId"] as? String == "c1")
        // Kept, so a refused resume still gets its transcript at once.
        #expect(resuming["prefetch"] as? Bool == true)
    }

    @MainActor
    @Test func framesHeldBehindThePrefetchDoNotAdvanceTheCursor() {
        let link = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        link.handleLine(Data(#"{"type":"attach_ok","html":"<p>","prefetchedSessionRequestId":"p1","epoch":"e","seq":5}"#.utf8))
        link.handleLine(Data(#"{"type":"from-extension","seq":6,"message":{"type":"io_message"}}"#.utf8))
        #expect(link.tracker.seq == 5)
    }

    @MainActor
    @Test func framesHandedToThePageAdvanceTheCursor() {
        let link = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        var frames = 0
        link.onFrame = { _ in frames += 1 }
        link.handleLine(Data(#"{"type":"attach_ok","html":"<p>","epoch":"e","seq":5}"#.utf8))
        link.handleLine(Data(#"{"type":"from-extension","seq":6,"message":{"type":"io_message"}}"#.utf8))
        link.handleLine(Data(#"{"type":"from-extension","seq":7,"message":{"type":"io_message"}}"#.utf8))
        #expect(frames == 2)
        #expect(link.tracker.seq == 7)
    }

    @MainActor
    @Test func resumedIsReportedOnlyForALinkThatAskedToResume() {
        var reported: [Bool] = []
        let asked = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t",
                               resumeFrom: MirrorResumePoint(epoch: "e", seq: 5, channelId: "c1"))
        asked.onAttached = { reported.append($0.resumed) }
        asked.handleLine(Data(#"{"type":"attach_ok","html":"<p>","epoch":"e","seq":5,"resumed":true}"#.utf8))
        let fresh = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        fresh.onAttached = { reported.append($0.resumed) }
        fresh.handleLine(Data(#"{"type":"attach_ok","html":"<p>","epoch":"e","seq":5,"resumed":true}"#.utf8))
        #expect(reported == [true, false])
        #expect(asked.tracker.transcriptDelivered && !fresh.tracker.transcriptDelivered)
    }
}
