import Foundation
import Testing
@testable import CanopyMobile

struct SlackThreadTests {
    @Test func listSkipsRowsWithoutThreadAndReadsMillis() {
        let result: [String: Any] = [
            "items": [
                ["channel": "C1", "threadTs": "1700000000.123456", "sessionKey": "R1", "sessionLabel": "a",
                 "expiresAt": 1_700_000_000_000],
                ["channel": "C2", "sessionKey": "R2"],
                ["channel": "", "threadTs": "1.2"],
            ],
        ]
        let list = SlackBinding.list(from: result)
        #expect(list.count == 1)
        #expect(list[0].channel == "C1")
        #expect(list[0].expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(SlackBinding.list(from: [:]).isEmpty)
    }

    @Test func threadURLDropsTheDot() {
        let binding = SlackBinding(channel: "C033F6U7147", threadTs: "1700000000.123456", sessionKey: "",
                                   sessionLabel: "", expiresAt: .distantFuture)
        #expect(binding.threadURL?.absoluteString == "https://slack.com/archives/C033F6U7147/p1700000000123456")
    }

    @Test func belongsMatchesResumeIdIgnoringCaseOrTheMacKey() {
        func binding(_ key: String) -> SlackBinding {
            SlackBinding(channel: "C", threadTs: "1.2", sessionKey: key, sessionLabel: "", expiresAt: .distantFuture)
        }
        #expect(binding("ABC-123").belongs(sessionId: "mac-key", resumeId: "abc-123"))
        #expect(binding("mac-key").belongs(sessionId: "mac-key", resumeId: "abc-123"))
        #expect(binding("mac-key").belongs(sessionId: "mac-key", resumeId: nil))
        #expect(!binding("other").belongs(sessionId: "mac-key", resumeId: "abc-123"))
        // An empty key must not match a session that has no resumeId either.
        #expect(!binding("").belongs(sessionId: "", resumeId: ""))
    }

    @Test func errorMessageNamesTheUpdateAndTheBridgeSwitch() {
        #expect(SlackBinding.errorMessage(MachineControl.ControlError.failed("local clients only")).contains("3.19.0"))
        let off = MachineControl.ControlError.failed(
            "the Slack bridge is off on this Mac (set canopy.slackBridgeEnabled to true in settings.json)")
        #expect(SlackBinding.errorMessage(off).contains("Slack bridge is off"))
        #expect(SlackBinding.errorMessage(MachineControl.ControlError.failed("permalink is required")) == "permalink is required")
        #expect(SlackBinding.errorMessage(MachineControl.ControlError.passwordRejected) == "Password rejected")
    }
}
