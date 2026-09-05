import Foundation

/// What can go wrong fetching a roster, kept distinguishable so the phone
/// never renders "no roster" for four unrelated causes. Never carries the
/// secret — the unauthorized case says only that, nothing about the value
/// that produced it.
enum RosterError: Error {
    case unauthorized
    case notFound
    case unexpectedStatus(Int)
    case decodingFailed(String)
    /// The Mac answered and said it could not use the delivery — a session
    /// that has closed, a shim that is busy. Carries the Mac's own words.
    ///
    /// Separate from `.notDelivered` because the two need different advice:
    /// this one will not work on a retry, that one might.
    case refusedByMac(String)
    /// It never reached the Mac: no publisher connected, or none answered
    /// within the relay's window. **Not the same as "the Mac said no"** —
    /// before the ack protocol these were one 200 and the user was told
    /// their message had been sent.
    case notDelivered(String)

    var message: String {
        switch self {
        case .unauthorized:
            return "Unauthorized (401) — check ROSTER_SECRET"
        case .notFound:
            return "Not found (404) — this Mac has never published"
        case .unexpectedStatus(let code):
            return "Unexpected response (\(code))"
        case .decodingFailed(let description):
            return "Could not parse roster: \(description)"
        case .refusedByMac(let reason):
            return reason
        case .notDelivered(let reason):
            return reason
        }
    }
}

struct RosterClient {
    let baseURL: URL
    let secret: String

    func fetch(machine: String) async throws -> MachineSnapshot {
        var components = URLComponents(url: baseURL.appendingPathComponent("roster"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "machine", value: machine)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch statusCode {
        case 200:
            break
        case 401:
            throw RosterError.unauthorized
        case 404:
            throw RosterError.notFound
        default:
            throw RosterError.unexpectedStatus(statusCode)
        }
        do {
            return try JSONDecoder().decode(MachineSnapshot.self, from: data)
        } catch {
            throw RosterError.decodingFailed(String(describing: error))
        }
    }

    /// Sends a reply. Throws `RosterError.unexpectedStatus(503)` when no Mac is
    /// connected — a distinguishable Swift case, because "your Mac is asleep"
    /// is a different thing for the user to do about than "that failed". The
    /// human-readable distinction is NOT made here or in `RosterError.message`
    /// (shared with the roster-fetch path, where a 503 means something else
    /// entirely — a misconfigured relay); `SessionConversationView`'s catch is what turns
    /// this specific case into reply-specific wording.
    func sendReply(machine: String, sessionId: String, text: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("reply"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "machine": machine, "sessionId": sessionId, "text": text,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }

    /// Turns a delivery response into the truth about it.
    ///
    /// **200 means the Mac acted on it.** That is new: it used to mean the
    /// relay had written to a socket, which on a half-open connection is
    /// indistinguishable from success and told the user their message had
    /// been sent when nothing had happened.
    private static func check(status: Int, body: Data) throws {
        if status == 200 { return }
        let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?
            .flatMap { $0["reason"] as? String }
        switch status {
        case 401: throw RosterError.unauthorized
        case 409: throw RosterError.refusedByMac(reason ?? "The Mac could not use that")
        case 503: throw RosterError.notDelivered(reason ?? "It did not reach the Mac")
        default: throw RosterError.unexpectedStatus(status)
        }
    }

    /// Answers a permission ask. `decision` must be exactly `"allow"` or
    /// `"deny"` — the relay's `/decide` refuses any other value (see
    /// `worker/src/index.ts`) and `"allow_always"` on purpose. This is the
    /// ONE method both answer paths call — the lock-screen/Watch action in
    /// `PushRegistrar` and the Allow/Deny buttons in `SessionConversationView`
    /// (via `CanopyMobileApp`) — so the two cannot drift into answering the
    /// same question two different ways. A 503 means no Mac is connected;
    /// that surfaces as `.unexpectedStatus(503)` like `sendReply`'s does,
    /// left for the caller to decide how to log it.
    func sendDecision(machine: String, sessionId: String, requestId: String, decision: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("decide"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "machine": machine, "sessionId": sessionId, "requestId": requestId, "decision": decision,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
    }
}
