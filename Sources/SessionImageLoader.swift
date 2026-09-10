import Foundation

/// R2 に置かれた画像を取ってくる。
///
/// **`AsyncImage` を使えない理由**: relay は Bearer secret を要求し、
/// `AsyncImage` はヘッダを付けられない。だから最小のローダを 1 つ持つ。
///
/// **キャッシュはメモリだけ。** ディスク永続化を作らないのは、
/// `SessionEventStore` 自体が durable store ではなく、オフラインで見えるのは
/// `HistoryStore` の通知(元から画像が無い)だけだから。`URLCache` も別に
/// 効く —— relay は `Cache-Control: immutable` を返す。
@MainActor
final class SessionImageLoader {
    static let shared = SessionImageLoader()

    /// 100 枚ぶん。サムネイルが 1 枚 20KB 程度なので約 2MB。原寸も同じ
    /// キャッシュに入るが、`totalCostLimit` がバイトで抑える。
    private let cache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// 同じ URL に同時に来た要求を 1 本にまとめる。会話をスクロールすると
    /// 同じ行が何度も現れる。
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    // `nonisolated` because this is a pure function with no actor state to
    // protect, and the test in SessionImageTests.swift calls it from a
    // synchronous, non-actor context — see this project's AGENTS.md on
    // adding a pure function to an `@MainActor` type.
    nonisolated static func url(base: URL, machine: String, session: String,
                                event: String, variant: String) -> URL? {
        guard var components = URLComponents(url: base.appendingPathComponent("image"),
                                             resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [
            URLQueryItem(name: "machine", value: machine),
            URLQueryItem(name: "session", value: session),
            URLQueryItem(name: "event", value: event),
            URLQueryItem(name: "variant", value: variant),
        ]
        return components.url
    }

    func data(at url: URL, secret: String) async -> Data? {
        if let cached = cache.object(forKey: url as NSURL) { return cached as Data }
        if let running = inFlight[url] { return await running.value }
        let task = Task<Data?, Never> {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty
            else { return nil }
            return data
        }
        inFlight[url] = task
        let data = await task.value
        inFlight[url] = nil
        if let data { cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count) }
        return data
    }
}
