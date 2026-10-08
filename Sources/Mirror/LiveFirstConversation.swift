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
    @State private var backgroundReturn = BackgroundReturn()
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
            // An offline view is never touched: only a live view on screen counts as `live`.
            .onChange(of: scenePhase) { _, phase in
                if backgroundReturn.phaseChanged(to: phase, live: live != nil && fallback == nil, now: Date()) == .rebuild {
                    attempt += 1
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
                                  switch backgroundReturn.dropped(now: Date()) {
                                  case .keep: break
                                  case .rebuild: attempt += 1
                                  case .fail: fallback = .unavailable(reason)
                                  }
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
                                      backgroundReturn.cancelReconnect()
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

    /// A fresh attempt, so the live view that gave up is not the one shown again.
    private func showLive() {
        waitingForRestart = false
        restartUntil = nil
        backgroundReturn.cancelReconnect()
        resumeOnAttach = false
        fallback = nil
        attempt += 1
    }

    private var unavailableReason: String? {
        if case .unavailable(let reason) = fallback { return reason }
        return nil
    }
}
