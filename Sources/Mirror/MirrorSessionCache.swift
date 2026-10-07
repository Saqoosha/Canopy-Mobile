import Foundation

/// Live sessions kept attached for a while after their screen closes, so reopening one shows its page at once.
///
/// Without it every open connects, attaches and replays from nothing (about 1.5 s on a tailnet Mac). A parked
/// model keeps its socket and webview, and the Mac keeps sending it frames, so the page it hands back is current.
/// A model whose link failed while parked is never handed back; the screen attaches fresh as before.
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

    /// The parked model for `key` if it is still attached. Leaves it parked: SwiftUI may build a view and
    /// discard it, so the screen claims the model in `claim` once it is actually on screen.
    static func model(for key: Key) -> MirrorLiveModel? {
        parked.first { $0.key == key && $0.model.isReusable }?.model
    }

    /// Stops the expiry of a model now on screen.
    static func claim(_ model: MirrorLiveModel) {
        guard let index = parked.firstIndex(where: { $0.model === model }) else { return }
        parked.remove(at: index).expiry.cancel()
    }

    /// Keeps a model whose screen closed, or closes it when it cannot be reused.
    static func park(_ model: MirrorLiveModel, key: Key) {
        claim(model)
        guard model.isReusable else {
            model.close()
            return
        }
        // Another screen of the same session parked earlier: the newer page wins.
        for stale in parked where stale.key == key { evict(stale.model) }
        let expiry = Task { @MainActor [weak model] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let model else { return }
            evict(model)
        }
        parked.append(Entry(key: key, model: model, expiry: expiry))
        while parked.count > limit { evict(parked[0].model) }
    }

    private static func evict(_ model: MirrorLiveModel) {
        guard let index = parked.firstIndex(where: { $0.model === model }) else { return }
        parked.remove(at: index).expiry.cancel()
        model.close()
    }
}
