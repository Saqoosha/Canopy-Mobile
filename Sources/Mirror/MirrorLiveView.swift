import SwiftUI

/// The Mac's own session view, attached live over a direct connection.
struct MirrorLiveView: View {
    let address: String
    let sessionId: String
    let title: String
    var token: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var model = MirrorLiveModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .task { model.start(address: address, sessionId: sessionId, token: token ?? KeychainHelper.load(key: MirrorConnectionInfo.tokenKeychainKey)) }
        .onDisappear { model.close() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .connecting:
            ProgressView("Connecting to \(address)…")
        case .attached(let attached):
            if let link = model.link {
                MirrorWebView(link: link, attached: attached)
                    .ignoresSafeArea(.container, edges: .bottom)
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

    func start(address: String, sessionId: String, token: String?) {
        guard link == nil else { return }
        guard let token, !token.isEmpty else {
            phase = .failed("No password stored. Paste the connection from Canopy's Settings.")
            return
        }
        guard let colon = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: colon)...]), port != 0,
              !address[..<colon].isEmpty
        else {
            phase = .failed("Address must be <IPv4>:<port>")
            return
        }
        let link = MirrorLink(host: String(address[..<colon]), port: port, sessionId: sessionId, token: token)
        link.onAttached = { [weak self] attached in
            self?.phase = .attached(attached)
        }
        link.onFailure = { [weak self] reason in
            guard let self else { return }
            if case .failed = self.phase { return }
            self.phase = .failed(reason)
        }
        self.link = link
        link.start()
    }

    func close() {
        link?.close()
    }
}

/// `CANOPY_MIRROR_ATTACH="<IPv4>:<port>/<sessionId>"` (+ `CANOPY_MIRROR_TOKEN`) opens a live session at launch, for testing without UI.
struct LaunchMirror: Identifiable {
    let id = UUID()
    let address: String
    let sessionId: String
    var token: String? { ProcessInfo.processInfo.environment["CANOPY_MIRROR_TOKEN"] }

    static func fromEnvironment() -> LaunchMirror? {
        guard let raw = ProcessInfo.processInfo.environment["CANOPY_MIRROR_ATTACH"],
              let slash = raw.firstIndex(of: "/")
        else { return nil }
        let address = String(raw[..<slash])
        let sessionId = String(raw[raw.index(after: slash)...])
        guard !address.isEmpty, !sessionId.isEmpty else { return nil }
        return LaunchMirror(address: address, sessionId: sessionId)
    }
}
