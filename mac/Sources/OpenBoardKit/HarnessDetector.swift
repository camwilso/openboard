import Foundation

/**
 Which coding harnesses are actually on this Mac.

 The sidebar used to show Claude Code as connected whether or not it was there,
 because "connected" meant "OpenBoard supports this" rather than "this exists". Those
 are different claims and only one of them is checkable.

 ## Every row is a probe that ran

 A harness appears here only if there is something specific to look for: a config
 directory it creates on first run, an app bundle, a binary on the path. A row we cannot
 probe would sit permanently grey, which reads as *absent* while meaning *unknown* —
 the same class of lie as a red dot for a sleeping pad.

 That is why this is three rather than the fifty-nine CodexBar draws icons for: a
 harness earns a row by being one OpenBoard can drive, and everything else was a list
 of things it cannot.

 ## Cheap enough to run on appearance

 Every probe is a `stat` or two. No subprocesses, no `which`, nothing that shells out —
 the pane calls this when it opens and the cost is invisible. `PATH` is searched
 directly rather than by running a shell, because spawning one per harness to answer a
 question about the filesystem is how a settings pane starts taking a second to open.
 */
public enum HarnessDetector {
    public struct Agent: Sendable, Identifiable, Equatable {
        public let id: String
        public let name: String
        /// The harness this is. Optional only because a future entry might be
        /// detectable before it is drivable; every current one has it.
        public let harnessID: String?
        /// Directories it creates, relative to home.
        public let homePaths: [String]
        /// Application bundle names, resolved against the applications directory
        /// rather than hardcoded to `/Applications`. Absolute paths made the probe
        /// untestable: an "empty machine" fixture could not hide a real ChatGPT.app,
        /// so the one test that matters — absent reads as absent — could not run.
        public let bundles: [String]
        /// Command names to look for on `PATH`.
        public let commands: [String]

        public init(
            id: String,
            name: String,
            harnessID: String? = nil,
            homePaths: [String] = [],
            bundles: [String] = [],
            commands: [String] = []
        ) {
            self.id = id
            self.name = name
            self.harnessID = harnessID
            self.homePaths = homePaths
            self.bundles = bundles
            self.commands = commands
        }
    }

    /**
     The three, in sidebar order.

     It listed ten more for a while — Codex, Cursor, Zed and the rest — under a heading
     that told you what OpenBoard *cannot* light. That was a screenful of grey rows
     answering a question nobody asked while opening this pane, and ten filesystem
     probes on every appearance to produce it. The heading went, and these probes went
     with it: a detector for harnesses, which is what the name says.
     */
    public static let known: [Agent] = [
        Agent(
            id: "claude", name: "Claude Code", harnessID: "claude-code",
            homePaths: [".claude"], commands: ["claude"]
        ),
        Agent(
            id: "hermes", name: "Hermes Agent", harnessID: "hermes",
            homePaths: [".hermes"], commands: ["hermes"]
        ),
        Agent(
            id: "pi", name: "Pi", harnessID: "pi",
            homePaths: [".pi"], commands: ["pi"]
        ),
    ]

    /**
     Where a CLI is likely to be, beyond `PATH`.

     A parameter rather than a constant inside the search, because baked in it made the
     probe untestable: an "empty machine" fixture could set `PATH` to nothing and still
     find the real `claude` in `/opt/homebrew/bin`, so the one test that matters — that
     absent reads as absent — quietly could not fail.

     Needed in production all the same. A GUI app inherits launchd's minimal `PATH`, not
     the login shell's, so a CLI installed by Homebrew or npm is invisible without this.
     */
    public static let defaultPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// Whether this agent left something on disk. Nil is not possible here — the
    /// question is answerable for every entry, which is the entry criterion.
    public static func isInstalled(
        _ agent: Agent,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applications: URL = URL(fileURLWithPath: "/Applications"),
        env: [String: String] = ProcessInfo.processInfo.environment,
        extraPaths: [String] = defaultPaths
    ) -> Bool {
        let manager = FileManager.default
        for relative in agent.homePaths
        where manager.fileExists(atPath: home.appendingPathComponent(relative).path) {
            return true
        }
        for bundle in agent.bundles {
            // Both roots: an app installed for one user lives in ~/Applications and is
            // just as installed as one in /Applications.
            if manager.fileExists(atPath: applications.appendingPathComponent(bundle).path) {
                return true
            }
            if manager.fileExists(
                atPath: home.appendingPathComponent("Applications/" + bundle).path
            ) {
                return true
            }
        }
        guard !agent.commands.isEmpty else { return false }

        /*
         `PATH` read directly, not `which`.

         A settings pane that opens thirteen shells to ask thirteen filesystem questions
         is a settings pane that takes a second to open. The default is what a GUI app
         inherits from launchd, which is *not* the user's login shell path — so the
         usual install locations are added, since a CLI installed by Homebrew or npm is
         invisible otherwise.
        */
        var directories = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += extraPaths
        directories += [
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".npm-global/bin").path,
        ]
        for directory in Set(directories) {
            for command in agent.commands
            where manager.isExecutableFile(atPath: directory + "/" + command) {
                return true
            }
        }
        return false
    }

    /// Every agent, with its answer. One pass, for a pane that shows them as a list.
    public static func survey(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applications: URL = URL(fileURLWithPath: "/Applications"),
        env: [String: String] = ProcessInfo.processInfo.environment,
        extraPaths: [String] = defaultPaths
    ) -> [(agent: Agent, installed: Bool)] {
        known.map {
            (
                $0,
                isInstalled(
                    $0, home: home, applications: applications, env: env, extraPaths: extraPaths
                )
            )
        }
    }
}
