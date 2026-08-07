import Foundation

/**
 The coding agent whose sessions the board is showing.

 Everything this app knows about a harness is one of four things: **where its settings
 live**, **which events it emits**, **what those events mean**, and **which surfaces it
 runs on and how each one is reached**. Until now those four were scattered — the events
 in `HookInstall`, their meanings in `EventMapper`, the surfaces in `Eligibility` and
 `SessionOrigin`, the settings path in `HookInstall.settingsURL` — which was fine while
 there was exactly one agent and is the wrong shape the moment there are two.

 So this is the description, in one value. Adding a second harness means adding a
 `Harness` and teaching the mapper its event names; it does not mean finding four
 scattered places that assumed Claude Code.

 ## Three, and they are not equal

 Claude Code is wired end to end and OpenBoard writes its file. Hermes and Pi are wired
 as far as they can be: the same helper, the same socket, the same payload fields — but
 their configuration is theirs to edit, so the app hands over the exact text instead of
 writing YAML into somebody's file or dropping a TypeScript module into their extension
 directory.

 What a fourth would need, since the list no longer says so on screen: a way to run or
 call a command on session events, a per-session id stable for the life of the session,
 an event when a turn starts, ends and needs a human, and a local process — the board is
 driven over USB or Bluetooth from this Mac.

 Each also carries its `limitations`, and those are load-bearing rather than a
 disclaimer. Hermes has no completion event, so a Hermes key never turns green. Pi has
 no documented approval event, so a Pi key never turns orange — which is the state this
 whole board exists for. Saying that on the pane is the difference between a feature and
 a screen describing behaviour that does not exist.
 */
public struct Harness: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    /// Wired end to end, versus described. Nothing in this app claims the second.
    public let isSupported: Bool
    /// Where the agent keeps the configuration OpenBoard has to edit, if it has one.
    public let settingsPath: String?
    /// The environment variable naming the surface a session is running on.
    public let entrypointVariable: String?
    /// Entry points that may claim a key. A fail-closed allowlist — see `Eligibility`.
    public let entrypoints: [String]
    /// The hooks the board needs, and the matcher each carries.
    public let events: [(name: String, matcher: String?)]
    /// What this harness cannot do, in its own terms. Shown beside it, because a
    /// missing state is not a detail — it is a color that will never appear.
    public let limitations: [String]
    /**
     How its hooks are wired, and whether OpenBoard can do it.

     Claude Code's file is JSON that can be merged safely — every unrelated key and any
     other tool's hooks on the same events survive, and the previous version is backed
     up beside it. The others are not: Hermes keeps YAML, and Pi has no out-of-process
     hooks at all. Editing somebody's YAML by machine risks their comments and ordering,
     and there is no honest way to "install" into a mechanism that does not exist.

     So those two hand over the exact text instead. It is a worse experience and a true
     one, which is the trade this project keeps making.
     */
    public enum Setup: Sendable, Equatable {
        /// OpenBoard writes it, with a backup.
        case automatic
        /// The user pastes it. The payload is what to paste, and where.
        case manual(path: String, snippet: String)
    }

    public let setup: Setup

    public static func == (lhs: Harness, rhs: Harness) -> Bool { lhs.id == rhs.id }

    /// How a session on this surface is found, and how a key press reaches it.
    public struct Surface: Sendable, Identifiable, Equatable {
        public let id: String
        public let name: String
        /// How the app knows a session is running there.
        public let detection: String
        /// What pressing that session's key does.
        public let jump: String
        /// Nil when the surface is supported. Present when it is not, and then it is
        /// the reason rather than a shrug.
        public let unsupported: String?

        public init(
            id: String,
            name: String,
            detection: String,
            jump: String,
            unsupported: String? = nil
        ) {
            self.id = id
            self.name = name
            self.detection = detection
            self.jump = jump
            self.unsupported = unsupported
        }
    }

    public let surfaces: [Surface]

    public init(
        id: String,
        name: String,
        isSupported: Bool,
        settingsPath: String?,
        entrypointVariable: String?,
        entrypoints: [String],
        events: [(name: String, matcher: String?)],
        surfaces: [Surface],
        limitations: [String],
        setup: Setup
    ) {
        self.id = id
        self.name = name
        self.isSupported = isSupported
        self.settingsPath = settingsPath
        self.entrypointVariable = entrypointVariable
        self.entrypoints = entrypoints
        self.events = events
        self.surfaces = surfaces
        self.limitations = limitations
        self.setup = setup
    }
}

extension Harness {
    /**
     Claude Code.

     The event list is `HookInstall.events` rather than a copy of it: two lists that
     must agree is one list and a bug waiting to happen, and the hook audit is what
     writes the file, so it owns the truth.
     */
    public static let claudeCode = Harness(
        id: "claude-code",
        name: "Claude Code",
        isSupported: true,
        settingsPath: "~/.claude/settings.json",
        entrypointVariable: "CLAUDE_CODE_ENTRYPOINT",
        entrypoints: Array(Eligibility.defaultEntrypoints).sorted(),
        events: HookInstall.events,
        surfaces: [
            Surface(
                id: "terminal",
                name: "Terminal",
                detection: "The session's tty, captured from its process at claim time.",
                jump: "Matched against Terminal's per-tab tty — the exact tab, not the window."
            ),
            Surface(
                id: "vscode",
                name: "VS Code",
                detection: "Entry point `claude-vscode`, or the owning process when a "
                    + "session runs in the integrated terminal.",
                jump: "`code -r` on the workspace folder: the right window, not the "
                    + "specific panel."
            ),
            Surface(
                id: "subagent",
                name: "Subagents",
                detection: "`CLAUDE_AGENT_ID`, or an agent type in the payload.",
                jump: "—",
                unsupported: "Never given a key, by design: one parallel fan-out would "
                    + "take all six at once."
            ),
            Surface(
                id: "sdk",
                name: "Embedded SDK clients",
                detection: "`CLAUDE_AGENT_SDK_CLIENT_APP`.",
                jump: "—",
                unsupported: "Other tools spawn `claude` of their own accord — ten were "
                    + "seen running under one unrelated extension."
            ),
            Surface(
                id: "remote",
                name: "claude.ai, cloud, SSH",
                detection: "—",
                jump: "—",
                unsupported: "Unreachable: hooks run in the session's own process, and "
                    + "only a local one can talk to the pad."
            ),
        ],
        limitations: [],
        setup: .automatic
    )

    /**
     Hermes Agent, from Nous Research.

     Its shell hooks pipe JSON to stdin with `hook_event_name`, `session_id`, `cwd` and
     `tool_name` — the same four fields Claude Code sends. That is why nothing in the
     helper or the socket had to change to accept it: only the event *names* differ, and
     names are what `EventMapper` is for.

     `pre_approval_request` is the reason this was worth doing. It is the whole product
     in one event: the moment a session stops and waits for a human.

     **No completion event.** Its plugin hooks cover sessions, tools and approvals, but
     nothing that means "this turn is finished" — `agent:end` is a gateway event, not a
     shell hook. So a Hermes session goes idle → working → awaiting → working, and never
     shows green. That is stated on the pane rather than quietly missing.
     */
    public static let hermes = Harness(
        id: "hermes",
        name: "Hermes Agent",
        isSupported: true,
        settingsPath: "~/.hermes/config.yaml",
        entrypointVariable: nil,
        entrypoints: [],
        events: [
            ("on_session_start", nil),
            ("pre_tool_call", nil),
            ("post_tool_call", nil),
            ("pre_approval_request", nil),
            ("post_approval_response", nil),
            ("on_session_end", nil),
        ],
        surfaces: [
            Surface(
                id: "terminal",
                name: "Terminal",
                detection: "`cwd` and `session_id` from the hook payload.",
                jump: "The owning process's tty, when the session was started from one."
            ),
            Surface(
                id: "subagent",
                name: "Subagents",
                detection: "`subagent_start` and `subagent_stop`.",
                jump: "—",
                unsupported: "Not wired, and would not take a key if it were — six keys "
                    + "is a scarce budget."
            ),
            Surface(
                id: "gateway",
                name: "Gateway sessions",
                detection: "—",
                jump: "—",
                unsupported: "A gateway run is not a terminal you can be sent to, and "
                    + "may not be on this machine at all."
            ),
        ],
        limitations: [
            "No completion event: nothing in its shell hooks means \"this turn ended\", "
                + "so a Hermes key never turns green.",
        ],
        setup: .manual(
            path: "~/.hermes/config.yaml",
            snippet: """
            hooks:
              on_session_start:
                - command: "OPENBOARD --harness hermes"
              pre_tool_call:
                - command: "OPENBOARD --harness hermes"
              post_tool_call:
                - command: "OPENBOARD --harness hermes"
              pre_approval_request:
                - command: "OPENBOARD --harness hermes"
              post_approval_response:
                - command: "OPENBOARD --harness hermes"
              on_session_end:
                - command: "OPENBOARD --harness hermes"
            """
        )
    )

    /**
     Pi, the coding agent harness.

     The one that does not fit, and the pane says so. Pi has **no out-of-process hook
     mechanism** — its extensions are in-process TypeScript, loaded from
     `~/.pi/agent/extensions/`. There is no command for OpenBoard to install into a
     config file, because there is no config file that runs commands.

     What there is instead is an extension that forwards the same JSON to the same
     socket. Twelve lines, shipped as text to paste rather than a file written into
     somebody's extension directory by a keyboard app.

     Its event names are its own — `turn_end` is what Claude calls `Stop` — and unlike
     Hermes it does have one, so a Pi session shows green.
     */
    public static let pi = Harness(
        id: "pi",
        name: "Pi",
        isSupported: true,
        settingsPath: "~/.pi/agent/extensions/",
        entrypointVariable: nil,
        entrypoints: [],
        events: [
            ("session_start", nil),
            ("agent_start", nil),
            ("turn_start", nil),
            ("turn_end", nil),
            ("session_shutdown", nil),
        ],
        surfaces: [
            Surface(
                id: "terminal",
                name: "Terminal",
                detection: "`session_id` and `cwd`, forwarded by the extension.",
                jump: "The owning process's tty, when the session was started from one."
            ),
            Surface(
                id: "sdk",
                name: "Embedded and RPC modes",
                detection: "—",
                jump: "—",
                unsupported: "Pi embeds in other apps. Those sessions are not something "
                    + "a key can raise."
            ),
        ],
        limitations: [
            "No approval event is documented, so a Pi key never turns orange — the one "
                + "state this board exists for.",
            "In-process extensions only, so setup is a file you add rather than a "
                + "command OpenBoard can install.",
        ],
        setup: .manual(
            path: "~/.pi/agent/extensions/openboard.ts",
            snippet: """
            import { spawn } from "node:child_process";

            const send = (name: string, ctx: any) =>
              spawn("OPENBOARD", ["--harness", "pi", "--event", name], { stdio: ["pipe"] })
                .stdin.end(JSON.stringify({
                  hook_event_name: name,
                  session_id: ctx?.sessionId,
                  cwd: process.cwd(),
                }));

            export default (pi: any) => {
              for (const name of [
                "session_start", "agent_start", "turn_start", "turn_end", "session_shutdown",
              ]) {
                pi.on(name, (ctx: any) => send(name, ctx));
              }
            };
            """
        )
    )

    /// Every harness the app knows about.
    public static let all: [Harness] = [.claudeCode, .hermes, .pi]

}
