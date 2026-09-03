import SwiftUI

@main
struct CanopyMobileApp: App {
    @State private var snapshot: MachineSnapshot?
    @State private var now = Date()

    private let client = RosterClient(
        baseURL: URL(string: ProcessInfo.processInfo.environment["ROSTER_URL"] ?? "https://example.invalid")!,
        secret: ProcessInfo.processInfo.environment["ROSTER_SECRET"] ?? "")
    private let machine = ProcessInfo.processInfo.environment["ROSTER_MACHINE"] ?? ""

    var body: some Scene {
        WindowGroup {
            RosterView(snapshot: snapshot, now: now)
                .task {
                    snapshot = try? await client.fetch(machine: machine)
                }
                .refreshable {
                    snapshot = try? await client.fetch(machine: machine)
                }
        }
    }
}
