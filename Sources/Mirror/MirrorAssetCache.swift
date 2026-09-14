import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.canopy-app", category: "MirrorAssetCache")

/// Extension assets already fetched from a Mac, on disk under the extension version they came from.
///
/// The Mac's `attach_ok` names its extension version; a fetched file is
/// stored under that version and served from disk on the next attach to
/// any Mac running the same version. Other versions are removed the first
/// time a new one is seen, so the cache holds one extension at a time.
struct MirrorAssetCache {
    let version: String
    private let root: URL

    /// nil when the Mac sent no version: nothing is cached and nothing is served.
    init?(version: String?, root: URL = MirrorAssetCache.defaultRoot) {
        guard let version, Self.isSafeComponent(version) else { return nil }
        self.version = version
        self.root = root
    }

    static let defaultRoot: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("mirror-assets", isDirectory: true)
    }()

    /// A version or a file name that cannot escape its directory.
    static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/") && !component.contains("\0")
    }

    /// The on-disk name for an asset path: its SHA-256, so distinct paths never share a file.
    static func fileName(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var versionDirectory: URL { root.appendingPathComponent(version, isDirectory: true) }

    /// One file per asset: the MIME type, a newline, then the bytes, so the pair is written and read together.
    func load(path: String) -> (data: Data, mime: String)? {
        guard let stored = try? Data(contentsOf: versionDirectory.appendingPathComponent(Self.fileName(for: path))),
              let newline = stored.firstIndex(of: 0x0A),
              let mime = String(data: stored[..<newline], encoding: .utf8), !mime.isEmpty
        else { return nil }
        return (Data(stored[stored.index(after: newline)...]), mime)
    }

    func store(path: String, data: Data, mime: String) {
        guard !mime.contains("\n") else { return }
        do {
            try evictOtherVersions()
            try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
            var stored = Data(mime.utf8)
            stored.append(0x0A)
            stored.append(data)
            try stored.write(to: versionDirectory.appendingPathComponent(Self.fileName(for: path)), options: .atomic)
        } catch {
            logger.error("store \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func evictOtherVersions() throws {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != version {
            try FileManager.default.removeItem(at: entry)
            logger.notice("evicted assets of extension \(entry.lastPathComponent, privacy: .public)")
        }
    }
}
