import Foundation

/// Makes CommonMark emphasis work in Japanese.
///
/// `**全部きれい。**次の文` renders as literal asterisks, and the reason is a
/// rule, not a bug. A closing `**` may only close if it is *right-flanking*:
/// not preceded by whitespace, and either **not** preceded by punctuation, or
/// preceded by punctuation **and followed by whitespace or punctuation**.
/// English satisfies that by accident — `**bold.** Next` has a space. Japanese
/// does not use spaces between sentences, so `。**次` fails the second clause
/// and the span never closes.
///
/// Measured against markdown-it 14 (CommonMark), 2026-09-05 — exactly two
/// shapes fail and both match that condition:
///
///     **正規化。**句読点     closing ** after 。 then a letter   → FAIL
///     **「正規化」**句読点   closing ** after 」 then a letter   → FAIL
///     **正規化。** 句読点    …then a space                       → ok
///     **正規化**。句読点     punctuation already outside         → ok
///
/// The fix is a **zero-width space immediately before the closing delimiter**,
/// so the delimiter is preceded by ZWSP rather than by punctuation and the
/// first clause carries it. Also measured: moving the punctuation outside
/// works for `。` but is wrong for `」` — it would break the bracket pair —
/// and ZWSP *after* the delimiter, a word joiner, and inline `<strong>` all
/// still fail. One character, no reordering, nothing visible.
///
/// This runs on the phone because the phone owns the text it hands to
/// MarkdownUI. Canopy's own webview renders through the Claude Code
/// extension, which is not ours to change — the same bodies read correctly
/// here and not there, and that asymmetry is the reason this file exists.
enum CJKEmphasis {
    /// U+200B. Invisible, zero-width, and — the property that matters —
    /// neither whitespace nor punctuation to CommonMark, so a delimiter
    /// preceded by it takes the "not preceded by punctuation" branch.
    static let zeroWidthSpace = "\u{200B}"

    /// Rewrites only the closing delimiters that CommonMark would refuse.
    ///
    /// Code is left exactly alone: a `**` inside a fenced block or a code
    /// span is text, not markup, and inserting an invisible character into a
    /// command someone is about to run — or approve — would be worse than the
    /// formatting it fixes.
    static func normalized(_ markdown: String) -> String {
        guard markdown.contains("*") else { return markdown }
        var out = ""
        out.reserveCapacity(markdown.count + 16)
        for segment in CodeSegmenter.segments(of: markdown) {
            out += segment.isCode ? segment.text : fixEmphasis(in: segment.text)
        }
        return out
    }

    /// One pass over prose. A delimiter run of `*` gets a ZWSP before it when
    /// the character before is punctuation and the character after is neither
    /// whitespace nor punctuation.
    ///
    /// **That condition does not distinguish an opening run from a closing
    /// one**, and deliberately so: telling them apart needs the delimiter
    /// matching a real parser does, and this is a pre-pass, not a parser. An
    /// opener that picks up a ZWSP — `合計+**強調**` — is unaffected in the
    /// output, because the same "followed by a non-whitespace,
    /// non-punctuation character" clause that triggers the insert is already
    /// what makes an opener left-flanking, whatever precedes it. Measured
    /// against markdown-it 14: no input that rendered before renders
    /// differently after.
    ///
    /// A run at the start of a line is never touched: that is a bullet or a
    /// thematic break, not emphasis.
    private static func fixEmphasis(in text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        let chars = Array(text)
        var i = 0
        var atLineStart = true
        while i < chars.count {
            let ch = chars[i]
            guard ch == "*" else {
                out.append(ch)
                atLineStart = ch == "\n"
                i += 1
                continue
            }
            var run = i
            while run < chars.count, chars[run] == "*" { run += 1 }
            let before: Character? = i > 0 ? chars[i - 1] : nil
            let after: Character? = run < chars.count ? chars[run] : nil
            if !atLineStart,
               let before, before.isPunctuationForCommonMark,
               let after, !after.isWhitespace, !after.isPunctuationForCommonMark {
                out += zeroWidthSpace
            }
            out += String(repeating: "*", count: run - i)
            atLineStart = false
            i = run
        }
        return out
    }
}

extension Character {
    /// CommonMark's "punctuation character": ASCII punctuation plus the
    /// Unicode punctuation categories. `Character.isPunctuation` covers the
    /// Unicode ones but reports false for `$ + < = > ^ \` | ~`, which the
    /// spec counts, so symbols are included too — `。「」、！？` are what
    /// matter here and are all Po/Ps/Pe.
    var isPunctuationForCommonMark: Bool {
        isPunctuation || isSymbol
    }
}

/// Splits Markdown into code and not-code so a rewrite can skip the former.
///
/// Deliberately small: it tracks fenced blocks (``` or ~~~) and inline code
/// spans, and nothing else. It is not a parser and does not need to be — the
/// only question asked of it is "may this stretch be rewritten", and every
/// construct it does not know about is prose, which is the safe answer for a
/// rewrite that only ever inserts an invisible character.
enum CodeSegmenter {
    struct Segment {
        let text: String
        let isCode: Bool
    }

    static func segments(of markdown: String) -> [Segment] {
        // `split(omittingEmptySubsequences: false)` is exactly invertible by
        // joining with "\n" — "a\n" becomes ["a", ""] and joins back to
        // "a\n". Appending "\n" to each line instead adds one the original
        // never had, which is what three tests caught: a trailing newline
        // grew on every input that reached this far.
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [Segment] = []
        var buffer: [Substring] = []
        var fence: (marker: Character, length: Int)?
        var inIndentedCode = false
        var previousWasBlank = true

        func flush(isCode: Bool) {
            guard !buffer.isEmpty else { return }
            result.append(Segment(text: buffer.joined(separator: "\n"), isCode: isCode))
            buffer = []
        }

        for line in lines {
            let trimmed = line.drop(while: { $0 == " " })
            let blank = trimmed.isEmpty

            if let open = fence {
                buffer.append(line)
                // **A closing run must be at least as long as the opener.**
                // Truncating the opener to three characters made an inner
                // ``` line close a ```` block, so the real closing fence read
                // as a new opener and every following paragraph stayed
                // "code" — silently skipping the rewrite for the rest of the
                // message.
                if let run = fenceRun(trimmed), run.marker == open.marker, run.length >= open.length {
                    flush(isCode: true)
                    fence = nil
                }
                previousWasBlank = blank
                continue
            }

            if let run = fenceRun(trimmed) {
                if inIndentedCode { flush(isCode: true); inIndentedCode = false }
                flush(isCode: false)
                fence = run
                buffer.append(line)
                previousWasBlank = false
                continue
            }

            // Four-space (or tab) indented code. It cannot interrupt a
            // paragraph, so it only STARTS after a blank line — otherwise an
            // indented continuation line of ordinary prose would be frozen.
            // A blank line inside an indented block does not end it; a
            // non-indented, non-blank line does.
            let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
            if inIndentedCode {
                if indented || blank {
                    buffer.append(line)
                    previousWasBlank = blank
                    continue
                }
                flush(isCode: true)
                inIndentedCode = false
            } else if indented, previousWasBlank {
                flush(isCode: false)
                inIndentedCode = true
                buffer.append(line)
                previousWasBlank = false
                continue
            }

            buffer.append(line)
            previousWasBlank = blank
        }
        // An unterminated fence stays code. The alternative — treating a
        // half-written block as prose — would rewrite inside a command
        // someone is about to approve.
        flush(isCode: fence != nil || inIndentedCode)

        // Segments were split on newlines that are no longer inside any of
        // them, so re-insert exactly one between neighbours.
        var joined: [Segment] = []
        for (index, segment) in result.enumerated() {
            let text = index == 0 ? segment.text : "\n" + segment.text
            joined.append(Segment(text: text, isCode: segment.isCode))
        }
        return joined.flatMap { $0.isCode ? [$0] : splitInlineCode($0.text) }
    }

    /// The fence marker and its run length, for a line already stripped of
    /// leading spaces. Three or more of the same character; the length is
    /// kept because a closing run must be at least as long as the opener.
    private static func fenceRun(_ line: Substring) -> (marker: Character, length: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix { $0 == first }.count
        return run >= 3 ? (first, run) : nil
    }

    /// Backtick spans inside a prose segment. A run of N backticks opens a
    /// span that only a run of exactly N backticks closes, which is the rule
    /// that lets ``a ` b`` hold a literal backtick.
    private static func splitInlineCode(_ text: String) -> [Segment] {
        guard text.contains("`") else { return [Segment(text: text, isCode: false)] }
        var result: [Segment] = []
        var buffer = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "`" else {
                buffer.append(chars[i])
                i += 1
                continue
            }
            var open = i
            while open < chars.count, chars[open] == "`" { open += 1 }
            let ticks = open - i
            // Find a closing run of exactly `ticks`.
            var j = open
            var close: Int?
            while j < chars.count {
                guard chars[j] == "`" else { j += 1; continue }
                var end = j
                while end < chars.count, chars[end] == "`" { end += 1 }
                if end - j == ticks { close = end; break }
                j = end
            }
            guard let close else {
                // No closing run: the backticks are literal text, so the rest
                // is prose and stays eligible for the rewrite.
                buffer += String(chars[i...])
                break
            }
            if !buffer.isEmpty {
                result.append(Segment(text: buffer, isCode: false))
                buffer = ""
            }
            result.append(Segment(text: String(chars[i ..< close]), isCode: true))
            i = close
        }
        if !buffer.isEmpty { result.append(Segment(text: buffer, isCode: false)) }
        return result
    }
}
