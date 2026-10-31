import Foundation

/// Which sign-in page to open in-app: the `auth_url` the extension sends for a `login` this
/// phone's page started. That page shows the code the page asks to have pasted back; the
/// `open_url` the extension sends at the same time redirects to the Mac's localhost and
/// opens on the Mac.
nonisolated struct MirrorSignIn {
    private var loginIds: Set<String> = []

    /// A frame the page sent to the Mac.
    mutating func noteSent(_ object: [String: Any]) {
        guard object["type"] as? String == "request",
              (object["request"] as? [String: Any])?["type"] as? String == "login",
              let id = object["requestId"] as? String
        else { return }
        loginIds.insert(id)
    }

    /// A frame from the Mac: a login's answer ends it, and an `auth_url` for one still open is its page.
    mutating func pageToOpen(_ frame: [String: Any]) -> URL? {
        guard let message = frame["message"] as? [String: Any] else { return nil }
        if message["type"] as? String == "response", let id = message["requestId"] as? String {
            loginIds.remove(id)
            return nil
        }
        guard message["type"] as? String == "request",
              let request = message["request"] as? [String: Any],
              request["type"] as? String == "auth_url",
              let id = request["loginRequestId"] as? String, loginIds.contains(id),
              let text = request["url"] as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }
}
