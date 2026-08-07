import Foundation

/**
 What to call a session.

 Six keys and six rows of "openboard" is not a board — if every row shows the working
 directory, the popover cannot tell you which chat is which, only which *project* is
 which. Two sessions in the same repo are indistinguishable, and that is the common
 case.

 The name used is the **first thing you asked for**. Claude Code writes no title into a
 live transcript — `summary` lines only appear once a session is compacted or closed —
 but the opening user message is what a person would call the session anyway, and it
 never changes, so it can be read once and kept.
 */
public enum SessionTitle {
    /// Read once per transcript. The first user message is immutable, so a cache never
    /// goes stale — and the popover asks for this on every repaint.
    /// `nonisolated(unsafe)` with an explicit lock rather than an actor: this is read
    /// during a SwiftUI body evaluation, which cannot await, and the cost of the wrong
    /// answer is a stale row rather than corruption. The lock makes it correct anyway.
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    /// Stop after this much of the file.
    ///
    /// A transcript grows without bound, and `file-history-snapshot` entries near the
    /// top can be enormous. The opening message is within the first few entries or it
    /// is not worth finding — this runs on the main thread when the popover opens, and
    /// a 40MB read there is a visible hang.
    private static let byteBudget = 512 * 1024

    public static func forSession(transcriptPath: String?) -> String? {
        guard let transcriptPath, !transcriptPath.isEmpty else { return nil }

        lock.lock()
        if let hit = cache[transcriptPath] { lock.unlock(); return hit }
        lock.unlock()

        guard let title = readFirstUserMessage(at: transcriptPath) else { return nil }
        lock.lock()
        cache[transcriptPath] = title
        lock.unlock()
        return title
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

    private static func readFirstUserMessage(at path: String) -> String? {
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
        return firstUserMessage(inJSONL: text)
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
