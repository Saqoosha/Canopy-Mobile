import Foundation

/// Cross-process broadcast for "history changed". The Notification Service
/// Extension and the host app share the App Group container but each runs in
/// its own process, so we use a Darwin notification to bridge them — the
/// extension posts after appending and the app posts a regular
/// `NotificationCenter` event in response so SwiftUI views can observe it.
enum HistoryUpdateBridge {
    static let darwinName = "sh.saqoo.canopy-app.historyDidUpdate"

    /// `NotificationCenter` name re-posted inside the host app whenever the
    /// Darwin event fires. SwiftUI views should listen here, not on Darwin
    /// directly.
    static let didUpdate = Notification.Name("CanopyMobileHistoryDidUpdate")

    /// Posts the Darwin notification so any process subscribed to
    /// `HistoryUpdateBridge.darwinName` is woken, and re-posts `didUpdate`
    /// locally so THIS process is woken too.
    ///
    /// **The local re-post is not redundant belt-and-braces — it is the only
    /// thing that guarantees the writing process sees its own write.** Both
    /// writers now run in the host app as well as in the extension:
    /// `updateDecision` is called from `CanopyMobileApp.sendDecision` and from
    /// `PushRegistrar`'s lock-screen handler, both in-process. Whether
    /// `notifyd` loops a Darwin notification back to the process that posted
    /// it is an implementation detail of libnotify that this app must not
    /// depend on, and the failure when it does not is silent and specific: the
    /// answered ask keeps rendering its buttons, because `SessionConversationView`
    /// only reloads on `didUpdate`.
    ///
    /// If the loopback DOES happen, `didUpdate` fires twice and the list
    /// reloads twice. `load()` is a pure re-read, so that costs a duplicate
    /// pass and changes nothing — the right trade against an answer that
    /// silently never appears.
    static func postDarwinUpdate() {
        let name = darwinName as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil,
            nil,
            true
        )
        // `NotificationCenter` delivers synchronously on the calling thread,
        // and the observers are SwiftUI `.onReceive` handlers, so hop to main
        // rather than reloading a view's state from whatever queue the write
        // finished on.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didUpdate, object: nil)
        }
    }

    /// Subscribes the current process to the Darwin notification and
    /// re-broadcasts it as `didUpdate` on the main `NotificationCenter`.
    /// **Not idempotent.** The observer is registered with a nil observer
    /// pointer, so CF has nothing to deduplicate on and a second call installs
    /// a second callback — harmless in effect (both do the same repost) but it
    /// reloads the list twice. There is exactly one caller today; keep it that
    /// way rather than adding a flag to make a one-call function safe to call
    /// twice.
    static func startBridge() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = darwinName as CFString
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                NotificationCenter.default.post(name: HistoryUpdateBridge.didUpdate, object: nil)
            },
            name,
            nil,
            .deliverImmediately
        )
    }
}
