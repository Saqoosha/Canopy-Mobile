import SwiftUI

/// A session opened live when its Mac is reachable, and as the relay's last-known conversation when it is not.
///
/// Both are the same screen on the stack: the live attempt runs first and, on
/// any failure or drop, the offline view takes its place with the reason on a
/// banner; the toolbar button switches to it without one. The offline view's
/// own Live button retries in a cover.
struct LiveFirstConversation<Offline: View>: View {
    /// The caller passes nil when no paste covers this Mac or the session has no `resumeId` to attach by.
    let live: MirrorTarget?
    let sessionId: String
    let title: String
    @ViewBuilder let offline: (_ liveUnavailable: String?) -> Offline

    @State private var fallback: Fallback?
    /// Bumped to rebuild the live view with a fresh link; iOS closes the socket while the app is in the background.
    @State private var attempt = 0
    /// Whether the live view was on screen when the app left the foreground.
    @State private var wasLiveInBackground = false
    /// Until when a drop reported after returning from the background rebuilds live instead of falling back.
    @State private var reconnectUntil: Date?
    @Environment(\.scenePhase) private var scenePhase

    private enum Fallback: Equatable {
        case unavailable(String)
        case chosen
    }

    var body: some View {
        content
            // iOS may close the socket while the app is in the background, and the app only
            // hears about it once active again. For a few seconds after a return, a drop
            // rebuilds the live view instead of falling back. Only a drop: a page whose link
            // survived keeps its half-typed reply, and an offline view is never touched.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    wasLiveInBackground = live != nil && fallback == nil
                case .active:
                    guard wasLiveInBackground else { return }
                    wasLiveInBackground = false
                    reconnectUntil = Date().addingTimeInterval(3)
                default:
                    break
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let live, fallback == nil {
            let current = attempt
            MirrorLiveContent(target: live, sessionId: sessionId) { reason in
                // A drop reported by a live view that has already been replaced.
                guard current == attempt else { return }
                if let until = reconnectUntil, Date() < until {
                    reconnectUntil = nil
                    attempt += 1
                    return
                }
                fallback = .unavailable(reason)
            }
            .id(attempt)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        fallback = .chosen
                    } label: {
                        Image(systemName: "rectangle.on.rectangle.slash")
                    }
                    .accessibilityLabel("Show offline view")
                }
            }
        } else {
            offline(unavailableReason)
        }
    }

    private var unavailableReason: String? {
        if case .unavailable(let reason) = fallback { return reason }
        return nil
    }
}
