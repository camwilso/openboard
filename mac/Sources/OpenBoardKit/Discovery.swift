import Foundation

/**
 Find Claude Code sessions that are already running.

 The registry is rebuilt from hooks, and a hook only fires when a session *does*
 something. So after the app starts, a session sitting idle in another tab is invisible
 until you go and type in it — which is exactly backwards for a board whose job is to
 tell you what is happening without being asked.

 This walks the process table instead, so the board is populated the moment the app
 starts.

 ## Two signatures, and nothing else

 A terminal session is the bare `claude` command on a real tty: unambiguously `cli` and
 unambiguously interactive.

 An extension-hosted session has no tty at all, and for a long time that made it
 undiscoverable. The reasoning was that a tty-less `claude` might be the genuine VS Code
 extension — eligible — or an embedded SDK client, which is not: ten of those were once
 observed under an unrelated extension, and they would take all six keys before a human
 session appeared. `CLAUDE_AGENT_SDK_CLIENT_APP` tells them apart and is readable only by
 the process itself, so the hook path forwards it and this path cannot.

 But the *command line* says as much. A real VS Code chat runs Anthropic's binary out of
 the installed extension, driven over a stream-json pipe:

 ```
 ~/.vscode/extensions/anthropic.claude-code-<version>/resources/native-binary/claude \
   --output-format stream-json --verbose --input-format stream-json …
 ```

 An unrelated extension spawning `claude` runs its own copy or the one on `PATH`, not
 Anthropic's out of Anthropic's directory — so the path is the discriminator that was
 said not to exist. The flags are checked too, because the same binary in the same
 directory also runs as `--claude-in-chrome-mcp`, which is a server rather than a chat.

 Both halves must match, and either one changing means a session is not discovered —
 which is where this started, and is still fail-closed. It appears on its first hook.
 */
public enum Discovery {
    public struct Found: Equatable, Sendable {
        public let pid: Int
        /// Nil for an extension-hosted session. It has no controlling terminal, which
        /// is exactly what kept it off the board until now.
        public let tty: String?
        public let cwd: String?
        /// What a hook would have reported. Discovery has to supply it because a
        /// discovered session has not sent one — and without it an extension-hosted
        /// chat would be labelled `cli`, land on the Terminal jump, and go nowhere.
        public let entrypoint: String

        public init(pid: Int, tty: String?, cwd: String?, entrypoint: String = "cli") {
            self.pid = pid
            self.tty = tty
            self.cwd = cwd
            self.entrypoint = entrypoint
        }

        /// A stand-in until a real hook supplies the session id. Prefixed so it is
        /// never mistaken for one, and so the takeover below can recognise it.
        public var placeholderSessionID: String { "host:\(pid)" }
    }

    public static let placeholderPrefix = "host:"

    public static func isPlaceholder(_ sessionID: String) -> Bool {
        sessionID.hasPrefix(placeholderPrefix)
    }

    /// Live interactive sessions, newest process last.
    public static func runningSessions() -> [Found] {
        parse(ps: shell("/bin/ps", ["-axo", "pid=,tty=,command="]))
            .map { Found(pid: $0.pid, tty: $0.tty, cwd: workingDirectory(of: $0.pid), entrypoint: $0.entrypoint) }
    }

    /// Where the extension keeps its binary, relative to whichever extensions directory
    /// is in use — `.vscode`, `.vscode-insiders`, or a portable install. Matching from
    /// `/extensions/` rather than from home covers all of them without listing any.
    private static let extensionSignature = "/extensions/anthropic.claude-code"

    /// The flags the extension drives a chat with. The same binary in the same
    /// directory also runs as an MCP server, and that is not a session.
    private static let chatFlags = ["--output-format", "stream-json", "--input-format"]

    /**
     `ps` output to candidates. Pure, so the two signatures can be tested against real
     command lines rather than against whatever happens to be running on this Mac.

     The cwd is not resolved here — that is one `lsof` per process, and a parser that
     shells out cannot be tested at all.
     */
    public static func parse(ps listing: String) -> [(pid: Int, tty: String?, entrypoint: String)] {
        var found: [(pid: Int, tty: String?, entrypoint: String)] = []

        for line in listing.split(separator: "\n") {
            let parts = String(line).split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int(parts[0]) else { continue }
            let tty = String(parts[1])
            let command = parts.dropFirst(2).joined(separator: " ")
            let executable = String(parts[2])

            if tty != "??", !tty.isEmpty {
                // The bare CLI. Anything with flags on a tty is being driven by
                // something else — a script, a wrapper, another tool's subprocess.
                guard command == "claude" || command.hasSuffix("/claude") else { continue }
                found.append((pid, "/dev/\(tty)", "cli"))
                continue
            }

            // No tty: eligible only on the extension's exact signature. See the type
            // comment — the path is what separates a real chat from an SDK client.
            guard executable.contains(extensionSignature), executable.hasSuffix("/claude"),
                  chatFlags.allSatisfy({ command.contains($0) })
            else { continue }
            found.append((pid, nil, "claude-vscode"))
        }
        return found
    }

    /// A process's cwd, so the board can name the project.
    private static func workingDirectory(of pid: Int) -> String? {
        let output = shell("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Read before waiting: a large listing can fill the pipe buffer and deadlock.
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

extension SessionRegistry {
    /**
     Seed the board from processes that are already running.

     Each gets a placeholder session id, replaced by the real one as soon as that
     session emits a hook — see `adoptRealSessionID`.

     Idempotent: a host already on the board keeps its slot rather than taking another.
     */
    @discardableResult
    public mutating func reconnect(
        _ sessions: [Discovery.Found],
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> Int {
        // Entries restored from disk, or claimed before this field existed, arrive with
        // no host — and a session that emits no hooks is never enriched, so nothing
        // else would ever fill it in. That was exactly the unnamed VS Code session:
        // labelled "Terminal" and unreachable, permanently.
        for index in entries.indices where entries[index].host == .unknown {
            guard let pid = entries[index].pid, isAlive(pid) else { continue }
            entries[index].host = ProcessAncestry.host(ofPID: pid)
        }

        var added = 0
        for session in sessions {
            // Guarded on the *session's* tty, not just the entry's: two extension-hosted
            // chats both have none, and `nil == nil` would make the second one look like
            // a duplicate of the first and cost it its key.
            let known = entries.contains {
                $0.pid == session.pid || (session.tty != nil && $0.tty == session.tty)
            }
            guard !known else { continue }

            var result = claim(
                sessionID: session.placeholderSessionID,
                cwd: session.cwd,
                pid: session.pid,
                tty: session.tty,
                entrypoint: session.entrypoint,
                state: .idle,
                now: now,
                isAlive: isAlive
            )
            if let entry = result.entry {
                added += 1
                // Asked once, here, rather than per repaint: `ps` is not free and the
                // owning app cannot change while the process lives.
                if let index = entries.firstIndex(where: { $0.sessionID == entry.sessionID }) {
                    entries[index].host = ProcessAncestry.host(ofPID: session.pid)
                }
            }
        }
        return added
    }

    /**
     Hand a placeholder's slot to the real session.

     Called when a hook arrives for a session the registry has not seen. If a
     discovered host on the same pid or tty is holding a slot, that slot is what the
     session should get — otherwise it would take a *second* key and the board would
     show one session twice.

     Returns true if a takeover happened.
     */
    @discardableResult
    public mutating func adoptRealSessionID(
        _ sessionID: String,
        pid: Int?,
        tty: String?,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        entrypoint: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard entry(forSession: sessionID) == nil else { return false }
        guard let index = entries.firstIndex(where: { candidate in
            Discovery.isPlaceholder(candidate.sessionID)
                && ((pid != nil && candidate.pid == pid)
                    || (tty != nil && candidate.tty == tty))
        }) else { return false }

        entries[index].sessionID = sessionID
        entries[index].updatedAt = now

        /*
         Take the hook's details too, not just its id.

         A discovered host is found by walking the process table, which can see a pid, a
         tty and a working directory and nothing else — no session id, no transcript.
         Renaming alone left those fields empty *permanently*, because adoption happens
         once and every later hook takes the ordinary path. The visible result was a
         board where every adopted row was named after its folder and none could be told
         apart, which is most rows after an app restart.
         */
        if let cwd { entries[index].cwd = cwd }
        if let transcriptPath { entries[index].transcriptPath = transcriptPath }
        if let entrypoint { entries[index].entrypoint = entrypoint }
        return true
    }
}
