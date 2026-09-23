import SwiftUI

/// The Mac's own session view, attached live over a direct connection, as a full-screen cover.
struct MirrorLiveView: View {
    let target: MirrorTarget
    let sessionId: String
    let title: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MirrorLiveContent(target: target, sessionId: sessionId, onUnavailable: nil)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}

/// The attach lifecycle and the three things it can show, without any chrome, so a cover and a pushed screen share it.
struct MirrorLiveContent: View {
    let target: MirrorTarget
    let sessionId: String
    /// Called once when the attach cannot start, fails or drops; nil keeps the failure on screen instead.
    let onUnavailable: ((String) -> Void)?

    @State private var model = MirrorLiveModel()
    @AppStorage("sendWithReturn") private var sendWithReturn = false

    var body: some View {
        content
            .task { model.start(target: target, sessionId: sessionId) }
            .onDisappear { model.close() }
            .onChange(of: model.failure) { _, reason in
                if let reason { onUnavailable?(reason) }
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

    var failure: String? {
        if case .failed(let reason) = phase { return reason }
        return nil
    }

    func start(target: MirrorTarget, sessionId: String) {
        guard link == nil else { return }
        let address = target.address
        guard let colon = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: colon)...]), port != 0,
              !address[..<colon].isEmpty
        else {
            phase = .failed("Address must be host:port")
            return
        }
        let link = MirrorLink(host: String(address[..<colon]), port: port, sessionId: sessionId, token: target.token)
        link.onAttached = { [weak self] attached in
            self?.phase = .attached(attached)
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
