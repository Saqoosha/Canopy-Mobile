import Foundation

/// Reported by `RosterSocket` when its receive loop stops for good. Thin on
/// purpose — this is visibility, not recovery: no reconnect state, no
/// backoff. Recovery is a background/foreground cycle, which re-runs
/// `connectAll()` and installs a fresh socket.
struct RosterSocketError: Error {
    let underlying: Error

    var message: String {
        "Live connection dropped: \(underlying.localizedDescription)"
    }
}

/// Holds a WebSocket only while the app is foregrounded. Backgrounding drops
/// it: iOS would suspend it anyway, and a hibernated Durable Object bills
/// nothing for a connection that is not there.
@MainActor
final class RosterSocket {
    private var task: URLSessionWebSocketTask?
    private let baseURL: URL
    private let secret: String

    init(baseURL: URL, secret: String) {
        self.baseURL = baseURL
        self.secret = secret
    }

    func connect(machine: String,
                 onSnapshot: @escaping @Sendable (MachineSnapshot) -> Void,
                 onEvent: @escaping @Sendable (SessionEventRecord) -> Void = { _ in },
                 onBackfill: @escaping @Sendable ([SessionEventRecord], Int, String) -> Void = { _, _, _ in },
                 onFailure: @escaping @Sendable (RosterSocketError) -> Void) {
        disconnect()
        var components = URLComponents(url: baseURL.appendingPathComponent("watch"),
                                       resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "machine", value: machine)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive(on: task, onSnapshot: onSnapshot, onEvent: onEvent,
                onBackfill: onBackfill, onFailure: onFailure)
    }

    /// Ask the relay for everything after `seq` in one session.
    ///
    /// Sent on the same socket the events arrive on, so the answer comes back
    /// to this phone only. A send failure is silent: the socket is either
    /// about to report its own failure through `onFailure`, or the next
    /// foreground cycle will connect a new one and ask again.
    func requestEvents(sessionId: String, since seq: Int) {
        let body: [String: Any] = ["type": "events_since", "sessionId": sessionId, "seq": seq]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { _ in }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Re-arms on every frame it can read from the wire — including a
    /// binary frame or a string frame that fails to decode — because none
    /// of those mean the socket is dead. Only a genuine `.failure` result
    /// (deploy closing the socket, DO eviction, a Wi-Fi→cellular handoff)
    /// stops the loop; that path reports through `onFailure` instead of
    /// silently returning, so the app can say the live connection is gone
    /// rather than keep rendering a frozen last snapshot as if it were live.
    private func receive(on task: URLSessionWebSocketTask,
                         onSnapshot: @escaping @Sendable (MachineSnapshot) -> Void,
                         onEvent: @escaping @Sendable (SessionEventRecord) -> Void,
                         onBackfill: @escaping @Sendable ([SessionEventRecord], Int, String) -> Void,
                         onFailure: @escaping @Sendable (RosterSocketError) -> Void) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                var decoded: Frame?
                if case .string(let text) = message,
                   let data = text.data(using: .utf8) {
                    decoded = Self.decode(data)
                }
                Task { @MainActor in
                    // **Same identity check the failure branch makes, and for
                    // a reason that got sharper with the stream.** A frame
                    // read from a task this object has already replaced is
                    // from a socket nobody asked for: with only snapshots it
                    // meant a stale roster, and now it also means events and
                    // a whole backfill page landing in the store under a
                    // machine whose live socket is somewhere else. Worse, the
                    // loop re-armed on the OLD task, so a discarded socket
                    // kept receiving forever. Found by review.
                    guard let self, self.task === task else { return }
                    switch decoded {
                    case .snapshot(let snapshot): onSnapshot(snapshot)
                    case .event(let record): onEvent(record)
                    case .backfill(let page): onBackfill(page.events, page.oldestSeq, page.sessionId)
                    case nil: break
                    }
                    self.receive(on: task, onSnapshot: onSnapshot, onEvent: onEvent,
                                 onBackfill: onBackfill, onFailure: onFailure)
                }
            case .failure(let error):
                Task { @MainActor in
                    // Our own teardown arrives here too: `disconnect()`
                    // cancels the task, and the cancellation is delivered to
                    // this pending `receive` as a failure. Backgrounding and
                    // `connect()`'s leading `disconnect()` both take that
                    // path, so reporting it flashed "Live connection dropped:
                    // cancelled" on every return to the app (seen on device
                    // 2026-09-04) for a socket that was already being
                    // replaced.
                    //
                    // Keyed on whether this object still HOLDS the task, not
                    // on the error being `.cancelled`. A remote drop arrives
                    // while `task` is still ours and is still reported, so
                    // this cannot re-hide the frozen-snapshot failure that
                    // `onFailure` exists to surface — matching on the error
                    // code would, since a server-side close can also cancel.
                    guard let self, self.task === task else { return }
                    onFailure(RosterSocketError(underlying: error))
                }
            }
        }
    }

    /// What one text frame on this socket turned out to be.
    enum Frame: Equatable {
        case snapshot(MachineSnapshot)
        case event(SessionEventRecord)
        case backfill(EventsPage)
    }

    /// The relay's answer to `events_since`.
    struct EventsPage: Decodable, Equatable {
        let sessionId: String
        /// The oldest seq the relay still holds. Greater than what was asked
        /// for means everything between is gone; see `SessionEventStore.hasGap`.
        let oldestSeq: Int
        let events: [SessionEventRecord]
    }

    /// Decide what a frame is, then decode it.
    ///
    /// **Discriminated by the `type` field's presence, not by trying each
    /// decode in turn.** A roster snapshot carries no `type` at all, which is
    /// the whole basis of the split — and attempting `MachineSnapshot` first
    /// would swallow an event as a snapshot with no panes, silently.
    ///
    /// An unrecognised `type` returns nil rather than being forced into one of
    /// the three: the relay may grow a message this build does not know, and a
    /// wrong guess renders it as a conversation entry.
    static func decode(_ data: Data) -> Frame? {
        let decoder = JSONDecoder()
        guard let tag = try? decoder.decode(TypeTag.self, from: data) else { return nil }
        switch tag.type {
        case "event":
            return (try? decoder.decode(SessionEventRecord.self, from: data)).map(Frame.event)
        case "events":
            return (try? decoder.decode(EventsPage.self, from: data)).map(Frame.backfill)
        case nil:
            return (try? decoder.decode(MachineSnapshot.self, from: data)).map(Frame.snapshot)
        default:
            return nil
        }
    }

    /// Reads only `type`, so the frame can be classified before it is decoded.
    private struct TypeTag: Decodable { let type: String? }
}
