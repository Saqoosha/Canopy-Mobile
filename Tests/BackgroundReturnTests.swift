import Foundation
import SwiftUI
import Testing
@testable import CanopyMobile

struct BackgroundReturnTests {
    let now = Date(timeIntervalSince1970: 1_000)

    @Test func aDropOnTheWayBackRebuildsAtOnceAndNeverFails() {
        var r = BackgroundReturn()
        #expect(r.phaseChanged(to: .background, live: true, now: now) == .keep)
        #expect(r.phaseChanged(to: .inactive, live: true, now: now) == .keep)
        #expect(r.dropped(now: now) == .rebuild)
        #expect(r.phaseChanged(to: .active, live: true, now: now) == .keep)
    }

    @Test func aDropInTheBackgroundWaitsForInactiveAndRebuildsOnce() {
        var r = BackgroundReturn()
        _ = r.phaseChanged(to: .background, live: true, now: now)
        #expect(r.dropped(now: now) == .keep)
        #expect(r.phaseChanged(to: .inactive, live: true, now: now) == .rebuild)
        #expect(r.phaseChanged(to: .active, live: true, now: now) == .keep)
    }

    @Test func aDropInTheBackgroundRebuildsOnActiveWhenInactiveIsSkipped() {
        var r = BackgroundReturn()
        _ = r.phaseChanged(to: .background, live: true, now: now)
        #expect(r.dropped(now: now) == .keep)
        #expect(r.phaseChanged(to: .active, live: true, now: now) == .rebuild)
    }

    @Test func aDropWithoutABackgroundTripFails() {
        var r = BackgroundReturn()
        #expect(r.dropped(now: now) == .fail)
    }

    @Test func inactiveWithoutABackgroundTripDoesNotRebuild() {
        var r = BackgroundReturn()
        #expect(r.phaseChanged(to: .inactive, live: true, now: now) == .keep)
        #expect(r.dropped(now: now) == .fail)
    }

    @Test func aCleanReturnRebuildsADropOnlyInsideTheWindow() {
        var r = BackgroundReturn()
        _ = r.phaseChanged(to: .background, live: true, now: now)
        _ = r.phaseChanged(to: .inactive, live: true, now: now)
        #expect(r.phaseChanged(to: .active, live: true, now: now) == .keep)
        #expect(r.dropped(now: now.addingTimeInterval(2)) == .rebuild)
        // The window is spent by the rebuild.
        #expect(r.dropped(now: now.addingTimeInterval(2.5)) == .fail)

        var late = BackgroundReturn()
        _ = late.phaseChanged(to: .background, live: true, now: now)
        _ = late.phaseChanged(to: .active, live: true, now: now)
        #expect(late.dropped(now: now.addingTimeInterval(BackgroundReturn.reconnectWindow)) == .fail)
    }

    @Test func aBackgroundRebuildClosesAWindowLeftFromAnEarlierReturn() {
        var r = BackgroundReturn()
        _ = r.phaseChanged(to: .background, live: true, now: now)
        _ = r.phaseChanged(to: .active, live: true, now: now)
        _ = r.phaseChanged(to: .background, live: true, now: now)
        _ = r.phaseChanged(to: .inactive, live: true, now: now)
        #expect(r.dropped(now: now.addingTimeInterval(1)) == .rebuild)
        #expect(r.dropped(now: now.addingTimeInterval(1.5)) == .fail)
    }

    @Test func aRebuiltLinkThatDropsAgainFails() {
        var r = BackgroundReturn()
        _ = r.phaseChanged(to: .background, live: true, now: now)
        _ = r.phaseChanged(to: .inactive, live: true, now: now)
        #expect(r.dropped(now: now) == .rebuild)
        #expect(r.dropped(now: now) == .fail)
    }

    @Test func noLiveViewOnScreenLeavesTheReturnAlone() {
        var r = BackgroundReturn()
        _ = r.phaseChanged(to: .background, live: false, now: now)
        #expect(r.dropped(now: now) == .fail)
        #expect(r.phaseChanged(to: .inactive, live: false, now: now) == .keep)
        #expect(r.phaseChanged(to: .active, live: false, now: now) == .keep)
        #expect(r.dropped(now: now) == .fail)
    }

    @Test func nothingToAttachByShowsTheDrop() {
        var r = BackgroundReturn()
        _ = r.phaseChanged(to: .background, live: true, now: now)
        _ = r.phaseChanged(to: .inactive, live: true, now: now)
        #expect(r.dropped(canRebuild: false, now: now) == .fail)
    }

    @Test func nothingToAttachByShowsADropStillInTheBackground() {
        var r = BackgroundReturn()
        _ = r.phaseChanged(to: .background, live: true, now: now)
        #expect(r.dropped(canRebuild: false, now: now) == .fail)
        #expect(r.phaseChanged(to: .inactive, live: false, now: now) == .keep)
    }

    @Test func aNewTripToTheBackgroundForgetsAnEarlierDeferredDrop() {
        var r = BackgroundReturn()
        _ = r.phaseChanged(to: .background, live: true, now: now)
        #expect(r.dropped(now: now) == .keep)
        _ = r.phaseChanged(to: .background, live: true, now: now)
        #expect(r.phaseChanged(to: .inactive, live: true, now: now) == .keep)
    }

    @Test func cancelReconnectClosesTheWindow() {
        var r = BackgroundReturn()
        _ = r.phaseChanged(to: .background, live: true, now: now)
        _ = r.phaseChanged(to: .active, live: true, now: now)
        r.cancelReconnect()
        #expect(r.dropped(now: now.addingTimeInterval(1)) == .fail)
    }
}
