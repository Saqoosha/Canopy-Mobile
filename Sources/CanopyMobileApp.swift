import SwiftUI

@main
struct CanopyMobileApp: App {
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar

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
    @State private var secret: String = CanopyDemo.isEnabled ? "" : (KeychainHelper.load(key: "rosterSecret") ?? "")
    /// Demo mode binds Settings to this instead of `rosterUrl`, so poking at
    /// the field on a demo run cannot rewrite the real stored URL.
    @State private var demoURL = "https://demo.invalid"
    @State private var showingSettings = false

    // ONE destination for the whole app. A roster row, a History row and a
    // notification tap all push `SessionConversationView` for the same
    // session, so there is a single place that shows what a session has said
    // and a single place to answer it — including an unanswered permission
    // ask, which renders Allow/Deny inline in that stream. The reply sheet
    // and the notification detail this replaced were two more screens saying
    // subsets of the same thing, and keeping them in step was already a
    // review finding once.
    //
    // One path, so a notification tap can replace it outright and land the
    // user on the session that buzzed them from wherever they were — with no
    // tab to select first and no second stack to leave stale behind it.
    @State private var path: [Route] = []

    private var baseURL: URL? {
        // Nil in demo mode on purpose: every network path is behind a
        // `client` that this makes unavailable, so the fixtures cannot be
        // mistaken for a live relay and no request can leave the simulator.
        CanopyDemo.isEnabled || rosterUrl.isEmpty ? nil : URL(string: rosterUrl)
    }

    private var directory: MachineDirectory? {
        baseURL.map { MachineDirectory(baseURL: $0, secret: secret) }
    }
    private var client: RosterClient? {
        baseURL.map { RosterClient(baseURL: $0, secret: secret) }
    }

    var body: some Scene {
        WindowGroup {
            // Two tabs, each with its own `NavigationStack` (standard iOS
            // shape) so History's list→detail push doesn't fight the
            // roster's own navigation. The reply sheet is presented from
            // this outer level, not from either stack, because it can be
            // driven by a notification tap regardless of which tab is
            // frontmost.
            // One NavigationStack, no tab bar. The roster IS the app: every
            // session is a row here, and a row leads to that session's
            // conversation. History is the cross-machine question ("what has
            // happened anywhere"), which is a place you visit, not a mode you
            // live in — so it sits beside Settings in the toolbar rather than
            // taking half the bottom chrome forever.
            NavigationStack(path: $path) {
                Group {
                    if baseURL == nil && !CanopyDemo.isEnabled {
                        Text("Set the relay URL in Settings")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        RosterView(machineIds: machineIds, snapshots: snapshots, errors: errors, directoryError: directoryError) { machineId, pane in
                            path = [.conversation(ConversationTarget(
                                machine: machineId,
                                sessionId: pane.sessionId,
                                resumeId: pane.resumeId,
                                title: pane.title,
                                subtitle: pane.project
                            ))]
                        }
                        .refreshable {
                            await refresh()
                        }
                    }
                }
                .navigationTitle("Canopy")
                // MUST sit on the stack's CONTENT, never on the
                // `NavigationStack` itself: a destination declared outside is
                // not visible from the pushed value, and SwiftUI then renders
                // a blank screen with a bare warning triangle and no message —
                // measured on device 2026-09-04, and indistinguishable from
                // the view failing to load.
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .conversation(let target):
                        conversation(target)
                    case .history:
                        HistoryView { item in
                            path.append(.conversation(ConversationTarget(
                                machine: item.machine,
                                sessionId: item.sessionId,
                                resumeId: item.resumeId,
                                title: item.title,
                                // The roster's own name for the machine when
                                // it has one. A raw machine UUID under the
                                // title is an id the reader cannot use.
                                subtitle: snapshots[item.machine]?.displayName ?? item.machine
                            )))
                        }
                        .navigationTitle("History")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            path = [.history]
                        } label: {
                            Image(systemName: "clock")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(rosterUrl: CanopyDemo.isEnabled ? $demoURL : $rosterUrl, secret: $secret)
                }
            }
            .task {
                await refresh()
                // The live app is fed by the roster socket, so it never polls.
                // The fixtures have no socket; re-publishing every 30 s is
                // what keeps "Updated Ns ago" ticking the way a real Mac does.
                if CanopyDemo.isEnabled {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                        await refresh()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .canopyMobileReplyRequested)) { notification in
                guard let machine = notification.userInfo?["machine"] as? String,
                      let sessionId = notification.userInfo?["sessionId"] as? String else { return }
                handleReplyRequested(machine: machine, sessionId: sessionId,
                                      requestId: notification.userInfo?["requestId"] as? String)
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
        // The fixtures re-publish with a current timestamp each pass, so the
        // "Updated Ns ago" line ticks the way it does against a real Mac.
        if CanopyDemo.isEnabled {
            snapshots = CanopyDemo.liveSnapshots()
            machineIds = ["studio", "macbook"]
            directoryError = nil
            return
        }
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
        // No socket in demo mode — and not merely to avoid the network.
        // `connectAll()` starts by clearing `machineIds`, so a scene
        // activation landing after `refresh()` populated the fixtures wiped
        // them again and the roster read "No machines yet" with the state
        // demonstrably set (measured: the values printed, the list stayed
        // empty). This guard is the whole reason the demo renders.
        guard !CanopyDemo.isEnabled else { return }
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

    /// A notification tap carries only `machine` + `sessionId` (see
    /// `PushRegistrar`) — no title, no project, nothing to render a sheet
    /// with. The matching `PaneRow` is looked up from whatever snapshot is
    /// already in memory. If that machine hasn't been fetched yet, or the
    /// pane closed between the push firing and the tap landing, there is
    /// A tap on a push lands on that session's conversation, whatever the
    /// push was and whichever tab was frontmost. There is nothing to branch
    /// on any more: an unanswered permission ask renders its own Allow/Deny
    /// inline in that stream, so the tap does not have to decide in advance
    /// whether the user came to answer or to reply.
    ///
    /// The title prefers the live roster pane and falls back to the history
    /// item, because a notification can name a session the roster has not
    /// listed yet (a pane opened between polls) — and landing on the right
    /// conversation with a plain title beats declining to open at all, which
    /// is what the pane-only lookup used to do.
    private func handleReplyRequested(machine: String, sessionId: String, requestId: String?) {
        let pane = snapshots[machine]?.panes.first { $0.sessionId == sessionId }
        let item = (try? HistoryStore.loadAll())?.first {
            $0.machine == machine && $0.sessionId == sessionId
        }
        guard let title = pane?.title ?? item?.title else { return }
        path = [.conversation(ConversationTarget(
            machine: machine,
            sessionId: sessionId,
            resumeId: pane?.resumeId ?? item?.resumeId,
            title: title,
            subtitle: pane?.project ?? machine
        ))]
    }

    /// Every reply goes through here, whichever entry point opened the
    /// conversation, so `RosterClient` stays owned by this scene rather than
    /// by the view — the view is handed a closure, never the credentials.
    private func sendReply(machine: String, sessionId: String, text: String) async throws {
        if CanopyDemo.isEnabled { return }
        guard let client else { throw RosterError.unexpectedStatus(-1) }
        try await client.sendReply(machine: machine, sessionId: sessionId, text: text)
    }

    /// `SessionConversationView`'s Allow/Deny route here, through the SAME
    /// `RosterClient.sendDecision` method `PushRegistrar`'s lock-screen/Watch
    /// action handler calls — see that type's `postDecision`. Two callers,
    /// one client method, so they cannot drift into answering the same ask
    /// two different ways. A failed POST is logged, not swallowed, but the
    /// history update still runs — same shape as `PushRegistrar`'s: the local
    /// record of "the user tapped Allow" must not depend on the relay being
    /// reachable. What it DOES depend on is honesty about it: the outcome is
    /// written to `decisionDelivered` so a decision the Mac never received
    /// cannot render identically to one it acted on. No background-task
    /// assertion here, unlike `PushRegistrar`'s path — this button is only
    /// reachable with the app in the foreground.
    /// - Parameter answers: set only for an `AskUserQuestion`. `decision`
    ///   stays `"allow"` on the wire — an ask is resolved by allowing the
    ///   tool — while what gets RECORDED is `recordAs`, the labels the user
    ///   picked, so the history row reads "Answered: Postgres" rather than
    ///   "Answered: allow". The two differ on purpose: one is the protocol,
    ///   the other is what the person did.
    private func sendDecision(item: NotificationHistoryItem, decision: String,
                              answers: [String: String]? = nil,
                              recordAs: String? = nil) {
        guard let requestId = item.requestId else { return }
        // Answering in demo mode moves the fixture rather than the relay, so
        // the roster row flips to "working" the way it would after a real one.
        if CanopyDemo.isEnabled {
            CanopyDemo.decide(item, decision: recordAs ?? decision)
            snapshots = CanopyDemo.liveSnapshots()
            return
        }
        let decidedAt = Date()
        Task {
            var delivered = false
            if let client {
                do {
                    try await client.sendDecision(machine: item.machine, sessionId: item.sessionId,
                                                   requestId: requestId, decision: decision,
                                                   answers: answers)
                    delivered = true
                } catch {
                    print("Permission decision POST failed: \(error.localizedDescription)")
                }
            } else {
                print("Permission decision skipped: relay not configured")
            }
            do {
                try HistoryStore.updateDecision(requestId: requestId,
                                                 decision: recordAs ?? decision,
                                                 decidedAt: decidedAt, delivered: delivered)
            } catch {
                print("HistoryStore.updateDecision failed: \(error.localizedDescription)")
            }
        }
    }

    /// Builds the one destination. Kept here rather than in the view because
    /// `RosterClient` is owned by this scene — the view is handed closures,
    /// not credentials.
    /// The roster's current row for a conversation, matched the same way the
    /// history is: on `resumeId` when both sides have one, else `sessionId`.
    /// A restart mints a new `sessionId`, so matching on that alone would
    /// drop the dot exactly when Canopy came back.
    private func livePane(for target: ConversationTarget) -> PaneRow? {
        snapshots[target.machine]?.panes.first { pane in
            if let want = target.resumeId, let have = pane.resumeId { return have == want }
            return pane.sessionId == target.sessionId
        }
    }

    @ViewBuilder
    private func conversation(_ target: ConversationTarget) -> some View {
        SessionConversationView(
            machine: target.machine,
            sessionId: target.sessionId,
            resumeId: target.resumeId,
            title: target.title,
            subtitle: target.subtitle,
            // Looked up on every re-render rather than captured into the
            // target, so the header tracks the roster instead of freezing at
            // the moment the row was tapped. You open a session BECAUSE it
            // raised its hand; it can finish while you are reading, and a
            // frozen dot would still say "asking". nil when the roster does
            // not list this session — the header then shows no dot at all,
            // because grey means idle here and "we don't know" is not idle.
            pane: livePane(for: target),
            onDecision: { item, decision in sendDecision(item: item, decision: decision) },
            // An answered form is an allow carrying the picked labels. Same
            // method, same single wire path as Allow/Deny — see
            // `RosterClient.sendDecision`'s note on why there is only one.
            onAnswer: { item, answers in
                sendDecision(item: item, decision: "allow", answers: answers,
                             recordAs: answers.values.sorted().joined(separator: " · "))
            },
            onSend: { text in
                try await sendReply(machine: target.machine,
                                    sessionId: target.sessionId, text: text)
            }
        )
    }
}

/// What a push onto the navigation stack needs to open one session's
/// conversation. Deliberately not a `PaneRow` or a `NotificationHistoryItem`:
/// a notification tap can name a session the roster has not listed, and the
/// two originating types do not share a shape. `Hashable` because
/// `navigationDestination(for:)` keys on the value.
enum Route: Hashable {
    case conversation(ConversationTarget)
    case history
}

struct ConversationTarget: Hashable {
    let machine: String
    let sessionId: String
    /// See `SessionConversationView.resumeId` — the durable half of the pair.
    var resumeId: String?
    let title: String
    let subtitle: String
}
