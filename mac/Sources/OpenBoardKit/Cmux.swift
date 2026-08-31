import Foundation

/**
 cmux, as much of it as a status board needs.

 cmux is a terminal that hosts agents in *surfaces* — a tab or a split, each with its
 own pty — grouped into panes, workspaces and windows. From the outside a Claude Code
 session in one looks exactly like a session in Terminal.app: entrypoint `cli`, a real
 `/dev/ttysNNN`, a `zsh`, a `claude`. So the board found them, labelled them "Terminal",
 and then could not jump to any of them: `Focus` selects a Terminal tab *by tty*, and
 Terminal does not own that pty. This is the same mislabelling `ProcessAncestry` was
 written for, one host further on.

 ## Why not AppleScript

 cmux has no AppleScript dictionary, and its surfaces do not expose a tty even
 internally (`cmux debug-terminals` prints `tty=nil` for every one) — so neither half of
 the Terminal/iTerm2 strategy has anything to bind to.

 It ships a CLI over a Unix socket instead, and that turns out to be *better* than the
 Apple-event path in three ways worth naming, because they are why this file looks
 nothing like `Focus.focusTerminal`:

 1. **No permission.** Automation is per-target-app and has to be granted, refused
    silently as `-1743` until it is, and re-granted after the target restarts. The cmux
    socket needs none of that: a plain subprocess, no TCC record, nothing for the user
    to find in System Settings.
 2. **Stable identity.** A surface has a UUID that lives as long as the surface. Refs
    like `surface:12` are positional and renumber, so only the UUID is stored or
    compared.
 3. **One call answers everything.** `cmux top --processes` prints the whole tree —
    every window, workspace, pane, surface and process — so one spawn yields both
    "which surface is this pid in" and "what is that surface called", which are the two
    questions the board asks per cycle.

 Everything here degrades to nothing rather than to a wrong answer: cmux not installed,
 not running, a socket password set, an output format that changed — all of them mean
 no cmux surfaces are known, which costs the *cmux* rows their jump and leaves the rest
 of the board untouched.
 */
public enum Cmux {
    public static let bundleID = "com.cmuxterm.app"

    /// One surface, as the board needs to see it.
    public struct Surface: Equatable, Sendable {
        /// Stable for the life of the surface. The only value stored or compared.
        public let id: String
        /// `surface:12`. Positional — printed in logs because it is what the user sees
        /// in cmux's own output, never persisted.
        public let ref: String
        /// The tab title. Claude Code keeps this describing what the session is doing
        /// right now, exactly as it does in Terminal — so it feeds the same
        /// `TerminalTitle.clean` the Terminal path uses, spinner glyph and all.
        public let title: String?

        public init(id: String, ref: String, title: String?) {
            self.id = id
            self.ref = ref
            self.title = title
        }
    }

    // MARK: - locating the CLI

    /// Where the CLI lives inside the app bundle.
    private static let cliInBundle = "Contents/Resources/bin/cmux"

    /**
     The `cmux` binary, or nil if there is not one to run.

     - Parameter bundlePath: the *running* app's bundle, which the caller reads from
       `NSRunningApplication`. Preferred over the default location because a user who
       runs cmux from `~/Applications`, a second copy, or a build directory still gets a
       working jump — and because the CLI in the bundle you are talking to is the one
       that speaks its socket's protocol version.
     - Parameter env: `CMUX_BUNDLED_CLI_PATH` is exported into every cmux terminal, so a
       *development* build of OpenBoard launched from inside cmux finds the CLI with no
       bundle lookup at all. A GUI launch inherits no environment, which is why this is
       a fallback rather than the first answer.
     */
    public static func cliPath(
        inBundle bundlePath: String? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let bundlePath, !bundlePath.isEmpty {
            candidates.append(
                URL(fileURLWithPath: bundlePath).appendingPathComponent(cliInBundle).path
            )
        }
        if let exported = env["CMUX_BUNDLED_CLI_PATH"], !exported.isEmpty {
            candidates.append(exported)
        }
        candidates.append("/Applications/cmux.app/\(cliInBundle)")
        return candidates.first(where: exists)
    }

    // MARK: - reading the tree

    /**
     Every pid cmux is running, and which surface it is in.

     Keyed by pid because that is the handle the registry already holds for every
     session — no new field, no hook change, and it works identically for a session
     discovered from the process table and one that has sent hooks.

     ## The walk

     A process line's parent is a surface, another pid, or neither:

     ```
     …	surface	surface:12 5DBF…	pane:1 1D62…	◑ Build the thing
     …	process	87144	surface:12 5DBF…	2.1.251
     …	process	89248	87144	zsh
     ```

     cmux launching the agent itself puts `claude` directly under the surface, but a
     `claude` *typed* into a cmux terminal sits under the shell, which sits under the
     surface. Both must resolve, so parents are followed transitively rather than read
     one level deep — the one-level version worked on this machine and would have
     missed every hand-started session.

     The same pid is also printed a second time under a `tag` grouping row, whose ref is
     neither a surface nor a pid. Those are ignored rather than special-cased: a parent
     that is not an integer and not a `surface:` ref simply ends the walk.
     */
    public static func parseTop(_ tsv: String) -> [Int: Surface] {
        var surfaces: [String: Surface] = [:]   // ref -> surface
        var parentOfPID: [Int: String] = [:]    // pid -> parent token (surface ref or pid)

        for line in tsv.split(separator: "\n") {
            // cpu, memory, count, kind, ref, parent, label
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 6 else { continue }
            let kind = fields[3]
            let (ref, id) = handle(fields[4])
            let (parentRef, _) = handle(fields[5])

            switch kind {
            case "surface":
                guard let id else { continue }
                let label = fields.count > 6 ? fields[6] : ""
                surfaces[ref] = Surface(
                    id: id, ref: ref, title: label.isEmpty ? nil : label
                )
            case "process":
                guard let pid = Int(ref) else { continue }
                /*
                 First parent wins, unless a later one is a surface.

                 A pid appears under its `tag` row *before* its surface row, and the tag
                 parent leads nowhere. Preferring the surface means the order the tree
                 happens to be printed in cannot decide whether a session is reachable.
                */
                if parentOfPID[pid] == nil || parentRef.hasPrefix("surface:") {
                    parentOfPID[pid] = parentRef
                }
            default:
                continue
            }
        }

        var result: [Int: Surface] = [:]
        for pid in parentOfPID.keys {
            // A bound, not a guess about the tree: surface → shell → claude → hook is
            // four, and the limit only stops a cycle if the output ever contains one.
            var current = pid
            for _ in 0..<8 {
                guard let parent = parentOfPID[current] else { break }
                if let surface = surfaces[parent] {
                    result[pid] = surface
                    break
                }
                guard let next = Int(parent) else { break }
                current = next
            }
        }
        return result
    }

    /**
     The surface you are looking at right now, from `cmux identify --id-format uuids`.

     `caller` is null when the CLI is run from outside cmux — which is always, here —
     and `focused` is what the board wants anyway: not "who asked" but "what is in
     front of you".

     A focused *browser* surface is returned like any other. It cannot match a session's
     id, so it reads as "you are looking at none of these", which is exactly right.
     */
    public static func parseFocusedSurfaceID(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let focused = object["focused"] as? [String: Any],
              let id = focused["surface_id"] as? String,
              !id.isEmpty
        else { return nil }
        return id
    }

    /// Split `surface:12 5DBF67AD-…` into its ref and its UUID. With
    /// `--id-format both` a handle is two tokens in one field; the UUID is absent for
    /// rows that have none (a pid is its own handle), so it is optional.
    private static func handle(_ field: String) -> (ref: String, id: String?) {
        let tokens = field.split(separator: " ", omittingEmptySubsequences: true)
        guard let ref = tokens.first else { return ("", nil) }
        let id = tokens.count > 1 ? String(tokens[tokens.count - 1]) : nil
        return (String(ref), id)
    }

    // MARK: - talking to it

    /// Every surface cmux is running, by pid. Empty when cmux cannot be reached, which
    /// is indistinguishable — deliberately — from cmux running nothing.
    public static func surfaces(cli: String) -> [Int: Surface] {
        parseTop(output(cli, ["top", "--all", "--processes", "--format", "tsv", "--id-format", "both"]))
    }

    /// The focused surface's id, or nil if cmux could not be asked.
    public static func focusedSurfaceID(cli: String) -> String? {
        parseFocusedSurfaceID(output(cli, ["identify", "--id-format", "uuids"]))
    }

    /**
     Select a surface and the workspace holding it.

     `focus-panel` is cmux's own alias for a surface focus, and it does the whole walk:
     the surface's workspace is selected and the surface focused within it, in one call.
     It answers `OK surface:12 workspace:1`.

     Focusing *inside* cmux is all this does — bringing cmux itself forward is the
     caller's job, and is one `NSRunningApplication.activate()` rather than anything
     asked of cmux, so a jump into cmux needs no Automation grant at any point.
     */
    public static func focus(surfaceID: String, cli: String) -> Bool {
        output(cli, ["focus-panel", "--panel", surfaceID]).hasPrefix("OK")
    }

    /**
     Run the CLI and read its stdout. Empty on any failure, of which "cmux is not
     running" is the ordinary case rather than an error worth surfacing.

     ## Why not `waitUntilExit`

     `Process.waitUntilExit()` runs the main run loop while it waits, which re-enters
     queued work — the reentrancy that once killed this app at launch, documented at
     length in `ProcessAncestry.defaultParentOf`. A semaphore signalled from the
     termination handler waits just as thoroughly and runs nothing. The handler fires on
     a background queue, so blocking here cannot deadlock against it.

     The timeout is not tuning: the socket is local and answers in milliseconds, so it
     only exists so that a wedged CLI costs a stale reading rather than a frozen board.
     */
    private static func output(_ cli: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return "" }
        // Read before waiting: `top` prints more than a pipe buffer holds on a busy
        // machine, and waiting first would deadlock against a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        _ = exited.wait(timeout: .now() + 3)
        guard process.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
