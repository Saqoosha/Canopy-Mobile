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
    let expiresAt: Date

    var id: String { "\(channel)/\(threadTs)" }

    /// Slack redirects this to the thread in the signed-in workspace.
    var threadURL: URL? {
        URL(string: "https://slack.com/archives/\(channel)/p\(threadTs.replacingOccurrences(of: ".", with: ""))")
    }

    /// Rows without a channel or thread are skipped.
    static func list(from result: [String: Any]) -> [SlackBinding] {
        guard let rows = result["items"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let channel = row["channel"] as? String, !channel.isEmpty,
                  let threadTs = row["threadTs"] as? String, !threadTs.isEmpty
            else { return nil }
            let millis = (row["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            return SlackBinding(
                channel: channel,
                threadTs: threadTs,
                sessionKey: row["sessionKey"] as? String ?? "",
                sessionLabel: row["sessionLabel"] as? String ?? "",
                expiresAt: Date(timeIntervalSince1970: millis / 1000)
            )
        }
    }

    /// `slack_bindings` lists the whole Mac. A binding names its session by resumeId,
    /// or by the Mac's key (the roster's `sessionId`) when it was made without one.
    func belongs(sessionId: String, resumeId: String?) -> Bool {
        guard !sessionKey.isEmpty else { return false }
        if let resumeId, !resumeId.isEmpty, sessionKey.lowercased() == resumeId.lowercased() { return true }
        return sessionKey == sessionId
    }

    /// What a failed verb means for the user. Every refusal is a bare `error` string.
    static func errorMessage(_ error: Error) -> String {
        guard let control = error as? MachineControl.ControlError else {
            return MachineControl.ControlError.notReachable.message
        }
        guard case .failed(let text) = control else { return control.message }
        // A daemon older than 3.19.0 refuses the verbs to TCP clients.
        if text == "local clients only" { return "Update Canopy on that Mac to 3.19.0 or later to connect Slack threads." }
        if text.contains("slackBridgeEnabled") { return "The Slack bridge is off on that Mac. Turn on canopy.slackBridgeEnabled in its settings.json." }
        return text
    }
}

extension MachineControl {
    func slackBindings() async throws -> [SlackBinding] {
        SlackBinding.list(from: try await request("slack_bindings", [:]))
    }

    /// `key` is the roster's `sessionId` (the Mac's key); `resumeId` outlives a restart.
    func slackBind(key: String, resumeId: String?, permalink: String) async throws {
        _ = try await request("slack_bind", [
            "key": key,
            "sessionId": resumeId ?? "",
            "permalink": permalink.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
    }

    func slackUnbind(_ binding: SlackBinding) async throws {
        _ = try await request("slack_unbind", ["channel": binding.channel, "threadTs": binding.threadTs])
    }
}
