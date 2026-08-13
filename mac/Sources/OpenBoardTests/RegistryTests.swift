import Foundation
import OpenBoardKit

/**
 Slot allocation, which is where a board learns to lie.

 Every rule here exists because of a specific failure: a tab burning a key on every
 `/clear`, a dead session holding a light, an orange key stolen to show something
 nobody asked about. The tests are written against those failures rather than against
 the implementation.
 */
func runRegistryTests() {
    let alwaysAlive: (Int?) -> Bool = { _ in true }
    let neverAlive: (Int?) -> Bool = { _ in false }

    test("a new session takes the lowest free slot") {
        var registry = SessionRegistry()
        for expected in 1...6 {
            let result = registry.claim(
                sessionID: "s\(expected)", pid: expected, isAlive: alwaysAlive
            )
            expectEqual(result.entry?.slot, expected)
            expectEqual(result.mode, .unused)
        }
    }

    test("a known session keeps its slot rather than taking another") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        let again = registry.claim(sessionID: "a", pid: 1, state: .working, isAlive: alwaysAlive)
        expectEqual(again.mode, .kept)
        expectEqual(again.entry?.slot, 1)
        expectEqual(again.entry?.state, .working)
        expectEqual(registry.entries.count, 1)
    }

    test("one tab, one key — a cleared session reuses its own slot") {
        // `/clear` mints a fresh session_id inside the same process. Without this a
        // single tab burns another key every time and the board fills with dead
        // entries for a window you never left.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "before", pid: 100, tty: "/dev/ttys001", isAlive: neverAlive)
        let after = registry.claim(
            sessionID: "after", pid: 100, tty: "/dev/ttys001", isAlive: neverAlive
        )
        expectEqual(after.mode, .sameHost)
        expectEqual(after.entry?.slot, 1)
        expectEqual(registry.entries.count, 1, "the old entry is replaced, not kept alongside")
    }

    test("a live session sharing a tty does not lose its key") {
        // The same-host rule only applies to a session that is genuinely finished or
        // gone; otherwise it would steal a key from something still running.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "live", pid: 100, tty: "/dev/ttys001", isAlive: alwaysAlive)
        let other = registry.claim(
            sessionID: "new", pid: 100, tty: "/dev/ttys001", isAlive: alwaysAlive
        )
        expectEqual(other.mode, .unused, "must take a fresh slot")
        expectEqual(other.entry?.slot, 2)
        expectEqual(registry.entries.count, 2)
    }

    test("a full board reclaims the oldest finished session") {
        var registry = SessionRegistry()
        for i in 1...6 { _ = registry.claim(sessionID: "s\(i)", pid: i, isAlive: alwaysAlive) }
        registry.markEnded(sessionID: "s3")

        let result = registry.claim(sessionID: "new", pid: 99, isAlive: alwaysAlive)
        expectEqual(result.mode, .reclaimed)
        expectEqual(result.entry?.slot, 3)
    }

    test("eviction never takes a key that is asking for attention") {
        // Stealing the orange key to show something nobody asked about is the single
        // worst thing this could do — it destroys the one signal the product exists
        // to deliver.
        var registry = SessionRegistry()
        for i in 1...6 { _ = registry.claim(sessionID: "s\(i)", pid: i, isAlive: alwaysAlive) }
        registry.setState(sessionID: "s1", to: .awaiting, pendingTool: "Bash")
        registry.setState(sessionID: "s2", to: .stalled)

        let result = registry.claim(sessionID: "new", pid: 99, isAlive: alwaysAlive)
        expectEqual(result.mode, .evicted)
        expect(result.entry?.slot != 1, "must not evict the awaiting key")
        expect(result.entry?.slot != 2, "must not evict the stalled key")
        expectEqual(registry.entry(forSession: "s1")?.state, .awaiting)
    }

    test("a board where every key is waiting fails dark") {
        // Better to give the new session nothing than to take the light someone
        // needs in order to see.
        var registry = SessionRegistry()
        for i in 1...6 {
            _ = registry.claim(sessionID: "s\(i)", pid: i, isAlive: alwaysAlive)
            registry.setState(sessionID: "s\(i)", to: .awaiting)
        }
        let result = registry.claim(sessionID: "new", pid: 99, isAlive: alwaysAlive)
        expectEqual(result.mode, .noSlot)
        expect(result.entry == nil)
        expectEqual(registry.entries.count, 6, "nothing was disturbed")
    }

    test("leaving an attention state clears what was pending") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        registry.setState(sessionID: "a", to: .awaiting, pendingTool: "AskUserQuestion")
        expectEqual(registry.entry(forSession: "a")?.pendingTool, "AskUserQuestion")

        registry.setState(sessionID: "a", to: .working)
        expect(registry.entry(forSession: "a")?.pendingTool == nil, "nothing is pending now")
    }

    test("a session already in progress can be adopted") {
        // The registry is rebuilt from hooks and SessionStart fires once, so a session
        // that was already running when the app started would otherwise stay invisible
        // forever. Observed for real: hooks arriving normally while the board reported
        // zero sessions.
        var registry = SessionRegistry()
        expect(registry.setState(sessionID: "already-running", to: .working) == nil,
               "setState alone must not create it")

        let adopted = registry.claim(
            sessionID: "already-running", cwd: "/tmp", state: .working, isAlive: alwaysAlive
        )
        expectEqual(adopted.mode, .unused)
        expectEqual(registry.entry(forSession: "already-running")?.state, .working)
    }

    test("an unknown session is ignored, not given a key") {
        var registry = SessionRegistry()
        expect(registry.setState(sessionID: "ghost", to: .working) == nil)
        expectEqual(registry.entries.count, 0, "a stray event must not claim a slot")
    }

    test("a dead process does not keep its light") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.claim(sessionID: "b", pid: 2, isAlive: alwaysAlive)
        expectEqual(registry.prune(isAlive: { $0 == 1 }), 1)
        expect(registry.entry(forSession: "b") == nil)
        expect(registry.entry(forSession: "a") != nil)
    }

    test("done holds; awaiting expires") {
        // Reversed from the original rule, on purpose. `done` used to age out after 90s
        // on the reasoning that permanent green stops meaning anything. That traded away
        // the more valuable signal: a session that finished while you were elsewhere is
        // exactly the one you need to be told about, and a timer makes the board forget
        // it before you look. Green now clears when you go back and send something.
        var registry = SessionRegistry()
        let start = Date()
        _ = registry.claim(sessionID: "a", pid: 1, now: start, isAlive: alwaysAlive)
        registry.setState(sessionID: "a", to: .done, now: start)
        _ = registry.claim(sessionID: "b", pid: 2, now: start, isAlive: alwaysAlive)
        registry.setState(sessionID: "b", to: .awaiting, now: start)

        // Two minutes on, nothing has changed.
        expectEqual(registry.decay(now: start.addingTimeInterval(120)), 0)
        expectEqual(registry.entry(forSession: "a")?.state, .done)
        expectEqual(registry.entry(forSession: "b")?.state, .awaiting)

        // Twenty minutes on, both are still lit. Attention is held by default now: the
        // hooks clear it the moment the prompt is answered, and a deadline for a prompt
        // that is never answered is a question nobody can answer in minutes.
        expectEqual(registry.decay(now: start.addingTimeInterval(1200)), 0)
        expectEqual(registry.entry(forSession: "b")?.state, .awaiting)
        expectEqual(registry.entry(forSession: "a")?.state, .done, "green cleared itself")

        // Asked for, the old safety net comes back at a fixed 15 minutes.
        expectEqual(
            registry.decay(holdAttention: false, now: start.addingTimeInterval(1200)), 1
        )
        expectEqual(registry.entry(forSession: "b")?.state, .idle)
        expect(registry.entry(forSession: "b")?.pendingTool == nil)
    }

    test("reset forgets everything") {
        var registry = SessionRegistry()
        for i in 1...6 { _ = registry.claim(sessionID: "s\(i)", pid: i, isAlive: alwaysAlive) }
        registry.reset()
        expectEqual(registry.entries.count, 0)
        // The cursor resets too, or the next claim looks arbitrarily old.
        let result = registry.claim(sessionID: "fresh", pid: 1, isAlive: alwaysAlive)
        expectEqual(result.entry?.slot, 1)
        expectEqual(result.entry?.claimSeq, 1)
    }

    test("occupancy always reports all six slots") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        let rows = registry.occupancy()
        expectEqual(rows.count, 6)
        expectEqual(rows[0].entry?.sessionID, "a")
        expect(rows[1].entry == nil)
    }

    // MARK: - event mapping

    test("hook events map to the states the Node version used") {
        expectEqual(EventMapper.state(for: "SessionStart"), .idle)
        expectEqual(EventMapper.state(for: "UserPromptSubmit"), .working)
        expectEqual(EventMapper.state(for: "Stop"), .done)
        expectEqual(EventMapper.state(for: "SessionEnd"), .ended)
        expectEqual(EventMapper.state(for: "StopFailure"), .error)
        // Fires the instant a prompt appears; the equivalent Notification lags it by
        // about six seconds, measured.
        expectEqual(EventMapper.state(for: "PermissionRequest"), .awaiting)
        expect(EventMapper.state(for: "SomethingElse") == nil)
    }

    test("idle_prompt stays unmapped") {
        // It means "sitting idle", not "needs you". Mapping it lights the attention
        // color with nothing to act on, which teaches you to ignore the one color
        // that must never be ignored.
        expect(EventMapper.state(for: "Notification", matcher: "idle_prompt") == nil)
        expectEqual(EventMapper.state(for: "Notification", matcher: "permission_prompt"), .awaiting)
        expectEqual(EventMapper.state(for: "Notification", matcher: "agent_needs_input"), .awaiting)
        // Not per-session status: these are about the app, not about a key.
        expect(EventMapper.state(for: "Notification", matcher: "agent_completed") == nil)
        expect(EventMapper.state(for: "Notification", matcher: "auth_success") == nil)
    }

    test("a muted event repaints nothing") {
        // Muting is a supported configuration, not a failure — so it returns nil
        // exactly like an unrecognised event.
        expect(EventMapper.state(for: "Stop", enabledEvents: ["Stop": false]) == nil)
        expectEqual(EventMapper.state(for: "Stop", enabledEvents: ["Stop": true]), .done)
        expectEqual(EventMapper.state(for: "Stop", enabledEvents: [:]), .done, "absent means enabled")
    }

    test("every event the installer registers is understood") {
        // A toggle for an event nothing handles would be a lie in the settings window.
        let installed = [
            "SessionStart", "UserPromptSubmit", "Notification", "Stop",
            "SessionEnd", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
        ]
        for event in installed where event != "Notification" {
            expect(EventMapper.state(for: event) != nil, "\(event) maps to nothing")
        }
        // Notification needs a matcher, and carries its own map.
        expect(EventMapper.state(for: "Notification") == nil)
    }

    test("adjustDelegation on SubagentStart increments an existing entry, and ignores an unknown session") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart")
        expectEqual(registry.entry(forSession: "a")?.delegatedCount, 1)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart")
        expectEqual(registry.entry(forSession: "a")?.delegatedCount, 2)

        // An unknown session_id never allocates a slot — mirrors setState's own rule.
        let before = registry.entries.count
        let result = registry.adjustDelegation(sessionID: "ghost", event: "SubagentStart")
        expect(result == nil, "an unknown session must not be given a key")
        expectEqual(registry.entries.count, before)
    }

    test("adjustDelegation on SubagentStop decrements, floors at 0, and ignores an unknown session") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart")
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart")
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStop")
        expectEqual(registry.entry(forSession: "a")?.delegatedCount, 1)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStop")
        expectEqual(registry.entry(forSession: "a")?.delegatedCount, 0)
        // Duplicate SubagentStop delivery must not go negative.
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStop")
        expectEqual(registry.entry(forSession: "a")?.delegatedCount, 0)

        expect(
            registry.adjustDelegation(sessionID: "ghost", event: "SubagentStop") == nil,
            "an unknown session must not be given a key"
        )
    }

    test("reconcileDelegation is authoritative, overriding drifted incremental counts") {
        // Simulates the spike's out-of-order-finish / non-head-removal case: whatever
        // SubagentStart/SubagentStop produced is replaced wholesale by the live
        // background_tasks count on every Stop, never trusted as a running total.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart")
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart")
        _ = registry.adjustDelegation(sessionID: "a", event: "SubagentStart")
        expectEqual(registry.entry(forSession: "a")?.delegatedCount, 3)

        // The authoritative Stop-time count disagrees with the drifted increments.
        _ = registry.reconcileDelegation(sessionID: "a", count: 1)
        expectEqual(registry.entry(forSession: "a")?.delegatedCount, 1)

        _ = registry.reconcileDelegation(sessionID: "a", count: 0)
        expectEqual(registry.entry(forSession: "a")?.delegatedCount, 0)

        expect(
            registry.reconcileDelegation(sessionID: "ghost", count: 5) == nil,
            "an unknown session must not be given a key"
        )
    }

    test("the Stop override formula: done + delegating stays working, done + not delegating stays done") {
        // Pure-function replica of BoardController.handle's counter-gated override
        // (the `else` branch of its if/else if/else chain) — the live socket/hook
        // path is not reachable from this suite, but the formula itself, including
        // its load-bearing parens, is. `?? 0 > 0` would parse as `?? (0 > 0)` without
        // them, which always evaluates true for an existing entry with count 0.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "a", pid: 1, isAlive: alwaysAlive)

        func applied(_ state: SessionState, sessionID: String) -> SessionState {
            (state == .done && (registry.entry(forSession: sessionID)?.delegatedCount ?? 0) > 0)
                ? .working : state
        }

        // No agents in flight: a plain turn's Stop -> done, unchanged
        // (regression guard).
        expectEqual(applied(.done, sessionID: "a"), .done)

        // Reconciled to 1 in-flight subagent: Stop -> working, not done.
        _ = registry.reconcileDelegation(sessionID: "a", count: 1)
        expectEqual(applied(.done, sessionID: "a"), .working)

        // A state other than .done is never touched by the override, delegating or not.
        expectEqual(applied(.awaiting, sessionID: "a"), .awaiting)

        // Reconciled back to 0: Stop -> done again.
        _ = registry.reconcileDelegation(sessionID: "a", count: 0)
        expectEqual(applied(.done, sessionID: "a"), .done)

        // An unknown session_id must not crash or be treated as delegating.
        expectEqual(applied(.done, sessionID: "ghost"), .done)

        // The formula alone is not the whole story: BoardController feeds `applied`
        // into `setState`, which is itself gated by `SessionState.mayReplace`. Prove
        // `.working` is actually accepted over an entry sitting at `.done` — the exact
        // path a recovering delegating session takes — rather than
        // stopping one line short of the guard that could silently swallow it.
        _ = registry.setState(sessionID: "a", to: .done)
        expectEqual(registry.entry(forSession: "a")?.state, .done)
        _ = registry.reconcileDelegation(sessionID: "a", count: 1)
        let override = applied(.done, sessionID: "a")
        _ = registry.setState(sessionID: "a", to: override)
        expectEqual(
            registry.entry(forSession: "a")?.state, .working,
            "mayReplace must not swallow the delegating override"
        )
    }

    test("suppressesDelegating: idle_prompt suppressed only while delegating") {
        // idle_prompt fires on an idle timer, independent of subagent activity — it
        // must not be allowed to clobber a delegating .working key, but a plain
        // session (count == 0) is unaffected: the notification applies exactly as it
        // always has.
        expect(
            EventMapper.suppressesDelegating(
                eventName: "Notification", matcher: "idle_prompt", delegatedCount: 1
            ),
            "idle_prompt while delegating must be suppressed"
        )
        expect(
            !EventMapper.suppressesDelegating(
                eventName: "Notification", matcher: "idle_prompt", delegatedCount: 0
            ),
            "idle_prompt with no subagents in flight must apply normally"
        )
    }

    test("suppressesDelegating: real attention subtypes are never suppressed") {
        // permission_prompt/agent_needs_input/elicitation_dialog are genuine
        // human-attention signals and must keep winning orange precedence over a
        // delegating .working key — the suppression is keyed on the idle_prompt
        // subtype specifically, never on any other Notification subtype.
        for matcher in ["permission_prompt", "agent_needs_input", "elicitation_dialog"] {
            expect(
                !EventMapper.suppressesDelegating(
                    eventName: "Notification", matcher: matcher, delegatedCount: 1
                ),
                "\(matcher) must never be suppressed, delegating or not"
            )
        }
    }

    test("suppressesDelegating: keyed on subtype, not event name or mapped state") {
        // A non-Notification event, or a Notification with no matcher/a different
        // subtype, must never be suppressed regardless of delegatedCount — the
        // suppression follows the false signal (the subtype), not the color it
        // happens to be remapped to.
        expect(
            !EventMapper.suppressesDelegating(
                eventName: "Stop", matcher: "idle_prompt", delegatedCount: 1
            ),
            "only a Notification event can be suppressed"
        )
        expect(
            !EventMapper.suppressesDelegating(
                eventName: "Notification", matcher: nil, delegatedCount: 1
            ),
            "a Notification with no matcher must not be suppressed"
        )
        expect(
            !EventMapper.suppressesDelegating(
                eventName: "Notification", matcher: "agent_completed", delegatedCount: 1
            ),
            "an unrelated subtype must not be suppressed"
        )
    }
}

/**
 Reconnecting to sessions that were already running.

 The board's job is to say what is happening without being asked, so a session sitting
 idle in another tab must not be invisible until you go and type in it.
 */
func runDiscoveryTests() {
    let alwaysAlive: (Int?) -> Bool = { _ in true }

    test("running sessions are seeded onto the board") {
        var registry = SessionRegistry()
        let found = [
            Discovery.Found(pid: 100, tty: "/dev/ttys000", cwd: "/a"),
            Discovery.Found(pid: 200, tty: "/dev/ttys001", cwd: "/b"),
        ]
        expectEqual(registry.reconnect(found, isAlive: alwaysAlive), 2)
        expectEqual(registry.entries.count, 2)
        expectEqual(registry.entry(forSlot: 1)?.tty, "/dev/ttys000")
    }

    /*
     Real `ps` output, trimmed to the columns and abbreviated in the path only.

     Every line here was observed at once on one Mac: three Terminal chats, one VS Code
     chat, and the MCP server the same extension runs out of the same directory.
    */
    let extensionBinary =
        "/Users/x/.vscode/extensions/anthropic.claude-code-2.1.226-darwin-arm64"
            + "/resources/native-binary/claude"
    let listing = """
    98987 ttys000  claude
    57023 ttys002  claude
     4405 ??       \(extensionBinary) --output-format stream-json --verbose \
    --input-format stream-json --max-thinking-tokens 31999 --permission-prompt-tool stdio
     4440 ??       \(extensionBinary) --claude-in-chrome-mcp
    12745 ??       /bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh.sh
    """

    test("a terminal chat and an extension-hosted chat are both found") {
        let found = Discovery.parse(ps: listing)
        expectEqual(found.count, 3)
        expectEqual(found.map(\.pid), [98987, 57023, 4405])
        expectEqual(found.map(\.entrypoint), ["cli", "cli", "claude-vscode"])
        // No tty is the whole reason this one was invisible before.
        expect(found.last?.tty == nil)
        expectEqual(found.first?.tty, "/dev/ttys000")
    }

    test("the MCP server running the same binary is not a session") {
        // Same path, same directory, not a chat. Only the stream-json flags separate
        // them, which is why both halves of the signature are checked.
        expect(!Discovery.parse(ps: listing).contains { $0.pid == 4440 })
    }

    test("a tty-less claude that is not the extension's is refused") {
        // The failure this guards against was real: ten of these under an unrelated
        // extension would take all six keys before a human session appeared.
        let impostors = """
        31000 ??       /usr/local/bin/claude --output-format stream-json --input-format stream-json
        31001 ??       /Users/x/.other-editor/extensions/someone.else/claude \
        --output-format stream-json --input-format stream-json
        """
        expect(Discovery.parse(ps: impostors).isEmpty)
    }

    test("two extension-hosted chats each get their own key") {
        // Both have no tty, so a duplicate check that compared ttys directly would read
        // the second as already on the board and silently drop it.
        var registry = SessionRegistry()
        let found = [
            Discovery.Found(pid: 300, tty: nil, cwd: "/a", entrypoint: "claude-vscode"),
            Discovery.Found(pid: 400, tty: nil, cwd: "/a", entrypoint: "claude-vscode"),
        ]
        expectEqual(registry.reconnect(found, isAlive: alwaysAlive), 2)
        expectEqual(registry.entry(forSlot: 2)?.entrypoint, "claude-vscode")
    }

    test("reconnecting twice does not take more keys") {
        var registry = SessionRegistry()
        let found = [Discovery.Found(pid: 100, tty: "/dev/ttys000", cwd: "/a")]
        _ = registry.reconnect(found, isAlive: alwaysAlive)
        expectEqual(registry.reconnect(found, isAlive: alwaysAlive), 0, "already on the board")
        expectEqual(registry.entries.count, 1)
    }

    test("a real hook takes over its host's slot rather than a second one") {
        // Otherwise the same session appears twice: once as the discovered host and
        // again under its real id.
        var registry = SessionRegistry()
        _ = registry.reconnect(
            [Discovery.Found(pid: 100, tty: "/dev/ttys000", cwd: "/a")], isAlive: alwaysAlive
        )
        let slotBefore = registry.entry(forSlot: 1)?.slot

        expect(registry.adoptRealSessionID("real-abc", pid: 100, tty: "/dev/ttys000"))
        expectEqual(registry.entries.count, 1, "still one key")
        expectEqual(registry.entry(forSession: "real-abc")?.slot, slotBefore)
        expect(!Discovery.isPlaceholder(registry.entry(forSlot: 1)?.sessionID ?? ""))
    }

    test("a takeover matches on tty when the pid is unknown") {
        // Hooks do not always carry CLAUDE_PID.
        var registry = SessionRegistry()
        _ = registry.reconnect(
            [Discovery.Found(pid: 100, tty: "/dev/ttys000", cwd: "/a")], isAlive: alwaysAlive
        )
        expect(registry.adoptRealSessionID("real-abc", pid: nil, tty: "/dev/ttys000"))
        expectEqual(registry.entry(forSession: "real-abc")?.slot, 1)
    }

    test("a takeover never steals a real session's slot") {
        // Only placeholders are handed over. A genuine session keeps its key.
        var registry = SessionRegistry()
        _ = registry.claim(
            sessionID: "genuine", pid: 100, tty: "/dev/ttys000", isAlive: alwaysAlive
        )
        expect(!registry.adoptRealSessionID("other", pid: 100, tty: "/dev/ttys000"))
        expectEqual(registry.entry(forSession: "genuine")?.slot, 1)
    }

    test("a session already known is not taken over again") {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "known", pid: 100, isAlive: alwaysAlive)
        expect(!registry.adoptRealSessionID("known", pid: 100, tty: nil))
    }

    test("placeholders are recognisable and never look like a session id") {
        let found = Discovery.Found(pid: 4321, tty: "/dev/ttys000", cwd: nil)
        expect(Discovery.isPlaceholder(found.placeholderSessionID))
        expect(!Discovery.isPlaceholder("4f0e1d2c-3b4a-5968-8776-a5b4c3d2e1f0"))
    }
}

/**
 Dead sessions must not hold keys.

 `prune` was written with the right reasoning in its own doc comment and then never
 called from anywhere, so a closed Terminal tab kept its key until the 12h stale window
 and the header counted it as live. The board claimed activity that did not exist,
 which is the exact failure this project is meant to avoid.
 */
func runPruneTests() {
    func board(_ pids: [Int], state: SessionState = .idle) -> SessionRegistry {
        var registry = SessionRegistry()
        let now = Date()
        for pid in pids {
            _ = registry.claim(
                sessionID: "s\(pid)", pid: pid, tty: "/dev/ttys\(pid)",
                state: state, now: now, isAlive: { _ in true }
            )
        }
        return registry
    }

    test("a session whose process is gone loses its key") {
        var registry = board([100, 200, 300])
        let dead: Set<Int> = [100, 300]
        expectEqual(registry.prune(isAlive: { pid in !dead.contains(pid ?? 0) }), 2)
        expectEqual(registry.entries.map(\.sessionID), ["s200"])
    }

    test("pruning frees the key for reuse") {
        var registry = board([100, 200])
        let slot = try Harness.require(registry.entry(forSession: "s100")?.slot)
        _ = registry.prune(isAlive: { $0 == 200 })

        let claimed = registry.claim(
            sessionID: "new", pid: 999, isAlive: { _ in true }
        )
        expectEqual(claimed.entry?.slot, slot, "the freed key was not reused")
    }

    test("a finished session with a live process keeps its key") {
        // The interaction with green holding: `done` persists until you go back, and
        // pruning must not undo that. Only the process being *gone* frees the key.
        var registry = board([100], state: .done)
        expectEqual(registry.prune(isAlive: { _ in true }), 0)
        expectEqual(registry.entry(forSession: "s100")?.state, .done)

        // Close the terminal and there is nothing to go back to.
        expectEqual(registry.prune(isAlive: { _ in false }), 1)
        expect(registry.entries.isEmpty)
    }

    test("an entry with no pid is never pruned") {
        // A session can reach the board without one. Guessing it is dead would drop a
        // live session, which is the worse error.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "no-pid", pid: nil, isAlive: { _ in true })
        expectEqual(registry.prune(isAlive: { _ in false }), 0)
        expectEqual(registry.entries.count, 1)
    }

    test("pruning an already-clean board reports no change") {
        // The caller repaints only when something changed; a nonzero return on a clean
        // board would repaint on every cycle.
        var registry = board([100, 200])
        expectEqual(registry.prune(isAlive: { _ in true }), 0)
    }
}

/**
 What green survives.

 `done` holding until you go back only works if nothing quietly repaints over it. One
 thing did: Claude Code fires an `idle_prompt` notification about 60 seconds after a
 turn ends, and a config mapping that to `idle` painted straight over the green —
 indistinguishable from a decay timer that had been switched off and was somehow still
 running.
 */
func runDoneSurvivalTests() {
    test("idle does not overwrite done") {
        // `done` already means idle, plus the thing you have not seen.
        expect(!SessionState.mayReplace(.done, with: .idle))
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "s", pid: 1, state: .done, isAlive: { _ in true })
        registry.setState(sessionID: "s", to: .idle)
        expectEqual(registry.entry(forSession: "s")?.state, .done, "an idle prompt cleared it")
    }

    test("the exact sequence that caused it") {
        // Stop, then a Notification 60s later that a config maps to idle.
        var registry = SessionRegistry()
        let start = Date()
        _ = registry.claim(sessionID: "s", pid: 1, now: start, isAlive: { _ in true })
        registry.setState(sessionID: "s", to: .done, now: start)

        let mapped = EventMapper.state(
            for: "Notification", matcher: "idle_prompt", notifications: ["idle_prompt": .idle]
        )
        expectEqual(mapped, .idle, "the mapping itself is legitimate")
        registry.setState(sessionID: "s", to: mapped!, now: start.addingTimeInterval(60))
        expectEqual(registry.entry(forSession: "s")?.state, .done)
    }

    test("everything else still replaces done") {
        // Narrow on purpose: this must not become a general "green wins" rule, or a
        // session that fails or blocks after finishing would keep claiming it is fine.
        for next: SessionState in [.working, .awaiting, .stalled, .error, .ended, .viewing] {
            expect(
                SessionState.mayReplace(.done, with: next),
                "\(next.rawValue) was blocked from replacing done"
            )
        }
    }

    test("idle still replaces everything it should") {
        for current: SessionState in [.working, .viewing, .awaiting, .stalled, .error, .idle] {
            expect(
                SessionState.mayReplace(current, with: .idle),
                "idle was blocked from replacing \(current.rawValue)"
            )
        }
    }

    test("sending a new message still clears it") {
        // The intended way out has to keep working.
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "s", pid: 1, state: .done, isAlive: { _ in true })
        registry.setState(sessionID: "s", to: EventMapper.state(for: "UserPromptSubmit")!)
        expectEqual(registry.entry(forSession: "s")?.state, .working)
    }
}

/**
 The pad's physical rows.

 The wide MIC cap spans two columns, and only `Grid` honours that — `LazyVGrid` ignores
 `gridCellColumns` silently, which rendered the bottom row a column short and every key
 slightly wrong without anything failing.
 */
func runBoardRowTests() {
    test("four rows, each four columns wide") {
        let rows = BoardLayout.rows
        expectEqual(rows.count, 4)
        for (index, row) in rows.enumerated() {
            let width = row.reduce(0) { $0 + $1.span }
            expectEqual(width, 4, "row \(index + 1) is \(width) columns wide")
        }
    }

    test("the rows contain every cell, in order, once") {
        // Derived from `cells` so there is one definition of what is on the pad; this
        // is what stops the two drifting.
        let flattened = BoardLayout.rows.flatMap { $0 }.map(\.id)
        expectEqual(flattened, BoardLayout.cells.map(\.id))
    }

    test("the wide cap is the only one that spans") {
        let spanning = BoardLayout.cells.filter { $0.span > 1 }
        expectEqual(spanning.map(\.id), ["ACT10"])
        expectEqual(spanning.first?.span, 2)
        // And it carries both switches, because one keycap reports two names.
        expectEqual(spanning.first?.members, ["ACT10", "ACT11"])
    }

    test("the bottom row is the touch strip, the wide cap, and one more") {
        let last = try Harness.require(BoardLayout.rows.last)
        expectEqual(last.map(\.id), ["TOUCH", "ACT10", "ACT12"])
    }
}
