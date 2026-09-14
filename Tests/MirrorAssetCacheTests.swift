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

    @Test func pathsThatFlattenAlikeStillGetTheirOwnFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try #require(MirrorAssetCache(version: "2.1.270", root: root))
        cache.store(path: "a/b", data: Data("slash".utf8), mime: "text/plain")
        cache.store(path: "a__b", data: Data("underscores".utf8), mime: "text/css")
        cache.store(path: "a/b.mime", data: Data("mime-named".utf8), mime: "application/octet-stream")
        #expect(cache.load(path: "a/b").map { String(decoding: $0.data, as: UTF8.self) } == "slash")
        #expect(cache.load(path: "a/b")?.mime == "text/plain")
        #expect(cache.load(path: "a__b").map { String(decoding: $0.data, as: UTF8.self) } == "underscores")
    }
}
