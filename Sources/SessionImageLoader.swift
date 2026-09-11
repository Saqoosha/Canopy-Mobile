import Foundation
import ImageIO
import UIKit

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

    /// Decode for on-screen display, through ImageIO rather than
    /// `UIImage(data:)`.
    ///
    /// **The upload cap is on encoded bytes, not pixels.** A mostly-flat PNG
    /// compresses hard, so a file well under the 8MiB upload cap can still be
    /// tens of thousands of pixels on a side. `UIImage(data:)` decodes at
    /// native resolution regardless — a 20,000 × 20,000 source needs about
    /// 1.6GB at 4 bytes a pixel, which gets the app killed. Asking ImageIO for
    /// a thumbnail instead makes it downsample during decode, so the peak
    /// memory is bounded by the cap actually passed, not by the source.
    ///
    /// **4096 is chosen so the zoom stays useful for what this view is for.**
    /// A screenshot of a 4K display (3840 × 2160) decodes untouched, and
    /// reading small text in a screenshot is the main reason to open the
    /// full-size view at all — a tighter cap such as the screen size would
    /// defeat that. 4096² × 4 bytes is about 67MB, which is safe. Only
    /// sources larger than the cap are reduced.
    ///
    /// `nonisolated` for the same reason as `url(...)` above: a pure function
    /// on this `@MainActor` type, called from a synchronous test.
    nonisolated static func displayImage(from data: Data, maxPixelSize: Int = 4096) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // The source's own long edge, read from its header without decoding
        // any pixels. Falls back to the cap itself when the properties don't
        // carry a size, which asks ImageIO for exactly `maxPixelSize` below —
        // still a decode, just not a size-aware one.
        var longEdge = maxPixelSize
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            longEdge = max(width, height)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honours EXIF orientation, so a photo taken sideways is not
            // decoded sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // **`min`, not the bare cap — but not because ImageIO would
            // otherwise upscale.** Measured on both this runtime and macOS:
            // `CGImageSourceCreateThumbnailAtIndex` refuses to enlarge past the
            // source's native size even when handed the bare cap (a 100×60
            // source asked for 320 or 1000 comes back 100×60). The Mac side's
            // `RosterImageUploader.thumbnail(from:)` uses the same call and the
            // same clamp, so neither is load-bearing there either — the
            // `min` costs nothing. It stays anyway: a smaller, more obviously
            // correct expression of the intent ("never ask for more than the
            // source has") that does not depend on that framework detail
            // holding across OS versions.
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge, maxPixelSize),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
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
