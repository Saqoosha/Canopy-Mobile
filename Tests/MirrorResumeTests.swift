import Foundation
import Testing
@testable import CanopyMobile

struct MirrorResumeTests {
    private func ready() -> MirrorResumeTracker {
        var tracker = MirrorResumeTracker()
        tracker.noteAttached(["epoch": "e", "seq": 3], resumedFrom: nil)
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
        noTranscript.noteAttached(["epoch": "e", "seq": 3], resumedFrom: nil)
        noTranscript.noteSent(["type": "launch_claude", "channelId": "c1"])
        #expect(noTranscript.point == nil)

        var noChannel = MirrorResumeTracker()
        noChannel.noteAttached(["epoch": "e", "seq": 3], resumedFrom: nil)
        noChannel.noteTranscriptDelivered()
        #expect(noChannel.point == nil)

        // A Mac older than Canopy PR #321 sends neither field.
        var olderMac = MirrorResumeTracker()
        olderMac.noteAttached([:], resumedFrom: nil)
        olderMac.noteSent(["type": "launch_claude", "channelId": "c1"])
        olderMac.noteTranscriptDelivered()
        #expect(olderMac.point == nil)
    }

    @Test func aResumedLinkCanBeResumedFromAgainWithoutANewLaunch() {
        var tracker = MirrorResumeTracker()
        // The kept page sends no launch_claude on a resumed link; its channel comes from the point it resumed from.
        tracker.noteAttached(["epoch": "e", "seq": 3], resumedFrom: MirrorResumePoint(epoch: "e", seq: 3, channelId: "c1"))
        tracker.noteDelivered(["type": "from-extension", "seq": 8])
        #expect(tracker.point == MirrorResumePoint(epoch: "e", seq: 8, channelId: "c1"))
    }

    @Test func aBooleanSeqIsNotASeq() {
        var tracker = MirrorResumeTracker()
        tracker.noteAttached(["epoch": "e", "seq": true], resumedFrom: nil)
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
    @Test func thePageMessagesSentThroughTheLinkNameItsChannelAndPendingRequests() {
        let link = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        link.send(["type": "launch_claude", "channelId": "c1"])
        link.send(["type": "request", "requestId": "r1", "request": ["type": "list_sessions_request"]])
        #expect(link.tracker.channelId == "c1")
        #expect(link.tracker.pendingRequests == ["r1"])
        // A request the page sends after the link closed never leaves, and its answer never comes.
        link.close()
        link.send(["type": "request", "requestId": "r2", "request": ["type": "list_sessions_request"]])
        #expect(link.tracker.pendingRequests == ["r1", "r2"])
    }

    @MainActor
    @Test func theTranscriptAndTheFramesHeldBehindItMakeAResumePoint() {
        let link = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        var frames = 0
        link.onFrame = { _ in frames += 1 }
        link.handleLine(Data(#"{"type":"attach_ok","html":"<p>","sessionId":"s","prefetchedSessionRequestId":"p1","epoch":"e","seq":5}"#.utf8))
        link.send(["type": "launch_claude", "channelId": "c1"])
        link.handleLine(Data(#"{"type":"from-extension","seq":6,"message":{"type":"io_message"}}"#.utf8))
        // The page's own transcript request is answered by the prefetch, so it never waits on the Mac.
        link.send(["type": "request", "requestId": "page-1", "request": ["type": "get_session_request", "sessionId": "s"]])
        link.handleLine(Data(#"{"type":"from-extension","message":{"type":"response","requestId":"p1","response":{}}}"#.utf8))
        #expect(frames == 2)
        #expect(link.resumePoint == MirrorResumePoint(epoch: "e", seq: 6, channelId: "c1"))
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
        let refused = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t",
                                 resumeFrom: MirrorResumePoint(epoch: "e", seq: 5, channelId: "c1"))
        refused.onAttached = { reported.append($0.resumed) }
        refused.handleLine(Data(#"{"type":"attach_ok","html":"<p>","epoch":"e2","seq":9,"resumed":false,"prefetchedSessionRequestId":"p"}"#.utf8))
        #expect(reported == [true, false, false])
        #expect(!refused.tracker.transcriptDelivered)
        #expect(asked.tracker.point == MirrorResumePoint(epoch: "e", seq: 5, channelId: "c1"))
        #expect(!fresh.tracker.transcriptDelivered)
    }
}
