import Foundation
import Network
import os

private let logger = Logger(subsystem: "sh.saqoo.canopy-app", category: "MachineControl")

/// One NDJSON control connection to a Mac Canopy's mirror address (list / browse / open).
@MainActor
final class MachineControl {
    enum ControlError: Error {
        case notReachable
        case passwordRejected
        case updateCanopy
        case closed
        case failed(String)

        var message: String {
            switch self {
            case .notReachable: "Not reachable"
            case .passwordRejected: "Password rejected"
            case .updateCanopy: "Update Canopy on that Mac"
            case .closed: "Not reachable"
            case .failed(let text): text
            }
        }
    }

    private let target: MirrorTarget
    nonisolated(unsafe) private var connection: NWConnection?
    nonisolated private let buffer = LineBuffer()
    private let queue = DispatchQueue(label: "sh.saqoo.canopy-app.MachineControl")
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var helloContinuation: CheckedContinuation<Void, Error>?
    private var closed = false
    private var connected = false
    private var waitingDeadline: Task<Void, Never>?

    init(target: MirrorTarget) {
        self.target = target
    }

    func connect() async throws {
        guard !connected, !closed else { return }
        let address = target.address
        guard let colon = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: colon)...]), port != 0,
              !address[..<colon].isEmpty
        else { throw ControlError.notReachable }

        let connection = NWConnection(
            host: NWEndpoint.Host(String(address[..<colon])),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp
        )
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            helloContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(state) }
                }
            }
            waitingDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.failHello(ControlError.notReachable)
            }
            connection.start(queue: queue)
        }
        connected = true
    }

    func request(_ verb: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard connected, !closed, connection != nil else { throw ControlError.closed }
        let id = UUID().uuidString.lowercased()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            pending[id] = continuation
            send([
                "type": "request",
                "id": id,
                "verb": verb,
                "params": params,
            ])
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                waiting.resume(throwing: ControlError.notReachable)
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        waitingDeadline?.cancel()
        waitingDeadline = nil
        failHello(ControlError.closed)
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: ControlError.closed) }
        connection?.cancel()
        connection = nil
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            waitingDeadline?.cancel()
            logger.notice("control connected; sending hello")
            send([
                "type": "hello",
                "protocolVersion": 1,
                "client": "phone",
                "token": target.token,
            ])
            receive()
            waitingDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.failHello(ControlError.notReachable)
            }
        case .waiting:
            // Transient, as in MirrorLink: the hello deadline decides.
            break
        case .failed:
            if helloContinuation != nil {
                failHello(ControlError.notReachable)
            } else if connected {
                close()
            }
        default:
            break
        }
    }

    private func send(_ object: [String: Any]) {
        guard let connection, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        connection.send(content: data + Data([0x0A]), completion: .contentProcessed { error in
            if let error {
                logger.error("control send failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    nonisolated private func receive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                guard let frames = self.buffer.append(data),
                      let lines = MirrorWire.lines(from: frames)
                else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.failHello(ControlError.updateCanopy) }
                    }
                    return
                }
                if !lines.isEmpty {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { lines.forEach(self.handleLine) }
                    }
                }
            }
            if error != nil || isComplete {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if self.helloContinuation != nil {
                            self.failHello(ControlError.notReachable)
                        } else {
                            self.close()
                        }
                    }
                }
                return
            }
            self.receive()
        }
    }

    private func handleLine(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        if helloContinuation != nil {
            waitingDeadline?.cancel()
            waitingDeadline = nil
            switch type {
            case "hello_ok":
                let continuation = helloContinuation
                helloContinuation = nil
                continuation?.resume()
            case "hello_error":
                let message = object["message"] as? String ?? ""
                if message == "unauthorized" {
                    failHello(ControlError.passwordRejected)
                } else if message.contains("no control API") {
                    failHello(ControlError.updateCanopy)
                } else {
                    failHello(ControlError.updateCanopy)
                }
            default:
                failHello(ControlError.updateCanopy)
            }
            return
        }

        guard type == "response", let id = object["id"] as? String,
              let continuation = pending.removeValue(forKey: id)
        else { return }
        if let error = object["error"] as? String {
            continuation.resume(throwing: ControlError.failed(error))
        } else if let result = object["result"] as? [String: Any] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: ControlError.failed("Empty response"))
        }
    }

    private func failHello(_ error: ControlError) {
        waitingDeadline?.cancel()
        waitingDeadline = nil
        guard let continuation = helloContinuation else { return }
        helloContinuation = nil
        connection?.cancel()
        continuation.resume(throwing: error)
    }
}
