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
    /// `HistoryUpdateBridge.darwinName` is woken.
    static func postDarwinUpdate() {
        let name = darwinName as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil,
            nil,
            true
        )
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
