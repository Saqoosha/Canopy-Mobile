import Foundation

/// Opt-in simulator fixtures. No relay requests, notifications, Keychain writes,
/// or shared-history writes while this mode is active. Absent from release use.
@MainActor
enum CanopyDemo {
    static var isEnabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--demo")
        #else
        false
        #endif
    }

    static func snapshots(now: Date = .now) -> [String: MachineSnapshot] {
        let time = Int(now.timeIntervalSince1970)
        func pane(_ id: String, _ title: String, _ project: String, _ state: String, _ seconds: Int) -> PaneRow {
            PaneRow(sessionId: id, resumeId: id, paneIndex: 0, title: title, project: project,
                    state: state, stateSince: time - seconds, contextPct: 24, model: "Claude", messageCount: 12)
        }
        return [
            "studio": MachineSnapshot(machineId: "studio", displayName: "Mac Studio", publishedAt: time - 2,
                                      sessionPct: 32, weeklyPct: 58, panes: [
                pane("notifications", "Review notification flow", "Canopy Mobile", "asking", 120),
                pane("search", "Build session search", "Canopy", "working", 34),
                pane("questions", "Choose database & features", "Canopy", "asking", 60)
            ]),
            "macbook": MachineSnapshot(machineId: "macbook", displayName: "MacBook Pro", publishedAt: time - 8,
                                       sessionPct: 18, weeklyPct: 41, panes: [
                pane("onboarding", "Polish onboarding", "Companion", "unread", 360)
            ])
        ]
    }

    private static var machines = snapshots()

    static func liveSnapshots() -> [String: MachineSnapshot] {
        machines.mapValues { snapshot in
            MachineSnapshot(machineId: snapshot.machineId, displayName: snapshot.displayName,
                            publishedAt: Int(Date.now.timeIntervalSince1970),
                            sessionPct: snapshot.sessionPct, weeklyPct: snapshot.weeklyPct, panes: snapshot.panes)
        }
    }

    static var history: [NotificationHistoryItem] = [
        NotificationHistoryItem(id: "question-form", receivedAt: .now.addingTimeInterval(-60), title: "A few choices before I start",
                                // What a real push carries: the tool input as a fenced block.
                                // A friendly sentence here hid the "```json" preview bug.
                                body: "```json\n{\n  \"questions\" : [\n    {\n      \"header\" : \"Database\",\n      \"question\" : \"Which database?\"\n    }\n  ]\n}\n```",
                                machine: "studio", sessionId: "questions", kind: "asking", requestId: "demo-questions",
                                resumeId: "questions", answerable: false, choices: [
                                    // Descriptions on purpose: on a real ask they carry the
                                    // difference between terse labels, and the form is the
                                    // only place they appear, so the demo must draw them.
                                    AskChoice(question: "Which database?", header: "Database", options: [
                                        AskOption(label: "Postgres", description: "Managed, relational; the team already runs one."),
                                        AskOption(label: "SQLite", description: "Single file, zero ops; fine until two workers write."),
                                    ]),
                                    AskChoice(question: "Which features?", header: "Features", options: [
                                        AskOption(label: "Auth", description: "Sign-in and sessions."),
                                        AskOption(label: "Billing"),
                                        AskOption(label: "Analytics", description: "Usage events, sampled."),
                                    ], multiSelect: true)
                                ]),
        NotificationHistoryItem(id: "permission", receivedAt: .now.addingTimeInterval(-120), title: "Review notification flow",
                                body: "Run the test suite to verify the notification changes?\n\n```sh\nbun test\n```",
                                machine: "studio", sessionId: "notifications", kind: "asking", requestId: "demo-permission",
                                allowAlways: true, resumeId: "notifications"),
        NotificationHistoryItem(id: "update", receivedAt: .now.addingTimeInterval(-180), title: "Notification flow updated",
                                body: "Replies now return to the **correct session**, including after a reconnect.\n\n- Preserved session history\n- Improved permission handling\n- Ready for verification",
                                machine: "studio", sessionId: "notifications", kind: "completed", resumeId: "notifications"),
        NotificationHistoryItem(id: "onboarding-ready", receivedAt: .now.addingTimeInterval(-360), title: "Onboarding is ready",
                                body: "The welcome flow is simpler, and the connection state is easier to understand.\n\n**接続完了。**次のセッションを開始できます。",
                                machine: "macbook", sessionId: "onboarding", kind: "completed", resumeId: "onboarding"),
        NotificationHistoryItem(id: "search-update", receivedAt: .now.addingTimeInterval(-1200), title: "Search index updated",
                                body: "The search index is updated. Working on the remaining matching tests.",
                                machine: "studio", sessionId: "search", kind: "completed", resumeId: "search")
    ]

    static func append(_ item: NotificationHistoryItem) {
        history.insert(item, at: 0)
        NotificationCenter.default.post(name: HistoryUpdateBridge.didUpdate, object: nil)
    }

    static func decide(_ item: NotificationHistoryItem, decision: String) {
        guard let index = history.firstIndex(where: { $0.id == item.id }) else { return }
        if let snapshot = machines[item.machine] {
            let panes = snapshot.panes.map { pane in
                guard pane.sessionId == item.sessionId else { return pane }
                return PaneRow(sessionId: pane.sessionId, resumeId: pane.resumeId, paneIndex: pane.paneIndex,
                               title: pane.title, project: pane.project, state: "working",
                               stateSince: Int(Date.now.timeIntervalSince1970), contextPct: pane.contextPct,
                               model: pane.model, messageCount: pane.messageCount)
            }
            machines[item.machine] = MachineSnapshot(machineId: snapshot.machineId, displayName: snapshot.displayName,
                                                    publishedAt: snapshot.publishedAt, sessionPct: snapshot.sessionPct,
                                                    weeklyPct: snapshot.weeklyPct, panes: panes)
        }
        history[index].decision = decision
        history[index].decisionDelivered = true
        history[index].decidedAt = .now
        NotificationCenter.default.post(name: HistoryUpdateBridge.didUpdate, object: nil)
    }
}
