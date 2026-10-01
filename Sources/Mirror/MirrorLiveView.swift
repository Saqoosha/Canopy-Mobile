import SwiftUI

/// The Mac's own session view, attached live over a direct connection, as a full-screen cover.
struct MirrorLiveView: View {
    let target: MirrorTarget
    let sessionId: String
    let title: String
    var open: OpenRequest? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// What the next attach sends; replaced by `reattach` once the Mac has named the session.
    @State private var attach: Attach?
    /// Bumped to rebuild the live content with a fresh link; iOS closes the socket while the app is in the background.
    @State private var attempt = 0
    @State private var dropped = false
    @State private var wasInBackground = false
    /// Until when a drop reported after returning from the background rebuilds instead of staying failed.
    @State private var reconnectUntil: Date?

    struct Attach: Equatable {
        let sessionId: String
        var open: OpenRequest? = nil
        var key: String? = nil
    }

    /// The attach that finds an attached session again: by the Mac's key, never replaying `.new`.
    nonisolated static func reattach(_ first: Attach, after attached: MirrorLink.Attached) -> Attach {
        Attach(sessionId: attached.sessionId ?? first.sessionId,
               open: first.open == nil ? nil : .resume,
               key: attached.hostSessionId ?? first.key)
    }

    var body: some View {
        NavigationStack {
            let current = attach ?? Attach(sessionId: sessionId, open: open)
            let thisAttempt = attempt
            MirrorLiveContent(target: target, sessionId: current.sessionId, open: current.open, key: current.key,
                              onUnavailable: { _ in
                                  guard thisAttempt == attempt else { return }
                                  if let until = reconnectUntil, Date() < until {
                                      reconnectUntil = nil
                                      attempt += 1
                                  } else {
                                      dropped = true
                                  }
                              },
                              onAttached: { attached in
                                  attach = Self.reattach(current, after: attached)
                              })
                .id(attempt)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        // Same rule as `LiveFirstConversation`: only a drop around a return from the background
        // rebuilds, so a link that survived keeps its page and a half-typed reply.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasInBackground = !dropped
            case .active:
                guard wasInBackground else { return }
                wasInBackground = false
                if dropped, attach != nil {
                    dropped = false
                    attempt += 1
                } else {
                    reconnectUntil = Date().addingTimeInterval(3)
                }
            default:
                break
            }
        }
    }
}

/// The attach lifecycle and the three things it can show, without any chrome, so a cover and a pushed screen share it.
struct MirrorLiveContent: View {
    let target: MirrorTarget
    let sessionId: String
    var open: OpenRequest? = nil
    var key: String? = nil
    /// Called once when the attach cannot start, fails or drops; nil keeps the failure on screen instead.
    let onUnavailable: ((String) -> Void)?
    var onAttached: ((MirrorLink.Attached) -> Void)? = nil

    @State private var model = MirrorLiveModel()
    @AppStorage("sendWithReturn") private var sendWithReturn = false

    var body: some View {
        content
            .task { model.start(target: target, sessionId: sessionId, open: open, key: key) }
            .onDisappear { model.close() }
            .onChange(of: model.failure) { _, reason in
                if let reason { onUnavailable?(reason) }
            }
            .onChange(of: model.attachedCount) { _, _ in
                if case .attached(let attached) = model.phase { onAttached?(attached) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .connecting:
            ProgressView("Connecting to \(target.address)…")
        case .attached(let attached):
            if let link = model.link {
                // Under the page's composer, where the Mac draws it. Absent until a Mac that sends
                // it does, and while the line has nothing to draw (no repo, no window yet).
                let status = model.status.flatMap { $0.isEmpty ? nil : $0 }
                VStack(spacing: 0) {
                    MirrorWebView(link: link, attached: attached, sendWithReturn: sendWithReturn)
                    if let status {
                        MirrorStatusBar(status: status)
                    }
                }
                // The page reaches the screen's bottom edge only while nothing sits under it.
                .ignoresSafeArea(.container, edges: status == nil ? .bottom : [])
            }
        case .failed(let reason):
            ContentUnavailableView("Can't open live session", systemImage: "wifi.exclamationmark", description: Text(reason))
        }
    }
}

@Observable
@MainActor
final class MirrorLiveModel {
    enum Phase {
        case connecting
        case attached(MirrorLink.Attached)
        case failed(String)
    }

    private(set) var phase: Phase = .connecting
    private(set) var link: MirrorLink?
    /// The Mac's status bar; nil until the first `status` line, so an older Mac shows none.
    private(set) var status: MirrorStatus?
    /// Bumped on each `attach_ok`, so a view can react to it without `Attached` being Equatable.
    private(set) var attachedCount = 0

    var failure: String? {
        if case .failed(let reason) = phase { return reason }
        return nil
    }

    func start(target: MirrorTarget, sessionId: String, open: OpenRequest? = nil, key: String? = nil) {
        guard link == nil else { return }
        let address = target.address
        guard let colon = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: colon)...]), port != 0,
              !address[..<colon].isEmpty
        else {
            phase = .failed("Address must be host:port")
            return
        }
        let link = MirrorLink(host: String(address[..<colon]), port: port, sessionId: sessionId, token: target.token, open: open, key: key)
        link.onAttached = { [weak self] attached in
            self?.phase = .attached(attached)
            self?.attachedCount += 1
        }
        link.onFailure = { [weak self] reason in
            guard let self else { return }
            if case .failed = self.phase { return }
            self.phase = .failed(reason)
        }
        link.onStatus = { [weak self] status in
            self?.status = status
        }
        self.link = link
        link.start()
    }

    func close() {
        link?.close()
    }
}

/// `CANOPY_MIRROR_ATTACH="<IPv4>:<port>/<sessionId>"` opens a live session at launch for testing; without `CANOPY_MIRROR_TOKEN` nothing opens.
struct LaunchMirror: Identifiable {
    let id = UUID()
    let address: String
    let sessionId: String
    let token: String

    static func fromEnvironment() -> LaunchMirror? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["CANOPY_MIRROR_ATTACH"],
              let slash = raw.firstIndex(of: "/"),
              let token = env["CANOPY_MIRROR_TOKEN"], !token.isEmpty
        else { return nil }
        let address = String(raw[..<slash])
        let sessionId = String(raw[raw.index(after: slash)...])
        guard !address.isEmpty, !sessionId.isEmpty else { return nil }
        return LaunchMirror(address: address, sessionId: sessionId, token: token)
    }

    var target: MirrorTarget { MirrorTarget(address: address, token: token) }
}
