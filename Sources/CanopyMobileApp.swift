import SwiftUI

@main
struct CanopyMobileApp: App {
    @State private var snapshot: MachineSnapshot?
    @State private var lastError: Error?
    @Environment(\.scenePhase) private var scenePhase

    private let client = RosterClient(
        baseURL: URL(string: ProcessInfo.processInfo.environment["ROSTER_URL"] ?? "https://example.invalid")!,
        secret: ProcessInfo.processInfo.environment["ROSTER_SECRET"] ?? "")
    private let socket = RosterSocket(
        baseURL: URL(string: ProcessInfo.processInfo.environment["ROSTER_URL"] ?? "https://example.invalid")!,
        secret: ProcessInfo.processInfo.environment["ROSTER_SECRET"] ?? "")
    private let machine = ProcessInfo.processInfo.environment["ROSTER_MACHINE"] ?? ""

    var body: some Scene {
        WindowGroup {
            RosterView(snapshot: snapshot, error: lastError)
                .task {
                    await refresh()
                }
                .refreshable {
                    await refresh()
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        socket.connect(machine: machine) { snapshot = $0 }
                    default:
                        socket.disconnect()
                    }
                }
        }
    }

    private func refresh() async {
        do {
            snapshot = try await client.fetch(machine: machine)
            lastError = nil
        } catch {
            lastError = error
        }
    }
}
