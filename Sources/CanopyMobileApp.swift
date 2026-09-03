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

    // Configurable from inside the app now (see `SettingsView`) — an app
    // launched by tapping its icon gets no `ProcessInfo` environment at
    // all, so that was never reachable on a real phone. `rosterUrl` lives
    // in UserDefaults via `@AppStorage` so this scene and `SettingsView`
    // read and write the same key without any relay of their own; `secret`
    // is a plain `@State` seeded once from the Keychain and handed to
    // `SettingsView` by `Binding`, so a save there is visible here on the
    // next `directory`/`client` read — never cached into a `let`.
    @AppStorage("rosterUrl") private var rosterUrl = ""
    @State private var secret: String = KeychainHelper.load(key: "rosterSecret") ?? ""
    @State private var showingSettings = false

    private var baseURL: URL? {
        rosterUrl.isEmpty ? nil : URL(string: rosterUrl)
    }

    private var directory: MachineDirectory? {
        baseURL.map { MachineDirectory(baseURL: $0, secret: secret) }
    }
    private var client: RosterClient? {
        baseURL.map { RosterClient(baseURL: $0, secret: secret) }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Group {
                    if baseURL == nil {
                        Text("Set the relay URL in Settings")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        RosterView(machineIds: machineIds, snapshots: snapshots, errors: errors, directoryError: directoryError)
                            .refreshable {
                                await refresh()
                            }
                    }
                }
                .navigationTitle("Canopy")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(rosterUrl: $rosterUrl, secret: $secret)
                }
            }
            .task {
                await refresh()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    reconnect()
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
            // Neither the URL nor the secret is cached into a client/socket
            // `let` anywhere in this file — `directory`/`client` above and
            // `connectAll()` below all read `rosterUrl`/`secret` fresh, so
            // tearing down and reconnecting is enough to pick up an edit
            // made in Settings without relaunching. Guarded on `.active`
            // because Settings can only be open while the scene already is.
            .onChange(of: rosterUrl) { _, _ in
                guard scenePhase == .active else { return }
                reconnect()
            }
            .onChange(of: secret) { _, _ in
                guard scenePhase == .active else { return }
                reconnect()
            }
        }
    }

    /// Pulls the directory, then every listed machine's roster over REST.
    /// A machine whose own fetch fails keeps whatever snapshot it already
    /// had (stale, not cleared) and records the failure in `errors` so the
    /// view can say so — see `RosterView`. A no-op, deliberately, when the
    /// relay isn't configured (`directory`/`client` are `nil`).
    private func refresh() async {
        guard let directory, let client else {
            directoryError = nil
            return
        }
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

    /// Cancels any in-flight connect and starts a fresh one. Shared by the
    /// scene becoming active and by a Settings edit landing while already
    /// active — both mean "the configuration this app should be connected
    /// under just changed, reconnect."
    private func reconnect() {
        connectTask?.cancel()
        connectTask = Task { await connectAll() }
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
        guard let baseURL, let directory else {
            // Not configured: nothing to connect, and nothing should be
            // left over from a previous configuration either.
            machineIds = []
            directoryError = nil
            disconnectAll()
            return
        }
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
