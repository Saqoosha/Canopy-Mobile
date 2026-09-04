import UserNotifications

/// Records every delivered push into the shared `HistoryStore` before
/// passing it through unmodified. This is the only place that sees a push
/// the user never taps — `PushRegistrar`'s notification-tap handling in the
/// main app only fires on a tap, so a push that is swiped away or arrives
/// while the phone is locked would otherwise leave no trace at all.
///
/// Every failure below is logged, never swallowed — a history that silently
/// stops recording looks identical to no notifications arriving, which is
/// exactly the failure mode this extension exists to catch. The body text
/// is the user's conversation content and is never logged, even on error.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    // Kept only so `serviceExtensionTimeWillExpire` has something to deliver
    // when `bestAttempt` is nil (mutableCopy failed) — see that method.
    private var originalContent: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.originalContent = request.content
        let best = request.content.mutableCopy() as? UNMutableNotificationContent
        self.bestAttempt = best

        // Fall back to the original, unmutated content when mutableCopy
        // fails — the notification must still reach the user even though we
        // have nothing further to hand it through as. This extension never
        // actually mutates the content today, so `best` and `request.content`
        // render identically either way; the fallback exists so a future
        // mutation can't silently start dropping notifications on this path.
        let deliverableContent: UNNotificationContent
        if let best {
            deliverableContent = best
        } else {
            NSLog("CanopyMobileNotificationService: mutableCopy failed — delivering original content unmutated")
            deliverableContent = request.content
        }

        let userInfo = request.content.userInfo
        // These three are required by the worker's /notify contract (see
        // NotifyBody in worker/src/types.ts). A push missing any of them was
        // not sent by Canopy's relay, and there is nothing to key a history
        // entry on.
        guard let machine = userInfo["machine"] as? String,
              let sessionId = userInfo["sessionId"] as? String,
              let kind = userInfo["kind"] as? String else {
            NSLog("CanopyMobileNotificationService: userInfo missing machine/sessionId/kind — not recording")
            contentHandler(deliverableContent)
            self.contentHandler = nil
            return
        }

        let requestId = userInfo["requestId"] as? String
        // requestId doubles as the history id for an `asking` push, so the
        // main app's Allow/Deny handling and this entry agree on identity.
        // A `completed` push carries no requestId, so synthesize one.
        let historyId = requestId ?? UUID().uuidString

        // `shortBody` is the APNs banner text (aps.alert.body, already
        // decoded into request.content.body); `bodyFull` is the untouched
        // text the worker capped separately (see NotifyBody.bodyFull). Fall
        // back to the banner when bodyFull is absent, e.g. a bare test push
        // with no custom payload.
        let shortBody = request.content.body
        let fullBody = (userInfo["bodyFull"] as? String) ?? shortBody
        // The banner is a worker-generated summary only when it differs from
        // the full text; when they match there is nothing to show as a
        // separate short form.
        let bodyShort: String? = {
            let trimmedShort = shortBody.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedFull = fullBody.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedShort == trimmedFull ? nil : shortBody
        }()

        let item = NotificationHistoryItem(
            id: historyId,
            receivedAt: Date(),
            title: request.content.title,
            body: fullBody,
            bodyShort: bodyShort,
            machine: machine,
            sessionId: sessionId,
            kind: kind,
            requestId: requestId,
            decision: nil,
            decidedAt: nil
        )

        do {
            // HistoryStore.append posts the Darwin update itself on success,
            // waking any foregrounded main-app view observing history.
            try HistoryStore.append(item)
        } catch {
            NSLog("CanopyMobileNotificationService: HistoryStore.append failed for id=\(historyId) kind=\(kind): \(error)")
        }

        contentHandler(deliverableContent)
        self.contentHandler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        // The completion handler must be called exactly once on every path,
        // this one included — an uncalled handler doesn't error, it just
        // makes iOS show the unmodified banner after a timeout, which looks
        // identical to the extension having worked. `didReceive` is fully
        // synchronous today, so this method is currently unreachable with
        // `contentHandler` still set, but that stops being true the moment
        // any step in `didReceive` (body-shortening moving into the
        // extension, say) becomes async. Pager's copy of this method drops
        // the handler on the no-`bestAttempt` branch; this divergence from
        // it is deliberate, not a missed sync.
        guard let handler = contentHandler else { return }
        contentHandler = nil
        if let content = bestAttempt {
            handler(content)
        } else if let content = originalContent {
            NSLog("CanopyMobileNotificationService: serviceExtensionTimeWillExpire with no bestAttempt — delivering original content")
            handler(content)
        } else {
            // Unreachable in practice: `originalContent` is set on the same
            // line as `contentHandler` in `didReceive`, so it is always
            // present whenever the guard above passes. Deliver something
            // rather than drop the handler if that ever stops holding.
            NSLog("CanopyMobileNotificationService: serviceExtensionTimeWillExpire with neither bestAttempt nor originalContent — delivering empty content")
            handler(UNNotificationContent())
        }
    }
}
