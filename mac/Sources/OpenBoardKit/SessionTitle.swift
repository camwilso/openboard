import Foundation

/**
 What to call a session.

 Six keys and six rows of "openboard" is not a board — if every row shows the working
 directory, the popover cannot tell you which chat is which, only which *project* is
 which. Two sessions in the same repo are indistinguishable, and that is the common
 case.

 The name used is Claude Code's own: an `ai-title` entry, which is the same string the
 VS Code extension renames its tab to. So a row in the popover and a tab in the editor
 read alike, and mapping a key to a chat is a matter of recognising the words rather
 than counting windows.

 An earlier version used the **first thing you asked for**, on the reasoning that
 Claude Code writes no title into a *live* transcript and `summary` lines only appear
 once a session is compacted. That is no longer true — `ai-title` is written from the
 first turn or two and rewritten as the session goes on — and the opening message was
 always a poor name for a session that has moved on. It stays as the fallback, because
 a chat too young to have been named still has to be told apart from five others.
 */
public enum SessionTitle {
    /**
     A name, and whether it can be trusted not to change.

     The distinction is load-bearing. `ai-title` is *settled*: once Claude Code has
     named a session it rewrites the same line, so that answer can be kept forever and
     the popover — which asks on every repaint — never reads the file again.

     The opening message is only a **stand-in** until that name exists. Cached with the
     same finality it would freeze a row on the fallback seconds before the real name
     lands, and nothing would ever revisit it. So a provisional name is re-read, and
     only when the file has actually grown: a `stat` per repaint rather than a read.
     */
    private struct Cached {
        let name: String
        let settled: Bool
        let size: Int
    }

    /// `nonisolated(unsafe)` with an explicit lock rather than an actor: this is read
    /// during a SwiftUI body evaluation, which cannot await, and the cost of the wrong
    /// answer is a stale row rather than corruption. The lock makes it correct anyway.
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()

    /// Stop after this much of the file.
    ///
    /// A transcript grows without bound, and `file-history-snapshot` entries near the
    /// top can be enormous. Both names live near the front — the opening message is the
    /// first few entries, and across real transcripts from 24KB to 7.8MB the first
    /// `ai-title` landed between 21KB and 25KB in — so this is generous rather than
    /// tight. It runs on the main thread when the popover opens, and a 40MB read there
    /// is a visible hang.
    private static let byteBudget = 512 * 1024

    public static func forSession(transcriptPath: String?) -> String? {
        guard let transcriptPath, !transcriptPath.isEmpty else { return nil }
        let size = fileSize(of: transcriptPath)

        lock.lock()
        if let hit = cache[transcriptPath], hit.settled || hit.size == size {
            lock.unlock()
            return hit.name
        }
        lock.unlock()

        guard let found = name(inJSONL: readHead(of: transcriptPath) ?? "") else { return nil }
        lock.lock()
        cache[transcriptPath] = Cached(name: found.name, settled: found.settled, size: size)
        lock.unlock()
        return found.name
    }

    /// What to call this session, and whether the answer is final. Exposed for the
    /// tests, which parse a fixture rather than a real file.
    public static func name(inJSONL text: String) -> (name: String, settled: Bool)? {
        if let title = aiTitle(inJSONL: text) { return (title, true) }
        if let opening = firstUserMessage(inJSONL: text) { return (opening, false) }
        return nil
    }

    /**
     Claude Code's own name for the session.

     The *first* occurrence is taken, not the last. The line is rewritten as the session
     goes on, but reading the newest one would mean tailing a file that grows without
     bound on every repaint, to correct a name that in practice does not change — and
     the read budget above only reaches the front of the file anyway.
     */
    public static func aiTitle(inJSONL text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  entry["type"] as? String == "ai-title",
                  let raw = entry["aiTitle"] as? String,
                  let title = clean(raw)
            else { continue }
            return title
        }
        return nil
    }

    private static func fileSize(of path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Exposed for the tests, which need to parse a fixture rather than a real file.
    public static func firstUserMessage(inJSONL text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  entry["type"] as? String == "user",
                  let message = entry["message"] as? [String: Any]
            else { continue }

            // Content is either a bare string or the block form, depending on how the
            // message was submitted. Both appear in real transcripts.
            if let text = message["content"] as? String {
                return clean(text)
            }
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "text" {
                    if let text = block["text"] as? String { return clean(text) }
                }
            }
        }
        return nil
    }

    private static func readHead(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteBudget), !data.isEmpty else {
            return nil
        }
        // The budget almost certainly cuts a line in half; dropping the partial tail
        // keeps the parser from failing on it.
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if let lastNewline = text.lastIndex(of: "\n") {
            text = String(text[..<lastNewline])
        }
        return text
    }

    /**
     Turn a message into something that fits one line.

     A first message is often several paragraphs, and it frequently opens with pasted
     context or a command rather than a sentence. Taking the first line and trimming is
     enough — the row is 300pt wide and the full text would be truncated by the layout
     anyway, with the difference that this truncates at a word boundary the reader
     chose.
     */
    public static func clean(_ raw: String) -> String? {
        // System-injected wrappers are not what anyone typed — otherwise every resumed
        // session is named after a reminder block. The *whole* element goes: stripping
        // only the opening tag leaves its body, which is worse than leaving it alone
        // because the result looks like something the user wrote.
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("<"),
              let openEnd = text.firstIndex(of: ">") {
            let name = text[text.index(after: text.startIndex)..<openEnd]
            // Only well-formed named elements; a message that merely starts with "<"
            // is left as written.
            guard !name.isEmpty, !name.contains(" "), !name.hasPrefix("/") else { break }
            guard let closeStart = text.range(of: "</\(name)>") else { break }
            text = String(text[closeStart.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let firstLine, !firstLine.isEmpty else { return nil }
        return String(firstLine.prefix(120))
    }

    /// Forget a session's cached title. Called when a slot is released, so a key reused
    /// by a different chat does not keep the old name.
    public static func forget(transcriptPath: String?) {
        guard let transcriptPath else { return }
        lock.lock()
        cache.removeValue(forKey: transcriptPath)
        lock.unlock()
    }
}

/**
 Matching a session against the title of the window in front of you.

 VS Code has no way to say which chat is open, but its window title leads with the
 active tab's name and the Claude Code extension names its tabs after the session. So
 the title is the handle — the equivalent of Terminal's per-tab `tty`, and the only one
 on offer.

 It is not a clean handle. Observed, from a real title bar:

 ```
 Investigate VS Code even… — Projects
 ```

 VS Code **truncates** the tab name, around 25 characters, with a single-character
 ellipsis. A containment test against the session's full name therefore matches nothing,
 ever — which is exactly how this behaved for its first hour: the log showed VS Code
 focused and no slot matched, every time.

 So the comparison runs the other way. Take the leading segment, drop the ellipsis, and
 ask whether the session's name *starts with* what survived.

 Two sessions whose names agree for 25 characters are indistinguishable here. That is a
 real limit and an acceptable one: the alternative is no indicator at all, and the names
 are written to describe different work.
 */
public enum WindowTitle {
    /// VS Code's default `window.title` separator. A custom one is not chased: an
    /// unrecognised layout ends as no match, which is the behaviour from before any of
    /// this existed.
    private static let separator = " — "

    /// The character VS Code truncates with — one glyph, not three dots.
    private static let ellipsis: Character = "…"

    /// Does this window title name that session?
    public static func names(_ name: String, in windowTitle: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard var segment = windowTitle.components(separatedBy: separator).first?
            .trimmingCharacters(in: .whitespaces), !segment.isEmpty
        else { return false }

        // The unsaved-editor marker sits in front of the name. A webview panel is never
        // dirty, but the title format is not ours and this costs one comparison.
        if segment.hasPrefix("●") {
            segment = String(segment.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        guard segment.last == ellipsis else { return name == segment }
        let visible = String(segment.dropLast()).trimmingCharacters(in: .whitespaces)
        // A stub short enough to match half the board is not evidence of anything.
        guard visible.count >= 8 else { return false }
        return name.hasPrefix(visible)
    }
}

/**
 Where a session is running.

 The two surfaces behave differently in ways that matter when you are looking at the
 list: a Terminal session can be jumped to exactly, by tty, and a VS Code one can only
 be approximated by folder. Showing which is which sets the right expectation for what
 pressing its key will do.
 */
public enum SessionOrigin: String, Sendable, Equatable {
    case terminal = "Terminal"
    case vscode = "VS Code"
    case cli = "CLI"

    /// Decided from the entrypoint, then from which application actually owns the
    /// process — see `ProcessAncestry`. The tty is only a last resort, because it
    /// cannot distinguish a Terminal tab from VS Code's integrated terminal.
    public static func from(
        entrypoint: String?,
        tty: String?,
        host: ProcessAncestry.Host = .unknown
    ) -> SessionOrigin {
        if entrypoint == "claude-vscode" { return .vscode }
        // A tty is not enough. VS Code's integrated terminal allocates a real pty, so
        // a session there is indistinguishable from a Terminal tab by entrypoint and
        // tty alone — which is why this used to label it "Terminal" and then fail to
        // jump to it. The owning process is the only thing that actually knows.
        switch host {
        case .vscode: return .vscode
        case .terminal: return .terminal
        case .unknown: return tty != nil ? .terminal : .cli
        }
    }
}

/**
 Finding a session's transcript when the hook did not say where it is.

 `transcript_path` is normally in the hook payload, but not every event carries it and
 a session adopted from the process table has never seen a payload at all. The file is
 named after the session id, so it can be found without being told — and a row with no
 name is the difference between a board and a list of identical folder names.
 */
public enum SessionTranscript {
    /// `~/.claude/projects/<encoded-cwd>/<sessionID>.jsonl`.
    ///
    /// The directory is the working directory with separators replaced, which this does
    /// not attempt to reconstruct — encoding rules change and a wrong guess finds
    /// nothing. Searching the project directories for the file name is one shallow
    /// listing and cannot be wrong.
    public static func locate(
        sessionID: String,
        root: URL? = nil
    ) -> String? {
        // A discovered host has no real id yet; there is nothing to find.
        guard !sessionID.isEmpty, !Discovery.isPlaceholder(sessionID) else { return nil }

        let projects = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil
        ) else { return nil }

        let name = "\(sessionID).jsonl"
        for directory in directories {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}

/**
 The second line of a session row.

 Pure, and in the Kit rather than in the view, so the one rule that matters can be
 tested: a session with no name of its own must still be distinguishable from the five
 others in the same repo.
 */
public enum SessionDetail {
    /**
     - Parameter terminal: the tty, short form. Shown **only** when there is no name —
       a discovered session has emitted no hook, so its folder is all that is left and
       every session in that repo shares it. The tty tells them apart and names the tab
       you would switch to. Once a real name arrives it is noise.
     */
    public static func line(
        terminal: String?,
        project: String?,
        age: String?,
        isNamed: Bool
    ) -> String {
        [isNamed ? nil : terminal, project, age]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
