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
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([String].self, from: data)
    }
}
