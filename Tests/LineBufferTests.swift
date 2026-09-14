import Foundation
import Testing
@testable import CanopyMobile

struct LineBufferTests {
    private func text(_ lines: [Data]) -> [String] { lines.map { String(decoding: $0, as: UTF8.self) } }

    @Test func linesSplitAcrossChunksComeOutWholeAndInOrder() {
        let buffer = LineBuffer()
        #expect(text(buffer.append(Data("{\"a\":".utf8))).isEmpty)
        #expect(text(buffer.append(Data("1}\n{\"b\"".utf8))) == ["{\"a\":1}"])
        #expect(text(buffer.append(Data(":2}\n{\"c\":3}\n{\"d".utf8))) == ["{\"b\":2}", "{\"c\":3}"])
        #expect(text(buffer.append(Data("\":4}\n".utf8))) == ["{\"d\":4}"])
    }

    /// The bound is generous on purpose: the old accumulator took seconds here, so anything near a second is the quadratic scan coming back.
    @Test func aMultiMegabyteLineInSmallChunksIsAssembledInLinearTime() {
        let buffer = LineBuffer()
        let payload = Data(repeating: 0x61, count: 3_000_000) + Data([0x0A])
        let start = Date()
        var lines: [Data] = []
        var offset = 0
        while offset < payload.count {
            lines += buffer.append(payload[offset..<min(offset + 16_384, payload.count)])
            offset += 16_384
        }
        #expect(lines.count == 1 && lines[0].count == 3_000_000)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }
}
