import Foundation
import Testing
@testable import CanopyMobile

@MainActor
struct MirrorFileReceiverTests {
    private func makeReceiver() -> (MirrorFileReceiver, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorFileTests-\(UUID().uuidString)")
        return (MirrorFileReceiver(root: root), root)
    }

    @Test func chunksAssembleIntoTheFile() throws {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Data("%PDF-1.7 ".utf8), second = Data("body".utf8)
        receiver.handle(["type": "file_begin", "id": "a", "name": "tag.pdf", "size": first.count + second.count, "host": "mac"])
        receiver.handle(["type": "file_chunk", "id": "a", "data": first.base64EncodedString()])
        #expect(receiver.current?.received == first.count)
        receiver.handle(["type": "file_chunk", "id": "a", "data": second.base64EncodedString()])
        receiver.handle(["type": "file_end", "id": "a"])
        let url = try #require(receiver.received)
        #expect(url.lastPathComponent == "tag.pdf")
        #expect(try Data(contentsOf: url) == first + second)
        #expect(receiver.current == nil)
    }

    @Test func aSecondFileLeavesTheShownOneUntilItIsDismissed() throws {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = Data("1".utf8).base64EncodedString()
        receiver.handle(["type": "file_begin", "id": "a", "name": "a.txt", "size": 1])
        receiver.handle(["type": "file_chunk", "id": "a", "data": one])
        receiver.handle(["type": "file_end", "id": "a"])
        let first = try #require(receiver.received)
        receiver.handle(["type": "file_begin", "id": "b", "name": "b.txt", "size": 1])
        #expect(FileManager.default.fileExists(atPath: first.path))
        receiver.received = nil
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    @Test func aMalformedBeginLeavesTheTransferInFlight() {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "file_begin", "id": "a", "name": "a.txt", "size": 1])
        receiver.handle(["type": "file_begin", "id": "b", "name": "../x", "size": 1])
        #expect(receiver.current?.id == "a")
    }

    @Test func aShortFileIsNotOpened() {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "file_begin", "id": "a", "name": "a.txt", "size": 2])
        // A chunk for another transfer is not this one's bytes.
        receiver.handle(["type": "file_chunk", "id": "b", "data": Data("x".utf8).base64EncodedString()])
        receiver.handle(["type": "file_chunk", "id": "a", "data": Data("x".utf8).base64EncodedString()])
        receiver.handle(["type": "file_end", "id": "a"])
        #expect(receiver.received == nil)
        #expect(receiver.lastError == "a.txt: incomplete (1 of 2 bytes)")
    }

    @Test func bytesPastTheAnnouncedSizeAreRefused() {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "file_begin", "id": "a", "name": "a.txt", "size": 2])
        receiver.handle(["type": "file_chunk", "id": "a", "data": Data("abc".utf8).base64EncodedString()])
        #expect(receiver.current == nil)
        #expect(receiver.lastError == "a.txt: more bytes than announced")
    }

    @Test func aNewTransferClearsTheLastError() {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "file_begin", "id": "a", "name": "a.bin", "size": 3])
        receiver.handle(["type": "file_end", "id": "a", "error": "read failed"])
        receiver.handle(["type": "file_begin", "id": "b", "name": "b.bin", "size": 3])
        #expect(receiver.lastError == nil)
        #expect(receiver.current?.id == "b")
    }

    @Test func aDropMidTransferRemovesThePartialFile() throws {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "file_begin", "id": "a", "name": "a.bin", "size": 10])
        receiver.handle(["type": "file_chunk", "id": "a", "data": Data("12345".utf8).base64EncodedString()])
        receiver.connectionDropped()
        #expect(receiver.current == nil)
        #expect(receiver.received == nil)
        #expect(receiver.lastError == "a.bin: connection lost")
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix("a.bin") }
        #expect(leftovers.isEmpty)
    }

    @Test func anErrorEndReportsAndKeepsNothing() {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "file_begin", "id": "a", "name": "a.bin", "size": 3])
        receiver.handle(["type": "file_end", "id": "a", "error": "read failed"])
        #expect(receiver.received == nil)
        #expect(receiver.lastError == "a.bin: read failed")
    }

    @Test func aPathInTheNameIsRefused() {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "file_begin", "id": "a", "name": "../escape.txt", "size": 1])
        #expect(receiver.current == nil)
        #expect(MirrorFileWire.sanitizedName("..") == nil)
        #expect(MirrorFileWire.sanitizedName("a/b") == nil)
        #expect(MirrorFileWire.sanitizedName("tag.pdf") == "tag.pdf")
    }

    @Test func anOpenURLFrameIsIgnored() {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "open_url", "url": "https://example.com/x"])
        #expect(receiver.current == nil)
        #expect(receiver.received == nil)
        #expect(receiver.lastError == nil)
    }

    @Test func fileFramesAreRecognised() {
        for type in ["file_begin", "file_chunk", "file_end", "open_url"] {
            #expect(MirrorFileWire.isFileFrame(type))
        }
        #expect(!MirrorFileWire.isFileFrame("status"))
        #expect(!MirrorFileWire.isFileFrame(nil))
    }

    @Test func imageSourcesFromThePagesURLs() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(MirrorFileWire.imageSource("data:image/png;base64," + png.base64EncodedString()) == .inline(png))
        #expect(MirrorFileWire.imageSource("canopy-asset://ext/img/ab12") == .asset("imgfull/ab12"))
        #expect(MirrorFileWire.imageSource("canopy-asset://ext/img/") == nil)
        #expect(MirrorFileWire.imageSource("data:image/svg+xml,<svg/>") == nil)
        #expect(MirrorFileWire.imageSource("https://example.com/a.png") == nil)
    }

    @Test func aLiveThumbnailOpensFromItsOwnBytes() async throws {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        await receiver.showImage(url: "data:image/png;base64," + png.base64EncodedString(), name: "list.png") { _ in
            Issue.record("an inline image needs no request")
            return Data()
        }
        let url = try #require(receiver.received)
        #expect(url.lastPathComponent == "list.png")
        #expect(try Data(contentsOf: url) == png)
    }

    @Test func aReplayThumbnailAsksTheMacForTheOriginal() async throws {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        var asked: [String] = []
        await receiver.showImage(url: "canopy-asset://ext/img/ab12", name: "../evil") { path in
            asked.append(path)
            return Data("full".utf8)
        }
        #expect(asked == ["imgfull/ab12"])
        let url = try #require(receiver.received)
        #expect(url.lastPathComponent == "image.png")
        #expect(try Data(contentsOf: url) == Data("full".utf8))
    }

    @Test func aFailedImageFetchSaysSoAndLeavesATransferRunning() async {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "file_begin", "id": "a", "name": "a.txt", "size": 1])
        await receiver.showImage(url: "canopy-asset://ext/img/ab12", name: "list.png") { _ in
            throw MirrorLink.AssetError.refused("not found")
        }
        #expect(receiver.received == nil)
        #expect(receiver.lastError?.hasPrefix("list.png: ") == true)
        #expect(receiver.current?.id == "a")
    }
}
