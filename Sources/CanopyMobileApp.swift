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
    // The in-flight `connectAll()` task. Held so backgrounding can cancel
    // it — `connectAll()` awaits a network round trip before it creates any
    // socket, so without this the app could go background while that await
    // is still outstanding, and the late-arriving response would install
    // live sockets into a backgrounded app.
    @State private var connectTask: Task<Void, Never>?
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
                        connectTask?.cancel()
                        connectTask = Task { await connectAll() }
                    default:
                        // Cancel before disconnecting: a `connectAll()` still
                        // waiting on `directory.all()` must see cancellation
                        // (checked right after that await, see below) rather
                        // than resume and install sockets we just tore down.
                        connectTask?.cancel()
                        connectTask = nil
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
    ///
    /// Runs as an unstructured `Task` started from `.onChange`, so the scene
    /// can go background while this is still awaiting `directory.all()`.
    /// The `Task.isCancelled` check immediately after that await is what
    /// stops a late-arriving directory response from installing live
    /// sockets into a backgrounded app: the background branch above cancels
    /// this task before this line can resume. One check is enough — nothing
    /// below it suspends again, and this whole type is MainActor-isolated
    /// (implicit from `App`/`View`'s protocol requirements), so once the
    /// check passes, nothing else can run on this actor to cancel us out
    /// from under the loop before it finishes.
    private func connectAll() async {
        let ids: [String]
        do {
            ids = try await directory.all()
        } catch {
            if Task.isCancelled { return }
            directoryError = error
            return
        }
        if Task.isCancelled { return }
        machineIds = ids
        directoryError = nil
        disconnectAll()
        for id in machineIds {
            let socket = RosterSocket(baseURL: baseURL, secret: secret)
            sockets[id] = socket
            socket.connect(machine: id) { snapshot in
                snapshots[id] = snapshot
                errors[id] = nil
            } onFailure: { error in
                // The receive loop has stopped for this machine — surface it
                // through the same `errors` slot `refresh()` uses, so the
                // section says its live connection dropped instead of
                // silently keeping the last snapshot on screen with the
                // elapsed counter still ticking as though nothing happened.
                errors[id] = error
            }
        }
    }

    private func disconnectAll() {
        for socket in sockets.values { socket.disconnect() }
        sockets.removeAll()
    }
}
