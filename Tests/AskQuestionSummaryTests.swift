import Foundation
import Testing
@testable import CanopyMobile

/// `questionSummary` is the one rule three surfaces read: the conversation
/// card, the History row, and — since 2026-09-07 — the lock-screen banner the
/// Notification Service Extension rewrites. Before it existed, two of those
/// carried a copy apiece and the third was missed, so a real ask arrived on
/// the lock screen reading "```json / { / \"questions\" : [ / {…".
///
/// These are pure value tests: `NotificationHistoryItem` lives in `Shared/` and
/// needs no App Group container, unlike `HistoryStore`.
struct AskQuestionSummaryTests {
    private func ask(choices: [AskChoice]?,
                     body: String = "```json\n{\n  \"questions\" : [\n    {…",
                     bodyShort: String? = nil) -> NotificationHistoryItem {
        NotificationHistoryItem(
            id: "r1", receivedAt: Date(timeIntervalSince1970: 1), title: "Canopy — AskUserQuestion",
            body: body, bodyShort: bodyShort, machine: "M1", sessionId: "s1",
            kind: "asking", requestId: "r1", decision: nil, decidedAt: nil,
            allowAlways: nil, resumeId: nil, answerable: false, choices: choices,
            eventId: nil
        )
    }

    private func choice(_ question: String) -> AskChoice {
        AskChoice(question: question, header: nil,
                  options: [AskOption(label: "yes"), AskOption(label: "no")],
                  multiSelect: false)
    }

    @Test("One question is the summary")
    func singleQuestion() {
        #expect(ask(choices: [choice("Which database?")]).questionSummary == "Which database?")
    }

    @Test("Several questions join with a separator")
    func manyQuestions() {
        let item = ask(choices: [choice("Which database?"), choice("Which region?")])
        #expect(item.questionSummary == "Which database? · Which region?")
    }

    @Test("No choices means no summary, so the relay's banner stands")
    func noChoices() {
        #expect(ask(choices: nil).questionSummary == nil)
    }

    @Test("An empty form means no summary")
    func emptyChoices() {
        #expect(ask(choices: []).questionSummary == nil)
    }

    /// The regression that started this: the JSON body must never be what any
    /// surface shows when a form came through.
    @Test("The summary replaces the JSON body, never repeats it")
    func summaryIsNotTheBody() {
        let item = ask(choices: [choice("Which database?")])
        let summary = try! #require(item.questionSummary)
        #expect(!summary.contains("json"))
        #expect(!summary.contains("{"))
    }

    @Test("The History row prefers the questions over the body")
    func listRowUsesQuestions() {
        #expect(ask(choices: [choice("Which region?")]).listDisplayBody == "Which region?")
    }

    @Test("The History row falls back to the body when there is no form")
    func listRowFallsBack() {
        #expect(ask(choices: nil, body: "Run the migration?").listDisplayBody == "Run the migration?")
    }

    /// `bodyShort` is the relay's own shortened banner. It wins over `body`,
    /// but a form still wins over both.
    @Test("A form outranks the relay's short body")
    func formOutranksBodyShort() {
        let item = ask(choices: [choice("Which region?")], bodyShort: "shortened by the relay")
        #expect(item.listDisplayBody == "Which region?")
    }

    @Test("Without a form the relay's short body wins over the full one")
    func bodyShortWinsWithoutForm() {
        let item = ask(choices: nil, body: "the whole thing", bodyShort: "the short one")
        #expect(item.listDisplayBody == "the short one")
    }
}
