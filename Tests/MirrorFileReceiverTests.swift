import Foundation
import Testing
@testable import CanopyMobile

@MainActor
struct MirrorFileReceiverTests {
    private func makeReceiver(opened: @escaping (URL) -> Void = { _ in }) -> (MirrorFileReceiver, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorFileTests-\(UUID().uuidString)")
        return (MirrorFileReceiver(root: root, openURL: opened), root)
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

    @Test func aChunkForAnotherTransferIsIgnored() throws {
        let (receiver, root) = makeReceiver()
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "file_begin", "id": "a", "name": "a.txt", "size": 1])
        receiver.handle(["type": "file_chunk", "id": "b", "data": Data("x".utf8).base64EncodedString()])
        receiver.handle(["type": "file_end", "id": "a"])
        #expect(try Data(contentsOf: try #require(receiver.received)).isEmpty)
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

    @Test func onlyWebAndMailURLsOpen() {
        var opened: [URL] = []
        let (receiver, root) = makeReceiver { opened.append($0) }
        defer { try? FileManager.default.removeItem(at: root) }
        receiver.handle(["type": "open_url", "url": "https://example.com/x"])
        receiver.handle(["type": "open_url", "url": "file:///etc/passwd"])
        receiver.handle(["type": "open_url", "url": "tel:123"])
        #expect(opened.map(\.absoluteString) == ["https://example.com/x"])
    }

    @Test func fileFramesAreRecognised() {
        for type in ["file_begin", "file_chunk", "file_end", "open_url"] {
            #expect(MirrorFileWire.isFileFrame(type))
        }
        #expect(!MirrorFileWire.isFileFrame("status"))
        #expect(!MirrorFileWire.isFileFrame(nil))
    }
}
