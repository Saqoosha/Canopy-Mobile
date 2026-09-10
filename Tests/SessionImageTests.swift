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

/// A stub for `URLProtocol` that lets a test answer a request without
/// touching the network. Registered per-session (`URLSessionConfiguration
/// .protocolClasses`), never globally, so tests in this file cannot race
/// each other over the handler.
///
/// `URLProtocol`'s override points run on URLSession's own background queue,
/// never the caller's — so the handler is stored behind a lock rather than as
/// a plain static var, and its type is `@Sendable`.
final class StubURLProtocol: URLProtocol {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> Response)?

    static var handler: (@Sendable (URLRequest) -> Response)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let answer = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: answer.statusCode,
                                        httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = answer.body {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Thread-safe counter for asserting how many times the stub actually ran —
/// the coalescing test's whole point is a number, not a value.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// **Test seams were refused everywhere else in this feature** (the SwiftUI
/// views, the Mac's upload path) as overbuilding a one-shot feature. This
/// file is the exception: `SessionImageLoader.data(at:secret:)` decides three
/// things purely from the network response — a non-200 status, an empty body
/// on a 200, and whether two callers for the same URL share one fetch — and
/// this project already has a working test target and a ~30-line stub, so
/// there is no cost trade to refuse.
@Suite(.serialized)
struct SessionImageLoaderNetworkTests {
    private let url = URL(string: "https://relay.example/image")!

    private func makeLoader(handler: @escaping @Sendable (URLRequest) -> StubURLProtocol.Response) async -> SessionImageLoader {
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return await SessionImageLoader(session: URLSession(configuration: config))
    }

    // Pins the status-code guard in `data(at:secret:)`. Removing that guard
    // (treating any response as success) would return the 404 body here
    // instead of nil.
    @Test("A non-200 response is reported as unavailable")
    func rejectsNon200() async {
        let loader = await makeLoader { _ in .init(statusCode: 404, body: Data([1, 2, 3])) }
        let data = await loader.data(at: url, secret: "shh")
        #expect(data == nil)
    }

    // Pins `!data.isEmpty`. Removing just that clause (keeping the status
    // check) would return `Data()` here instead of nil, and the caller would
    // hand an empty buffer to `UIImage(data:)`, which itself returns nil —
    // this guard is what turns that into the same "unavailable" state rather
    // than a silently-failed decode with no distinguishing signal.
    @Test("A 200 with an empty body is reported as unavailable")
    func rejectsEmptyBody() async {
        let loader = await makeLoader { _ in .init(statusCode: 200, body: Data()) }
        let data = await loader.data(at: url, secret: "shh")
        #expect(data == nil)
    }

    // The success path, so the two rejection tests above are pinning a
    // narrowing of real data rather than of an always-nil function.
    @Test("A 200 with a body returns that body")
    func returnsSuccessfulData() async {
        let payload = Data([9, 9, 9])
        let loader = await makeLoader { _ in .init(statusCode: 200, body: payload) }
        let data = await loader.data(at: url, secret: "shh")
        #expect(data == payload)
    }

    // Pins `inFlight`. Removing the coalescing (always starting a fresh
    // `Task`) would make the stub run twice — once per caller — instead of
    // once.
    @Test("Two concurrent requests for the same URL share one fetch")
    func coalescesInFlightRequests() async {
        let counter = CallCounter()
        let loader = await makeLoader { _ in
            counter.increment()
            return .init(statusCode: 200, body: Data([1]))
        }
        async let first = loader.data(at: url, secret: "shh")
        async let second = loader.data(at: url, secret: "shh")
        _ = await (first, second)
        #expect(counter.value == 1)
    }
}

struct SessionImageURLTests {
    private let base = URL(string: "https://relay.example")!

    @Test("The variant URL carries every id the relay needs")
    func buildsTheURL() throws {
        let url = try #require(SessionImageLoader.url(
            base: base, machine: "M1", session: "s1", event: "e1", variant: "thumb"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let pairs = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        #expect(url.path == "/image")
        #expect(pairs["machine"] == "M1")
        #expect(pairs["session"] == "s1")
        #expect(pairs["event"] == "e1")
        #expect(pairs["variant"] == "thumb")
    }

    // machine id は IOPlatformUUID で、セッション id は UUID。どちらも
    // 今は安全な文字だけだが、エスケープを外すとクエリが壊れる形で
    // 静かに 400 になる。`&` は特に危険 —— エスケープを外すと、そこで
    // クエリが余分な 1 項目に分かれてしまう。ラウンドトリップで戻した
    // 値が元の文字列と一致し、かつ項目数が 4 のままであることを見れば、
    // スペースと `&` の両方のエスケープを同時に固定できる。
    @Test("Ids are percent-escaped")
    func escapesIds() throws {
        let url = try #require(SessionImageLoader.url(
            base: base, machine: "a b&c", session: "s1", event: "e1", variant: "full"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.count == 4)
        let pairs = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        #expect(pairs["machine"] == "a b&c")
    }
}
