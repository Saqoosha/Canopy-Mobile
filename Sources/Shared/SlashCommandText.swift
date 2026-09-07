import Foundation

/// Recovers the slash command a `user` event started life as.
///
/// The CLI expands `/remember-session push` before the model sees it, and the
/// expansion — not the line that was typed — is what it echoes back on the
/// webview channel. That echo is the path `publishSessionEvents` reads, so the
/// event's text is:
///
///     <command-message>remember-session</command-message>
///     <command-name>/remember-session</command-name>
///     <command-args>push</command-args>
///
/// which the phone drew verbatim, four lines of XML under a "You" header
/// (reported from the device). The Mac shows the same turn as the command.
///
/// **Whole text or nothing.** Canopy hit this hazard first, in
/// `ShimProcess.isRecapEcho`, and the reasoning transfers exactly: a substring
/// match destroys any message that merely QUOTES the wrapper — a pasted
/// transcript excerpt, a bug report about this feature, a review of this very
/// file. So the parse consumes the whole string or declines, and anything it
/// declines falls through to the ordinary Markdown rendering unchanged.
enum SlashCommandText {
    /// The command as typed — `/name` or `/name args` — or nil when `text` is
    /// not exactly one wrapper.
    ///
    /// `<command-args>` is optional: 3259 of 5258 wrappers sampled from local
    /// transcripts carry one, so an argument-less command must render as just
    /// its name. `<command-message>` is the name again without the slash and
    /// is read only to be discarded — accepting it is what lets the parse
    /// reach the end of the string.
    static func rendered(_ text: String) -> String? {
        var rest = Substring(text)
        _ = take(element: "command-message", from: &rest)
        guard let name = take(element: "command-name", from: &rest) else { return nil }
        let args = take(element: "command-args", from: &rest)
        // The trailing whitespace skip is what makes this whole-text: with it,
        // a wrapper followed by prose leaves that prose here and is declined.
        skipWhitespace(&rest)
        guard rest.isEmpty else { return nil }

        var slug = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Normally present (`/ship-it`), occasionally not. Strip whatever came
        // and write exactly one, so both spellings render identically.
        if slug.hasPrefix("/") { slug.removeFirst() }
        guard !slug.isEmpty else { return nil }

        let trimmedArgs = (args ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedArgs.isEmpty ? "/\(slug)" : "/\(slug) \(trimmedArgs)"
    }

    /// Consumes `<name>inner</name>` from the front of `rest` and returns
    /// `inner`, or returns nil and leaves `rest` untouched.
    ///
    /// Inner text containing `<` is refused rather than accepted greedily.
    /// That declines the element, which strands its opening tag in `rest`, and
    /// the caller's whole-text check then declines the message — the raw
    /// original is shown instead of a line assembled from a guess about where
    /// the value ended.
    private static func take(element name: String, from rest: inout Substring) -> String? {
        var cursor = rest
        skipWhitespace(&cursor)
        guard cursor.hasPrefix("<\(name)>") else { return nil }
        cursor = cursor.dropFirst(name.count + 2)
        guard let close = cursor.range(of: "</\(name)>") else { return nil }
        let inner = cursor[..<close.lowerBound]
        guard !inner.contains(where: { $0 == "<" }) else { return nil }
        rest = cursor[close.upperBound...]
        return String(inner)
    }

    /// The CLI writes its own indentation between the tags, so the layout
    /// between them is not something to pin.
    private static func skipWhitespace(_ rest: inout Substring) {
        rest = rest.drop(while: \.isWhitespace)
    }
}
