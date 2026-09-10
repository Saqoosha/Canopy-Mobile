import Foundation
import Testing
@testable import CanopyMobile

struct SessionEventImageTests {
    private func decode(_ json: String) throws -> SessionEventRecord {
        let decoder = JSONDecoder()
        return try decoder.decode(SessionEventRecord.self, from: Data(json.utf8))
    }

    @Test("An image field decodes into the record")
    func decodesAnImage() throws {
        let record = try decode("""
        {"seq":1,"eventId":"e1","sessionId":"s1","kind":"tool","text":"Read: shot.png",
         "at":0,"image":{"width":1440,"height":900,"bytes":434831}}
        """)
        #expect(record.image?.width == 1440)
        #expect(record.image?.height == 900)
        #expect(record.image?.bytes == 434831)
    }

    // 画像を持たないイベントが圧倒的多数。ここが optional でないと
    // 全イベントのデコードが落ちる。
    @Test("An event with no image field decodes with a nil image")
    func decodesWithoutAnImage() throws {
        let record = try decode("""
        {"seq":1,"eventId":"e1","sessionId":"s1","kind":"assistant","text":"hi","at":0}
        """)
        #expect(record.image == nil)
    }

    // 相手は Mac で、先に出るのはあちら。知らないキーで落ちてはいけない。
    @Test("An image field with unknown keys still decodes")
    func toleratesUnknownKeys() throws {
        let record = try decode("""
        {"seq":1,"eventId":"e1","sessionId":"s1","kind":"tool","text":"Read: shot.png",
         "at":0,"image":{"width":10,"height":20,"bytes":30,"rotation":90}}
        """)
        #expect(record.image?.width == 10)
    }

    // **これが一番大事。** 画像フィールドが壊れていても、そのページの
    // 残りは生きなければいけない。backfill は配列でデコードされるので、
    // 1 件の throw が最大 200 件を落とす（`Kind.other` と同じ理由）。
    @Test("A malformed image field does not fail the whole record")
    func survivesAMalformedImage() throws {
        let record = try decode("""
        {"seq":1,"eventId":"e1","sessionId":"s1","kind":"tool","text":"Read: shot.png",
         "at":0,"image":{"width":"wide"}}
        """)
        #expect(record.image == nil)
        #expect(record.text == "Read: shot.png")
    }
}
