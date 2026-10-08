import SwiftUI

/// A session opened live when its Mac is reachable, and as the relay's last-known conversation when it is not.
///
/// Both are the same screen on the stack: the live attempt runs first and, on
/// any failure or drop, the offline view takes its place with the reason on a
/// banner; the toolbar button switches to it without one. The offline view's
/// own Live button switches back, on the same screen.
struct LiveFirstConversation<Offline: View>: View {
    /// The caller passes nil when no paste covers this Mac or the session has no `resumeId` to attach by.
    let live: MirrorTarget?
    let sessionId: String
    let title: String
    /// `showLive` is nil when `live` is.
    @ViewBuilder let offline: (_ liveUnavailable: String?, _ showLive: (() -> Void)?) -> Offline

    @State private var fallback: Fallback?
    /// Bumped to rebuild the live view with a fresh link; iOS closes the socket while the app is in the background.
    @State private var attempt = 0
    /// Whether the live view was on screen when the app left the foreground.
    @State private var wasLiveInBackground = false
    /// A drop reported while still in the background, rebuilt as soon as the app starts coming back.
    @State private var droppedInBackground = false
    /// `scenePhase` as the last handler saw it; the environment value a closure captured can be a phase behind.
    @State private var currentPhase = ScenePhase.active
    /// Until when a drop reported after returning from the background rebuilds live instead of falling back.
    @State private var reconnectUntil: Date?
    /// Until when a drop re-attaches because the Mac announced a restart for an update.
    @State private var restartUntil: Date?
    @State private var waitingForRestart = false
    /// Set by a restart: the new service holds no sessions, so the next attach asks it to resume.
    @State private var resumeOnAttach = false
    @Environment(\.scenePhase) private var scenePhase

    private enum Fallback: Equatable {
        case unavailable(String)
        case chosen
    }

    var body: some View {
        content
            // iOS may close the socket while the app is in the background. A drop reported on the
            // way back, or for a few seconds after, rebuilds the live view instead of falling back.
            // Only a drop: a page whose link survived keeps its half-typed reply, and an offline
            // view is never touched.
            .onChange(of: scenePhase) { _, phase in
                currentPhase = phase
                switch phase {
                case .background:
                    wasLiveInBackground = live != nil && fallback == nil
                    droppedInBackground = false
                case .inactive:
                    if droppedInBackground { rebuildAfterBackground() }
                case .active:
                    guard wasLiveInBackground else { return }
                    if droppedInBackground {
                        rebuildAfterBackground()
                    } else {
                        wasLiveInBackground = false
                        reconnectUntil = Date().addingTimeInterval(3)
                    }
                @unknown default:
                    break
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if live != nil, fallback == nil, waitingForRestart {
            ProgressView("The Mac is restarting for an update. Reconnecting…")
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { offlineButton }
        } else if let live, fallback == nil {
            let current = attempt
            MirrorLiveContent(target: live, sessionId: sessionId, open: resumeOnAttach ? .resume : nil,
                              cacheable: true,
                              onUnavailable: { reason in
                                  // A drop reported by a live view that has already been replaced.
                                  guard current == attempt else { return }
                                  resumeOnAttach = false
                                  restartUntil = nil
                                  // The drop often lands before `.active` does. Falling back here and
                                  // undoing it there flashed the offline view for a frame on every return.
                                  if wasLiveInBackground {
                                      if currentPhase == .background {
                                          droppedInBackground = true
                                      } else {
                                          rebuildAfterBackground()
                                      }
                                      return
                                  }
                                  if let until = reconnectUntil, Date() < until {
                                      reconnectUntil = nil
                                      attempt += 1
                                      return
                                  }
                                  fallback = .unavailable(reason)
                              },
                              onAttached: { _ in
                                  restartUntil = nil
                                  // Only the attaches inside a restart ask the Mac to resume.
                                  resumeOnAttach = false
                              },
                              retryDrop: { announced in
                                  guard current == attempt else { return true }
                                  if announced { restartUntil = Date().addingTimeInterval(MirrorRestart.budget) }
                                  guard MirrorRestart.shouldRetry(until: restartUntil, now: Date()) else { return false }
                                  resumeOnAttach = true
                                  waitingForRestart = true
                                  Task { @MainActor in
                                      try? await Task.sleep(for: .seconds(MirrorRestart.interval))
                                      waitingForRestart = false
                                      guard current == attempt else { return }
                                      attempt += 1
                                  }
                                  return true
                              })
            .id(attempt)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { offlineButton }
        } else {
            offline(unavailableReason, showLiveAction)
        }
    }

    private var offlineButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                waitingForRestart = false
                restartUntil = nil
                fallback = .chosen
            } label: {
                Image(systemName: "rectangle.on.rectangle.slash")
            }
            .accessibilityLabel("Show offline view")
        }
    }

    private var showLiveAction: (() -> Void)? {
        guard live != nil else { return nil }
        return { showLive() }
    }

    /// Rebuilds a live view whose link iOS closed while the app was away, without passing through the offline view.
    private func rebuildAfterBackground() {
        wasLiveInBackground = false
        droppedInBackground = false
        reconnectUntil = nil
        attempt += 1
    }

    /// A fresh attempt, so the live view that gave up is not the one shown again.
    private func showLive() {
        waitingForRestart = false
        restartUntil = nil
        reconnectUntil = nil
        resumeOnAttach = false
        fallback = nil
        attempt += 1
    }

    private var unavailableReason: String? {
        if case .unavailable(let reason) = fallback { return reason }
        return nil
    }
}
