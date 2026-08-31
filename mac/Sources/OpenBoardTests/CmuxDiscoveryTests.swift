import Foundation
import OpenBoardKit

/**
 Discovering a cmux session from the process table.

 cmux does not run a bare `claude` — it passes `--session-id` and a `--settings`
 document installing its own hooks — so the bare-CLI rule refused every one of them and
 no cmux session was ever *discovered*. They reached the board only on their first hook,
 which is why a restart filled the six keys with whatever older sessions `ps` listed
 first and left the ones actually in use off the board.

 The command lines below are real, captured from `ps -axo pid=,tty=,command=` with the
 `--settings` payload shortened in the middle — the signature and the shape are exactly
 as they arrive.
 */
func runCmuxDiscoveryTests() {
    let hookCommand = "\\\"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}\\\" hooks claude stop"
    let cmuxLine = "87144 ttys011  /Users/cam/.local/bin/claude --session-id "
        + "b73160b5-9e23-43ba-9024-806bb1ea199b --settings {\"hooks\":{\"Stop\":[{\"matcher\":\"\","
        + "\"hooks\":[{\"type\":\"command\",\"command\":\"\(hookCommand)\",\"timeout\":10}]}]}}"

    test("a cmux session is discovered despite its flags") {
        let found = Discovery.parse(ps: cmuxLine)
        expectEqual(found.count, 1)
        expectEqual(found.first?.pid, 87144)
        expectEqual(found.first?.tty, "/dev/ttys011")
        expectEqual(found.first?.entrypoint, "cli")
    }

    test("the bare CLI still works, unchanged") {
        let found = Discovery.parse(ps: "69397 ttys000  claude")
        expectEqual(found.count, 1)
        expectEqual(found.first?.pid, 69397)
    }

    test("flags without the cmux signature are still refused") {
        // The rule this widens is the one keeping scripts and wrappers off a board with
        // six keys. A `claude` with flags and no named launcher stays out.
        let script = "5000 ttys003  /usr/local/bin/claude --session-id abc --dangerously-skip-permissions"
        expect(Discovery.parse(ps: script).isEmpty)
    }

    test("a non-interactive run is refused even under cmux") {
        // `claude -p` in a cmux tab is a script in a tab. A key for it is a key nobody
        // is going to press.
        let printed = "5001 ttys004  /Users/cam/.local/bin/claude -p \"do a thing\" --settings "
            + "{\"hooks\":{\"Stop\":[{\"command\":\"\(hookCommand)\"}]}}"
        expect(Discovery.parse(ps: printed).isEmpty)
        let longForm = "5002 ttys005  /Users/cam/.local/bin/claude --print --settings "
            + "{\"hooks\":{\"Stop\":[{\"command\":\"\(hookCommand)\"}]}}"
        expect(Discovery.parse(ps: longForm).isEmpty)
    }

    test("the signature has to be on a claude, not on anything that mentions it") {
        // A shell running the cmux CLI mentions the same variable. It is not a session.
        let shell = "5003 ttys006  /bin/zsh -c \(hookCommand)"
        expect(Discovery.parse(ps: shell).isEmpty)
    }

    test("an extension-hosted chat is unaffected by the new branch") {
        let vscode = "23750 ??  /Users/x/.vscode/extensions/anthropic.claude-code-2.1.226-darwin-arm64/"
            + "resources/native-binary/claude --output-format stream-json --verbose --input-format stream-json"
        let found = Discovery.parse(ps: vscode)
        expectEqual(found.count, 1)
        expectEqual(found.first?.entrypoint, "claude-vscode")
        expectEqual(found.first?.tty, nil)
    }

    test("a real mixed listing finds both hosts and nothing else") {
        let listing = [
            cmuxLine,
            "69397 ttys000  claude",
            "352 ??       /usr/libexec/logd",
            "5000 ttys003  /usr/local/bin/claude --session-id abc --resume",
            "80792 ??       /Applications/cmux.app/Contents/MacOS/cmux",
        ].joined(separator: "\n")
        let found = Discovery.parse(ps: listing)
        expectEqual(found.map(\.pid).sorted(), [69397, 87144])
    }
}

/**
 The two new-tab keys.

 A "new tab" key bound to `newtab` sends ⌘T to Terminal.app, so pressing it while
 working in cmux opens a Terminal window behind cmux — the wrong app doing the right
 thing. cmux has two things the key could mean and names both itself: ⌘T is a new
 *surface* (a tab in the pane you are in) and ⌘N is a new *workspace*, which cmux's own
 shortcut list calls `newTab`. Both are offered rather than guessed between.
 */
func runCmuxNewTabTests() {
    let here = Cmux.Focused(surface: "SURF", workspace: "WS", window: "WIN")

    test("a new tab names the workspace you are in") {
        // Without it the request resolves against the *first* workspace, so the key
        // would open its tab somewhere the user is not looking — the same trap the
        // focus path had.
        expectEqual(
            Cmux.newTabArguments(in: here),
            ["new-surface", "--type", "terminal", "--focus", "true",
             "--workspace", "WS", "--window", "WIN"]
        )
    }

    test("a new workspace names the window but has no workspace to name") {
        expectEqual(
            Cmux.newWorkspaceArguments(in: here),
            ["new-workspace", "--focus", "true", "--window", "WIN"]
        )
    }

    test("both ask for focus — a new tab you have to go and find is not the point") {
        expect(Cmux.newTabArguments(in: here).contains("--focus"))
        expect(Cmux.newWorkspaceArguments(in: here).contains("--focus"))
    }

    test("what cmux could not tell us is omitted, not invented") {
        // cmux unreachable, or an `identify` that did not parse. Bare commands still do
        // the right thing whenever the caller is in the first workspace, which beats
        // sending a handle that was made up.
        expectEqual(
            Cmux.newTabArguments(in: nil),
            ["new-surface", "--type", "terminal", "--focus", "true"]
        )
        expectEqual(Cmux.newWorkspaceArguments(in: nil), ["new-workspace", "--focus", "true"])

        let partial = Cmux.Focused(surface: nil, workspace: "WS", window: nil)
        expectEqual(
            Cmux.newTabArguments(in: partial),
            ["new-surface", "--type", "terminal", "--focus", "true", "--workspace", "WS"]
        )
    }

    // MARK: - reading where we are

    let identify = """
    {
      "caller" : null,
      "focused" : {
        "pane_id" : "1D625A49-ACF4-40DD-B06B-CAC166C93015",
        "surface_id" : "5DBF67AD-5331-43A9-A6BA-177C203D9B79",
        "surface_type" : "terminal",
        "window_id" : "237BD31D-4B4C-43E8-8C69-93B01D55A5E4",
        "workspace_id" : "A5521A79-947D-4986-B4DC-DA379F172DCC"
      }
    }
    """

    test("identify gives the whole context, not just the surface") {
        let focused = Cmux.parseFocused(identify)
        expectEqual(focused?.surface, "5DBF67AD-5331-43A9-A6BA-177C203D9B79")
        expectEqual(focused?.workspace, "A5521A79-947D-4986-B4DC-DA379F172DCC")
        expectEqual(focused?.window, "237BD31D-4B4C-43E8-8C69-93B01D55A5E4")
        // And the older, narrower reader still answers the same thing.
        expectEqual(Cmux.parseFocusedSurfaceID(identify), focused?.surface)
    }

    test("a shape that did not parse is nil, not an empty answer") {
        expectEqual(Cmux.parseFocused(""), nil)
        expectEqual(Cmux.parseFocused("not json"), nil)
        expectEqual(Cmux.parseFocused("{\"caller\":null}"), nil)
        // Present but empty strings are the same as absent — a handle of "" would be
        // passed to cmux as a flag value and refused.
        expectEqual(Cmux.parseFocused("{\"focused\":{\"surface_id\":\"\",\"window_id\":\"\"}}"), nil)
    }

    test("a partial identify keeps what it has") {
        let focused = Cmux.parseFocused("{\"focused\":{\"workspace_id\":\"WS\"}}")
        expectEqual(focused?.workspace, "WS")
        expectEqual(focused?.surface, nil)
    }

    // MARK: - the actions

    test("both actions exist, are bindable, and say which app they mean") {
        expect(KeyAction.allCases.contains(.newtabCmux))
        expect(KeyAction.allCases.contains(.newWorkspaceCmux))
        expectEqual(KeyAction.newtabCmux.rawValue, "newtab-cmux")
        expectEqual(KeyAction.newWorkspaceCmux.rawValue, "newworkspace-cmux")
        // The labels have to name the app, or three "new tab" entries in one picker are
        // indistinguishable.
        expectEqual(KeyAction.newtabCmux.short, "new cmux tab")
        expectEqual(KeyAction.newWorkspaceCmux.short, "new cmux workspace")
        expectEqual(KeyAction.newtab.short, "new Terminal tab")
    }

    test("a binding survives the config round trip") {
        // `ACT09` is the key this arrived from: bound to `newtab`, opening Terminal.
        let stored = Preferences.merging(["actionKeys": ["ACT09": "newtab-cmux"]])
        expectEqual(stored.keyActions["ACT09"], .newtabCmux)
        let reloaded = Preferences.merging(stored.json)
        expectEqual(reloaded.keyActions["ACT09"], .newtabCmux)
    }

    test("the controller runs them, and reports what cmux said") {
        let controller = (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("OpenBoard/BoardController.swift"),
            encoding: .utf8
        )) ?? ""
        expect(!controller.isEmpty, "BoardController.swift did not read")
        expect(controller.contains("case .newtabCmux:"))
        expect(controller.contains("Actions.newCmuxTab()"))
        expect(controller.contains("case .newWorkspaceCmux:"))
        expect(controller.contains("Actions.newCmuxWorkspace()"))
    }

    test("neither action goes through AppleScript") {
        // The Terminal version sends ⌘T to whatever is frontmost. Doing that for cmux
        // would only work when cmux already happened to be in front, and would type ⌘T
        // into something else otherwise.
        let actions = (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("OpenBoard/Actions.swift"),
            encoding: .utf8
        )) ?? ""
        expect(!actions.isEmpty, "Actions.swift did not read")
        guard let start = actions.range(of: "private static func cmux(") else {
            expect(false, "the shared cmux runner is gone")
            return
        }
        let body = String(actions[start.lowerBound...].prefix(900))
        expect(!body.contains("tell application"), "the cmux path must not emit AppleScript")
        expect(
            body.contains("cmux is not running"),
            "a refusal must say which precondition failed"
        )
    }
}
