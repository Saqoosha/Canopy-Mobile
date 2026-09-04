import UIKit
import UserNotifications

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
final class PushRegistrar: NSObject, UIApplicationDelegate {
    static var relayURL: URL?
    static var secret: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
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
