import Foundation
import Testing
@testable import CanopyMobile

struct MirrorDialogGateTests {
    private func prompt(_ requestId: String, channel: String? = "c1",
                        kind: String = "tool_permission_request") -> [String: Any] {
        var message: [String: Any] = ["type": "request", "requestId": requestId,
                                      "request": ["type": kind, "toolName": "AskUserQuestion"]]
        if let channel { message["channelId"] = channel }
        return ["type": "from-extension", "message": message]
    }

    private func transcript(liveInOtherSurface: Bool?) -> [String: Any] {
        var response: [String: Any] = ["type": "get_session_response", "messages": []]
        if let liveInOtherSurface { response["liveInOtherSurface"] = liveInOtherSurface }
        return ["type": "from-extension", "message": ["type": "response", "requestId": "s1", "response": response]]
    }

    private func admit(_ gate: inout MirrorDialogGate, _ frame: [String: Any]) -> MirrorDialogGate.Verdict {
        var frame = frame
        return gate.admit(&frame)
    }

    @Test func theSamePromptToTheSameChannelIsDrawnOnce() {
        var gate = MirrorDialogGate()
        #expect(admit(&gate, prompt("r1")) == .deliver)
        #expect(admit(&gate, prompt("r1")) == .drop)
        #expect(admit(&gate, prompt("r2")) == .deliver)
    }

    /// A relaunched page mints a new channel and has lost its prompts; the Mac's re-send is the only copy it gets.
    @Test func aPromptReSentToANewChannelIsDrawn() {
        var gate = MirrorDialogGate()
        #expect(admit(&gate, prompt("r1", channel: "c1")) == .deliver)
        #expect(admit(&gate, prompt("r1", channel: "c2")) == .deliver)
    }

    @Test func thePagesAnswerReleasesThePrompt() {
        var gate = MirrorDialogGate()
        _ = admit(&gate, prompt("r1"))
        gate.noteSent(["type": "response", "requestId": "r1", "response": ["type": "tool_permission_response"]])
        #expect(admit(&gate, prompt("r1")) == .deliver)
    }

    @Test func aCancelReleasesThePromptOnEveryChannel() {
        var gate = MirrorDialogGate()
        _ = admit(&gate, prompt("r1", channel: "c1"))
        _ = admit(&gate, prompt("r1", channel: "c2"))
        #expect(admit(&gate, ["type": "from-extension",
                              "message": ["type": "cancel_request", "targetRequestId": "r1"]]) == .deliver)
        #expect(admit(&gate, prompt("r1", channel: "c1")) == .deliver)
        #expect(admit(&gate, prompt("r1", channel: "c2")) == .deliver)
    }

    @Test func requestsThatAreNotPromptsAreNeverDropped() {
        var gate = MirrorDialogGate()
        let other: [String: Any] = ["type": "from-extension",
                                    "message": ["type": "request", "requestId": "x", "request": ["type": "open_diff"]]]
        #expect(admit(&gate, other) == .deliver)
        #expect(admit(&gate, other) == .deliver)
    }

    /// The page replays an unanswered AskUserQuestion only on `false`; that replay is the second, unclearable copy.
    @Test func aTranscriptThatWouldReplayTheQuestionIsRewritten() {
        var gate = MirrorDialogGate()
        var frame = transcript(liveInOtherSurface: false)
        #expect(gate.admit(&frame) == .rewritten)
        let response = (frame["message"] as? [String: Any])?["response"] as? [String: Any]
        #expect(response?["liveInOtherSurface"] as? Bool == true)
        #expect(response?["type"] as? String == "get_session_response")
        #expect((frame["message"] as? [String: Any])?["requestId"] as? String == "s1")
    }

    @Test func aTranscriptThatWouldNotReplayIsLeftAlone() {
        var gate = MirrorDialogGate()
        #expect(admit(&gate, transcript(liveInOtherSurface: true)) == .deliver)
        #expect(admit(&gate, transcript(liveInOtherSurface: nil)) == .deliver)
    }

    @Test func aUserDialogIsDrawnOnceToo() {
        var gate = MirrorDialogGate()
        #expect(admit(&gate, prompt("r1", kind: "user_dialog_request")) == .deliver)
        #expect(admit(&gate, prompt("r1", kind: "user_dialog_request")) == .drop)
    }

    /// Without a channel there is no telling a relaunched page from the same one; a missing prompt is worse.
    @Test func aPromptWithNoChannelIsNeverDropped() {
        var gate = MirrorDialogGate()
        #expect(admit(&gate, prompt("r1", channel: nil)) == .deliver)
        #expect(admit(&gate, prompt("r1", channel: nil)) == .deliver)
    }

    @Test func releasingOnePromptKeepsTheOthers() {
        var gate = MirrorDialogGate()
        _ = admit(&gate, prompt("r1"))
        _ = admit(&gate, prompt("r2"))
        _ = admit(&gate, ["type": "from-extension", "message": ["type": "cancel_request", "targetRequestId": "r1"]])
        gate.noteSent(["type": "response", "requestId": "other"])
        gate.noteSent(["type": "request", "requestId": "r2", "request": ["type": "list_sessions_request"]])
        #expect(admit(&gate, prompt("r1")) == .deliver)
        #expect(admit(&gate, prompt("r2")) == .drop)
    }

    @Test func onlyATranscriptIsRewritten() {
        var gate = MirrorDialogGate()
        let other: [String: Any] = ["type": "from-extension",
                                    "message": ["type": "response", "requestId": "x",
                                                "response": ["type": "init_response", "liveInOtherSurface": false]]]
        #expect(admit(&gate, other) == .deliver)
    }

    @Test func theRewriteKeepsTheTranscript() {
        var gate = MirrorDialogGate()
        var frame = transcript(liveInOtherSurface: false)
        _ = gate.admit(&frame)
        #expect(frame["type"] as? String == "from-extension")
        let response = (frame["message"] as? [String: Any])?["response"] as? [String: Any]
        #expect(response?["messages"] is [Any])
    }
}

/// The gate as `MirrorLink` drives it, on lines decoded from the wire.
struct MirrorDialogGateLinkTests {
    private func decoded(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    @MainActor
    @Test func thePrefetchedTranscriptReachesThePageWithItsReplayOff() {
        let link = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        var frames: [String] = []
        link.onFrame = { frames.append($0) }
        link.handleLine(Data(#"{"type":"attach_ok","html":"<p>","sessionId":"s","prefetchedSessionRequestId":"p1","epoch":"e","seq":5}"#.utf8))
        link.send(["type": "request", "requestId": "page-1", "request": ["type": "get_session_request", "sessionId": "s"]])
        link.handleLine(Data(#"{"type":"from-extension","message":{"type":"response","requestId":"p1","response":{"type":"get_session_response","messages":[],"liveInOtherSurface":false}}}"#.utf8))
        #expect(frames.count == 1)
        let message = frames.first.flatMap(decoded)?["message"] as? [String: Any]
        #expect(message?["requestId"] as? String == "page-1")
        #expect((message?["response"] as? [String: Any])?["liveInOtherSurface"] as? Bool == true)
    }

    @MainActor
    @Test func aDirectTranscriptReachesThePageWithItsReplayOff() {
        let link = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        var frames: [String] = []
        link.onFrame = { frames.append($0) }
        link.handleLine(Data(#"{"type":"from-extension","message":{"type":"response","requestId":"r","response":{"type":"get_session_response","messages":[],"liveInOtherSurface":false}}}"#.utf8))
        let message = frames.first.flatMap(decoded)?["message"] as? [String: Any]
        #expect((message?["response"] as? [String: Any])?["liveInOtherSurface"] as? Bool == true)
    }

    @MainActor
    @Test func aRepeatedPromptIsPostedOnceButStillCounted() {
        let link = MirrorLink(host: "127.0.0.1", port: 1, sessionId: "s", token: "t")
        var frames = 0
        link.onFrame = { _ in frames += 1 }
        let prompt = { (seq: Int) in
            Data(#"{"type":"from-extension","seq":\#(seq),"message":{"type":"request","requestId":"r1","channelId":"c1","request":{"type":"tool_permission_request"}}}"#.utf8)
        }
        link.handleLine(prompt(6))
        link.handleLine(prompt(7))
        #expect(frames == 1)
        #expect(link.tracker.seq == 7)
        // The page's answer releases it.
        link.send(["type": "response", "requestId": "r1", "response": ["type": "tool_permission_response"]])
        link.handleLine(prompt(8))
        #expect(frames == 2)
    }
}
