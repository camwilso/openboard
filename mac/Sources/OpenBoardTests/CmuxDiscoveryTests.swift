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
