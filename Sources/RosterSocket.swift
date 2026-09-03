import Foundation

/// Reported by `RosterSocket` when its receive loop stops for good. Thin on
/// purpose — this is visibility, not recovery: no reconnect state, no
/// backoff. Recovery is a background/foreground cycle, which re-runs
/// `connectAll()` and installs a fresh socket.
struct RosterSocketError: Error {
    let underlying: Error

    var message: String {
        "Live connection dropped: \(underlying.localizedDescription)"
    }
}

/// Holds a WebSocket only while the app is foregrounded. Backgrounding drops
/// it: iOS would suspend it anyway, and a hibernated Durable Object bills
/// nothing for a connection that is not there.
@MainActor
final class RosterSocket {
    private var task: URLSessionWebSocketTask?
    private let baseURL: URL
    private let secret: String

    init(baseURL: URL, secret: String) {
        self.baseURL = baseURL
        self.secret = secret
    }

    func connect(machine: String,
                 onSnapshot: @escaping @Sendable (MachineSnapshot) -> Void,
                 onFailure: @escaping @Sendable (RosterSocketError) -> Void) {
        disconnect()
        var components = URLComponents(url: baseURL.appendingPathComponent("watch"),
                                       resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "machine", value: machine)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive(on: task, onSnapshot: onSnapshot, onFailure: onFailure)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Re-arms on every frame it can read from the wire — including a
    /// binary frame or a string frame that fails to decode — because none
    /// of those mean the socket is dead. Only a genuine `.failure` result
    /// (deploy closing the socket, DO eviction, a Wi-Fi→cellular handoff)
    /// stops the loop; that path reports through `onFailure` instead of
    /// silently returning, so the app can say the live connection is gone
    /// rather than keep rendering a frozen last snapshot as if it were live.
    private func receive(on task: URLSessionWebSocketTask,
                         onSnapshot: @escaping @Sendable (MachineSnapshot) -> Void,
                         onFailure: @escaping @Sendable (RosterSocketError) -> Void) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                var snapshot: MachineSnapshot?
                if case .string(let text) = message,
                   let data = text.data(using: .utf8) {
                    snapshot = try? JSONDecoder().decode(MachineSnapshot.self, from: data)
                }
                Task { @MainActor in
                    if let snapshot {
                        onSnapshot(snapshot)
                    }
                    self?.receive(on: task, onSnapshot: onSnapshot, onFailure: onFailure)
                }
            case .failure(let error):
                Task { @MainActor in
                    onFailure(RosterSocketError(underlying: error))
                }
            }
        }
    }
}
