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
