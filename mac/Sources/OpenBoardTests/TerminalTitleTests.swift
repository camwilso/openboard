import Foundation
import OpenBoardKit

/**
 Naming a session from its terminal tab.

 Claude Code writes a summary of the work into the tab title and keeps it current. The
 first user message — what this replaced — is whatever you happened to type first, and
 stops describing the session about an hour in.

 The fixtures are real titles read off this machine.
 */
func runTerminalTitleTests() {
    test("a real tab title becomes a session name") {
        expectEqual(
            TerminalTitle.clean("✳ Auto-create Slack channel for high-value transactions"),
            "Auto-create Slack channel for high-value transactions"
        )
        expectEqual(
            TerminalTitle.clean("⠂ Build openboard ambient status board for Claude Code"),
            "Build openboard ambient status board for Claude Code"
        )
    }

    test("every spinner frame is stripped, not just the ones we have seen") {
        // The glyph in front is a spinner: it changes several times a second while a
        // turn runs. Leaving it in makes the title flicker, and comparing titles to
        // decide whether to repaint would never match.
        //
        // Matched by character *category* rather than by a list, because the frames are
        // undocumented and there is no reason to expect the set to be fixed.
        for glyph in ["✳", "⠂", "⠄", "⡀", "✶", "✻", "✽", "◐", "◓", "·", "∗"] {
            expectEqual(
                TerminalTitle.clean("\(glyph) Identify and fix mismatched customer names"),
                "Identify and fix mismatched customer names",
                "\(glyph) survived"
            )
        }
    }

    test("a shell's own path is not a session name") {
        // A tab with no Claude session titles itself with the directory, which is what
        // the second line of the row already shows.
        expect(TerminalTitle.clean("~/Developer/Projects") == nil)
        expect(TerminalTitle.clean("/Users/someone/Developer/Projects") == nil)
    }

    test("a title that is only a glyph names nothing") {
        expect(TerminalTitle.clean("✳") == nil)
        expect(TerminalTitle.clean("   ") == nil)
        expect(TerminalTitle.clean("") == nil)
    }

    test("an appended process and window size are dropped") {
        // Terminal can be set to show them: "… — claude — 147×61".
        expectEqual(
            TerminalTitle.clean("✳ Build openboard ambient status board — claude — 147×61"),
            "Build openboard ambient status board"
        )
    }

    test("a long title is bounded") {
        let long = "✳ " + String(repeating: "a", count: 400)
        expectEqual(TerminalTitle.clean(long)?.count, 120)
    }

    test("the reader's output maps tty to title") {
        // Real output shape, one tab per line.
        let output = """
        /dev/ttys000 || ⠂ Build openboard ambient status board for Claude Code
        /dev/ttys005 || ✳ Auto-create Slack channel for high-value transactions
        /dev/ttys001 || ~/Developer/Projects
        """
        let titles = TerminalTitle.parse(output)
        expectEqual(titles["/dev/ttys000"], "Build openboard ambient status board for Claude Code")
        expectEqual(titles["/dev/ttys005"], "Auto-create Slack channel for high-value transactions")
        // The bare shell is absent rather than present-and-useless, so the caller falls
        // back instead of showing a path where a name should be.
        expect(titles["/dev/ttys001"] == nil)
    }

    test("garbage in the stream does not lose the good lines") {
        // No Automation permission gives an error on stderr and nothing here; a
        // malformed line should cost that line only.
        let output = """
        not a tab at all
        /dev/ttys000 || ✳ A real one
        /dev/ttys009 ||
        """
        let titles = TerminalTitle.parse(output)
        expectEqual(titles.count, 1)
        expectEqual(titles["/dev/ttys000"], "A real one")
    }

    test("a title containing the delimiter survives") {
        // Unlikely, but the split must not truncate a name at the first "||".
        let titles = TerminalTitle.parse("/dev/ttys000 || ✳ Fix a || b parsing bug")
        expectEqual(titles["/dev/ttys000"], "Fix a || b parsing bug")
    }
}
