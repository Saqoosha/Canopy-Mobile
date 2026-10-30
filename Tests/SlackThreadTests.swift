import Foundation
import Testing
@testable import CanopyMobile

struct SlackThreadTests {
    @Test func listReadsEveryFieldAndSkipsRowsWithoutThread() {
        let result: [String: Any] = [
            "items": [
                ["channel": "C1", "threadTs": "1700000000.123456", "sessionKey": "R1", "sessionLabel": "a",
                 "expiresAt": 1_700_000_000_000],
                ["channel": "C2", "sessionKey": "R2"],
                ["channel": "C3", "threadTs": ""],
                ["channel": "", "threadTs": "1.2"],
                ["channel": "C4", "threadTs": "1.4", "sessionKey": "R4"],
            ],
        ]
        #expect(SlackBinding.list(from: result) == [
            SlackBinding(channel: "C1", threadTs: "1700000000.123456", sessionKey: "R1", sessionLabel: "a",
                         expiresAt: Date(timeIntervalSince1970: 1_700_000_000)),
            // A missing expiry stays missing rather than reading as 1970.
            SlackBinding(channel: "C4", threadTs: "1.4", sessionKey: "R4", sessionLabel: "", expiresAt: nil),
        ])
    }

    @Test func listIsNilOnlyWhenItemsIsNotAList() {
        #expect(SlackBinding.list(from: ["items": "x"]) == nil)
        // A missing list is empty, as the Mac reads it; a stray element is skipped, not fatal.
        #expect(SlackBinding.list(from: [:]) == [])
        #expect(SlackBinding.list(from: ["items": ["x", ["channel": "C", "threadTs": "1.2"]]])?.map(\.id) == ["C/1.2"])
    }

    @Test func threadURLDropsTheDot() {
        let binding = SlackBinding(channel: "C033F6U7147", threadTs: "1700000000.123456", sessionKey: "",
                                   sessionLabel: "", expiresAt: nil)
        #expect(binding.threadURL?.absoluteString == "https://slack.com/archives/C033F6U7147/p1700000000123456")
    }

    @Test func belongsMatchesResumeIdOrTheMacKeyIgnoringCase() {
        func binding(_ key: String) -> SlackBinding {
            SlackBinding(channel: "C", threadTs: "1.2", sessionKey: key, sessionLabel: "", expiresAt: nil)
        }
        #expect(binding("ABC-123").belongs(sessionId: "mac-key", resumeId: "abc-123"))
        #expect(binding("MAC-KEY").belongs(sessionId: "mac-key", resumeId: "abc-123"))
        #expect(binding("mac-key").belongs(sessionId: "mac-key", resumeId: nil))
        #expect(!binding("other").belongs(sessionId: "mac-key", resumeId: "abc-123"))
        // An empty key must not match a session that has no resumeId either.
        #expect(!binding("").belongs(sessionId: "", resumeId: ""))
    }

    @Test func bindParamsTrimTheLinkAndOmitAMissingResumeId() {
        #expect(SlackBinding.bindParams(key: "K", resumeId: "R", permalink: " https://x/p1\n")
            == ["key": "K", "sessionId": "R", "permalink": "https://x/p1"])
        #expect(SlackBinding.bindParams(key: "K", resumeId: nil, permalink: "l") == ["key": "K", "permalink": "l"])
        #expect(SlackBinding.bindParams(key: "K", resumeId: "", permalink: "l") == ["key": "K", "permalink": "l"])
        let binding = SlackBinding(channel: "C", threadTs: "1.2", sessionKey: "", sessionLabel: "", expiresAt: nil)
        #expect(binding.unbindParams == ["channel": "C", "threadTs": "1.2"])
    }

    @Test func errorMessageNamesTheUpdateAndTheBridgeSwitch() {
        #expect(SlackBinding.errorMessage(MachineControl.ControlError.failed("local clients only")).contains("3.19.0"))
        let off = MachineControl.ControlError.failed(
            "the Slack bridge is off on this Mac (set canopy.slackBridgeEnabled to true in settings.json)")
        #expect(SlackBinding.errorMessage(off).contains("Turn on"))
        #expect(SlackBinding.errorMessage(MachineControl.ControlError.failed("permalink is required")) == "permalink is required")
        #expect(SlackBinding.errorMessage(MachineControl.ControlError.passwordRejected) == "Password rejected")
        let other = URLError(.timedOut)
        #expect(SlackBinding.errorMessage(other) == other.localizedDescription)
    }
}
