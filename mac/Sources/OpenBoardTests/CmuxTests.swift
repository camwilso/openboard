import Foundation
import OpenBoardKit

/**
 cmux support: the parsers, the host detection, and the wiring in the app target.

 The fixture below is real `cmux top --all --processes --format tsv --id-format both`
 output, captured from a running cmux with two Claude Code sessions in it, not a
 hand-written approximation. That matters more here than usual: everything this file
 checks exists because cmux's output shape is the whole contract — there is no typed API
 to hold us to it — so a fixture that has been tidied up would test the tidying.

 Two rows in it are the reason the parser is not a one-liner:

 - pid **87144** is printed **twice**, once under a `tag` grouping row (which leads
   nowhere) and once under its surface. The surface must win regardless of print order.
 - pid **93742** sits under a `zsh` which sits under `surface:1` — a `claude` *typed*
   into a cmux terminal rather than launched by cmux. Reading one level up would miss
   every hand-started session, which is most of them.
 */
func runCmuxTests() {
    // Tab-separated, assembled from escapes so the tabs survive every editor and
    // every diff view that would otherwise turn them into spaces.
    let top = [
        "33.1\t1662247288\t11\ttotal\ttotal\t\t",
        "33.1\t1662247288\t11\twindow\twindow:1 237BD31D-4B4C-43E8-8C69-93B01D55A5E4\ttotal\t",
        "13.8\t558892952\t1\tprocess\t80792\twindow:1 237BD31D-4B4C-43E8-8C69-93B01D55A5E4\tcmux",
        "15.8\t753259680\t9\tworkspace\tworkspace:1 A5521A79-947D-4986-B4DC-DA379F172DCC\twindow:1 237BD31D-4B4C-43E8-8C69-93B01D55A5E4\t◑ Open board cmux support",
        "11.1\t442699664\t8\ttag\tworkspace:A5521A79-947D-4986-B4DC-DA379F172DCC:tag:claude_code A5521A79-947D-4986-B4DC-DA379F172DCC:tag:claude_code\tworkspace:1 A5521A79-947D-4986-B4DC-DA379F172DCC\tRunning",
        // The tag copy of 87144, printed *before* its surface copy.
        "11.1\t385009008\t1\tprocess\t87144\tworkspace:A5521A79-947D-4986-B4DC-DA379F172DCC:tag:claude_code A5521A79-947D-4986-B4DC-DA379F172DCC:tag:claude_code\t2.1.251",
        "0.0\t1638640\t1\tprocess\t91787\t87144\tcaffeinate",
        "15.8\t753259680\t9\tpane\tpane:1 1D625A49-ACF4-40DD-B06B-CAC166C93015\tworkspace:1 A5521A79-947D-4986-B4DC-DA379F172DCC\t",
        "0.4\t311919888\t3\tsurface\tsurface:1 6D5B3593-9846-4557-8796-8E29B492B9CA\tpane:1 1D625A49-ACF4-40DD-B06B-CAC166C93015\t✳ cmux welcome",
        // A shell under the surface, and a claude under the shell.
        "0.0\t1655144\t2\tprocess\t93736\tsurface:1 6D5B3593-9846-4557-8796-8E29B492B9CA\tzsh",
        "0.3\t301234567\t1\tprocess\t93742\t93736\t2.1.251",
        "11.1\t385009008\t1\tsurface\tsurface:12 5DBF67AD-5331-43A9-A6BA-177C203D9B79\tpane:1 1D625A49-ACF4-40DD-B06B-CAC166C93015\t◑ Open board cmux support",
        "11.1\t385009008\t1\tprocess\t87144\tsurface:12 5DBF67AD-5331-43A9-A6BA-177C203D9B79\t2.1.251",
        // A browser split: a surface with no process in it at all.
        "0.1\t120000000\t0\tsurface\tsurface:7 9F97C096-C875-4E80-B453-53FF5BAA960C\tpane:6 7F5D8919-FEFE-4E15-8D90-2D3DB19F75C7\t",
    ].joined(separator: "\n")

    let surfaces = Cmux.parseTop(top)

    test("a session launched by cmux resolves to its surface") {
        expectEqual(surfaces[87144]?.id, "5DBF67AD-5331-43A9-A6BA-177C203D9B79")
        expectEqual(surfaces[87144]?.ref, "surface:12")
    }

    test("a surface carries the workspace and window a focus request has to name") {
        // Without these, `focus-panel` resolves the surface inside the first workspace
        // only and answers `not_found` for every other one — so exactly one session on
        // the board could be jumped to, always the same one, and the rest reported
        // notFound.
        expectEqual(surfaces[87144]?.workspace, "A5521A79-947D-4986-B4DC-DA379F172DCC")
        expectEqual(surfaces[87144]?.window, "237BD31D-4B4C-43E8-8C69-93B01D55A5E4")
    }

    test("the workspace is resolved through nested panes, not one level up") {
        // A split's pane hangs off another pane. `surface:20` is two panes deep.
        let nested = Cmux.parseTop([
            "0\t0\t1\twindow\twindow:1 WIN-1\ttotal\t",
            "0\t0\t1\tworkspace\tworkspace:4 WS-4\twindow:1 WIN-1\tProjects",
            "0\t0\t1\tpane\tpane:9 PANE-9\tworkspace:4 WS-4\t",
            "0\t0\t1\tpane\tpane:11 PANE-11\tpane:9 PANE-9\t",
            "0\t0\t1\tsurface\tsurface:20 SURF-20\tpane:11 PANE-11\ta split",
            "0\t0\t1\tprocess\t700\tsurface:20 SURF-20\tclaude",
        ].joined(separator: "\n"))
        expectEqual(nested[700]?.workspace, "WS-4")
        expectEqual(nested[700]?.window, "WIN-1")
    }

    test("a surface whose workspace cannot be resolved still names its row") {
        // pane:6 has no row in the fixture. The surface is still listed — a row with a
        // name and no certain jump beats no row.
        let orphan = Cmux.parseTop([
            "0\t0\t1\tsurface\tsurface:7 SURF-7\tpane:6 PANE-6\tan orphan",
            "0\t0\t1\tprocess\t800\tsurface:7 SURF-7\tclaude",
        ].joined(separator: "\n"))
        expectEqual(orphan[800]?.title, "an orphan")
        expectEqual(orphan[800]?.workspace, nil)
        expectEqual(orphan[800]?.window, nil)
    }

    test("focus names the workspace and window, so any session is reachable") {
        let surface = Cmux.Surface(
            id: "SURF", ref: "surface:3", title: nil, workspace: "WS", window: "WIN"
        )
        expectEqual(
            Cmux.focusArguments(surface),
            ["focus-panel", "--panel", "SURF", "--workspace", "WS", "--window", "WIN"]
        )
    }

    test("a surface with no known workspace is still attempted bare") {
        // It works whenever the session is in the current workspace, which beats
        // refusing to try.
        let surface = Cmux.Surface(id: "SURF", ref: "surface:3", title: nil)
        expectEqual(Cmux.focusArguments(surface), ["focus-panel", "--panel", "SURF"])
    }

    test("the surface row wins over the tag row that printed first") {
        // The tag parent resolves to nothing. If the first parent seen were kept
        // unconditionally, this session would have no surface and no jump — and which
        // sessions broke would depend on the order cmux happened to print the tree in.
        expect(surfaces[87144] != nil, "the tag row must not shadow the surface row")
    }

    test("a claude started by hand resolves through the shell above it") {
        expectEqual(surfaces[93742]?.ref, "surface:1")
        expectEqual(surfaces[93742]?.id, "6D5B3593-9846-4557-8796-8E29B492B9CA")
    }

    test("a process under a window rather than a surface is not placed") {
        // cmux's own process. It is in the tree and is in no surface; claiming one for
        // it would point a jump at an unrelated tab.
        expectEqual(surfaces[80792]?.ref, nil)
    }

    test("titles arrive with Claude Code's spinner glyph, for TerminalTitle to strip") {
        // Deliberately not cleaned here: the Terminal path already owns that rule, and
        // two implementations of it would drift. This only checks the raw title is
        // carried through intact so the shared cleaner can do its job.
        expectEqual(surfaces[87144]?.title, "◑ Open board cmux support")
        expectEqual(
            surfaces[87144]?.title.flatMap(TerminalTitle.clean), "Open board cmux support"
        )
    }

    test("a surface with no title reports none rather than an empty name") {
        let empty = Cmux.parseTop(
            "0.1\t1\t0\tsurface\tsurface:7 9F97C096-C875-4E80-B453-53FF5BAA960C\tpane:6\t\n"
                + "0.1\t1\t0\tprocess\t42\tsurface:7 9F97C096-C875-4E80-B453-53FF5BAA960C\tclaude"
        )
        expectEqual(empty[42]?.id, "9F97C096-C875-4E80-B453-53FF5BAA960C")
        expectEqual(empty[42]?.title, nil)
    }

    test("output that is not the expected shape yields nothing, not a wrong answer") {
        expect(Cmux.parseTop("").isEmpty)
        expect(Cmux.parseTop("cmux: command not found").isEmpty)
        // The shape it would have without --id-format both: refs, no UUIDs. A surface
        // with no stable id cannot be focused, so it must not be offered.
        expect(Cmux.parseTop("0.1\t1\t1\tsurface\tsurface:1\tpane:1\ta tab").isEmpty)
    }

    test("a cycle in the tree cannot hang the walk") {
        let looped = Cmux.parseTop([
            "0\t0\t1\tprocess\t10\t11\ta",
            "0\t0\t1\tprocess\t11\t10\tb",
        ].joined(separator: "\n"))
        expect(looped.isEmpty)
    }

    // MARK: - identify

    let identify = """
    {
      "app_bundle_path" : "/Applications/cmux.app",
      "bundle_identifier" : "com.cmuxterm.app",
      "caller" : null,
      "focused" : {
        "is_browser_surface" : false,
        "pane_id" : "1D625A49-ACF4-40DD-B06B-CAC166C93015",
        "surface_id" : "5DBF67AD-5331-43A9-A6BA-177C203D9B79",
        "surface_type" : "terminal",
        "window_id" : "237BD31D-4B4C-43E8-8C69-93B01D55A5E4"
      },
      "socket_path" : "/Users/x/.local/state/cmux/cmux.sock"
    }
    """

    test("the focused surface is read from identify, ignoring the null caller") {
        // `caller` is null whenever the CLI is run from outside cmux — which is always,
        // for this app. `focused` is the question the board is asking anyway.
        expectEqual(
            Cmux.parseFocusedSurfaceID(identify), "5DBF67AD-5331-43A9-A6BA-177C203D9B79"
        )
    }

    test("nothing focused, or nothing readable, is nil rather than a guess") {
        expectEqual(Cmux.parseFocusedSurfaceID(""), nil)
        expectEqual(Cmux.parseFocusedSurfaceID("not json"), nil)
        expectEqual(Cmux.parseFocusedSurfaceID("{\"caller\":null}"), nil)
        expectEqual(Cmux.parseFocusedSurfaceID("{\"focused\":{\"surface_id\":\"\"}}"), nil)
    }

    // MARK: - locating the CLI

    test("the running app's own bundle is preferred over the default location") {
        // The CLI that ships with the copy of cmux you are talking to is the one that
        // speaks its socket's version — and a user running cmux from ~/Applications or
        // a build directory has no /Applications copy at all.
        let path = Cmux.cliPath(
            inBundle: "/Users/x/Applications/cmux.app",
            env: ["CMUX_BUNDLED_CLI_PATH": "/exported/cmux"],
            exists: { _ in true }
        )
        expectEqual(path, "/Users/x/Applications/cmux.app/Contents/Resources/bin/cmux")
    }

    test("the exported path is used when there is no running bundle to read") {
        let path = Cmux.cliPath(
            inBundle: nil,
            env: ["CMUX_BUNDLED_CLI_PATH": "/exported/cmux"],
            exists: { _ in true }
        )
        expectEqual(path, "/exported/cmux")
    }

    test("the default install is the last resort") {
        let path = Cmux.cliPath(inBundle: nil, env: [:], exists: { _ in true })
        expectEqual(path, "/Applications/cmux.app/Contents/Resources/bin/cmux")
    }

    test("a candidate that is not there is skipped, and none means nil") {
        let path = Cmux.cliPath(
            inBundle: "/gone/cmux.app",
            env: [:],
            exists: { $0 == "/Applications/cmux.app/Contents/Resources/bin/cmux" }
        )
        expectEqual(path, "/Applications/cmux.app/Contents/Resources/bin/cmux")
        expectEqual(Cmux.cliPath(inBundle: "/gone/cmux.app", env: [:], exists: { _ in false }), nil)
    }

    // MARK: - which app owns the session

    test("the parent chain identifies cmux, through login and the shell") {
        // The real chain, measured: claude → zsh → /usr/bin/login → the cmux bundle.
        // Nothing in the middle names cmux, which is why the walk has to continue
        // rather than answer from the immediate parent.
        let chain: [Int: (parent: Int, path: String)] = [
            87144: (87111, "/Users/x/.local/bin/claude"),
            87111: (87110, "-/bin/zsh"),
            87110: (80792, "/usr/bin/login"),
            80792: (1, "/Applications/cmux.app/Contents/MacOS/cmux"),
        ]
        expectEqual(ProcessAncestry.host(ofPID: 87144, parentOf: { chain[$0] }), .cmux)
    }

    test("a cmux-hosted session is not read as Terminal") {
        // The bug this whole feature is: a cmux session has a real tty, so before the
        // host was known it was labelled Terminal, and the jump then searched Terminal
        // for a tty Terminal does not own.
        expectEqual(
            SessionOrigin.from(entrypoint: "cli", tty: "/dev/ttys011", host: .cmux), .cmux
        )
        expectEqual(SessionOrigin.cmux.rawValue, "cmux")
    }

    test("an extension-hosted chat stays VS Code even under cmux") {
        // Launching VS Code from a cmux terminal makes cmux an ancestor of the editor
        // and therefore of its chats. The entrypoint is the stronger evidence and wins,
        // which is the rule that was already there for Terminal.
        expectEqual(
            SessionOrigin.from(entrypoint: "claude-vscode", tty: nil, host: .cmux), .vscode
        )
    }

    test("the host survives a round trip through the registry file") {
        // `RegistryStore` persists the host as a raw string and drops anything it cannot
        // decode. A missing case here would silently downgrade every restored cmux
        // session to Terminal on the next launch — the original bug, reintroduced by
        // the back door.
        expectEqual(ProcessAncestry.Host(rawValue: "cmux"), .cmux)
        expectEqual(ProcessAncestry.Host.cmux.rawValue, "cmux")
    }

    // MARK: - the app target

    /*
     Read as source, for the reason `runFocusITerm2Tests` documents at length: `Focus`,
     `Actions`, `FocusWatcher` and `BoardController` live in the `OpenBoard` executable
     target, which this one does not depend on, and their real behaviour needs a running
     cmux with someone's windows in it. So the contract is checked where it can be —
     that the routing is in the file, not only in the commit message.
    */
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("OpenBoard")

    func read(_ name: String) -> String {
        (try? String(contentsOf: sources.appendingPathComponent("\(name).swift"), encoding: .utf8)) ?? ""
    }

    let focus = read("Focus")
    let actions = read("Actions")
    let watcher = read("FocusWatcher")
    let controller = read("BoardController")

    test("the scan actually reads the four files it checks") {
        expect(!focus.isEmpty, "Focus.swift did not read — the scan is checking nothing")
        expect(!actions.isEmpty, "Actions.swift did not read — the scan is checking nothing")
        expect(!watcher.isEmpty, "FocusWatcher.swift did not read — the scan is checking nothing")
        expect(!controller.isEmpty, "BoardController.swift did not read — the scan is checking nothing")
    }

    test("raise routes cmux before the tty branch") {
        // A cmux session *has* a tty. Routed after, it would run Terminal's walk, match
        // nothing, then try iTerm2 — two Apple events, two possible permission prompts,
        // and a wrong answer at the end.
        guard let raiseStart = focus.range(of: "static func raise(_ slot: SlotView)"),
              let cmuxBranch = focus.range(of: "if slot.origin == .cmux {"),
              let ttyBranch = focus.range(of: "if let tty = slot.surface")
        else {
            expect(false, "raise no longer has a cmux branch and a tty branch")
            return
        }
        expect(raiseStart.lowerBound < cmuxBranch.lowerBound)
        expect(
            cmuxBranch.lowerBound < ttyBranch.lowerBound,
            "the cmux branch must come before the tty walk"
        )
    }

    test("focusCmux never launches cmux, and raises it only after selecting") {
        expect(focus.contains("runningApplications(withBundleIdentifier: Cmux.bundleID)"))
        expect(focus.contains("Cmux.focus(surface, cli: cli)"))
        guard let selected = focus.range(of: "Cmux.focus(surface, cli: cli)"),
              let activated = focus.range(of: "app.activate()")
        else {
            expect(false, "focusCmux no longer selects then activates")
            return
        }
        expect(
            selected.lowerBound < activated.lowerBound,
            "select the surface first, so the window that comes forward already shows it"
        )
        expect(focus.contains(".raised(method: \"cmux-surface\")"))
    }

    test("the cmux jump needs no Automation, and does not go through osascript") {
        guard let start = focus.range(of: "private static func focusCmux") else {
            expect(false, "focusCmux not found")
            return
        }
        let body = String(focus[start.lowerBound...].prefix(1200))
        expect(!body.contains("run("), "focusCmux must not emit AppleScript")
        expect(!body.contains("tell application"), "focusCmux must not emit AppleScript")
    }

    test("hasLanded confirms a cmux session by surface id") {
        expect(actions.contains("if target.origin == .cmux {"))
        expect(actions.contains("Cmux.focusedSurfaceID(cli: cli) == surface.id"))
    }

    test("hasLanded also requires cmux to be the frontmost app, not just internally focused") {
        // `cmux identify` reports the surface cmux has focused within itself whether or
        // not cmux is in front. On its own it would report "landed" for a session in a
        // cmux window behind your browser and fire ⏎ into the browser — the exact
        // misdelivery the check exists to prevent. The Terminal branch asks
        // `frontmost of window w` and the VS Code branch asks `isFrontmost` for the
        // same reason; this branch must not be the one that skips it.
        expect(
            actions.contains(
                "NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Cmux.bundleID"
            ),
            "the cmux branch must confirm cmux is frontmost before a keystroke is sent"
        )
    }

    test("the surface is resolved once, not once per poll") {
        // hasLanded runs up to nineteen times inside confirmFrontmost's timeout, and
        // resolving from a pid reads cmux's whole process tree.
        guard let start = actions.range(of: "private static func confirmFrontmost") else {
            expect(false, "confirmFrontmost not found")
            return
        }
        let body = String(actions[start.lowerBound...].prefix(1200))
        guard let resolve = body.range(of: "Focus.cmuxSurface(for: target, cli: cli)"),
              let loop = body.range(of: "while Date() < deadline")
        else {
            expect(false, "confirmFrontmost no longer resolves the surface before its loop")
            return
        }
        expect(resolve.lowerBound < loop.lowerBound, "resolve before the poll loop, not inside it")
    }

    test("the focus watcher reads cmux and keeps its handle separate") {
        expect(watcher.contains("case cmux(surface: String)"))
        expect(watcher.contains("Cmux.bundleID"))
        expect(watcher.contains("Cmux.focusedSurfaceID(cli: cli)"))
    }

    test("the controller reads cmux surfaces on the presence cycle, and skips when it is not running") {
        expect(controller.contains("await self.refreshCmuxSurfaces()"))
        guard let start = controller.range(of: "private func refreshCmuxSurfaces") else {
            expect(false, "refreshCmuxSurfaces not found")
            return
        }
        let body = String(controller[start.lowerBound...].prefix(900))
        expect(
            body.contains("Focus.isRunning(bundleID: Cmux.bundleID)"),
            "a user without cmux must not pay for a process spawn every cycle"
        )
    }

    test("only the sessions on the board are kept, so the board does not republish on churn") {
        // cmux's process tree changes several times a second — every subprocess a
        // session spawns is in it. Storing all of it made the change comparison true on
        // almost every cycle and rewrote the registry file continuously.
        expect(controller.contains("sessionPIDs.contains($0.key)"))
    }

    test("the controller matches the focused surface by pid, and publishes it") {
        expect(controller.contains("case let .cmux(surface):"))
        expect(controller.contains("entry.pid.flatMap { cmuxSurfaces[$0]?.id } == surface"))
        expect(controller.contains("cmuxSurface: entry.pid.flatMap { cmuxSurfaces[$0] }"))
    }

    test("a cmux tab title names the session, through the shared cleaner") {
        expect(controller.contains("cmuxSurfaces[$0]?.title }.flatMap(TerminalTitle.clean)"))
    }
}
