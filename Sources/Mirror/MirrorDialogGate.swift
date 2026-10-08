import Foundation

/// Where every question and permission prompt enters the mirrored page, so each one is drawn once and goes away
/// when it is answered.
///
/// **The webview does not de-duplicate.** `processRequest` (extension 2.1.294, `webview/index.js`) appends a new
/// prompt for every `request` frame and overwrites the abort controller under its `requestId`, so a second copy
/// draws a second prompt and `cancel_request` then aborts only the newest one. The older one stays on screen,
/// answered or not, until the page reloads.
///
/// Two things put a question on the page twice. Both are handled here, on the frames the link hands the page.
///
/// 1. **The page's own replay of an unanswered `AskUserQuestion`.** When a transcript response says
///    `liveInOtherSurface: false` and the transcript ends in an `AskUserQuestion` with no result, the page draws a
///    local copy of that question (`maybeReplayUnansweredQuestion`). That copy has no `requestId`: answering it
///    sends a new user turn ("Answering your earlier question …") rather than a response, and neither
///    `cancel_request` nor the tool result clears it. On a mirror the Mac re-sends every outstanding prompt as the
///    real request at the page's `launch_claude` (Canopy `ShimProcess`, `outstandingDialogRequests`), so the page
///    showed the question twice and kept the replayed one after the real one was answered. Canopy runs one
///    extension webview for all its surfaces, so the extension finds no other surface and reports `false` for
///    every load. The flag is read nowhere else in the page, so it is rewritten to `true` here.
///
///    The cost: a question left in the transcript with no outstanding request on the Mac (its CLI restarted, say)
///    is no longer replayed on the phone. Before, it was replayed, and answering it posted a user turn.
/// 2. **The same request sent twice to the same channel.** A request is keyed by its `requestId` and the channel it
///    is addressed to. The page mints a new channel id on every `launch_claude`, so a re-sent prompt for a
///    relaunched page has a new key and is let through; only a copy the page already holds is dropped.
///    The key is released when the page answers it or a `cancel_request` withdraws it.
struct MirrorDialogGate {
    private var shown: Set<Key> = []

    private struct Key: Hashable {
        let requestId: String
        let channelId: String
    }

    enum Verdict: Equatable {
        case deliver
        /// The frame with the page's replay switched off; re-encode it before posting.
        case rewritten
        case drop
    }

    /// One frame the Mac sent toward the page. `frame` is changed in place on `.rewritten`.
    mutating func admit(_ frame: inout [String: Any]) -> Verdict {
        guard var message = frame["message"] as? [String: Any] else { return .deliver }
        switch message["type"] as? String {
        case "request":
            guard let requestId = message["requestId"] as? String,
                  let request = message["request"] as? [String: Any],
                  request["type"] as? String == "tool_permission_request"
            else { return .deliver }
            let key = Key(requestId: requestId, channelId: message["channelId"] as? String ?? "")
            return shown.insert(key).inserted ? .deliver : .drop
        case "cancel_request":
            if let target = message["targetRequestId"] as? String { release(target) }
            return .deliver
        case "response":
            guard var response = message["response"] as? [String: Any],
                  response["type"] as? String == "get_session_response",
                  response["liveInOtherSurface"] as? Bool == false
            else { return .deliver }
            response["liveInOtherSurface"] = true
            message["response"] = response
            frame["message"] = message
            return .rewritten
        default:
            return .deliver
        }
    }

    /// One message the page sent to the Mac; its answer to a prompt releases that prompt.
    mutating func noteSent(_ message: [String: Any]) {
        guard message["type"] as? String == "response", let requestId = message["requestId"] as? String else { return }
        release(requestId)
    }

    private mutating func release(_ requestId: String) {
        shown = shown.filter { $0.requestId != requestId }
    }
}
