import Compression
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
    /// The Mac's status bar, on attach and after every change; never called by an older Mac.
    var onStatus: ((MirrorStatus) -> Void)?
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
    /// The page's own transcript request, once the prefetch was given up on.
    private var pageSessionResponseId: String?
    /// Frames that arrived after the Mac took the prefetch snapshot, held so the page sees the transcript first.
    private var framesBehindPrefetch: [Data] = []
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
        framesBehindPrefetch = []
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
                // Held frames stay held until the Mac answers this request, or the page would
                // apply them and then have the older transcript land on top.
                self.pageSessionResponseId = object["requestId"] as? String
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
        flushFramesBehindPrefetch()
    }

    private func flushFramesBehindPrefetch() {
        let waiting = framesBehindPrefetch
        framesBehindPrefetch = []
        for line in waiting { onFrame?(String(decoding: line, as: UTF8.self)) }
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
            // `compress`: the prefetched replay is one line of a megabyte or more, and that line is what
            // a slow uplink spends its time on. A Mac without Canopy PR #238 ignores the key and keeps sending plain lines.
            send(["type": "attach", "sessionId": sessionId, "token": token, "prefetch": true, "status": true,
                  "compress": MirrorWire.compressionName])
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
            if let data, !data.isEmpty {
                // The log names the cause; the user's message does not, since none of them is theirs to fix.
                func refuse(_ cause: String) {
                    logger.error("\(cause, privacy: .public); closing")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.fail("The Mac sent a line the app cannot read.") }
                    }
                }
                guard let frames = self.buffer.append(data) else {
                    refuse("framer refused the stream: \(self.buffer.refusal ?? "unknown")")
                    return
                }
                guard let lines = MirrorWire.lines(from: frames) else {
                    refuse("a Z payload did not decode to the length its header promised")
                    return
                }
                // In practice the transcript replay; the wire count is the proof the Mac compressed it.
                for (frame, line) in zip(frames, lines) where line.count >= 1 << 20 {
                    let wire = if case .compressed(let payload, _) = frame { payload.count } else { line.count }
                    logger.notice("received a \(line.count, privacy: .public)-byte line (\(wire, privacy: .public) on the wire)")
                }
                if !lines.isEmpty {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { lines.forEach(self.handleLine) }
                    }
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

    func handleLine(_ line: Data) {
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
        case "status":
            // Not a webview frame: it is read here and never posted into the page.
            guard let status = MirrorStatus(frame: object) else {
                logger.error("status line missing fields; ignored")
                return
            }
            onStatus?(status)
        case "asset_response":
            guard let id = object["id"] as? String, let continuation = pendingAssets.removeValue(forKey: id) else { return }
            if let base64 = object["base64"] as? String, let data = Data(base64Encoded: base64) {
                continuation.resume(returning: (data, object["mime"] as? String ?? "application/octet-stream"))
            } else {
                continuation.resume(throwing: AssetError.refused(object["error"] as? String ?? "unreadable"))
            }
        default:
            if let pending = pageSessionResponseId,
               (object["message"] as? [String: Any])?["requestId"] as? String == pending
            {
                pageSessionResponseId = nil
                onFrame?(String(decoding: line, as: UTF8.self))
                flushFramesBehindPrefetch()
                return
            }
            if pageSessionResponseId != nil,
               (object["message"] as? [String: Any])?["type"] as? String != "response"
            {
                framesBehindPrefetch.append(line)
                return
            }
            if let abandoned = abandonedPrefetchId,
               (object["message"] as? [String: Any])?["requestId"] as? String == abandoned
            {
                abandonedPrefetchId = nil
                return
            }
            if let prefetchId, let message = object["message"] as? [String: Any] {
                if message["type"] as? String == "response" {
                    if message["requestId"] as? String == prefetchId {
                        prefetched = object
                        if pageSessionRequestId != nil { deliverPrefetched() }
                        return
                    }
                    // Every other response answers a request the page made itself — init among
                    // them, and the page cannot ask for its transcript until that one lands.
                    onFrame?(String(decoding: line, as: UTF8.self))
                    return
                }
                // What the session did after the snapshot waits for it, or the page would
                // apply an older transcript over newer turns.
                framesBehindPrefetch.append(line)
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

/// The bytes on a mirror socket: NDJSON, with large lines optionally sent compressed.
///
/// A plain frame is one JSON object followed by `\n`. A compressed frame is the header
/// `Z <n> <m>\n` followed by exactly `n` bytes of Brotli (`Compression`'s `COMPRESSION_BROTLI`)
/// that decode to the `m`-byte JSON object, no trailing newline. `Z` cannot begin a JSON value,
/// so the first byte tells the two apart. The Mac sends `Z` frames only to a client whose
/// `attach` carried `"compress": "br"`, and only for lines of 4 KB or more that Brotli shrinks;
/// the phone decodes by first byte rather than by the `attach_ok` echo, so a Mac that never
/// compresses (before Canopy PR #238) runs the same code path. Mirrors `MirrorWire` in the Canopy repo.
enum MirrorWire {
    /// The value of the `compress` key both sides exchange at attach (HTTP's token for Brotli).
    static let compressionName = "br"

    /// The JSON line inside a `Z` frame's payload, or nil when the bytes do not decode to
    /// exactly `rawCount` bytes. Re-checks the size limit the framer already applied, since
    /// a `Frame` can be built by hand.
    static func decode(compressed payload: Data, rawCount: Int) -> Data? {
        guard rawCount >= 0, rawCount <= LineBuffer.maxLineBytes else { return nil }
        guard rawCount > 0 else { return payload.isEmpty ? Data() : nil }
        // Guards `baseAddress!` below; no test can pin it, since an empty Data decodes to 0 bytes here anyway.
        guard !payload.isEmpty else { return nil }
        // One spare byte, so a stream longer than `rawCount` writes past it and fails the
        // equality whatever the codec reports for an undersized destination.
        let capacity = rawCount + 1
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                    nil, COMPRESSION_BROTLI)
            }
        }
        guard written == rawCount else { return nil }
        out.count = rawCount
        return out
    }

    /// The JSON lines the frames carry, decoding compressed ones on the way; nil when a
    /// payload does not decode, on which the caller closes rather than skips.
    static func lines(from frames: [LineBuffer.Frame]) -> [Data]? {
        var lines: [Data] = []
        lines.reserveCapacity(frames.count)
        for frame in frames {
            switch frame {
            case .line(let data):
                lines.append(data)
            case .compressed(let payload, let rawCount):
                guard let line = decode(compressed: payload, rawCount: rawCount) else { return nil }
                lines.append(line)
            }
        }
        return lines
    }
}

/// Accumulates socket bytes and yields complete frames: newline-terminated lines, or the
/// payload of a `Z` frame once all of it has arrived.
final class LineBuffer: @unchecked Sendable {
    enum Frame: Equatable {
        /// One JSON line, newline stripped.
        case line(Data)
        /// A `Z` frame's Brotli bytes and the line length its header promised, for `MirrorWire.decode`.
        case compressed(Data, rawCount: Int)
    }

    /// The Mac client's bound. The Mac fits a Mac client's replay under it (`ShimProcess.mirrorReplayMaxBytes`,
    /// 12 MiB) but not yet a phone's, so a session whose last 10 typed turns exceed it closes the link here.
    static let maxLineBytes = 16 << 20
    /// 20 bytes holds `Z <8 digits> <8 digits>\n`; 24 leaves slack.
    static let maxHeaderBytes = 24
    private let lock = NSLock()
    private var data = Data()
    /// Bytes at the head of `data` already known to hold no newline, so a multi-megabyte plain
    /// line is scanned once, not once per chunk. Reset whenever the head is consumed.
    private var scanned = 0
    private var lastRefusal: String?
    /// Why the last `append` returned nil, for the caller's log.
    var refusal: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastRefusal
    }

    /// Complete frames, or nil once the stream is unusable: a line or `Z` length over
    /// `maxLineBytes`, or a malformed `Z` header. The offending bytes stay at the head, so
    /// every later call is nil too; the caller closes the connection.
    func append(_ chunk: Data) -> [Frame]? {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var frames: [Frame] = []
        var head = data.startIndex
        // One copy per append however many frames it yielded, not one per frame (a 1 MiB chunk of 100-byte lines is 10,000 frames).
        defer { if head > data.startIndex { data = Data(data[head...]) } }
        while head < data.endIndex {
            if data[head] == UInt8(ascii: "Z") {
                // `Z <n> <m>\n` then n bytes, counted: a pending payload costs a 24-byte header
                // parse per chunk, not a scan — and the payload is binary, so it may hold 0x0A itself.
                let window = data[head..<min(head + Self.maxHeaderBytes, data.endIndex)]
                guard let headerEnd = window.firstIndex(of: 0x0A) else {
                    if window.count >= Self.maxHeaderBytes { return refuse("no newline within \(Self.maxHeaderBytes) bytes of a Z header") }
                    break
                }
                let header = String(decoding: data[head..<headerEnd], as: UTF8.self)
                let fields = header.split(separator: " ", omittingEmptySubsequences: false)
                guard fields.count == 3, fields[0] == "Z",
                      let count = Int(fields[1]), count >= 0, count <= Self.maxLineBytes,
                      let rawCount = Int(fields[2]), rawCount >= 0, rawCount <= Self.maxLineBytes
                else { return refuse("malformed Z header \"\(header)\"") }
                let payloadStart = headerEnd + 1
                guard data.endIndex - payloadStart >= count else { break }
                let payloadEnd = payloadStart + count
                frames.append(.compressed(Data(data[payloadStart..<payloadEnd]), rawCount: rawCount))
                head = payloadEnd
                scanned = 0
                continue
            }
            guard let newline = data[(head + scanned)...].firstIndex(of: 0x0A) else {
                if data.endIndex - head > Self.maxLineBytes { return refuse("plain line over \(Self.maxLineBytes) bytes") }
                scanned = data.endIndex - head
                break
            }
            guard newline - head <= Self.maxLineBytes else { return refuse("plain line of \(newline - head) bytes") }
            frames.append(.line(Data(data[head..<newline])))
            head = newline + 1
            scanned = 0
        }
        return frames
    }

    private func refuse(_ reason: String) -> [Frame]? {
        lastRefusal = reason
        return nil
    }
}
