import Foundation

/**
 Which application a terminal session is actually running inside.

 A tty is not enough to tell. VS Code's integrated terminal allocates a real pty just
 as Terminal.app does, so a session there looks identical from the outside: entrypoint
 `cli`, a `/dev/ttysNNN`, a zsh, a `claude`. `SessionOrigin` said "Terminal" for both,
 and its own doc comment admitted the entrypoint could not distinguish them — then
 labelled it Terminal anyway.

 That mislabelling had a visible cost. Pressing the key tried to select a Terminal tab
 by tty, found none (Terminal does not own that pty), and fell through to opening the
 session's *folder* in VS Code — so "jump to this chat" opened an editor on a
 directory.

 The parent chain answers it exactly: walk up from the shell and see whose process it
 is. `ps` is not free, so callers should ask once and store the answer rather than
 asking per repaint.
 */
public enum ProcessAncestry {
    public enum Host: String, Sendable, Equatable {
        case terminal
        case vscode
        case unknown
    }

    /// Substrings that identify a host in a process path. Matched on the path rather
    /// than the process name because both apps spawn helpers whose names say nothing —
    /// VS Code's is `Code Helper`, which could be anything.
    private static let signatures: [(needle: String, host: Host)] = [
        ("Visual Studio Code.app", .vscode),
        ("Code Helper", .vscode),
        ("/Applications/Utilities/Terminal.app", .terminal),
        ("Terminal.app", .terminal),
    ]

    /// Walk up from a process until one of the known hosts is recognised.
    ///
    /// - Parameter depth: a bound, not a guess about the tree. A shell inside a helper
    ///   inside an app is three levels; the limit only stops a pathological loop if the
    ///   process table returns something cyclic.
    public static func host(
        ofPID pid: Int,
        depth: Int = 8,
        parentOf: (Int) -> (parent: Int, path: String)? = defaultParentOf
    ) -> Host {
        var current = pid
        for _ in 0..<depth {
            guard let info = parentOf(current) else { return .unknown }
            for signature in signatures where info.path.contains(signature.needle) {
                return signature.host
            }
            guard info.parent > 1 else { return .unknown }
            current = info.parent
        }
        return .unknown
    }

    /**
     `ps` for one process: its parent and its executable path.

     ## Why this does not call `waitUntilExit`

     `Process.waitUntilExit()` on the main thread **runs the main run loop** while it
     waits. This is called from inside `SessionRegistry.reconnect`, which is a mutating
     method on a stored property — so the run loop drained a queued `paint()`, `paint()`
     took a second mutating access to the same registry, and Swift's exclusivity
     checking aborted the process. The app died at launch, intermittently, depending on
     whether a repaint happened to be queued.

     A semaphore signalled from the termination handler waits just as thoroughly and
     runs nothing while it does. The handler fires on a background queue, so blocking
     the main thread here cannot deadlock against it.

     The wait is nearly instant regardless: `readDataToEndOfFile` above has already
     blocked until `ps` closed its output. The timeout only exists so that a `ps` that
     somehow never exits costs a stale reading instead of a frozen board.
     */
    public static func defaultParentOf(_ pid: Int) -> (parent: Int, path: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=,comm=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        _ = exited.wait(timeout: .now() + 2)

        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }

        // "  35272 /Applications/Visual Studio Code.app/…/Code Helper"
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let parent = Int(parts.first ?? "") else { return nil }
        let path = parts.count > 1 ? String(parts[1]) : ""
        return (parent, path)
    }
}
