import Foundation
import SwiftUI

/// Whether a live view's dropped link is rebuilt or shown, around a trip to the background.
///
/// iOS closes the socket while the app is away, and the drop is often reported before
/// `scenePhase` reaches `.active`. A drop on the way back rebuilds in place, so the
/// fallback is never drawn for a frame; one reported while still in the background waits
/// for `.inactive` or `.active`, because an attach started there can be killed again.
/// For a few seconds after a clean return a drop also rebuilds. Only a drop: a page whose
/// link survived keeps its half-typed reply.
nonisolated struct BackgroundReturn {
    enum Action: Equatable {
        case none
        case rebuild
        /// Show the drop: the caller's fallback or failure view.
        case fail
    }

    static let reconnectWindow: TimeInterval = 3

    /// Kept here rather than read from the environment: a closure's captured `scenePhase` can be a phase behind.
    private(set) var phase = ScenePhase.active
    /// A live view was on screen when the app left, and nothing has rebuilt it since.
    private var wasAway = false
    private var droppedAway = false
    private var reconnectUntil: Date?

    /// `live` is whether a live view that could be dropped is on screen.
    mutating func phaseChanged(to phase: ScenePhase, live: Bool, now: Date) -> Action {
        self.phase = phase
        switch phase {
        case .background:
            wasAway = live
            droppedAway = false
            return .none
        case .inactive:
            return droppedAway ? rebuild() : .none
        case .active:
            guard wasAway else { return .none }
            if droppedAway { return rebuild() }
            wasAway = false
            reconnectUntil = now.addingTimeInterval(Self.reconnectWindow)
            return .none
        @unknown default:
            return .none
        }
    }

    /// `canRebuild` is false while a rebuild has nothing to attach by; the drop is then shown.
    mutating func dropped(canRebuild: Bool = true, now: Date) -> Action {
        guard canRebuild else { return .fail }
        if wasAway {
            if phase == .background {
                droppedAway = true
                return .none
            }
            return rebuild()
        }
        if let until = reconnectUntil, now < until { return rebuild() }
        return .fail
    }

    /// For a rebuild the caller makes on its own, so a window left from an earlier return does not retry it.
    mutating func cancelReconnect() {
        reconnectUntil = nil
    }

    private mutating func rebuild() -> Action {
        wasAway = false
        droppedAway = false
        reconnectUntil = nil
        return .rebuild
    }
}
