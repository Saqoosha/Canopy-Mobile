import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted when the user taps a push notification, carrying `machine` and
    /// `sessionId` (both `String`) in `userInfo` — the same two fields the
    /// relay's `/notify` payload puts at the top level (see `worker/src/index.ts`).
    /// `CanopyMobileApp` turns this into the same `replyTarget` a row tap sets,
    /// so a notification tap and a row tap open the identical sheet.
    static let canopyMobileReplyRequested = Notification.Name("CanopyMobileReplyRequested")
}

/// Asks for notification permission, registers with APNs, and hands the
/// token to the relay. Split out of the App so the App stays about the
/// roster; this file is the only place that knows APNs exists.
///
/// The token is uploaded on EVERY launch, not only when it changes: APNs
/// reissues tokens on restore, reinstall and some OS updates, and a stale
/// one fails silently at send time — the exact invisible failure the roster
/// half already had to hunt down twice.
///
/// Surfaced, never swallowed, applies to `upload` too, not only to the
/// `didFailToRegisterForRemoteNotificationsWithError` path: a bad secret,
/// a malformed token, or the relay being unreachable must all leave a log
/// line, or this file repeats the exact silent-failure shape it exists to
/// prevent. Never log the token or the secret — status code and
/// `localizedDescription` only.
@MainActor
final class PushRegistrar: NSObject, UIApplicationDelegate, @MainActor UNUserNotificationCenterDelegate {
    static var relayURL: URL?
    static var secret: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Set before requesting authorization so a cold launch driven by a
        // notification tap still reaches `didReceive` below — UNUserNotification-
        // Center holds the response and redelivers it once a delegate exists.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    /// The user tapped a notification. The push payload carries `machine`
    /// and `sessionId` at the top level (not nested under `aps`), matching
    /// what `/notify` sends — see the payload build in `worker/src/index.ts`.
    /// Routed through `NotificationCenter` rather than called directly: this
    /// type has no reference to the app's `replyTarget` state, and shouldn't
    /// grow one just to open a sheet.
    func userNotificationCenter(_: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let machine = userInfo["machine"] as? String,
           let sessionId = userInfo["sessionId"] as? String {
            NotificationCenter.default.post(
                name: .canopyMobileReplyRequested,
                object: nil,
                userInfo: ["machine": machine, "sessionId": sessionId]
            )
        }
        completionHandler()
    }

    func application(_: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await PushRegistrar.upload(token: token) }
    }

    func application(_: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Surfaced, never swallowed: without a token every push is dropped
        // by APNs with no signal on this side.
        print("APNs registration failed: \(error.localizedDescription)")
    }

    private static func upload(token: String) async {
        guard let base = relayURL, let secret else {
            // Same "surfaced, never swallowed" rule as the APNs callback
            // above: a nil relayURL/secret here means the app is either not
            // configured yet or lost the cold-launch race against Settings
            // populating the statics, and silently dropping the token is
            // exactly the invisible failure this file exists to prevent.
            print("Push token upload skipped: relay not configured (relayURL or secret is nil)")
            return
        }
        var request = URLRequest(url: base.appendingPathComponent("register"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                print("Push token upload rejected by relay: HTTP \(http.statusCode)")
            }
        } catch {
            print("Push token upload failed: \(error.localizedDescription)")
        }
    }
}
