import Foundation
import UIKit
import WebKit

/// Live sessions kept attached for a while after their screen closes, so reopening one shows its page at once.
///
/// Without it every open connects, attaches and replays from nothing (seen at about 1.5 s on a tailnet Mac). A
/// parked model keeps its socket and webview, and the Mac keeps sending it frames, so the page it hands back is
/// current. A parked model whose link fails is closed at once, and the whole cache is closed when the app goes to
/// the background: iOS may close the sockets there, and the app hears of it only after a reopen could take one.
///
/// A closed session leaves its drawn page behind as a stale page: a reopen with nothing live to take shows it at
/// once, over the new attach, until the new page has drawn the conversation.
@MainActor
enum MirrorSessionCache {
    static let limit = 3
    static let lifetime: Duration = .seconds(600)

    private struct Entry {
        let key: Key
        let model: MirrorLiveModel
        let expiry: Task<Void, Never>
    }

    struct Key: Hashable {
        let address: String
        let sessionId: String
    }

    private static var parked: [Entry] = []
    private static var stale: [StalePage] = []
    static let staleLifetime: Duration = .seconds(1800)

    private struct StalePage {
        let key: Key
        let webView: WKWebView
        let expiry: Task<Void, Never>
    }
    private static var backgroundObserver: (any NSObjectProtocol)?
    /// Bumped on each entry to the background; a model claimed before the last one is not parked.
    private static var backgroundCount = 0

    /// The parked model for `key` if it is still attached. Leaves it parked: SwiftUI may build a view and
    /// discard it, so the screen claims the model in `claim` once it is actually on screen.
    static func model(for key: Key) -> MirrorLiveModel? {
        parked.first { $0.key == key && $0.model.isReusable }?.model
    }

    /// Takes the stale page for `key` out of the cache.
    static func takeStalePage(for key: Key) -> WKWebView? {
        guard let index = stale.firstIndex(where: { $0.key == key }) else { return nil }
        let page = stale.remove(at: index)
        page.expiry.cancel()
        return page.webView
    }

    /// Keeps a drawn page for the next open of `key`, replacing an older one.
    static func keepStalePage(_ webView: WKWebView, for key: Key) {
        _ = takeStalePage(for: key)
        let expiry = Task { @MainActor in
            try? await Task.sleep(for: staleLifetime)
            guard !Task.isCancelled else { return }
            _ = takeStalePage(for: key)
        }
        stale.append(StalePage(key: key, webView: webView, expiry: expiry))
        while stale.count > limit { _ = takeStalePage(for: stale[0].key) }
    }

    /// Takes a model now on screen out of the cache: no expiry, no eviction, no longer counted toward `limit`.
    /// Returns whether it was parked.
    @discardableResult
    static func claim(_ model: MirrorLiveModel) -> Bool {
        observeBackground()
        model.cacheEpoch = backgroundCount
        guard let index = parked.firstIndex(where: { $0.model === model }) else { return false }
        parked.remove(at: index).expiry.cancel()
        model.onFailureWhileParked = nil
        return true
    }

    /// Keeps a model whose screen closed, or closes it when it cannot be reused.
    static func park(_ model: MirrorLiveModel, key: Key) {
        let epoch = model.cacheEpoch
        claim(model)
        // On screen across a trip to the background: its socket may be dead without the app having heard yet.
        guard model.isReusable, epoch == backgroundCount else {
            retire(model, key: key)
            return
        }
        // Another screen of the same session parked earlier: the newer page wins.
        for older in parked where older.key == key { evict(older.model, reason: "superseded", keepPage: false) }
        let expiry = Task { @MainActor [weak model] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let model else { return }
            evict(model, reason: "expired")
        }
        model.onFailureWhileParked = { [weak model] in
            if let model { evict(model, reason: "link failed") }
        }
        parked.append(Entry(key: key, model: model, expiry: expiry))
        while parked.count > limit { evict(parked[0].model, reason: "over the limit") }
    }

    /// Closes a model, keeping its drawn page as the stale page for `key`.
    static func retire(_ model: MirrorLiveModel, key: Key) {
        if let webView = model.retire() { keepStalePage(webView, for: key) }
    }

    /// `keepPage` false: a newer page of the same session is parked, and this one would only be shown instead of it.
    private static func evict(_ model: MirrorLiveModel, reason: String, keepPage: Bool = true) {
        guard let index = parked.firstIndex(where: { $0.model === model }) else { return }
        let entry = parked.remove(at: index)
        entry.expiry.cancel()
        NSLog("[MirrorSessionCache] closed a parked session: %@", reason)
        if keepPage { retire(model, key: entry.key) } else { model.close() }
    }

    private static func observeBackground() {
        guard backgroundObserver == nil else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                backgroundCount += 1
                for entry in parked { evict(entry.model, reason: "app went to the background") }
            }
        }
    }
}
