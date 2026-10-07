import QuickLook
import SwiftUI

/// The Mac's own session view, attached live over a direct connection, pushed for a session the roster does not
/// list yet (Open on Mac, or the `LaunchMirror` debug attach). A listed session opens in `LiveFirstConversation` instead.
struct MirrorLiveView: View {
    let target: MirrorTarget
    let sessionId: String
    let title: String
    var open: OpenRequest? = nil

    @Environment(\.scenePhase) private var scenePhase
    /// What the next attach sends; replaced by `reattach` once the Mac has named the session.
    @State private var attach: Attach?
    /// Bumped to rebuild the live content with a fresh link; iOS closes the socket while the app is in the background.
    @State private var attempt = 0
    @State private var dropped = false
    @State private var wasInBackground = false
    /// Until when a drop reported after returning from the background rebuilds instead of staying failed.
    @State private var reconnectUntil: Date?
    /// Until when a drop re-attaches because the Mac announced a restart for an update.
    @State private var restartUntil: Date?
    @State private var waitingForRestart = false
    /// True only for the attaches inside a restart window: the new service holds no sessions.
    @State private var resumeForRestart = false

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

    /// What an attach asks the Mac to start: `.resume` only while re-attaching after a restart.
    nonisolated static func openRequest(_ attach: Attach, resumingAfterRestart: Bool) -> OpenRequest? {
        resumingAfterRestart ? .resume : attach.open
    }

    var body: some View {
        let current = attach ?? Attach(sessionId: sessionId, open: open)
        let thisAttempt = attempt
        Group {
            if waitingForRestart {
                ProgressView("The Mac is restarting for an update. Reconnecting…")
            } else {
                MirrorLiveContent(target: target, sessionId: current.sessionId,
                                  open: Self.openRequest(current, resumingAfterRestart: resumeForRestart), key: current.key,
                                  onUnavailable: { _ in
                                      guard thisAttempt == attempt else { return }
                                      resumeForRestart = false
                                      restartUntil = nil
                                      if let until = reconnectUntil, Date() < until, attach != nil {
                                          reconnectUntil = nil
                                          attempt += 1
                                      } else {
                                          dropped = true
                                      }
                                  },
                                  onAttached: { attached in
                                      restartUntil = nil
                                      resumeForRestart = false
                                      attach = Self.reattach(current, after: attached)
                                  },
                                  retryDrop: { announced in
                                      guard thisAttempt == attempt else { return true }
                                      if announced { restartUntil = Date().addingTimeInterval(MirrorRestart.budget) }
                                      guard MirrorRestart.shouldRetry(until: restartUntil, now: Date()), attach != nil else {
                                          return false
                                      }
                                      resumeForRestart = true
                                      waitingForRestart = true
                                      Task { @MainActor in
                                          try? await Task.sleep(for: .seconds(MirrorRestart.interval))
                                          waitingForRestart = false
                                          guard thisAttempt == attempt else { return }
                                          attempt += 1
                                      }
                                      return true
                                  })
                    .id(attempt)
            }
        }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
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

/// The attach lifecycle and the three things it can show, without any chrome, so `MirrorLiveView` and `LiveFirstConversation` share it.
struct MirrorLiveContent: View {
    let target: MirrorTarget
    let sessionId: String
    let open: OpenRequest?
    let key: String?
    /// Called once when the attach cannot start, fails or drops; nil keeps the failure on screen instead.
    let onUnavailable: ((String) -> Void)?
    var onAttached: ((MirrorLink.Attached) -> Void)? = nil
    /// Asked before `onUnavailable` for a drop that was not a refusal, with whether the Mac announced
    /// a restart first; returning true means the caller re-attaches and `onUnavailable` is skipped.
    var retryDrop: ((_ restartAnnounced: Bool) -> Bool)? = nil
    /// Set when this screen parks its attach in `MirrorSessionCache` on close and takes a parked one on open.
    let cacheKey: MirrorSessionCache.Key?

    @State private var model: MirrorLiveModel
    @AppStorage("sendWithReturn") private var sendWithReturn = false

    init(target: MirrorTarget, sessionId: String, open: OpenRequest? = nil, key: String? = nil,
         cacheable: Bool = false,
         onUnavailable: ((String) -> Void)?,
         onAttached: ((MirrorLink.Attached) -> Void)? = nil,
         retryDrop: ((_ restartAnnounced: Bool) -> Bool)? = nil) {
        self.target = target
        self.sessionId = sessionId
        self.open = open
        self.key = key
        self.onUnavailable = onUnavailable
        self.onAttached = onAttached
        self.retryDrop = retryDrop
        let cacheKey = Self.cacheKey(target: target, sessionId: sessionId, open: open, key: key, cacheable: cacheable)
        self.cacheKey = cacheKey
        _model = State(initialValue: cacheKey.flatMap(MirrorSessionCache.model(for:)) ?? MirrorLiveModel())
    }

    /// Only a plain attach is cached: one that asks the Mac to open or resume something, or names its key, must reach the Mac.
    nonisolated static func cacheKey(target: MirrorTarget, sessionId: String, open: OpenRequest?, key: String?,
                                     cacheable: Bool) -> MirrorSessionCache.Key? {
        guard cacheable, open == nil, key == nil else { return nil }
        return MirrorSessionCache.Key(address: target.address, sessionId: sessionId)
    }

    var body: some View {
        content
            .task {
                MirrorSessionCache.claim(model)
                // Closed by the cache before this screen claimed it (evicted between `init` and here), or while
                // the screen was covered and parked: attach afresh instead of showing a page with no link.
                if model.isClosed { model = MirrorLiveModel() }
                model.start(target: target, sessionId: sessionId, open: open, key: key)
                // A model from the cache is already attached, so `attachedCount` will not change; report it here.
                if case .attached(let attached) = model.phase { onAttached?(attached) }
            }
            .onDisappear {
                if let cacheKey {
                    MirrorSessionCache.park(model, key: cacheKey)
                } else {
                    model.close()
                }
            }
            .onChange(of: model.failure) { _, reason in
                guard let reason else { return }
                // The notice is read here, at the drop, so it cannot lose a race with it.
                if !model.refused, retryDrop?(model.restartAnnounced) == true { return }
                onUnavailable?(reason)
            }
            .onChange(of: model.attachedCount) { _, _ in
                if case .attached(let attached) = model.phase { onAttached?(attached) }
            }
            .overlay(alignment: .top) { MirrorFileOverlay(files: model.files) }
            .quickLookPreview(Bindable(model.files).received)

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
                    MirrorWebView(link: link, attached: attached, page: model.page, sendWithReturn: sendWithReturn)
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
    /// Set when the Mac sends `daemon_restarting`; read before the drop that follows it.
    private(set) var restartAnnounced = false
    let files = MirrorFileReceiver()
    let page = MirrorPage()
    private(set) var isClosed = false
    /// Set by `MirrorSessionCache` while the model is parked, so a link that fails there is released at once.
    var onFailureWhileParked: (() -> Void)?

    /// Attached, not failed or closed: safe to show again from `MirrorSessionCache`.
    var isReusable: Bool {
        guard !isClosed, case .attached = phase else { return false }
        return true
    }

    /// The Mac refused the attach; retrying will not change that.
    var refused: Bool { link?.refusedByMac == true }

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
            self.files.connectionDropped()
            self.phase = .failed(reason)
            self.onFailureWhileParked?()
        }
        link.onFile = { [weak self] frame in
            self?.files.handle(frame)
        }
        link.onStatus = { [weak self] status in
            self?.status = status
        }
        link.onRestarting = { [weak self] in
            self?.restartAnnounced = true
        }
        self.link = link
        link.start()
    }

    func close() {
        isClosed = true
        onFailureWhileParked = nil
        files.connectionDropped()
        link?.close()
        page.close()
    }
}

/// `CANOPY_MIRROR_ATTACH="<IPv4>:<port>/<sessionId>"` opens a live session at launch for testing; without `CANOPY_MIRROR_TOKEN` nothing opens.
struct LaunchMirror {
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

/// The name and progress of a file on its way from the Mac, or why it did not arrive.
private struct MirrorFileOverlay: View {
    let files: MirrorFileReceiver

    var body: some View {
        Group {
            if let error = files.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if files.showsOverlay, let transfer = files.current {
                VStack(alignment: .leading, spacing: 6) {
                    Label(transfer.name, systemImage: "arrow.down.doc")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressView(value: transfer.fraction)
                }
            }
        }
        .font(.footnote)
        .padding(12)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 8)
        .opacity(files.isOverlayVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: files.isOverlayVisible)
        .allowsHitTesting(false)
    }
}
