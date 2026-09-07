import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted when the user taps a push notification, carrying `machine` and
    /// `sessionId` (both `String`) in `userInfo`, plus `resumeId` and
    /// `requestId` when the push carried them — the same fields the relay's
    /// `/notify` payload puts at the top level (see `worker/src/index.ts`).
    /// `CanopyMobileApp` turns this into the same conversation push a row tap makes,
    /// so a notification tap and a row tap open the identical sheet.
    static let canopyMobileReplyRequested = Notification.Name("CanopyMobileReplyRequested")
}

/// Identifiers for the permission-ask notification category. The action
/// identifiers ARE the decision values `RosterClient.sendDecision` posts to
/// `/decide` — no separate translation table to keep in sync with the
/// relay's contract (which refuses anything but exactly `"allow"`/`"deny"`).
enum CanopyPermissionAction {
    static let categoryIdentifier = "CANOPY_PERMISSION"
    /// A second category, identical but for the extra action. iOS resolves a
    /// notification's actions from its category alone, so "offer Always only
    /// when the CLI proposed a rule" cannot be a per-notification flag — it
    /// has to be a different category, chosen by the relay.
    static let alwaysCategoryIdentifier = "CANOPY_PERMISSION_ALWAYS"
    static let allow = "allow"
    static let deny = "deny"
    static let allowAlways = "allowAlways"
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
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Started here, before any SwiftUI view exists to subscribe to
        // `.didUpdate` — the app delegate's `didFinishLaunchingWithOptions`
        // runs ahead of the `WindowGroup`'s first body evaluation, so
        // `HistoryView`'s `.onReceive` can never race an as-yet-unstarted
        // bridge. Without this call the Notification Service Extension's
        // Darwin post (`HistoryStore.append`/`updateDecision`) has nothing
        // on this side to re-broadcast as `.didUpdate`, and the history list
        // would only ever refresh on `.onAppear`. This is `startBridge()`'s
        // only caller, which is what its own doc asks for — a second call
        // would install a second observer and reload the list twice.
        HistoryUpdateBridge.startBridge()
        // Set before requesting authorization so a cold launch driven by a
        // notification tap still reaches `didReceive` below — UNUserNotification-
        // Center holds the response and redelivers it once a delegate exists.
        // No APNs registration in demo mode: the simulator has no token to
        // get, and asking for one raises a permission prompt over the design
        // being reviewed.
        if CanopyDemo.isEnabled {
            // Also UNregister. Skipping registration leaves a token from an
            // earlier non-demo run of this same install in place, and the
            // Notification Service Extension is a separate process that does
            // not see `--demo` — so a real push arriving mid-demo would be
            // appended to the shared history the real app reads next. The
            // next non-demo launch re-registers on its own; this costs it
            // nothing.
            application.unregisterForRemoteNotifications()
            return true
        }
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategory()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    /// Copied from Pager's `AppDelegate.registerNotificationCategory` — keep
    /// the shape AND the reasoning, not just the identifiers: no
    /// `.authenticationRequired`, because that option queues the action
    /// until the iPhone is unlocked, which means an Apple Watch tap on a
    /// locked iPhone never reaches the delegate.
    private func registerNotificationCategory() {
        let allow = UNNotificationAction(
            identifier: CanopyPermissionAction.allow,
            title: "Allow",
            options: []
        )
        let deny = UNNotificationAction(
            identifier: CanopyPermissionAction.deny,
            title: "Deny",
            options: [.destructive]
        )
        let always = UNNotificationAction(
            identifier: CanopyPermissionAction.allowAlways,
            title: "Always",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: CanopyPermissionAction.categoryIdentifier,
            actions: [allow, deny],
            intentIdentifiers: []
        )
        let alwaysCategory = UNNotificationCategory(
            identifier: CanopyPermissionAction.alwaysCategoryIdentifier,
            actions: [allow, always, deny],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category, alwaysCategory])
    }

    /// The user tapped a notification. The push payload carries `machine`
    /// and `sessionId` at the top level (not nested under `aps`), matching
    /// what `/notify` sends — see the payload build in `worker/src/index.ts`.
    /// Routed through `NotificationCenter` rather than called directly: this
    /// type has no reference to the app's navigation state, and shouldn't
    /// grow one just to open a sheet.
    func userNotificationCenter(_: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        if response.actionIdentifier == CanopyPermissionAction.allow ||
            response.actionIdentifier == CanopyPermissionAction.deny ||
            response.actionIdentifier == CanopyPermissionAction.allowAlways {
            handlePermissionDecision(actionIdentifier: response.actionIdentifier,
                                      userInfo: userInfo,
                                      completionHandler: completionHandler)
            return
        }

        // A tap (no registered action — `UNNotificationDefaultActionIdentifier`)
        // opens the reply composer, EXCEPT on a permission ask nobody has
        // answered, where `CanopyMobileApp` opens the ask itself. The
        // `requestId` is the only thing that tells the two apart, so it rides
        // along whenever the push carried one — without it the tap lands in
        // the composer, and a reply typed there is refused by the shim after
        // the sheet has already dismissed as success.
        if let machine = userInfo["machine"] as? String,
           let sessionId = userInfo["sessionId"] as? String {
            var info: [String: Any] = ["machine": machine, "sessionId": sessionId]
            // Forwarded because the push carries it and the app has a use for
            // it: `resumeId` is what groups a conversation across a Canopy
            // restart, and the tap handler's other two sources for it (the
            // roster snapshot, the stored history entry) can both be missing
            // exactly when the tap arrives — a cold start has no snapshot yet.
            // Dropping it here left that case with no id at all.
            if let resumeId = userInfo["resumeId"] as? String { info["resumeId"] = resumeId }
            if let requestId = userInfo["requestId"] as? String { info["requestId"] = requestId }
            // **Held as well as posted, and the held copy is the one that
            // works on a cold launch.** See `pendingTap`.
            PushRegistrar.pendingTap = info
            NotificationCenter.default.post(
                name: .canopyMobileReplyRequested,
                object: nil,
                userInfo: info
            )
        }
        completionHandler()
    }

    /// The most recent notification tap no scene has acted on yet, or nil.
    ///
    /// **A tap can land before anything is listening, and the post is then
    /// simply gone.** On a cold launch this type is installed as the
    /// `UNUserNotificationCenter` delegate inside
    /// `didFinishLaunchingWithOptions`, and iOS delivers the waiting response
    /// as soon as that happens — which can be before SwiftUI has evaluated the
    /// `WindowGroup` body and installed the `.onReceive` that turns the post
    /// into navigation. `NotificationCenter` does not queue for absent
    /// observers, so the tap vanishes and the app opens on the roster: the
    /// user taps a notification and gets the session list, with nothing
    /// anywhere reporting a dropped tap. Reported from the device.
    ///
    /// The scene collects this when it comes up (and again whenever it becomes
    /// active), so the delivery no longer has to win a race. Cleared by
    /// whoever acts on it, so one tap opens one conversation.
    static var pendingTap: [String: Any]?

    /// Show the banner even while Canopy Mobile is FRONTMOST. Without this
    /// iOS suppresses a foreground push entirely — no banner, no sound, no
    /// `didReceive` — and nothing anywhere reports it: the relay returns 200,
    /// APNs accepts the push, the Notification Service Extension still writes
    /// the history item, and the screen stays blank.
    ///
    /// Measured on device 2026-09-04, and only on device: a permission ask
    /// raised while the app was open produced no visible notification at all,
    /// while the same push with the app backgrounded worked. Every review of
    /// this feature missed it, because there is nothing in the code to see —
    /// the defect is an absent delegate method.
    ///
    /// It matters most for exactly the ask this feature exists for: opening
    /// the app to check on a session is the most likely thing to be doing
    /// when that session raises its hand.
    func userNotificationCenter(_: UNUserNotificationCenter,
                                 willPresent _: UNNotification,
                                 withCompletionHandler completionHandler:
                                     @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Allow/Deny tapped from the lock screen, an Apple Watch, or the
    /// expanded banner. Posts through `RosterClient.sendDecision` — the same
    /// method `CanopyMobileApp.sendDecision(item:decision:)` calls for the
    /// `SessionConversationView` buttons, so a lock-screen tap and an in-app tap
    /// cannot diverge into two different ways of answering the same ask.
    ///
    /// `completionHandler` is called IMMEDIATELY, and the POST runs under a
    /// `beginBackgroundTask` assertion — Pager's shape, copied deliberately.
    /// An outstanding handler does NOT buy background runtime: if the process
    /// is suspended before the POST lands (cold TLS, a slow network, a locked
    /// phone), the decision is dropped, the Mac never hears it, and the user
    /// believes they answered a session that is still blocked. That is this
    /// feature's worst failure, so it does not rest on an assumption about
    /// how long iOS tolerates a deferred handler.
    private func handlePermissionDecision(actionIdentifier: String,
                                           userInfo: [AnyHashable: Any],
                                           completionHandler: @escaping () -> Void) {
        let decision = actionIdentifier // already exactly "allow", "deny" or "allowAlways"
        guard let machine = userInfo["machine"] as? String,
              let sessionId = userInfo["sessionId"] as? String,
              let requestId = userInfo["requestId"] as? String
        else {
            print("Permission decision action fired with missing machine/sessionId/requestId")
            completionHandler()
            return
        }
        // Taken synchronously, before the handler returns: this method is
        // already `@MainActor`, so unlike Pager's delegate there is no hop to
        // schedule, and no window where the notification system has been told
        // "done" while nothing yet holds the process up.
        let app = UIApplication.shared
        let bgState = BackgroundDecisionState()
        bgState.bgTaskId = app.beginBackgroundTask(withName: "CanopySendDecision") {
            print("CanopySendDecision background task expired before the POST finished")
            bgState.endIfActive(app: app)
        }
        completionHandler()

        let decidedAt = Date()
        Task {
            let delivered = await PushRegistrar.postDecision(
                machine: machine, sessionId: sessionId,
                requestId: requestId, decision: decision
            )
            do {
                try HistoryStore.updateDecision(requestId: requestId, decision: decision,
                                                 decidedAt: decidedAt, delivered: delivered)
            } catch {
                print("HistoryStore.updateDecision failed: \(error.localizedDescription)")
            }
            await MainActor.run { bgState.endIfActive(app: app) }
        }
    }

    /// Same relay-config read `upload(token:)` uses below, for the same
    /// reason: this type has no reference to the app's already-built
    /// `RosterClient`, and shouldn't grow one just to answer one push.
    /// Returns whether the relay accepted the decision. A failure is never
    /// thrown further — the history still records what the user tapped — but
    /// it is never reported as success either: the caller writes the result
    /// onto the item so the list and the detail can say the Mac never heard
    /// it. A 503 (no Mac connected) is the common shape, and it is silent on
    /// the wire; the phone is the only place left that can tell the user.
    private static func postDecision(machine: String, sessionId: String,
                                      requestId: String, decision: String) async -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: "rosterUrl"),
              let base = URL(string: stored),
              let secret = KeychainHelper.load(key: "rosterSecret"),
              !secret.isEmpty
        else {
            print("Permission decision skipped: relay not configured (relayURL or secret is nil)")
            return false
        }
        do {
            try await RosterClient(baseURL: base, secret: secret)
                .sendDecision(machine: machine, sessionId: sessionId, requestId: requestId, decision: decision)
            return true
        } catch {
            print("Permission decision POST failed: \(error.localizedDescription)")
            return false
        }
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
        // Read the config HERE rather than from statics the App populates.
        // Measured on device 2026-09-04: the APNs token callback wins the
        // race against SwiftUI's `.onChange(of: scenePhase, initial: true)`,
        // so a static set only by that handler is still nil when the token
        // arrives — every launch skipped the upload, and said so only
        // because an earlier review refused to let this path stay silent.
        // Reading the same UserDefaults key `@AppStorage("rosterUrl")`
        // writes, and the same Keychain item Settings writes, removes the
        // race instead of trying to win it.
        guard let stored = UserDefaults.standard.string(forKey: "rosterUrl"),
              let base = URL(string: stored),
              let secret = KeychainHelper.load(key: "rosterSecret"),
              !secret.isEmpty
        else {
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

/// Holds one `beginBackgroundTask` assertion across the async POST.
/// Copied from `Pager/Sources/Pager/AppDelegate.swift` — a class rather than a
/// captured `var` so the expiry handler and the completion path mutate the SAME
/// identifier, which is what makes `endIfActive` idempotent: whichever fires
/// first ends the assertion and the other finds `.invalid` and does nothing.
/// Ending it twice is a hard crash, and never ending it gets the app killed.
@MainActor
private final class BackgroundDecisionState {
    var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    func endIfActive(app: UIApplication) {
        guard bgTaskId != .invalid else { return }
        app.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }
}
