import Foundation
import Testing
@testable import CanopyMobile

struct MirrorDialogGateTests {
    private func prompt(_ requestId: String, channel: String = "c1") -> [String: Any] {
        ["type": "from-extension",
         "message": ["type": "request", "requestId": requestId, "channelId": channel,
                     "request": ["type": "tool_permission_request", "toolName": "AskUserQuestion"]]]
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
}
