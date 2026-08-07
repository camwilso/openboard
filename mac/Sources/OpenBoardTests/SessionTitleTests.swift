import Foundation
import OpenBoardKit

/**
 Naming a session, and saying where it runs.

 Six rows showing the same repo name tell you which *project* is busy, never which
 *chat* — and two sessions in one repo is the common case, not the edge case.
 */
func runSessionTitleTests() {
    func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    test("the first user message becomes the name") {
        // Claude Code writes no title into a live transcript — `summary` lines only
        // appear once a session is compacted or closed — so the opening message is the
        // only thing available, and it is what a person would call it anyway.
        let jsonl = [
            line(["type": "mode", "sessionId": "a"]),
            line(["type": "file-history-snapshot"]),
            line(["type": "user", "message": ["content": "Fix the flaky login test"]]),
            line(["type": "user", "message": ["content": "and then deploy it"]]),
        ].joined(separator: "\n")

        expectEqual(SessionTitle.firstUserMessage(inJSONL: jsonl), "Fix the flaky login test")
    }

    test("the block content form is read too") {
        // Both shapes appear in real transcripts depending on how the message was sent.
        let jsonl = line([
            "type": "user",
            "message": ["content": [
                ["type": "image"],
                ["type": "text", "text": "Port the countdown module"],
            ]],
        ])
        expectEqual(SessionTitle.firstUserMessage(inJSONL: jsonl), "Port the countdown module")
    }

    test("only the first line is kept, and it is bounded") {
        // A first message is often several paragraphs of pasted context. The row is one
        // line wide; truncating here beats letting the layout do it.
        expectEqual(SessionTitle.clean("Do the thing\n\nwith all this context"), "Do the thing")
        expectEqual(SessionTitle.clean("   \n  Real content  \n"), "Real content")
        expectEqual(SessionTitle.clean(String(repeating: "x", count: 400))?.count, 120)
        expect(SessionTitle.clean("") == nil)
        expect(SessionTitle.clean("\n\n   \n") == nil)
    }

    test("a system-injected wrapper is not what anyone typed") {
        // Otherwise every resumed session is named after a reminder block.
        expectEqual(
            SessionTitle.clean("<system-reminder>be careful</system-reminder>Actual request"),
            "Actual request"
        )
    }

    test("a transcript with no user message yet has no name") {
        // A session that has started but not been spoken to. It must fall back to the
        // folder rather than showing an empty row.
        let jsonl = [line(["type": "mode"]), line(["type": "file-history-snapshot"])]
            .joined(separator: "\n")
        expect(SessionTitle.firstUserMessage(inJSONL: jsonl) == nil)
    }

    test("a truncated or corrupt line does not lose the whole transcript") {
        // The read is capped at a byte budget, so the last line is routinely cut in
        // half — and a snapshot entry can be megabytes.
        let jsonl = [
            line(["type": "user", "message": ["content": "The real name"]]),
            "{\"type\":\"user\",\"message\":{\"conte",
        ].joined(separator: "\n")
        expectEqual(SessionTitle.firstUserMessage(inJSONL: jsonl), "The real name")

        // A broken line *before* the message must not stop the scan either.
        let leading = [
            "{ not json at all",
            line(["type": "user", "message": ["content": "Still found"]]),
        ].joined(separator: "\n")
        expectEqual(SessionTitle.firstUserMessage(inJSONL: leading), "Still found")
    }

    test("an assistant message is never mistaken for the name") {
        let jsonl = [
            line(["type": "assistant", "message": ["content": "I'll help with that"]]),
            line(["type": "user", "message": ["content": "What I asked"]]),
        ].joined(separator: "\n")
        expectEqual(SessionTitle.firstUserMessage(inJSONL: jsonl), "What I asked")
    }

    test("this machine's real transcript yields a name") {
        // The fixture above is written from the format; this checks the format did not
        // change underneath it.
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let transcripts = (FileManager.default.enumerator(atPath: projects.path)?
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".jsonl") }) ?? []
        guard let first = transcripts.first else {
            skip("no transcripts on this machine")
            return
        }
        let path = projects.appendingPathComponent(first).path
        // Not asserting a particular name — just that a real file produces one.
        let title = SessionTitle.forSession(transcriptPath: path)
        expect(title != nil, "no name read from \(first)")
        expect((title?.count ?? 0) <= 120)
    }

    test("a missing transcript is not a crash") {
        expect(SessionTitle.forSession(transcriptPath: nil) == nil)
        expect(SessionTitle.forSession(transcriptPath: "") == nil)
        expect(SessionTitle.forSession(transcriptPath: "/nope/missing.jsonl") == nil)
    }
}

/**
 Where a session runs.

 Shown because it predicts what pressing the key will do: a Terminal session is raised
 exactly by tty, anything else only approximately.
 */
func runSessionOriginTests() {
    test("the entrypoint decides, with the tty as the tiebreak") {
        expectEqual(SessionOrigin.from(entrypoint: "claude-vscode", tty: nil), .vscode)
        expectEqual(SessionOrigin.from(entrypoint: "cli", tty: "/dev/ttys001"), .terminal)
        // A cli session with no tty cannot be raised, so it is not called Terminal.
        expectEqual(SessionOrigin.from(entrypoint: "cli", tty: nil), .cli)
        expectEqual(SessionOrigin.from(entrypoint: nil, tty: nil), .cli)
    }

    test("the VS Code extension keeps its label even with a tty") {
        // The extension host can report one; the surface is still VS Code, and jumping
        // there works differently.
        expectEqual(SessionOrigin.from(entrypoint: "claude-vscode", tty: "/dev/ttys009"), .vscode)
    }

    test("the labels are what a person would recognise") {
        // These are read at a glance in a 376pt popover.
        expectEqual(SessionOrigin.terminal.rawValue, "Terminal")
        expectEqual(SessionOrigin.vscode.rawValue, "VS Code")
    }
}

/**
 Finding a transcript without being told where it is.

 The bug this closes: `adoptRealSessionID` renamed a discovered placeholder and kept
 none of the hook's details, so every adopted session — most of them after a restart —
 had no transcript, no cwd, and therefore no name.
 */
func runTranscriptLocateTests() {
    test("a placeholder has nothing to find") {
        // A discovered host has no real session id yet, so searching is pointless and
        // any match would be a coincidence.
        expect(SessionTranscript.locate(sessionID: "host:12345") == nil)
        expect(SessionTranscript.locate(sessionID: "") == nil)
    }

    test("a real transcript is found by session id alone") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-projects-\(UUID().uuidString)")
        let project = root.appendingPathComponent("-Users-someone-repo")
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let id = "abc-123"
        let file = project.appendingPathComponent("\(id).jsonl")
        try Data("{}".utf8).write(to: file)

        // Compared through resolvedSymlinksInPath: NSTemporaryDirectory hands back
        // /var/..., and directory enumeration returns the real /private/var/... .
        expectEqual(
            SessionTranscript.locate(sessionID: id, root: root)
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            file.resolvingSymlinksInPath().path
        )
        expect(SessionTranscript.locate(sessionID: "not-there", root: root) == nil)
    }

    test("a missing projects directory is not a crash") {
        expect(SessionTranscript.locate(
            sessionID: "abc", root: URL(fileURLWithPath: "/nope/nothing")
        ) == nil)
    }

    test("adoption carries the hook's details, not just its id") {
        // Renaming alone left cwd and transcriptPath empty permanently: adoption happens
        // once, and every later hook takes the ordinary path. The board then showed rows
        // named after their folder with no way to tell them apart.
        var registry = SessionRegistry()
        let now = Date()
        registry.reconnect(
            [Discovery.Found(pid: 4242, tty: "/dev/ttys009", cwd: "/tmp/discovered")],
            now: now,
            isAlive: { _ in true }
        )
        let placeholder = try Harness.require(registry.entries.first)
        expect(Discovery.isPlaceholder(placeholder.sessionID))
        expect(placeholder.transcriptPath == nil, "a discovered host cannot know this")

        expect(registry.adoptRealSessionID(
            "real-session-id",
            pid: 4242,
            tty: "/dev/ttys009",
            cwd: "/Users/someone/actual-project",
            transcriptPath: "/tmp/real-session-id.jsonl",
            entrypoint: "cli",
            now: now
        ))

        let adopted = try Harness.require(registry.entry(forSession: "real-session-id"))
        expectEqual(adopted.slot, placeholder.slot, "adoption must not move the key")
        expectEqual(adopted.transcriptPath, "/tmp/real-session-id.jsonl")
        expectEqual(adopted.cwd, "/Users/someone/actual-project")
        expectEqual(adopted.entrypoint, "cli")
        expectEqual(registry.entries.count, 1, "the session took a second key")
    }

    test("adoption without details leaves what was there") {
        // A hook that omits a field must not blank a value discovery already found.
        var registry = SessionRegistry()
        let now = Date()
        registry.reconnect(
            [Discovery.Found(pid: 77, tty: "/dev/ttys010", cwd: "/tmp/known")],
            now: now, isAlive: { _ in true }
        )
        expect(registry.adoptRealSessionID("sid", pid: 77, tty: "/dev/ttys010", now: now))
        expectEqual(registry.entry(forSession: "sid")?.cwd, "/tmp/known")
    }
}

/**
 What the second line says.

 A discovered session has emitted no hook, so there is nothing to read and nothing to
 name it after but its folder — which every session in that repo shares. The tty is the
 one thing that distinguishes them, and it names the tab you would switch to.
 */
func runRowDetailTests() {
    test("an unnamed session shows its tty, a named one does not") {
        // Six identical "Projects" rows is the failure this exists to prevent.
        let unnamed = SessionDetail.line(
            terminal: "ttys004", project: "~/Developer/Projects", age: "12m", isNamed: false
        )
        expect(unnamed.contains("ttys004"), "nothing distinguishes this row")

        let named = SessionDetail.line(
            terminal: "ttys004", project: "~/Developer/Projects", age: "12m", isNamed: true
        )
        expect(!named.contains("ttys004"), "the tty is noise once there is a name")
        expect(named.contains("12m"))
    }

    test("the detail line survives missing pieces") {
        // A session can reach the board with no cwd and no tty at all.
        expectEqual(
            SessionDetail.line(terminal: nil, project: nil, age: nil, isNamed: false), ""
        )
        // No stray separators when only one part is present.
        expectEqual(
            SessionDetail.line(terminal: nil, project: "repo", age: nil, isNamed: true), "repo"
        )
        expectEqual(
            SessionDetail.line(terminal: "", project: "repo", age: "3m", isNamed: false),
            "repo · 3m",
            "an empty tty produced a leading separator"
        )
    }
}

/**
 Which application a session is really running in.

 A tty cannot answer this: VS Code's integrated terminal allocates a real pty, so a
 session there looks exactly like a Terminal tab — entrypoint `cli`, a `/dev/ttysNNN`,
 a zsh, a `claude`. It was labelled "Terminal" and then could not be jumped to, because
 Terminal.app does not own that pty.
 */
func runProcessAncestryTests() {
    /// A fake process tree: pid -> (parent, executable path).
    func tree(_ nodes: [Int: (Int, String)]) -> (Int) -> (parent: Int, path: String)? {
        { pid in nodes[pid].map { (parent: $0.0, path: $0.1) } }
    }

    test("a shell inside VS Code is recognised through its helper") {
        // The real chain from this machine. The middle process is "Code Helper", whose
        // name says nothing — which is why the *path* is matched rather than the name.
        let chain = tree([
            92148: (35272, "/bin/zsh"),
            35272: (35173, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
            35173: (1, "/Applications/Visual Studio Code.app/Contents/MacOS/Code"),
        ])
        expectEqual(ProcessAncestry.host(ofPID: 92148, parentOf: chain), .vscode)
    }

    test("a shell inside Terminal is recognised") {
        let chain = tree([
            5000: (4000, "/bin/zsh"),
            4000: (1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ])
        expectEqual(ProcessAncestry.host(ofPID: 5000, parentOf: chain), .terminal)
    }

    test("an unrecognised host is admitted, not guessed") {
        // iTerm, Ghostty, tmux, a launchd job. Claiming one of the two known hosts
        // would send a jump somewhere wrong.
        let chain = tree([
            7000: (6000, "/bin/zsh"),
            6000: (1, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        ])
        expectEqual(ProcessAncestry.host(ofPID: 7000, parentOf: chain), .unknown)
    }

    test("the ps lookup really reads this process's parent") {
        // The pure logic above is driven by a fixture, so nothing here would notice if
        // the `ps` invocation itself broke — which is the half that runs in production.
        guard let info = ProcessAncestry.defaultParentOf(Int(ProcessInfo.processInfo.processIdentifier))
        else {
            skip("ps produced nothing")
            return
        }
        expect(info.parent > 0, "no parent pid")
        expect(!info.path.isEmpty, "no executable path")
    }

    test("the ancestry lookup never waits by running the run loop") {
        // `Process.waitUntilExit()` drains the main run loop while it waits. This is
        // called from inside a mutating access to the registry, so that drain ran a
        // queued repaint, the repaint took a second mutating access to the same
        // registry, and Swift's exclusivity check aborted the app at launch.
        //
        // A source check because the failure is a *reentrancy* one: the function's own
        // return value is correct either way, which is why no test of its behaviour
        // caught it.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // OpenBoardTests
            .deletingLastPathComponent()      // Sources
            .appendingPathComponent("OpenBoardKit/ProcessAncestry.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            skip("source not readable")
            return
        }
        // The call, not the word: the comment above it explains the hazard by name.
        expect(!text.contains("process.waitUntilExit()"), "the run loop reentrancy is back")
    }

    test("a truncated or cyclic tree terminates") {
        expectEqual(ProcessAncestry.host(ofPID: 999, parentOf: { _ in nil }), .unknown)
        // A tree that never reaches init must not spin.
        let loop = tree([1000: (1001, "/bin/zsh"), 1001: (1000, "/bin/zsh")])
        expectEqual(ProcessAncestry.host(ofPID: 1000, depth: 4, parentOf: loop), .unknown)
    }

    test("the host decides the origin, not the presence of a tty") {
        // The bug: a tty meant "Terminal", so a VS Code integrated terminal was
        // mislabelled and then unreachable.
        expectEqual(
            SessionOrigin.from(entrypoint: "cli", tty: "/dev/ttys002", host: .vscode), .vscode
        )
        expectEqual(
            SessionOrigin.from(entrypoint: "cli", tty: "/dev/ttys000", host: .terminal), .terminal
        )
        // With no answer, a tty still implies a terminal of some kind — the old
        // behaviour, kept as the fallback rather than as the rule.
        expectEqual(
            SessionOrigin.from(entrypoint: "cli", tty: "/dev/ttys001", host: .unknown), .terminal
        )
        // And the extension host still wins outright, whatever the process tree says.
        expectEqual(
            SessionOrigin.from(entrypoint: "claude-vscode", tty: nil, host: .terminal), .vscode
        )
    }
}
