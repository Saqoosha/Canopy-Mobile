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
    /// connected — a distinguishable case, because "your Mac is asleep" is a
    /// different thing for the user to do about than "that failed".
    func sendReply(machine: String, sessionId: String, text: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("reply"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "machine": machine, "sessionId": sessionId, "text": text,
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200: return
        case 401: throw RosterError.unauthorized
        default: throw RosterError.unexpectedStatus(status)
        }
    }
}
