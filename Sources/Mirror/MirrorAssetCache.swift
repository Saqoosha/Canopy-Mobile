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

    /// The on-disk name for an asset path: one flat file per path, with the MIME type kept beside it.
    static func fileName(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "__")
    }

    private var versionDirectory: URL { root.appendingPathComponent(version, isDirectory: true) }

    func load(path: String) -> (data: Data, mime: String)? {
        let name = Self.fileName(for: path)
        guard Self.isSafeComponent(name) else { return nil }
        let file = versionDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file),
              let mime = try? String(contentsOf: file.appendingPathExtension("mime"), encoding: .utf8)
        else { return nil }
        return (data, mime)
    }

    func store(path: String, data: Data, mime: String) {
        let name = Self.fileName(for: path)
        guard Self.isSafeComponent(name) else { return }
        do {
            try evictOtherVersions()
            try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
            let file = versionDirectory.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            try mime.write(to: file.appendingPathExtension("mime"), atomically: true, encoding: .utf8)
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
