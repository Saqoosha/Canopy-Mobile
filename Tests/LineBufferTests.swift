import Compression
import Foundation
import Testing
@testable import CanopyMobile

struct LineBufferTests {
    private func text(_ frames: [LineBuffer.Frame]?) -> [String]? {
        frames.map { $0.map { frame in
            if case .line(let data) = frame { String(decoding: data, as: UTF8.self) } else { "<Z>" }
        } }
    }

    /// The frame Canopy's `MirrorWire.encode` produced (`COMPRESSION_BROTLI`, checked with `brotli -d`)
    /// for `{"type":"user","text":"a line that repeats"},` repeated 120 times: 5400 bytes as 71.
    private static let fixtureLine = Data(String(repeating: "{\"type\":\"user\",\"text\":\"a line that repeats\"},", count: 120).utf8)
    private static let fixturePayload = Data(base64Encoded:
        "GxcVAICqqqrq/3QV4LMcTnq7yYEBVAEUFARUWQFUQUEH4GAsiMQkMcCdNjffUgaAB90kCvbihEM8QkFYb4OmGrLJZGjhuw4=")!
    private static var fixtureFrame: Data { Data("Z 71 5400\n".utf8) + fixturePayload }

    @Test func linesSplitAcrossChunksComeOutWholeAndInOrder() {
        let buffer = LineBuffer()
        #expect(text(buffer.append(Data("{\"a\":".utf8))) == [])
        #expect(text(buffer.append(Data("1}\n{\"b\"".utf8))) == ["{\"a\":1}"])
        #expect(text(buffer.append(Data(":2}\n{\"c\":3}\n{\"d".utf8))) == ["{\"b\":2}", "{\"c\":3}"])
        #expect(text(buffer.append(Data("\":4}\n".utf8))) == ["{\"d\":4}"])
    }

    /// The bound is generous on purpose: the old accumulator took seconds here, so anything near a second is the quadratic scan coming back.
    @Test func aMultiMegabyteLineInSmallChunksIsAssembledInLinearTime() {
        let buffer = LineBuffer()
        let payload = Data(repeating: 0x61, count: 3_000_000) + Data([0x0A])
        let start = Date()
        var frames: [LineBuffer.Frame] = []
        var offset = 0
        while offset < payload.count {
            frames += buffer.append(payload[offset..<min(offset + 16_384, payload.count)]) ?? []
            offset += 16_384
        }
        #expect(frames.count == 1 && frames[0] == .line(Data(repeating: 0x61, count: 3_000_000)))
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    /// The other shape: one chunk, many lines. Copying the tail once per line took 1.3 s here (measured 2026-09-19).
    @Test func manySmallLinesInOneChunkAreFramedInLinearTime() throws {
        let chunk = Data(String(repeating: String(repeating: "x", count: 99) + "\n", count: 10_000).utf8)
        let start = Date()
        let frames = try #require(LineBuffer().append(chunk))
        #expect(frames.count == 10_000)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test func theMacsFixtureFrameDecodesToItsLine() throws {
        #expect(Self.fixturePayload.count == 71)
        let buffer = LineBuffer()
        let frames = try #require(buffer.append(Self.fixtureFrame))
        #expect(frames == [.compressed(Self.fixturePayload, rawCount: 5400)])
        let lines = try #require(MirrorWire.lines(from: frames))
        #expect(lines == [Self.fixtureLine])
    }

    /// The header, the header/payload seam and the payload itself all get cut: the framer must count, not scan.
    @Test func aCompressedFrameSplitAtEveryChunkBoundaryReassembles() throws {
        let stream = Data("{\"before\":1}\n".utf8) + Self.fixtureFrame + Data("{\"after\":2}\n".utf8)
        for chunkSize in [1, 3, 7, 13, 64] {
            let buffer = LineBuffer()
            var frames: [LineBuffer.Frame] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                frames += try #require(buffer.append(stream[offset..<end]), "chunk size \(chunkSize)")
                offset = end
            }
            let lines = try #require(MirrorWire.lines(from: frames))
            #expect(lines == [Data("{\"before\":1}".utf8), Self.fixtureLine, Data("{\"after\":2}".utf8)], "chunk size \(chunkSize)")
        }
    }

    /// Brotli output is binary, so the byte the plain path splits on can sit inside a payload;
    /// the framer counts the header's `n` bytes and never looks at them.
    @Test func aNewlineInsideACompressedPayloadIsPayloadNotAFrameEnd() throws {
        let stream = Data("Z 3 5\n".utf8) + Data([0x0A, 0x0A, 0x0A]) + Data("{\"tail\":1}\n".utf8)
        let frames = try #require(LineBuffer().append(stream))
        #expect(frames == [.compressed(Data([0x0A, 0x0A, 0x0A]), rawCount: 5), .line(Data("{\"tail\":1}".utf8))])
    }

    /// What the Mac's encoder does to a line this app then reads, end to end through the framework.
    @Test func aLineEncodedWithTheFrameworkRoundTrips() throws {
        let line = Data(String(repeating: "{\"type\":\"assistant\",\"text\":\"round trip\"},", count: 200).utf8)
        let payload = try #require(Self.brotli(line))
        #expect(payload.count < line.count)
        let stream = Data("Z \(payload.count) \(line.count)\n".utf8) + payload + Data("{\"tail\":1}\n".utf8)
        let frames = try #require(LineBuffer().append(stream))
        #expect(MirrorWire.lines(from: frames) == [line, Data("{\"tail\":1}".utf8)])
    }

    @Test func anEmptyZFrameIsAnEmptyLine() throws {
        let frames = try #require(LineBuffer().append(Data("Z 0 0\n{\"x\":1}\n".utf8)))
        #expect(frames == [.compressed(Data(), rawCount: 0), .line(Data("{\"x\":1}".utf8))])
        #expect(MirrorWire.lines(from: frames) == [Data(), Data("{\"x\":1}".utf8)])
    }

    @Test func aMalformedHeaderEndsTheStreamAndStaysEnded() {
        for header in ["Z 5\n", "Z x 9\n", "Z -1 4\n", "Z 4 -1\n", "Z 4 4 4\n", "Zebra\n", "ZZ 3 5\n", "Z  5 6\n", "Z 5 6 \n",
                       "Z 16777217 1\n", "Z 1 16777217\n", "Z 00000000000000000071 5400\n"] {
            let buffer = LineBuffer()
            #expect(buffer.append(Data(header.utf8)) == nil, Comment(rawValue: header))
            #expect(buffer.refusal?.isEmpty == false, Comment(rawValue: header))
            #expect(buffer.append(Data("{\"x\":1}\n".utf8)) == nil, "after \(header)")
        }
    }

    @Test func aHeaderWithNoNewlineWithin24BytesEndsTheStream() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data("Z 12345678 1234".utf8)) == [])
        #expect(buffer.append(Data("5678 extra".utf8)) == nil)
        // Exactly 24 bytes is the last chance for the newline.
        #expect(LineBuffer().append(Data("Z 12345678 12345678 wxy".utf8)) == [])
        #expect(LineBuffer().append(Data("Z 12345678 12345678 wxyz".utf8)) == nil)
    }

    /// `maxLineBytes` itself is legal, on the plain path and in both header fields.
    @Test func theExactLimitIsAccepted() throws {
        let plain = LineBuffer()
        #expect(plain.append(Data(repeating: 0x61, count: LineBuffer.maxLineBytes)) == [])
        #expect(try #require(plain.append(Data([0x0A]))).map { if case .line(let d) = $0 { d.count } else { -1 } } == [LineBuffer.maxLineBytes])
        #expect(LineBuffer().append(Data("Z 16777216 16777216\n".utf8)) == [])
    }

    @Test func aPayloadThatDoesNotDecodeToTheHeadersLengthIsRefused() throws {
        // Right bytes, wrong promise, in both directions; and bytes that are not Brotli at all.
        #expect(MirrorWire.decode(compressed: Self.fixturePayload, rawCount: 5399) == nil)
        #expect(MirrorWire.decode(compressed: Self.fixturePayload, rawCount: 5401) == nil)
        #expect(MirrorWire.decode(compressed: Data("not brotli".utf8), rawCount: 10) == nil)
        #expect(MirrorWire.decode(compressed: Data(), rawCount: 10) == nil)
        #expect(MirrorWire.decode(compressed: Self.fixturePayload, rawCount: 0) == nil)
        #expect(MirrorWire.lines(from: [.compressed(Self.fixturePayload, rawCount: 5399)]) == nil)
        // A payload that really expands past the bound, so the bound is what refuses it and not the length check.
        let oversize = try #require(Self.brotli(Data(count: LineBuffer.maxLineBytes + 1)))
        #expect(oversize.count < 100)
        #expect(MirrorWire.decode(compressed: oversize, rawCount: LineBuffer.maxLineBytes + 1) == nil)
    }

    /// Frames are bounded one by one, so a batch of maximum frames is bounded in total too; a few
    /// dozen wire bytes must not become gigabytes of memory.
    @Test func aBatchThatWouldDecodePastTheBatchLimitIsRefused() throws {
        let zeros = Data(count: LineBuffer.maxLineBytes)
        let payload = try #require(Self.brotli(zeros))
        #expect(payload.count < 100)
        let frame = LineBuffer.Frame.compressed(payload, rawCount: LineBuffer.maxLineBytes)
        #expect(MirrorWire.lines(from: Array(repeating: frame, count: 4))?.count == 4)
        #expect(MirrorWire.lines(from: Array(repeating: frame, count: 5)) == nil)
        // Plain lines count toward the same total.
        #expect(MirrorWire.lines(from: Array(repeating: frame, count: 4) + [.line(Data([0x7B]))]) == nil)
    }

    @Test func aPlainLineOverTheLimitEndsTheStream() {
        let buffer = LineBuffer()
        #expect(buffer.append(Data(repeating: 0x61, count: LineBuffer.maxLineBytes + 1)) == nil)
    }

    private static func brotli(_ line: Data) -> Data? {
        let capacity = max(line.count, 64)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            line.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, line.count,
                    nil, COMPRESSION_BROTLI)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }
}
