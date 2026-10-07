import Foundation
import UIKit

/// Live sessions kept attached for a while after their screen closes, so reopening one shows its page at once.
///
/// Without it every open connects, attaches and replays from nothing (seen at about 1.5 s on a tailnet Mac). A
/// parked model keeps its socket and webview, and the Mac keeps sending it frames, so the page it hands back is
/// current. A parked model whose link fails is closed at once, and the whole cache is closed when the app goes to
/// the background: iOS may close the sockets there, and the app hears of it only after a reopen could take one.
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
    private static var backgroundObserver: (any NSObjectProtocol)?
    /// Bumped on each entry to the background; a model claimed before the last one is not parked.
    private static var backgroundCount = 0

    /// The parked model for `key` if it is still attached. Leaves it parked: SwiftUI may build a view and
    /// discard it, so the screen claims the model in `claim` once it is actually on screen.
    static func model(for key: Key) -> MirrorLiveModel? {
        parked.first { $0.key == key && $0.model.isReusable }?.model
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
            model.close()
            return
        }
        // Another screen of the same session parked earlier: the newer page wins.
        for stale in parked where stale.key == key { evict(stale.model, reason: "superseded") }
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

    private static func evict(_ model: MirrorLiveModel, reason: String) {
        guard let index = parked.firstIndex(where: { $0.model === model }) else { return }
        parked.remove(at: index).expiry.cancel()
        NSLog("[MirrorSessionCache] closed a parked session: %@", reason)
        model.close()
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
