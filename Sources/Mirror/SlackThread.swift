import Foundation

/// A Slack thread bound to a session on a Mac, as `slack_bindings` lists it (Canopy 3.19.0+).
///
/// The Saqoolaude Worker holds the bindings; the Mac relays the three verbs to it.
/// Replies in the thread reach the session through the Mac, so the phone only
/// lists, binds and unbinds. Spec: Canopy `docs/CONTROL_PROTOCOL.md`.
struct SlackBinding: Identifiable, Equatable {
    let channel: String
    let threadTs: String
    /// The session's resumeId, or the Mac's key for bindings made before 3.16.6 or without one.
    let sessionKey: String
    let sessionLabel: String
    let expiresAt: Date?

    var id: String { "\(channel)/\(threadTs)" }

    /// Slack redirects this to the thread in the signed-in workspace.
    var threadURL: URL? {
        URL(string: "https://slack.com/archives/\(channel)/p\(threadTs.replacingOccurrences(of: ".", with: ""))")
    }

    /// Nil when `items` is not a list, so a broken answer is not read as "none". A missing
    /// `items` is an empty list, as the Mac reads it. Rows without a channel or thread are skipped.
    static func list(from result: [String: Any]) -> [SlackBinding]? {
        guard let rows = result["items"].map({ $0 as? [Any] }) ?? [] else { return nil }
        let list = rows.compactMap { item -> SlackBinding? in
            guard let row = item as? [String: Any],
                  let channel = row["channel"] as? String, !channel.isEmpty,
                  let threadTs = row["threadTs"] as? String, !threadTs.isEmpty
            else { return nil }
            return SlackBinding(
                channel: channel,
                threadTs: threadTs,
                sessionKey: row["sessionKey"] as? String ?? "",
                sessionLabel: row["sessionLabel"] as? String ?? "",
                expiresAt: (row["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            )
        }
        if list.count < rows.count { NSLog("[slack] skipped %d binding rows without a thread", rows.count - list.count) }
        return list
    }

    /// `slack_bindings` lists the whole Mac. A binding names its session by resumeId,
    /// or by the Mac's key (the roster's `sessionId`) when it was made without one.
    func belongs(sessionId: String, resumeId: String?) -> Bool {
        guard !sessionKey.isEmpty else { return false }
        let key = sessionKey.lowercased()
        if let resumeId, !resumeId.isEmpty, key == resumeId.lowercased() { return true }
        return key == sessionId.lowercased()
    }

    /// `key` is the roster's `sessionId` (the Mac's key); `resumeId` outlives a restart.
    static func bindParams(key: String, resumeId: String?, permalink: String) -> [String: String] {
        var params = ["key": key, "permalink": permalink.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let resumeId, !resumeId.isEmpty { params["sessionId"] = resumeId }
        return params
    }

    var unbindParams: [String: String] { ["channel": channel, "threadTs": threadTs] }

    /// What a failed verb means for the user. Every refusal is a bare `error` string.
    static func errorMessage(_ error: Error) -> String {
        guard let control = error as? MachineControl.ControlError else { return error.localizedDescription }
        guard case .failed(let text) = control else { return control.message }
        // A daemon older than 3.19.0 refuses the verbs to TCP clients.
        if text == "local clients only" { return "Update Canopy on that Mac to 3.19.0 or later to connect Slack threads." }
        if text.contains("slackBridgeEnabled") { return "The Slack bridge is off on that Mac. Turn on canopy.slackBridgeEnabled in its settings.json." }
        return text
    }
}

extension MachineControl {
    func slackBindings() async throws -> [SlackBinding] {
        guard let list = SlackBinding.list(from: try await request("slack_bindings", [:])) else {
            throw ControlError.failed("The Mac sent an unreadable list of Slack threads.")
        }
        return list
    }

    /// The new binding, from the result; nil when the result names no thread.
    func slackBind(key: String, resumeId: String?, permalink: String) async throws -> SlackBinding? {
        let result = try await request("slack_bind", SlackBinding.bindParams(key: key, resumeId: resumeId, permalink: permalink))
        let row = result.merging(["sessionKey": resumeId.flatMap { $0.isEmpty ? nil : $0 } ?? key]) { have, _ in have }
        return SlackBinding.list(from: ["items": [row]])?.first
    }

    func slackUnbind(_ binding: SlackBinding) async throws {
        _ = try await request("slack_unbind", binding.unbindParams)
    }
}
