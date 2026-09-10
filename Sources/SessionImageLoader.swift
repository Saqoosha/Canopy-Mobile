import Foundation

/// R2 に置かれた画像を取ってくる。
///
/// **`AsyncImage` を使えない理由**: relay は Bearer secret を要求し、
/// `AsyncImage` はヘッダを付けられない。だから最小のローダを 1 つ持つ。
///
/// **キャッシュはメモリだけ。** ディスク永続化を作らないのは、
/// `SessionEventStore` 自体が durable store ではなく、オフラインで見えるのは
/// `HistoryStore` の通知(元から画像が無い)だけだから。
///
/// **`session` は `.ephemeral`、`.shared` ではない。** `URLSession.shared` は
/// ディスクに書く既定の `URLCache` を持っていて、relay が返す
/// `Cache-Control: immutable`(`worker/src/index.ts`)がそのまま効いてしまう
/// —— 会話由来の画像が R2 の 7 日保持を超えてアプリのコンテナに残る。
/// `docs/session-images.md` が「ディスク永続化は作らない」と書いている以上、
/// これは見た目のキャッシュの話ではなくその宣言そのものが崩れる話で、
/// 直す場所は 1 行しかない。
@MainActor
final class SessionImageLoader {
    static let shared = SessionImageLoader()

    /// 100 枚ぶん。サムネイルが 1 枚 20KB 程度なので約 2MB ―― という
    /// 見積もりは `totalCostLimit` と合っていない。実際の上限は 32MB で、
    /// 20KB のサムネイルなら約 1600 枚ぶん。`countLimit` は設定していない
    /// ので、効いているのは常にバイト側。
    private let cache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// 同じ URL に同時に来た要求を 1 本にまとめる。会話をスクロールすると
    /// 同じ行が何度も現れる。
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    /// 本番は `.ephemeral` な `URLSession`(ディスクキャッシュを持たない
    /// 既定構成)。テストだけが差し替える —— `URLProtocol` スタブを積んだ
    /// セッションを渡せば、ネットワークに一切出ずに 3 つの分岐
    /// (ステータス判定・空ボディ判定・in-flight の合流)を固定できる。
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

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
        // Captured into a local before the `Task` literal: `session` is a
        // `let` on this `@MainActor` type, and reading it from inside the
        // closure without hopping through a local reads as an actor-isolation
        // question the compiler need not be asked — `URLSession` is `Sendable`
        // either way.
        let session = self.session
        let task = Task<Data?, Never> {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await session.data(for: request),
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
