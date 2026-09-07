import Foundation
import Testing
@testable import CanopyMobile

struct SlashCommandTextTests {
    /// The reported turn, tags separated the way the CLI writes them.
    private let reported = """
        <command-message>remember-session</command-message>
        <command-name>/remember-session</command-name>
        <command-args>push</command-args>
        """

    @Test("The reported wrapper renders as the command that was typed")
    func rendersTheReportedWrapper() {
        #expect(SlashCommandText.rendered(reported) == "/remember-session push")
    }

    @Test("A command with no arguments renders as just its name")
    func rendersWithoutArgs() {
        let text = """
            <command-message>merge-cleanup</command-message>
            <command-name>/merge-cleanup</command-name>
            """
        #expect(SlashCommandText.rendered(text) == "/merge-cleanup")
    }

    @Test("A namespaced command keeps its colon")
    func keepsNamespace() {
        let text = "<command-name>/claude-md-management:claude-md-improver</command-name>"
        #expect(SlashCommandText.rendered(text) == "/claude-md-management:claude-md-improver")
    }

    // Both spellings appear in sampled transcripts. They are the same command.
    @Test("A name written without the leading slash gets exactly one")
    func normalizesTheSlash() {
        #expect(SlashCommandText.rendered("<command-name>schedule</command-name>") == "/schedule")
        #expect(SlashCommandText.rendered("<command-name>/schedule</command-name>") == "/schedule")
    }

    @Test("Arbitrary whitespace between the tags is tolerated")
    func toleratesIndentation() {
        let text = "  <command-message>x</command-message>\n\n\t<command-name>/x</command-name>   "
        #expect(SlashCommandText.rendered(text) == "/x")
    }

    @Test("Multi-word arguments survive intact")
    func keepsWholeArgs() {
        let text = """
            <command-name>/merge-cleanup</command-name>
            <command-args>install, then test it.</command-args>
            """
        #expect(SlashCommandText.rendered(text) == "/merge-cleanup install, then test it.")
    }

    // The hazard Canopy's `isRecapEcho` documents: a substring match would
    // eat every message that merely quotes the wrapper — a pasted transcript,
    // a bug report about this feature, a review of the parser itself.
    @Test("A message that quotes the wrapper is not transformed")
    func declinesAQuotedWrapper() {
        #expect(SlashCommandText.rendered("Look at this: \(reported)") == nil)
        #expect(SlashCommandText.rendered("\(reported)\n\nwhat is that?") == nil)
    }

    @Test("Prose that merely names the tags is not transformed")
    func declinesProseAboutTheTags() {
        #expect(SlashCommandText.rendered("The command-name tag holds the slug.") == nil)
        #expect(SlashCommandText.rendered("Why is <command-name> showing up?") == nil)
    }

    @Test("Ordinary text is left alone")
    func declinesOrdinaryText() {
        #expect(SlashCommandText.rendered("push it") == nil)
        #expect(SlashCommandText.rendered("") == nil)
    }

    // Refusing beats guessing where the value ended: the raw original is
    // shown instead of a line assembled from a bad cut.
    @Test("A value containing a tag character is refused, not cut short")
    func declinesNestedMarkup() {
        let text = "<command-name>/x</command-name><command-args>a < b</command-args>"
        #expect(SlashCommandText.rendered(text) == nil)
        #expect(SlashCommandText.rendered("<command-name>/x <y></command-name>") == nil)
    }

    @Test("An unclosed tag is refused")
    func declinesUnclosedTag() {
        #expect(SlashCommandText.rendered("<command-name>/remember-session") == nil)
    }

    // `/` alone is not a command, and rendering it would put a bare slash
    // where the message used to be.
    @Test("An empty name is refused")
    func declinesEmptyName() {
        #expect(SlashCommandText.rendered("<command-name></command-name>") == nil)
        #expect(SlashCommandText.rendered("<command-name>/</command-name>") == nil)
        #expect(SlashCommandText.rendered("<command-name>   </command-name>") == nil)
    }

    // The tags carry the CLI's newlines; blank args must not become a
    // trailing space on the rendered line.
    @Test("Blank arguments render as no arguments")
    func dropsBlankArgs() {
        let text = "<command-name>/x</command-name>\n<command-args>\n</command-args>"
        #expect(SlashCommandText.rendered(text) == "/x")
    }

    // Order is the CLI's, and a wrapper that does not follow it is not one.
    @Test("The elements are only accepted in the order the CLI writes them")
    func requiresTheCLIOrder() {
        let text = """
            <command-args>push</command-args>
            <command-name>/remember-session</command-name>
            """
        #expect(SlashCommandText.rendered(text) == nil)
    }
}
