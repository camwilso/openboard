import Foundation

/**
 What Claude Code calls a session.

 Claude Code sets the terminal tab's title to a summary of what the session is doing —
 "Build openboard ambient status board for Claude Code" — which is a far better name than
 anything derivable from the transcript. The previous approach used the first user
 message, which is whatever you happened to type first: often a pasted path, a URL, or
 a sentence that stopped being what the session was about an hour later.

 The tab title also *updates* as the work changes. The first message never does.

 ## The leading glyph

 Titles arrive with a status character in front — `✳` when idle, `⠂` and friends while
 a turn runs, because it is a spinner. It changes several times a second, so leaving it
 in would make the title look like it is flickering and would defeat any comparison
 against the previous value.

 Stripping it is deliberately done by *category* rather than by listing the glyphs:
 the spinner frames are not documented and there is no reason to think the set is
 fixed.
 */
public enum TerminalTitle {
    /**
     Clean one tab title, or nil if nothing useful is left.

     - Returns: the summary without its status glyph, or nil for a title that is only a
       shell path, only a glyph, or empty — none of which name a session.
     */
    public static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        /*
         Drop a leading status glyph.

         The rule is structural rather than a list of characters: a *short leading token
         containing no letters or digits, followed by a space*. That is what a spinner
         frame looks like, and it is the only thing that reliably distinguishes one from
         a title that genuinely starts with punctuation.

         Matching by character category instead was wrong in both directions. Excluding
         punctuation left `·` in place; including it would eat the opening quote of a
         title like `"fix" the parser`. Neither is a category question — it is a
         question of whether the thing is a separate token in front of the name.
         */
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2,
           parts[0].count <= 2,
           parts[0].rangeOfCharacter(from: .alphanumerics) == nil {
            text = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }

        // A name has to contain something readable. A title that is only a glyph — which
        // happens for a moment as a session starts — is not stripped by the rule above,
        // because there is no space to split on.
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }

        // A bare shell in a directory titles itself with the path. That is the folder
        // name we already show on the second line, so it is not a session name.
        if text.hasPrefix("/") || text.hasPrefix("~") { return nil }

        // Terminal can be configured to append the process and window size —
        // "… — claude — 147×61". The summary is the part before that.
        if let separator = text.range(of: " — ") {
            let head = String(text[text.startIndex..<separator.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { text = head }
        }

        return text.isEmpty ? nil : String(text.prefix(120))
    }

    /// Parse the reader's output: one `tty || title` per line.
    ///
    /// A delimiter rather than JSON because this comes back from AppleScript, which has
    /// no JSON — and `||` cannot appear in a tty path and has not been seen in a title.
    public static func parse(_ output: String) -> [String: String] {
        var titles: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: " || ")
            guard parts.count >= 2 else { continue }
            let tty = parts[0].trimmingCharacters(in: .whitespaces)
            guard tty.hasPrefix("/dev/"), let title = clean(parts[1...].joined(separator: " || "))
            else { continue }
            titles[tty] = title
        }
        return titles
    }
}
