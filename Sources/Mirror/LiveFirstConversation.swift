import SwiftUI

/// A session opened live when its Mac is reachable, and as the relay's last-known conversation when it is not.
///
/// Both are the same screen on the stack: the live attempt runs first and, on
/// any failure or drop, the offline view takes its place with the reason on a
/// banner; the toolbar menu switches to it without one, and back, on the same
/// screen.
struct LiveFirstConversation<Offline: View>: View {
    /// The caller passes nil when no paste covers this Mac or the session has no `resumeId` to attach by.
    let live: MirrorTarget?
    let sessionId: String
    let title: String
    /// The header's fallback second line; see `SessionHeader`.
    let subtitle: String
    /// The roster's live row for the header's dot and state, nil when it does not list the session.
    let pane: PaneRow?
    /// What the menu's Slack Thread item opens; nil when no paste covers the Mac, and then there is no item.
    let slack: SlackThreadContext?
    /// Changes on every notification tap; an open sheet would hide what the tap opens.
    let dismissal: Int
    @ViewBuilder let offline: (_ liveUnavailable: String?) -> Offline

    /// The context the open Slack sheet was opened with, kept whole if the roster or the stored connection changes meanwhile.
    @State private var slackPresented: SlackThreadContext?

    @State private var fallback: Fallback?
    /// Bumped to rebuild the live view with a fresh link; iOS closes the socket while the app is in the background.
    @State private var attempt = 0
    @State private var backgroundReturn = BackgroundReturn()
    /// Until when a drop re-attaches because the Mac announced a restart for an update.
    @State private var restartUntil: Date?
    @State private var waitingForRestart = false
    /// Set by a restart: the new service holds no sessions, so the next attach asks it to resume.
    @State private var resumeOnAttach = false
    /// Until when an attach the network stopped is retried; set by the first such failure, cleared by an attach.
    @State private var stallUntil: Date?
    @State private var waitingForNetwork = false
    @Environment(\.scenePhase) private var scenePhase

    private enum Fallback: Equatable {
        case unavailable(String)
        case chosen
    }

    var body: some View {
        content
            // An offline view is never touched: only a live view on screen counts as `live`.
            .onChange(of: scenePhase) { _, phase in
                // A stall budget spent before the trip must not cut short the attaches after it.
                if phase == .background { stallUntil = nil }
                if backgroundReturn.phaseChanged(to: phase, live: live != nil && fallback == nil, now: Date()) == .rebuild {
                    attempt += 1
                }
            }
            .sheet(isPresented: Binding(get: { slackPresented != nil }, set: { if !$0 { slackPresented = nil } })) {
                if let slackPresented {
                    SlackThreadSheet(target: slackPresented.target, sessionId: slackPresented.sessionId,
                                     resumeId: slackPresented.resumeId, title: slackPresented.title)
                }
            }
            .onChange(of: dismissal) { _, _ in slackPresented = nil }
    }

    @ViewBuilder
    private var content: some View {
        if live != nil, fallback == nil, waitingForRestart {
            ProgressView("The Mac is restarting for an update. Reconnecting…")
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { liveToolbar }
        } else if live != nil, fallback == nil, waitingForNetwork {
            ProgressView(MirrorStall.label)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { liveToolbar }
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
                                  stallUntil = nil
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
                              },
                              retryStall: { failure in
                                  guard current == attempt else { return true }
                                  guard MirrorStall.isStall(failure, stalling: stallUntil != nil) else { return false }
                                  // In the background the drop goes to `BackgroundReturn`, which re-attaches on the return.
                                  guard !backgroundReturn.inBackground,
                                        let until = MirrorStall.next(current: stallUntil, now: Date()) else {
                                      if stallUntil != nil { NSLog("[stall] budget spent or app away; giving up the retries") }
                                      stallUntil = nil
                                      return false
                                  }
                                  NSLog("[stall] the network lost the attach; re-attaching")
                                  stallUntil = until
                                  waitingForNetwork = true
                                  Task { @MainActor in
                                      try? await Task.sleep(for: .seconds(MirrorStall.interval))
                                      waitingForNetwork = false
                                      guard current == attempt, fallback == nil else { return }
                                      // Locked during the wait: report the drop so the return re-attaches.
                                      if backgroundReturn.inBackground {
                                          switch backgroundReturn.dropped(now: Date()) {
                                          case .keep: return
                                          case .rebuild: break
                                          case .fail:
                                              fallback = .unavailable("The network lost the connection to the Mac.")
                                              return
                                          }
                                      }
                                      backgroundReturn.cancelReconnect()
                                      attempt += 1
                                  }
                                  return true
                              },
                              connectingLabel: stallUntil == nil ? nil : MirrorStall.label)
            .id(attempt)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { liveToolbar }
        } else {
            offline(unavailableReason)
                .toolbar { menu }
        }
    }

    @ToolbarContentBuilder
    private var liveToolbar: some ToolbarContent {
        menu
        SessionHeader(title: title, subtitle: subtitle, pane: pane)
    }

    /// Every action for the session behind one button, so the header keeps the width.
    /// The offline view's header is its own; only the menu is added to it.
    @ToolbarContentBuilder
    private var menu: some ToolbarContent {
        let items = SessionMenu.items(hasSlack: slack != nil, showingLive: live != nil && fallback == nil,
                                      canAttach: live != nil)
        if !items.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(items, id: \.self) { item in
                        switch item {
                        case .slack:
                            Button {
                                slackPresented = slack
                            } label: {
                                Label("Slack Thread", systemImage: "bubble.left.and.text.bubble.right")
                            }
                        case .showOffline:
                            Button {
                                showOffline()
                            } label: {
                                Label("Show Offline View", systemImage: "rectangle.on.rectangle.slash")
                            }
                        case .openLive:
                            Button {
                                showLive()
                            } label: {
                                Label("Open Live Session", systemImage: "rectangle.on.rectangle")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Session actions")
            }
        }
    }

    private func showOffline() {
        waitingForRestart = false
        restartUntil = nil
        waitingForNetwork = false
        stallUntil = nil
        fallback = .chosen
    }

    /// A fresh attempt, so the live view that gave up is not the one shown again.
    private func showLive() {
        waitingForRestart = false
        restartUntil = nil
        waitingForNetwork = false
        stallUntil = nil
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

/// Which items a conversation's menu offers, in order; empty means no menu button at all.
enum SessionMenu {
    enum Item: Hashable {
        case slack
        case showOffline
        case openLive
    }

    /// The Slack item is not gated on attaching: a binding can be listed or made while the session is not attachable.
    static func items(hasSlack: Bool, showingLive: Bool, canAttach: Bool) -> [Item] {
        var items: [Item] = hasSlack ? [.slack] : []
        if showingLive {
            items.append(.showOffline)
        } else if canAttach {
            items.append(.openLive)
        }
        return items
    }
}
