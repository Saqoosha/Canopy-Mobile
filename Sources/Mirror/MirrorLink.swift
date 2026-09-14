import Foundation
import Network
import os

private let logger = Logger(subsystem: "sh.saqoo.canopy-app", category: "MirrorLink")

/// One NDJSON connection to a Mac Canopy's mirror server, attached to one session.
@MainActor
final class MirrorLink {
    struct Attached {
        let html: String
        let userScripts: [(source: String, atDocumentStart: Bool)]
    }

    enum AssetError: Error, LocalizedError {
        case refused(String)
        case closed

        var errorDescription: String? {
            switch self {
            case .refused(let reason): "Asset refused: \(reason)"
            case .closed: "Connection closed"
            }
        }
    }

    var onAttached: ((Attached) -> Void)?
    /// A webview frame, as the raw JSON text of its line.
    var onFrame: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    nonisolated(unsafe) private let connection: NWConnection
    nonisolated private let buffer = LineBuffer()
    private let queue = DispatchQueue(label: "sh.saqoo.canopy-app.MirrorLink")
    private let sessionId: String
    private let token: String
    private var pendingAssets: [String: CheckedContinuation<(data: Data, mime: String), Error>] = [:]
    private var failed = false
    private var closed = false
    private var waitingDeadline: Task<Void, Never>?

    init(host: String, port: UInt16, sessionId: String, token: String) {
        self.sessionId = sessionId
        self.token = token
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(state) }
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        guard !closed else { return }
        closed = true
        waitingDeadline?.cancel()
        connection.cancel()
        failPendingAssets()
    }

    func send(_ object: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        connection.send(content: data + Data([0x0A]), completion: .contentProcessed { error in
            if let error {
                logger.error("send failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    func requestAsset(path: String) async throws -> (data: Data, mime: String) {
        guard !closed, !failed else { throw AssetError.closed }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pendingAssets[id] = continuation
            send(["type": "asset_request", "id": id, "path": path])
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            waitingDeadline?.cancel()
            waitingDeadline = nil
            logger.notice("connected; attaching \(self.sessionId, privacy: .public)")
            send(["type": "attach", "sessionId": sessionId, "token": token])
            receive()
        case .waiting(let error):
            // Transient: NWConnection keeps retrying. Give it 10 s (local-network prompt, VPN coming up) before failing.
            logger.notice("waiting: \(error.localizedDescription, privacy: .public)")
            guard waitingDeadline == nil else { return }
            waitingDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.fail("Cannot reach the Mac: \(error.localizedDescription)")
            }
        case .failed(let error):
            fail("Connection failed: \(error.localizedDescription)")
        default:
            break
        }
    }

    nonisolated private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let lines = data.map { self.buffer.append($0) } ?? []
            if !lines.isEmpty {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { lines.forEach(self.handleLine) }
                }
            }
            if let error {
                logger.error("receive failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.fail("Disconnected from the Mac (\(error.localizedDescription))") }
                }
                return
            }
            if isComplete {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.fail("The Mac closed the connection") }
                }
                return
            }
            self.receive()
        }
    }

    private func handleLine(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        switch object["type"] as? String {
        case "attach_ok":
            guard let html = object["html"] as? String, !html.isEmpty else {
                fail("The Mac sent an empty page. Update Canopy on the Mac.")
                return
            }
            let scripts = (object["userScripts"] as? [[String: Any]] ?? []).compactMap { entry -> (source: String, atDocumentStart: Bool)? in
                guard let source = entry["source"] as? String else { return nil }
                return (source, entry["atDocumentStart"] as? Bool ?? false)
            }
            logger.notice("attach_ok with \(scripts.count) user scripts")
            onAttached?(Attached(html: html, userScripts: scripts))
        case "attach_error":
            switch object["message"] as? String {
            case "unauthorized": fail("The Mac rejected the password. Copy the connection again from Canopy's Settings.")
            case "no such session": fail("This session is not running on the Mac.")
            case let other: fail(other ?? "The Mac refused the connection.")
            }
        case "asset_response":
            guard let id = object["id"] as? String, let continuation = pendingAssets.removeValue(forKey: id) else { return }
            if let base64 = object["base64"] as? String, let data = Data(base64Encoded: base64) {
                continuation.resume(returning: (data, object["mime"] as? String ?? "application/octet-stream"))
            } else {
                continuation.resume(throwing: AssetError.refused(object["error"] as? String ?? "unreadable"))
            }
        default:
            onFrame?(String(decoding: line, as: UTF8.self))
        }
    }

    private func fail(_ reason: String) {
        guard !failed, !closed else { return }
        failed = true
        waitingDeadline?.cancel()
        logger.error("\(reason, privacy: .public)")
        connection.cancel()
        failPendingAssets()
        onFailure?(reason)
    }

    private func failPendingAssets() {
        let pending = pendingAssets
        pendingAssets.removeAll()
        pending.values.forEach { $0.resume(throwing: AssetError.closed) }
    }
}

/// Accumulates socket bytes and yields complete newline-terminated lines.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            lines.append(data[data.startIndex..<newline])
            data.removeSubrange(data.startIndex...newline)
        }
        return lines
    }
}
