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
    @State private var wasInBackground = false
    @Environment(\.scenePhase) private var scenePhase

    private enum Fallback: Equatable {
        case unavailable(String)
        case chosen
    }

    var body: some View {
        content
            // iOS closes the socket while the app is in the background, but the app only
            // hears about it after it is active again — after this handler has run. So
            // a return from the background rebuilds the live view outright rather than
            // waiting for the drop; a view the user switched to offline themselves stays.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    wasInBackground = true
                case .active:
                    let dropped: Bool
                    if case .unavailable = fallback { dropped = true } else { dropped = false }
                    guard wasInBackground || dropped else { return }
                    wasInBackground = false
                    if fallback != .chosen {
                        fallback = nil
                        attempt += 1
                    }
                default:
                    break
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let live, fallback == nil {
            MirrorLiveContent(target: live, sessionId: sessionId) { reason in
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
