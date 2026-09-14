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
        /// The Mac's extension version, the key its assets are cached under; nil from a Mac that sent none.
        let extensionVersion: String?
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
    /// The replay the Mac started fetching at attach; the page's own get_session_request is answered with it.
    private var prefetchId: String?
    private var prefetched: [String: Any]?
    private var pageSessionRequestId: String?
    private var abandonedPrefetchId: String?
    private var prefetchFallback: Task<Void, Never>?
    private var closed = false
    private var waitingDeadline: Task<Void, Never>?
    private var lastWaitingError: NWError?

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
        // Armed before the connection opens, not on `.waiting`: a tailnet Mac with no listener stayed
        // in `.preparing` for 25 s+ without reporting `.waiting` or `.failed` (measured 2026-09-14).
        waitingDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            let detail = self.lastWaitingError?.localizedDescription ?? "no answer in 10 s"
            self.fail("Cannot reach the Mac: \(detail).")
        }
        connection.start(queue: queue)
    }

    func close() {
        guard !closed else { return }
        closed = true
        waitingDeadline?.cancel()
        prefetchFallback?.cancel()
        connection.cancel()
        failPendingAssets()
    }

    func send(_ object: [String: Any]) {
        if claimsPageSessionRequest(object) { return }
        guard !closed, !failed, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        connection.send(content: data + Data([0x0A]), completion: .contentProcessed { error in
            if let error {
                logger.error("send failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    /// True when `object` is the page's first get_session_request and the prefetched replay will answer it.
    private func claimsPageSessionRequest(_ object: [String: Any]) -> Bool {
        guard prefetchId != nil, pageSessionRequestId == nil,
              object["type"] as? String == "request",
              let request = object["request"] as? [String: Any],
              request["type"] as? String == "get_session_request",
              request["sessionId"] as? String == sessionId,
              let requestId = object["requestId"] as? String
        else { return false }
        pageSessionRequestId = requestId
        if prefetched != nil {
            deliverPrefetched()
        } else {
            // A prefetch the Mac never answers must not leave the page without its transcript.
            prefetchFallback = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, let pending = self.prefetchId else { return }
                logger.error("prefetched replay did not arrive; asking the Mac directly")
                // Remembered so a late arrival is dropped rather than handed to the page under an id it never issued.
                self.abandonedPrefetchId = pending
                self.prefetchId = nil
                self.send(object)
            }
        }
        return true
    }

    private func deliverPrefetched() {
        guard var frame = prefetched, let requestId = pageSessionRequestId,
              var message = frame["message"] as? [String: Any]
        else { return }
        prefetchFallback?.cancel()
        prefetchId = nil
        prefetched = nil
        message["requestId"] = requestId
        frame["message"] = message
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        onFrame?(String(decoding: data, as: UTF8.self))
    }

    func requestAsset(path: String) async throws -> (data: Data, mime: String) {
        guard !closed, !failed else { throw AssetError.closed }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pendingAssets[id] = continuation
            send(["type": "asset_request", "id": id, "path": path])
            // A request the Mac never answers must not hold the page's loader forever.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.pendingAssets.removeValue(forKey: id)?.resume(throwing: AssetError.refused("timed out"))
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            waitingDeadline?.cancel()
            logger.notice("connected; attaching \(self.sessionId, privacy: .public)")
            send(["type": "attach", "sessionId": sessionId, "token": token, "prefetch": true])
            receive()
            // The Mac answers attach at once; a silent Mac would otherwise leave the view connecting forever.
            waitingDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.fail("The Mac did not answer the attach.")
            }
        case .waiting(let error):
            // Transient: NWConnection keeps retrying under the deadline `start()` armed.
            lastWaitingError = error
            logger.notice("waiting: \(error.localizedDescription, privacy: .public)")
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
            waitingDeadline?.cancel()
            waitingDeadline = nil
            guard let html = object["html"] as? String, !html.isEmpty else {
                fail("The Mac sent an empty page. Update Canopy on the Mac.")
                return
            }
            let scripts = (object["userScripts"] as? [[String: Any]] ?? []).compactMap { entry -> (source: String, atDocumentStart: Bool)? in
                guard let source = entry["source"] as? String else { return nil }
                return (source, entry["atDocumentStart"] as? Bool ?? false)
            }
            prefetchId = (object["prefetchedSessionRequestId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let version = (object["extensionVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            logger.notice("attach_ok with \(scripts.count) user scripts, extension \(version ?? "unknown", privacy: .public)")
            onAttached?(Attached(html: html, userScripts: scripts, extensionVersion: version))
        case "attach_error":
            waitingDeadline?.cancel()
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
            if let abandoned = abandonedPrefetchId,
               (object["message"] as? [String: Any])?["requestId"] as? String == abandoned
            {
                abandonedPrefetchId = nil
                return
            }
            if let prefetchId,
               let message = object["message"] as? [String: Any],
               message["type"] as? String == "response", message["requestId"] as? String == prefetchId
            {
                prefetched = object
                if pageSessionRequestId != nil { deliverPrefetched() }
                return
            }
            onFrame?(String(decoding: line, as: UTF8.self))
        }
    }

    private func fail(_ reason: String) {
        guard !failed, !closed else { return }
        failed = true
        waitingDeadline?.cancel()
        prefetchFallback?.cancel()
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
    /// Bytes of `data` already known to hold no newline, so a multi-megabyte line is scanned once, not once per chunk.
    private var scanned = 0

    func append(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [Data] = []
        var lineStart = data.startIndex
        var searchFrom = data.startIndex + scanned
        while let newline = data[searchFrom...].firstIndex(of: 0x0A) {
            lines.append(Data(data[lineStart..<newline]))
            lineStart = newline + 1
            searchFrom = lineStart
        }
        if lineStart > data.startIndex { data = Data(data[lineStart...]) }
        scanned = data.count
        return lines
    }
}
