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
}
