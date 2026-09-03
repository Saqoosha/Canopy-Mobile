import Foundation

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
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(MachineSnapshot.self, from: data)
    }
}
