import Foundation
import Testing
@testable import CanopyMobile

/// The same cases and strings as Canopy's `_JobLogicProbe.display`: the phone row must read
/// exactly like the Mac sidebar row.
struct JobDisplayTests {
    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()
    private func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
        Self.cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }
    private func unix(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }
    private var now: Date { at(21, 9, 45) }

    private var running: PaneJob { PaneJob(label: "IG LOD", done: 328, total: 793, etaAt: unix(at(21, 10, 40)), state: "running") }
    private var stalled: PaneJob { PaneJob(label: "h7", done: 680, total: 1077, state: "stalled", stalledSince: unix(at(21, 9, 30))) }

    @Test func timeLabels() {
        #expect(JobDisplay.timeLabel(at(21, 10, 40), now: now, calendar: Self.cal) == "10:40")
        #expect(JobDisplay.timeLabel(at(22, 1, 20), now: now, calendar: Self.cal) == "明日 1:20")
    }

    @Test func trailing() {
        let r = JobDisplay.trailing(running, now: now, calendar: Self.cal)
        #expect(r.top == "10:40" && r.bottom == "41%" && !r.isAlert)
        let s = JobDisplay.trailing(stalled, now: now, calendar: Self.cal)
        #expect(s.top == "停止" && s.bottom == "15m" && s.isAlert)
        let m = JobDisplay.trailing(PaneJob(label: "IG LOD", done: 328, total: 793, state: "measuring"), now: now, calendar: Self.cal)
        #expect(m.top == "計測中" && m.bottom == "41%" && !m.isAlert)
        let u = JobDisplay.trailing(PaneJob(label: "IG LOD", done: 328, total: 793, state: "unknown"), now: now, calendar: Self.cal)
        #expect(u.top == "—" && u.bottom == nil)
    }

    @Test func lines() {
        #expect(JobDisplay.stalledLine(stalled) == "680/1077 で止まっている")
        #expect(abs(JobDisplay.fraction(running) - 328.0 / 793) < 0.0001)
    }

    @Test func ringState() {
        #expect(JobDisplay.ringState("idle", job: running) == "background")
        #expect(JobDisplay.ringState("unread", job: running) == "background")
        #expect(JobDisplay.ringState("asking", job: stalled) == "asking")
        #expect(JobDisplay.ringState("working", job: stalled) == "error")
        #expect(JobDisplay.ringState("idle", job: nil) == "idle")
        #expect(!JobDisplay.drawsRing(PaneJob(label: "x", done: 10, total: 10, state: "done")))
        #expect(JobDisplay.drawsRing(running))
    }

    @Test func stalledJobNeedsAttention() {
        let pane = PaneRow(sessionId: "s", resumeId: "r", paneIndex: 0, title: "T", project: "P", state: "idle",
                           stateSince: 0, contextPct: 0, model: "", messageCount: 0, live: true, job: stalled)
        #expect(JobDisplay.needsAttention(pane))
        let calm = PaneRow(sessionId: "s", resumeId: "r", paneIndex: 0, title: "T", project: "P", state: "idle",
                           stateSince: 0, contextPct: 0, model: "", messageCount: 0, live: true, job: running)
        #expect(!JobDisplay.needsAttention(calm))
    }

    @Test func aFinishedJobShowsDoneWhereTheTimeWas() {
        let done = PaneJob(label: "IG LOD", done: 793, total: 793, state: "done")
        let pane = PaneRow(sessionId: "s", resumeId: "r", paneIndex: 0, title: "T", project: "P", state: "idle",
                           stateSince: 0, contextPct: 0, model: "", messageCount: 0, live: true, job: done)
        #expect(RosterView.trailingJob(pane) == done)
        #expect(JobDisplay.trailing(done, now: now, calendar: Self.cal).top == "完了")
        #expect(!JobDisplay.drawsRing(done))
    }

    @Test func decodesJobAndAttentionLine() throws {
        let json = Data(#"{"sessionId":"s","paneIndex":0,"title":"","project":"","state":"background","stateSince":0,"contextPct":0,"model":"","messageCount":0,"attentionLine":"Bash: make","job":{"label":"IG LOD","done":328,"total":793,"etaAt":1795000000,"state":"running"}}"#.utf8)
        let row = try JSONDecoder().decode(PaneRow.self, from: json)
        #expect(row.attentionLine == "Bash: make")
        #expect(row.job?.etaAt == 1_795_000_000 && row.job?.state == "running" && row.job?.stalledSince == nil)
    }

    @Test func decodesWithoutTheNewKeys() throws {
        let json = Data(#"{"sessionId":"s","paneIndex":0,"title":"","project":"","state":"idle","stateSince":0,"contextPct":0,"model":"","messageCount":0}"#.utf8)
        let row = try JSONDecoder().decode(PaneRow.self, from: json)
        #expect(row.job == nil && row.attentionLine == nil)
    }
}
