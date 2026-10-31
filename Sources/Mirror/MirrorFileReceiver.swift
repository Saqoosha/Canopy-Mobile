import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.canopy-app", category: "MirrorFile")

/// A file the phone clicked in a live session, sent back by the Mac as `file_begin` /
/// `file_chunk`* / `file_end`. The Mac sends these only to a client whose `attach` carried
/// `"files": true`. Mirrors `MirrorFileWire` in the Canopy repo, whose `open_url` serves only a
/// Mac's `open` redirect: it is recognised here so it stays out of the page, and never opened.
enum MirrorFileWire {
    static let begin = "file_begin"
    static let chunk = "file_chunk"
    static let end = "file_end"
    static let url = "open_url"

    static func isFileFrame(_ type: String?) -> Bool {
        type == begin || type == chunk || type == end || type == url
    }

    /// Where the bytes of an image the page asks to open full size come from.
    enum ImageSource: Equatable {
        /// A `data:` URL: a Read result the page got live, with its MIME type.
        case inline(Data, mime: String)
        /// The `asset_request` path of the original behind a replay thumbnail's `canopy-asset://ext/img/<id>`;
        /// the Mac's `RemoteMirrorBridge.fullImagePath(forThumbnailURL:)` maps it the same way.
        case asset(String)
    }

    static func imageSource(_ url: String) -> ImageSource? {
        if url.hasPrefix("data:"), let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64") {
            let mime = String(url[url.index(url.startIndex, offsetBy: 5)..<comma].dropLast(";base64".count))
            return Data(base64Encoded: String(url[url.index(after: comma)...])).map { .inline($0, mime: mime) }
        }
        let prefix = "\(MirrorAssetSchemeHandler.scheme)://ext/img/"
        guard url.hasPrefix(prefix), url.count > prefix.count else { return nil }
        return .asset("imgfull/" + url.dropFirst(prefix.count))
    }

    /// `name` with the extension `mime` calls for, since Quick Look picks its previewer by extension.
    static func imageFileName(_ name: String, mime: String) -> String {
        let extensions = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
                          "image/heic": "heic", "image/bmp": "bmp", "image/avif": "avif"]
        guard let wanted = extensions[mime.lowercased()] else { return name }
        let url = URL(fileURLWithPath: name)
        let current = url.pathExtension.lowercased()
        if current == wanted || (wanted == "jpg" && current == "jpeg") { return name }
        return url.deletingPathExtension().lastPathComponent + "." + wanted
    }

    /// The name a `file_begin` may carry: a bare file name, never a path.
    static func sanitizedName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, !raw.contains("/"), !raw.contains("\0"),
              raw != ".", raw != "..", raw.utf8.count <= 255
        else { return nil }
        return raw
    }
}

/// Writes an incoming file under the app's temporary directory and hands it to Quick Look
/// through `received`; the live view reads `current` and `lastError` for its overlay.
@Observable
@MainActor
final class MirrorFileReceiver {
    struct Transfer: Equatable {
        let id: String
        let name: String
        let size: Int
        var received = 0
        var fraction: Double { size > 0 ? min(1, Double(received) / Double(size)) : 0 }
    }

    private(set) var current: Transfer?
    /// Shown for a few seconds after a failed transfer; nil otherwise.
    private(set) var lastError: String?
    /// True once a transfer has run long enough to be worth an overlay.
    private(set) var showsOverlay = false
    /// The last complete file, for `quickLookPreview`; the view sets it back to nil on dismiss,
    /// which deletes it.
    var received: URL? {
        didSet {
            if let oldValue, oldValue != received {
                try? FileManager.default.removeItem(at: oldValue.deletingLastPathComponent())
            }
        }
    }

    /// The name of an image being fetched for Quick Look; nil otherwise.
    private(set) var openingImage: String?
    private var imageRequest = 0

    private let root: URL
    private var handle: FileHandle?
    private var destination: URL?
    private var overlayTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    static let overlayDelay: Duration = .milliseconds(400)
    static let errorHold: Duration = .seconds(4)

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorFiles")) {
        self.root = root
    }

    var isOverlayVisible: Bool { (current != nil && showsOverlay) || lastError != nil || openingImage != nil }

    func handle(_ frame: [String: Any]) {
        switch frame["type"] as? String {
        case MirrorFileWire.begin:
            begin(frame)
        case MirrorFileWire.chunk:
            chunk(frame)
        case MirrorFileWire.end:
            end(frame)
        default:
            break
        }
    }

    private func begin(_ frame: [String: Any]) {
        guard let id = frame["id"] as? String,
              let name = MirrorFileWire.sanitizedName(frame["name"] as? String),
              let size = frame["size"] as? Int, size >= 0
        else {
            logger.error("begin: malformed frame")
            return
        }
        abort(reason: nil)
        errorTask?.cancel()
        lastError = nil
        let dir = root.appendingPathComponent(UUID().uuidString)
        let dest = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            handle = try FileHandle(forWritingTo: dest)
        } catch {
            fail("Could not save \(name): \(error.localizedDescription)")
            return
        }
        destination = dest
        current = Transfer(id: id, name: name, size: size)
        showsOverlay = false
        overlayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.overlayDelay)
            guard let self, !Task.isCancelled, self.current?.id == id else { return }
            self.showsOverlay = true
        }
        logger.notice("receiving \(name, privacy: .private) \(size) bytes")
    }

    private func chunk(_ frame: [String: Any]) {
        guard let id = frame["id"] as? String, current?.id == id,
              let b64 = frame["data"] as? String, let data = Data(base64Encoded: b64)
        else { return }
        guard let transfer = current, transfer.received + data.count <= transfer.size else {
            fail("\(current?.name ?? "file"): more bytes than announced")
            return
        }
        do {
            try handle?.write(contentsOf: data)
            current?.received += data.count
        } catch {
            fail("Could not save \(current?.name ?? "file"): \(error.localizedDescription)")
        }
    }

    private func end(_ frame: [String: Any]) {
        guard let id = frame["id"] as? String, let transfer = current, transfer.id == id else { return }
        if let error = frame["error"] as? String {
            fail("\(transfer.name): \(error)")
            return
        }
        guard transfer.received == transfer.size else {
            fail("\(transfer.name): incomplete (\(transfer.received) of \(transfer.size) bytes)")
            return
        }
        try? handle?.close()
        handle = nil
        overlayTask?.cancel()
        let dest = destination
        current = nil
        showsOverlay = false
        destination = nil
        received = dest
        logger.notice("received \(transfer.name, privacy: .private)")
    }

    /// Opens an image the page asked for full size (a Read thumbnail's tap) in the same Quick Look as a file.
    /// `fetch` answers an `asset_request` path. Only the latest tap opens; an in-flight transfer is left alone.
    func showImage(url: String, name: String?, fetch: (String) async throws -> (data: Data, mime: String)) async {
        imageRequest += 1
        let request = imageRequest
        let shownName = MirrorFileWire.sanitizedName(name) ?? "image"
        guard let source = MirrorFileWire.imageSource(url) else {
            logger.error("openImage: unsupported URL (\(url.prefix(while: { $0 != ":" }).prefix(24), privacy: .public))")
            report("\(shownName): not an image this app can open")
            return
        }
        let data: Data, mime: String
        switch source {
        case .inline(let bytes, let type):
            (data, mime) = (bytes, type)
        case .asset(let path):
            openingImage = shownName
            do {
                (data, mime) = try await fetch(path)
            } catch {
                guard imageRequest == request else { return }
                openingImage = nil
                logger.error("openImage: fetch failed: \(error.localizedDescription, privacy: .public)")
                report("\(shownName): \(error.localizedDescription)")
                return
            }
            guard imageRequest == request else { return }
            openingImage = nil
        }
        let fileName = MirrorFileWire.imageFileName(shownName, mime: mime)
        let dir = root.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(fileName))
        } catch {
            logger.error("openImage: write failed: \(error.localizedDescription, privacy: .public)")
            report("Could not save \(fileName): \(error.localizedDescription)")
            return
        }
        errorTask?.cancel()
        lastError = nil
        received = dir.appendingPathComponent(fileName)
        logger.notice("openImage: opened \(data.count) bytes")
    }

    private func fail(_ message: String) {
        abort(reason: message)
    }

    /// The connection went while a file was in flight: drop the partial file and say so.
    func connectionDropped() {
        // A fetch that answers after this has nowhere to show.
        imageRequest += 1
        openingImage = nil
        guard let name = current?.name else { return }
        abort(reason: "\(name): connection lost")
    }

    /// Drops an in-flight transfer and its partial file. `reason` nil is a silent supersede.
    private func abort(reason: String?) {
        overlayTask?.cancel()
        try? handle?.close()
        handle = nil
        if let destination, current != nil { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        destination = nil
        current = nil
        showsOverlay = false
        guard let reason else { return }
        report(reason)
    }

    /// Logs `reason` and shows it in the overlay for `errorHold`.
    private func report(_ reason: String) {
        logger.error("\(reason, privacy: .private)")
        lastError = reason
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: Self.errorHold)
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }
}
