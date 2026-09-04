import Foundation

/// Every machine id the Worker has ever seen publish. The phone cannot
/// enumerate Durable Objects directly, so this is the only way it learns
/// which sections to render.
struct MachineDirectory {
    let baseURL: URL
    let secret: String

    func all() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("machines"))
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        // Never flatten to URLError.badServerResponse: the phone's only
        // failure surface is this string, and "-1011" names four unrelated
        // causes (401 / 404 / other status / decode).
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
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw RosterError.decodingFailed(error.localizedDescription)
        }
    }
}
