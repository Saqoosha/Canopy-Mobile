import Foundation
import Testing
@testable import CanopyMobile

/// Every fixture here was measured against markdown-it 14 (CommonMark) before
/// being written down: the "was broken" cases really did render as literal
/// asterisks, and the "already fine" ones really did render as emphasis. A
/// fixture whose expectation was reasoned about rather than measured would
/// pin this file's opinion instead of CommonMark's behaviour.
struct CJKEmphasisTests {
    private let zwsp = "\u{200B}"

    // MARK: - The shapes that were broken

    @Test("A closing ** between punctuation and a letter gets a zero-width space")
    func closingAfterPunctuationBeforeLetter() {
        #expect(CJKEmphasis.normalized("**正規化。**句読点") == "**正規化。\(zwsp)**句読点")
    }

    @Test("A bracket is not moved — only the delimiter is guarded")
    func bracketStaysInsideTheSpan() {
        // Moving `」` outside would fix the flanking and break the pair; this
        // is why the fix inserts rather than reorders.
        #expect(CJKEmphasis.normalized("**「正規化」**句読点") == "**「正規化」\(zwsp)**句読点")
    }

    @Test("Italics break the same way and are fixed the same way")
    func singleAsteriskEmphasis() {
        #expect(CJKEmphasis.normalized("*正規化。*句読点") == "*正規化。\(zwsp)*句読点")
    }

    // MARK: - The shapes that were already fine, and must not change

    @Test("A space after the closing run already satisfies CommonMark")
    func spaceAfterClosingIsUntouched() {
        #expect(CJKEmphasis.normalized("**正規化。** 句読点") == "**正規化。** 句読点")
    }

    @Test("Punctuation already outside the span is untouched")
    func punctuationOutsideIsUntouched() {
        #expect(CJKEmphasis.normalized("**正規化**。句読点") == "**正規化**。句読点")
    }

    @Test("English prose is untouched")
    func englishIsUntouched() {
        #expect(CJKEmphasis.normalized("**bold.** Next") == "**bold.** Next")
    }

    @Test("Text with no asterisk at all short-circuits unchanged")
    func noAsterisk() {
        #expect(CJKEmphasis.normalized("ただの文。") == "ただの文。")
    }

    // MARK: - Code must never be rewritten

    @Test("An inline code span keeps its asterisks verbatim")
    func inlineCodeUntouched() {
        #expect(CJKEmphasis.normalized("説明。`a。**b`と書く") == "説明。`a。**b`と書く")
    }

    @Test("A fenced block keeps its asterisks verbatim")
    func fencedBlockUntouched() {
        let src = """
        文章。**強調**する

        ```sh
        echo "。**not markup"
        ```

        続き。**強調**する
        """
        let out = CJKEmphasis.normalized(src)
        #expect(out.contains("echo \"。**not markup\""))
        #expect(!out.contains("。\(zwsp)**not markup"))
    }

    @Test("An unterminated fence is treated as code, not prose")
    func unterminatedFenceIsCode() {
        // The dangerous direction: a half-written block rewritten as prose
        // would insert an invisible character into a command someone is about
        // to approve.
        let src = "説明。\n```sh\nrm -rf 。**x\n"
        #expect(CJKEmphasis.normalized(src) == src)
    }

    @Test("A backtick with no closing run leaves the rest as prose")
    func unclosedInlineCode() {
        // `contains` rather than an exact match: what matters is that the
        // fix still applies after a stray backtick, not the exact placement
        // of the backtick itself.
        #expect(CJKEmphasis.normalized("a ` b **強調。**続き").contains("強調。\(zwsp)**続き"))
    }

    @Test("A four-backtick fence is not closed by a three-backtick line")
    func longerFenceNeedsALongerClose() {
        // Truncating the opener to three made the inner ``` close the block,
        // so the real closing fence read as a NEW opener and every paragraph
        // after it stayed "code" — the rewrite silently stopped applying for
        // the rest of the message.
        // The trailing text must be one the rule actually fires on, and the
        // assertion must be an AND, not an OR: an OR that also accepts the
        // buggy "remainder swallowed as code" outcome passes against the old
        // implementation and pins nothing. Verified: this fails against the
        // pre-fix code, which never left the block.
        let src = """
        ````
        ```
        ````

        続き**強調。**する
        """
        let out = CJKEmphasis.normalized(src)
        #expect(out.contains("強調。\(zwsp)**する"))
        #expect(out.hasPrefix("````\n```\n````"))
    }

    @Test("An indented code block is never rewritten")
    func indentedCodeUntouched() {
        // The dangerous shape: an invisible character inside a command.
        let src = "説明。\n\n    echo 。**hidden\n"
        #expect(CJKEmphasis.normalized(src) == src)
    }

    /// A characterization test, not a regression one: it also passes against
    /// the implementation that had no indented-code detection at all, because
    /// that one treated every line as prose. What it pins is the FUTURE —
    /// widening the indented rule to fire without a preceding blank line
    /// would break it, and that is the change most likely to be made by
    /// someone "tidying" the condition.
    @Test("An indented line that continues a paragraph is still prose")
    func indentedParagraphContinuationIsProse() {
        // Indented code cannot interrupt a paragraph, so this must still be
        // normalised — treating it as code would silently skip the fix on
        // any wrapped, indented line.
        // The punctuation must sit before the CLOSING delimiter for the rule
        // to fire at all — `。**強調**する` puts it before the OPENING one and
        // already renders, which is what a first draft of this fixture got
        // wrong.
        let src = "説明が続く\n    そして**強調。**する"
        #expect(CJKEmphasis.normalized(src).contains("強調。\(zwsp)**する"))
    }

    @Test("A blank line inside an indented block does not end it")
    func blankLineInsideIndentedCode() {
        let src = "説明。\n\n    a 。**x\n\n    b 。**y\n"
        #expect(CJKEmphasis.normalized(src) == src)
    }

    @Test("A closing fence may be followed by whitespace only")
    func closingFenceRejectsTrailingText() {
        // ```notes is content inside the block, not a close. Treating it as
        // one exits early and hands the REST of the code block to the
        // rewrite — the invisible-character-in-a-command failure this file
        // exists to prevent.
        let src = "```\n```notes\necho 。**x\n```\n\n続き**強調。**する"
        let out = CJKEmphasis.normalized(src)
        #expect(out.contains("echo 。**x"))
        #expect(!out.contains("echo 。\(zwsp)**x"))
        #expect(out.contains("強調。\(zwsp)**する"))
    }

    // MARK: - Line starts belong to lists, not emphasis

    @Test("A bullet at the start of a line is never guarded")
    func bulletUntouched() {
        #expect(CJKEmphasis.normalized("- 一つ目\n* 二つ目\n") == "- 一つ目\n* 二つ目\n")
    }

    @Test("A thematic break is left alone")
    func thematicBreakUntouched() {
        #expect(CJKEmphasis.normalized("***\n") == "***\n")
    }

    // MARK: - Round-tripping

    @Test("Text needing no change comes back byte-identical, trailing newline and all")
    func roundTripsExactly() {
        // Every fixture contains an asterisk on purpose: `normalized` returns
        // early when there is none, so a fixture without one exercises the
        // guard instead of the segmenter — which is what this test did until
        // three other tests failed and exposed it.
        for src in ["*a*", "*a*\n", "*a*\n\n", "- *a*\n* b\n",
                    "```\n**x**\n```", "```\n**x**\n```\n", "a **b** c"] {
            #expect(CJKEmphasis.normalized(src) == src, "changed: \(src.debugDescription)")
        }
    }

    @Test("Applying the fix twice changes nothing the second time")
    func idempotent() {
        let once = CJKEmphasis.normalized("**正規化。**句読点")
        #expect(CJKEmphasis.normalized(once) == once)
    }
}

/// The `AskUserQuestion` form. The format asserted here is the EXTENSION's,
/// read out of its webview bundle — answers keyed by the question's own text,
/// labels joined with ", ". Measured against 2.1.260, the version Canopy
/// loads, and unchanged in 2.1.90. Nothing on the phone controls it, and
/// getting it wrong produces a silent refusal on the Mac rather than anything
/// visible here, which is why it is pinned on this side as well as the Mac's.
struct AskChoiceTests {
    private let form = [
        AskChoice(question: "Which database?", header: "DB", options: ["Postgres", "SQLite"]),
    ]

    @Test("An answer is keyed by the question's own text")
    func answerKeyedByQuestionText() {
        let answers = AskChoice.answers(for: form, picked: ["Which database?": ["Postgres"]])
        #expect(answers == ["Which database?": "Postgres"])
    }

    @Test("Several labels join with the extension's separator")
    func multiSelectJoins() {
        let multi = [AskChoice(question: "Which?", options: ["A", "B", "C"], multiSelect: true)]
        #expect(AskChoice.answers(for: multi, picked: ["Which?": ["C", "A"]]) == ["Which?": "A, C"])
    }

    @Test("Labels come back in the order they were offered, not in set order")
    func optionOrderWins() {
        // A Set has no order, so building the string from it directly makes
        // the answer vary between runs — and the Mac compares against the
        // labels it offered, so an unstable order is an unstable answer.
        let multi = [AskChoice(question: "Q", options: ["first", "second"], multiSelect: true)]
        for picked in [Set(["second", "first"]), Set(["first", "second"])] {
            #expect(AskChoice.answers(for: multi, picked: ["Q": picked]) == ["Q": "first, second"])
        }
    }

    @Test("A question with nothing picked is omitted, which is what makes it detectable")
    func unansweredQuestionOmitted() {
        let two = [AskChoice(question: "Q1", options: ["a"]),
                   AskChoice(question: "Q2", options: ["b"])]
        #expect(AskChoice.answers(for: two, picked: ["Q1": ["a"]]) == ["Q1": "a"])
        #expect(!AskChoice.isComplete(form: two, picked: ["Q1": ["a"]]))
        #expect(AskChoice.isComplete(form: two, picked: ["Q1": ["a"], "Q2": ["b"]]))
    }

    @Test("An empty form is complete, so no card can be stuck unsendable")
    func emptyFormIsComplete() {
        #expect(AskChoice.isComplete(form: [], picked: [:]))
    }

    // MARK: - Decoding what APNs actually hands over

    @Test("A push entry decodes, defaulting multiSelect to single")
    func decodesFromUserInfo() {
        let choice = AskChoice(userInfo: [
            "question": "Which database?", "header": "DB", "options": ["Postgres", "SQLite"],
        ])
        #expect(choice?.question == "Which database?")
        #expect(choice?.options.map(\.label) == ["Postgres", "SQLite"])
        #expect(choice?.multiSelect == false)
    }

    @Test("An entry with no options is refused rather than decoded into a dead card")
    func refusesEmptyOptions() {
        #expect(AskChoice(userInfo: ["question": "Q", "options": [String]()]) == nil)
        #expect(AskChoice(userInfo: ["question": "", "options": ["a"]]) == nil)
        #expect(AskChoice(userInfo: ["options": ["a"]]) == nil)
    }
}

/// Which notifications draw an answerable form. Split out of the view so the
/// rules can be exercised without one — the failure they prevent is a card
/// that latches into "Sending…" forever, which no build error and no crash
/// would ever surface.
struct AnswerableFormTests {
    private func item(
        kind: String = "asking",
        requestId: String? = "r1",
        answerable: Bool? = false,
        decision: String? = nil,
        choices: [AskChoice]? = [AskChoice(question: "Q", options: ["a"])]
    ) -> NotificationHistoryItem {
        NotificationHistoryItem(
            id: "1", receivedAt: Date(), title: "t", body: "b",
            machine: "m", sessionId: "s", kind: kind, requestId: requestId,
            decision: decision, answerable: answerable, choices: choices)
    }

    @Test("An unanswered ask with a form and a request id draws it")
    func drawsTheForm() {
        #expect(item().answerableForm?.count == 1)
    }

    // The reported bug: the form commits optimistically, and the send path
    // needs a requestId to address anything. Without one the card disabled
    // itself, showed "Sending…", and never came back.
    @Test("A form with no request id is not drawn")
    func refusesWithoutRequestId() {
        #expect(item(requestId: nil).answerableForm == nil)
    }

    @Test("An already-answered ask is not drawn again")
    func refusesAnswered() {
        #expect(item(decision: "Postgres").answerableForm == nil)
    }

    @Test("An Allow/Deny ask is not drawn as a form")
    func refusesAnswerableAsk() {
        #expect(item(answerable: true).answerableForm == nil)
        #expect(item(answerable: nil).answerableForm == nil)
    }

    @Test("A completion is never a form")
    func refusesCompletion() {
        #expect(item(kind: "completed").answerableForm == nil)
    }

    @Test("An ask with no form falls back to the older no-buttons rendering")
    func refusesEmptyChoices() {
        #expect(item(choices: nil).answerableForm == nil)
        #expect(item(choices: []).answerableForm == nil)
    }
}

/// Whether a push's form is usable at all. Every case here ends in the same
/// fallback — draw no buttons, answer at the Mac — because a form that is
/// wrong in these ways produces an answer the Mac refuses, which reaches the
/// user as "not delivered" with no better move available.
struct AskFormParsingTests {
    @Test("A well-formed push becomes a form")
    func parsesAWholeForm() {
        let form = AskChoice.form(userInfo: [
            ["question": "Q1", "options": ["a"]],
            ["question": "Q2", "options": ["b"], "multiSelect": true],
        ])
        #expect(form?.count == 2)
        #expect(form?[1].multiSelect == true)
    }

    // Keeping the entries that parsed would draw a form missing a question,
    // and the phone only checks the form it has — so it would call itself
    // complete and send an answer the Mac refuses.
    @Test("One malformed entry discards the whole form, not just that entry")
    func partialFormIsRefused() {
        #expect(AskChoice.form(userInfo: [
            ["question": "Q1", "options": ["a"]],
            ["question": "Q2"],
        ]) == nil)
    }

    // The answer map is keyed by the question's text, so one selection would
    // answer both — while `isComplete` sees a single satisfied key and says
    // the form is done.
    @Test("Two questions sharing one text discard the form")
    func duplicateQuestionIsRefused() {
        #expect(AskChoice.form(userInfo: [
            ["question": "Same", "options": ["a"]],
            ["question": "Same", "options": ["b"]],
        ]) == nil)
    }

    @Test("An absent or empty form is nil, not an empty list")
    func absentFormIsNil() {
        #expect(AskChoice.form(userInfo: nil) == nil)
        #expect(AskChoice.form(userInfo: [[String: Any]]()) == nil)
        #expect(AskChoice.form(userInfo: "not a form") == nil)
    }
}

/// Whether the raw `body` is worth rendering under a form. The failure it
/// prevents is not a crash — it is the tool's input JSON printed above the
/// buttons that say the same thing, pushing them most of a screen down.
struct ShowsBodyTests {
    private func item(choices: [AskChoice]?, decision: String? = nil) -> NotificationHistoryItem {
        NotificationHistoryItem(
            id: "1", receivedAt: Date(), title: "t", body: "{\"questions\":[…]}",
            machine: "m", sessionId: "s", kind: "asking", requestId: "r",
            decision: decision, answerable: choices == nil ? nil : false, choices: choices)
    }

    @Test("A notification with no form shows its body")
    func plainNotificationShowsBody() {
        #expect(item(choices: nil).showsBody)
        #expect(item(choices: []).showsBody)
    }

    @Test("A form replaces the body rather than sitting under it")
    func formHidesBody() {
        #expect(!item(choices: [AskChoice(question: "Q", options: ["a"])]).showsBody)
    }

    // Keyed on the form, not on answerability: reverting to raw JSON at the
    // moment the ask is answered is the same duplication with worse timing.
    @Test("An answered form still hides the body")
    func answeredFormHidesBody() {
        #expect(!item(choices: [AskChoice(question: "Q", options: ["a"])], decision: "a").showsBody)
    }
}

/// Option descriptions and the old bare-label shape. The first version of the
/// push dropped descriptions on the argument that nobody taps them — true and
/// irrelevant, since they are read, not tapped, and once the tool's raw input
/// stopped being shown above the form the phone held no copy of them at all.
struct AskOptionTests {
    @Test("An option carries its description")
    func carriesDescription() {
        let choice = AskChoice(userInfo: [
            "question": "Q",
            "options": [["label": "a", "description": "the first"], ["label": "b"]],
        ])
        #expect(choice?.options.map(\.label) == ["a", "b"])
        #expect(choice?.options.first?.description == "the first")
        #expect(choice?.options.last?.description == nil)
    }

    @Test("An empty description is dropped rather than rendered as a blank line")
    func emptyDescriptionIsNil() {
        let choice = AskChoice(userInfo: ["question": "Q", "options": [["label": "a", "description": ""]]])
        #expect(choice?.options.first?.description == nil)
    }

    // An option that silently vanished is a choice the user cannot make and
    // cannot see they could have made.
    @Test("One unusable option discards the whole question")
    func partialOptionsRefused() {
        #expect(AskChoice(userInfo: ["question": "Q", "options": [["label": "a"], ["nope": 1]]]) == nil)
    }

    // Stored notifications from the build that had no descriptions are still
    // in the App Group container, and HistoryStore decodes the whole file at
    // once — refusing the old shape would make the entire history unreadable,
    // not lose one card.
    @Test("A bare string still decodes, so old stored history keeps loading")
    func bareLabelDecodes() throws {
        let json = Data("""
        {"question":"Q","header":null,"options":["a","b"],"multiSelect":false}
        """.utf8)
        let choice = try JSONDecoder().decode(AskChoice.self, from: json)
        #expect(choice.options.map(\.label) == ["a", "b"])
        #expect(choice.options.allSatisfy { $0.description == nil })
    }

    @Test("A bare string in the push shape decodes too")
    func bareLabelFromUserInfo() {
        #expect(AskChoice(userInfo: ["question": "Q", "options": ["a"]])?.options.first?.label == "a")
    }
}

/// The body must reappear whenever the card will NOT draw the questions
/// itself. `showsBody` was keyed on "has choices", which is a weaker
/// condition than "draws a form" — an item holding choices but missing the
/// `requestId` needed to answer drew neither, leaving an empty card.
struct RendersQuestionsTests {
    private func item(requestId: String?, answerable: Bool?, decision: String?) -> NotificationHistoryItem {
        NotificationHistoryItem(
            id: "1", receivedAt: Date(), title: "t", body: "raw json",
            machine: "m", sessionId: "s", kind: "asking", requestId: requestId,
            decision: decision, answerable: answerable,
            choices: [AskChoice(question: "Q", options: ["a"])])
    }

    @Test("An answerable form draws the questions and hides the body")
    func formDrawsQuestions() {
        let it = item(requestId: "r", answerable: false, decision: nil)
        #expect(it.rendersQuestions)
        #expect(!it.showsBody)
    }

    @Test("An answered form still draws them")
    func answeredDrawsQuestions() {
        #expect(item(requestId: "r", answerable: false, decision: "a").rendersQuestions)
    }

    // The regression: choices present, form unrenderable, nothing answered.
    @Test("Choices with no request id fall back to the body, not to nothing")
    func unrenderableFormShowsBody() {
        let it = item(requestId: nil, answerable: false, decision: nil)
        #expect(!it.rendersQuestions)
        #expect(it.showsBody)
    }

    @Test("Inconsistent answerable metadata also falls back to the body")
    func inconsistentAnswerableShowsBody() {
        #expect(item(requestId: "r", answerable: true, decision: nil).showsBody)
    }
}

/// The roster header's "Updated …" wording. It sits over a once-a-second
/// TimelineView, so anything with seconds in it becomes a counter.
struct PublishedLabelTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Under a minute reads as just now, whatever the seconds say")
    func underAMinuteIsJustNow() {
        for s in [0, 5, 30, 59] {
            #expect(SessionActivityStyle.published(since: 1_000_000 - s, now: now) == "just now")
        }
    }

    @Test("From a minute on it steps by the minute, then the hour")
    func minutesThenHours() {
        #expect(SessionActivityStyle.published(since: 1_000_000 - 60, now: now) == "1m ago")
        #expect(SessionActivityStyle.published(since: 1_000_000 - 7_200, now: now) == "2h ago")
    }

    @Test("A publish stamped in the future is treated as now, not as negative")
    func futureClampsToNow() {
        #expect(SessionActivityStyle.published(since: 1_000_000 + 30, now: now) == "just now")
    }
}

/// What the History list previews for an ask. An AskUserQuestion's body is
/// the tool's input as a fenced JSON block, which read as "```json" / "{…"
/// in the two-line preview.
struct ListDisplayBodyTests {
    private func item(choices: [AskChoice]?, bodyShort: String? = nil) -> NotificationHistoryItem {
        NotificationHistoryItem(
            id: "1", receivedAt: Date(), title: "t", body: "```json\n{\n}\n```", bodyShort: bodyShort,
            machine: "m", sessionId: "s", kind: "asking", requestId: "r", answerable: false, choices: choices)
    }

    @Test("An ask with a form previews its questions, not the JSON fence")
    func askPreviewsQuestions() {
        let form = [AskChoice(question: "Which database?", options: ["a"]),
                    AskChoice(question: "Which features?", options: ["b"])]
        #expect(item(choices: form).listDisplayBody == "Which database? · Which features?")
    }

    @Test("Without a form the preview is the body as before")
    func noFormFallsBackToBody() {
        #expect(item(choices: nil).listDisplayBody == "```json\n{\n}\n```")
        #expect(item(choices: nil, bodyShort: "short").listDisplayBody == "short")
    }
}
