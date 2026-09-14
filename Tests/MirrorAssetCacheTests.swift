import Foundation
import Testing
@testable import CanopyMobile

struct MirrorAssetCacheTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mirror-assets-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aMacWithoutAVersionGetsNoCache() {
        #expect(MirrorAssetCache(version: nil) == nil)
        #expect(MirrorAssetCache(version: "") == nil)
        #expect(MirrorAssetCache(version: "../x") == nil)
    }

    @Test func roundTripsAnAssetUnderItsVersion() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try #require(MirrorAssetCache(version: "2.1.270", root: root))
        #expect(cache.load(path: "webview/index.js") == nil)
        cache.store(path: "webview/index.js", data: Data("console.log(1)".utf8), mime: "text/javascript")
        let hit = try #require(cache.load(path: "webview/index.js"))
        #expect(String(decoding: hit.data, as: UTF8.self) == "console.log(1)")
        #expect(hit.mime == "text/javascript")
    }

    @Test func aNewVersionEvictsTheOldOne() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try #require(MirrorAssetCache(version: "2.1.269", root: root))
        old.store(path: "webview/index.js", data: Data("old".utf8), mime: "text/javascript")
        let new = try #require(MirrorAssetCache(version: "2.1.270", root: root))
        new.store(path: "webview/index.css", data: Data("new".utf8), mime: "text/css")
        #expect(old.load(path: "webview/index.js") == nil)
        #expect(new.load(path: "webview/index.css") != nil)
    }

    @Test func aPathThatEscapesItsDirectoryIsRefused() {
        #expect(MirrorAssetCache.isSafeComponent(MirrorAssetCache.fileName(for: "webview/index.js")))
        #expect(!MirrorAssetCache.isSafeComponent(".."))
        #expect(!MirrorAssetCache.isSafeComponent(""))
    }
}
