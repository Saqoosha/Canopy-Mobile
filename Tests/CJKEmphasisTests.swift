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
/// read out of its webview bundle (2.1.90, component `h30`) — answers keyed by
/// the question's own text, labels joined with ", ". Nothing on the phone
/// controls it, and getting it wrong produces a silent refusal on the Mac
/// rather than anything visible here, which is why it is pinned on this side
/// as well as the Mac's.
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
        #expect(choice?.options == ["Postgres", "SQLite"])
        #expect(choice?.multiSelect == false)
    }

    @Test("An entry with no options is refused rather than decoded into a dead card")
    func refusesEmptyOptions() {
        #expect(AskChoice(userInfo: ["question": "Q", "options": [String]()]) == nil)
        #expect(AskChoice(userInfo: ["question": "", "options": ["a"]]) == nil)
        #expect(AskChoice(userInfo: ["options": ["a"]]) == nil)
    }
}
