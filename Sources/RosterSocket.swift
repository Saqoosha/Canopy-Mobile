import Foundation

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

    func connect(machine: String, onSnapshot: @escaping @Sendable (MachineSnapshot) -> Void) {
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
        receive(on: task, onSnapshot: onSnapshot)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive(on task: URLSessionWebSocketTask,
                         onSnapshot: @escaping @Sendable (MachineSnapshot) -> Void) {
        task.receive { [weak self] result in
            guard case .success(.string(let text)) = result,
                  let data = text.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(MachineSnapshot.self, from: data)
            else { return }
            Task { @MainActor in
                onSnapshot(snapshot)
                self?.receive(on: task, onSnapshot: onSnapshot)
            }
        }
    }
}
