import Foundation
import Testing
@testable import CanopyMobile

struct MirrorStatusTests {
    /// The line Canopy 2.39 sends, as `MirrorStatusFrame.payload` writes it.
    private static var line: [String: Any] {
        [
            "type": "status",
            "branch": "mbp-session-view-sync",
            "vcs": "git",
            "contextUsed": 123_000,
            "contextWindow": 967_000,
            "contextPct": 12,
            "contextLevel": "ok",
            "didCompact": false,
        ]
    }

    @Test func readsTheMacsLine() throws {
        let status = try #require(MirrorStatus(frame: Self.line))
        #expect(status.branch == "mbp-session-view-sync")
        #expect(status.vcs == "git")
        #expect(status.contextUsed == 123_000)
        #expect(status.contextWindow == 967_000)
        #expect(status.contextPct == 12)
        #expect(status.contextLevel == .ok)
        #expect(!status.didCompact)
        #expect(status.remoteHost == nil)
        #expect(status.hasContext)
        #expect(status.tint == .calm)
    }

    @Test func aFreshSessionHidesTheMeter() throws {
        var frame = Self.line
        frame["contextWindow"] = 0
        frame["contextPct"] = 0
        frame["contextLevel"] = "unknown"
        let status = try #require(MirrorStatus(frame: frame))
        #expect(!status.hasContext)
        #expect(!status.isEmpty, "the branch still draws")
        frame["branch"] = ""
        #expect(try #require(MirrorStatus(frame: frame)).isEmpty)
    }

    @Test func carriesTheRemoteHostWhenPresent() throws {
        var frame = Self.line
        frame["remoteHost"] = "studio"
        #expect(try #require(MirrorStatus(frame: frame)).remoteHost == "studio")
    }

    @Test func rejectsAnotherFrameType() {
        var frame = Self.line
        frame["type"] = "asset_response"
        #expect(MirrorStatus(frame: frame) == nil)
    }

    @Test func rejectsALineMissingTheWindow() {
        var frame = Self.line
        frame["contextWindow"] = nil
        #expect(MirrorStatus(frame: frame) == nil)
    }

    /// A level this build has no name for must not hide the meter or read as fine.
    @Test func anUnknownLevelFallsBackToThePercentage() throws {
        for (pct, tint) in [(85, MirrorStatus.Tint.alert), (80, .alert), (79, .warn), (50, .warn), (49, .calm)] {
            var frame = Self.line
            frame["contextLevel"] = "critical"
            frame["contextPct"] = pct
            let status = try #require(MirrorStatus(frame: frame))
            #expect(status.contextLevel == .unknown)
            #expect(status.tint == tint, "\(pct)%")
        }
    }

    @Test func aRemoteHostAloneStillDraws() throws {
        var frame = Self.line
        frame["branch"] = ""
        frame["contextWindow"] = 0
        frame["remoteHost"] = "studio"
        #expect(try #require(MirrorStatus(frame: frame)).isEmpty == false)
    }

    @Test func tintFollowsTheLevelWhenKnown() throws {
        for (level, tint) in [("ok", MirrorStatus.Tint.calm), ("warn", .warn), ("compact", .alert), ("blocked", .alert)] {
            var frame = Self.line
            frame["contextLevel"] = level
            frame["contextPct"] = 5
            #expect(try #require(MirrorStatus(frame: frame)).tint == tint, "\(level)")
        }
    }

    @Test func barFillClampsAnUnclampedPercentage() {
        #expect(MirrorStatus.barFillWidth(pct: 150, track: 40, minimum: 4) == 40)
        #expect(MirrorStatus.barFillWidth(pct: 1, track: 40, minimum: 4) == 4)
        #expect(MirrorStatus.barFillWidth(pct: 0, track: 40, minimum: 4) == 0)
        #expect(MirrorStatus.barFillWidth(pct: 50, track: 40, minimum: 4) == 20)
    }

    @Test func formatsTokensLikeTheMac() {
        #expect(MirrorStatus.formatTokens(123_000) == "123K")
        #expect(MirrorStatus.formatTokens(967_000) == "967K")
        #expect(MirrorStatus.formatTokens(1_000_000) == "1.0M")
        #expect(MirrorStatus.formatTokens(999) == "999")
    }
}
