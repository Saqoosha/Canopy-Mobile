import SwiftUI

@main
struct CanopyMobileApp: App {
    // Keyed by machine id (`MachineSnapshot.machineId`). A machine only
    // leaves `machineIds` if the Worker's directory stops listing it —
    // never because one fetch failed, so a transient error doesn't blank
    // a whole section.
    @State private var machineIds: [String] = []
    @State private var snapshots: [String: MachineSnapshot] = [:]
    @State private var errors: [String: Error] = [:]
    @State private var directoryError: Error?
    @State private var sockets: [String: RosterSocket] = [:]
    @Environment(\.scenePhase) private var scenePhase

    private let baseURL = URL(string: ProcessInfo.processInfo.environment["ROSTER_URL"] ?? "https://example.invalid")!
    private let secret = ProcessInfo.processInfo.environment["ROSTER_SECRET"] ?? ""

    private var directory: MachineDirectory { MachineDirectory(baseURL: baseURL, secret: secret) }
    private var client: RosterClient { RosterClient(baseURL: baseURL, secret: secret) }

    var body: some Scene {
        WindowGroup {
            RosterView(machineIds: machineIds, snapshots: snapshots, errors: errors, directoryError: directoryError)
                .task {
                    await refresh()
                }
                .refreshable {
                    await refresh()
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        Task { await connectAll() }
                    default:
                        disconnectAll()
                    }
                }
        }
    }

    /// Pulls the directory, then every listed machine's roster over REST.
    /// A machine whose own fetch fails keeps whatever snapshot it already
    /// had (stale, not cleared) and records the failure in `errors` so the
    /// view can say so — see `RosterView`.
    private func refresh() async {
        do {
            let ids = try await directory.all()
            machineIds = ids
            directoryError = nil
        } catch {
            // Directory unreachable: keep the last known machine list rather
            // than blanking every section, and surface the failure.
            directoryError = error
            return
        }
        await withTaskGroup(of: (String, Result<MachineSnapshot, Error>).self) { group in
            for id in machineIds {
                group.addTask {
                    do {
                        return (id, .success(try await client.fetch(machine: id)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let snapshot):
                    snapshots[id] = snapshot
                    errors[id] = nil
                case .failure(let error):
                    errors[id] = error
                }
            }
        }
    }

    /// One live socket per machine, held only while the app is foregrounded
    /// (mirrors the single-Mac `RosterSocket` lifetime rule).
    private func connectAll() async {
        do {
            let ids = try await directory.all()
            machineIds = ids
            directoryError = nil
        } catch {
            directoryError = error
            return
        }
        disconnectAll()
        for id in machineIds {
            let socket = RosterSocket(baseURL: baseURL, secret: secret)
            sockets[id] = socket
            socket.connect(machine: id) { snapshot in
                snapshots[id] = snapshot
                errors[id] = nil
            }
        }
    }

    private func disconnectAll() {
        for socket in sockets.values { socket.disconnect() }
        sockets.removeAll()
    }
}
