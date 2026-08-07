import Foundation

/**
 Where this app keeps things.

 Everything used to live in `~/.claude/openboard/` — the path the Node version wrote,
 chosen so an existing configuration was picked up unchanged. That was right while this
 was a personal tool sitting beside the Claude Code state it watches. It is wrong for
 something other people install:

 - **It is Anthropic's directory, not ours.** Putting user data in another vendor's
   config folder means it is not obviously yours to uninstall, and a reorganisation of
   `~/.claude/` could take a user's settings with it.
 - **One folder was doing four jobs** — preferences, hardware calibration, runtime
   state, logs, and an IPC socket — each of which macOS has a different convention for.

 So:

 | What | Where |
 |---|---|
 | `config.json`, `calibration.json`, `registry.json`, `hook.sock` | `~/Library/Application Support/OpenBoard/` |
 | `app.log` | `~/Library/Logs/OpenBoard/` |

 Logs are split out because `~/Library/Logs` is where Console.app looks and where "send
 me your logs" already points. Asking someone to open a dotfile directory to file a bug
 report is a worse first impression than it sounds.

 `OPENBOARD_HOME` still overrides everything, and still collapses both directories into
 one, so a test or a scratch run stays entirely self-contained.

 ## Not Application Support alone

 The socket lives here too rather than in a temp directory. A `sockaddr_un` path is
 limited to 104 bytes; this one is about 60, with room to spare, and a fixed location
 means the hook helper can find it without being told.
 */
public enum AppPaths {
    /// The folder name, used under both Application Support and Logs.
    public static let folder = "OpenBoard"

    /// Preferences, calibration, registry, socket.
    public static func state(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = overrideDirectory(env: env) { return override }
        // `.applicationSupportDirectory` resolves to the container when sandboxed and
        // to ~/Library/Application Support otherwise. This app can never be sandboxed —
        // it needs Input Monitoring, Accessibility, raw HID and Apple Events — but
        // asking the API is still better than assembling the path by hand.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folder)
    }

    /// `app.log`. Separate from state so it can be thrown away without losing settings.
    public static func logs(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = overrideDirectory(env: env) { return override }
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/\(folder)")
    }

    /// The fun mode library: one subfolder per video, each holding the video file and
    /// the `analysis.json` that drives the lights. Kept out of the repo and out of the
    /// bundle — a video is ~90MB and belongs to whoever downloaded it, not to the app.
    public static func media(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        state(env: env).appendingPathComponent("Media")
    }

    /// Created empty at launch. A folder you can be told to drop a video into is a
    /// place; a path in a README that does not exist yet is an instruction to guess.
    @discardableResult
    public static func ensureMedia(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let url = media(env: env)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The video folders inside the library, by name. Files and dotfiles are skipped:
    /// only a directory can hold both halves of a video.
    public static func mediaLibrary(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let root = media(env: env)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// Where everything used to be. Still read, so an existing install keeps working
    /// until it is migrated — and so the hook helper can fall back to it.
    public static func legacyState(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = overrideDirectory(env: env) { return override }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/openboard")
    }

    public static func socket(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        state(env: env).appendingPathComponent("hook.sock")
    }

    private static func overrideDirectory(env: [String: String]) -> URL? {
        guard let override = env["OPENBOARD_HOME"], !override.isEmpty else { return nil }
        return URL(fileURLWithPath: override)
    }

    /**
     Move an existing installation across, once.

     Only the files this app actually owns. The old directory also holds Node-era
     leftovers — `watch.log`, `keys.log`, `probe.jsonl` — and sweeping up things whose
     purpose is not understood is how a migration destroys something.

     Moves rather than copies. Two copies of a settings file is the worse failure: you
     edit one, the app reads the other, and nothing you change appears to take. The old
     directory itself is left in place, because it is Claude Code's and may hold state
     that is none of our business.

     Idempotent by construction — a file already at the destination is never
     overwritten, so this is safe to call on every launch, and safe if it half-finished
     last time.
     */
    @discardableResult
    public static func migrateIfNeeded(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        // With the override set there is only one directory and nothing to move.
        guard overrideDirectory(env: env) == nil else { return [] }
        return migrate(from: legacyState(env: env), state: state(env: env), logs: logs(env: env))
    }

    /// The move itself, with the three directories given rather than derived.
    ///
    /// Injectable so it can be tested against scratch directories: a test that ran the
    /// real thing would migrate the machine it runs on, which is both a side effect and
    /// a single-use test — the second run would find nothing left to move.
    @discardableResult
    public static func migrate(from old: URL, state: URL, logs: URL) -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.path) else { return [] }

        var moved: [String] = []
        let plan: [(name: String, destination: URL)] = [
            ("config.json", state),
            ("calibration.json", state),
            ("registry.json", state),
            ("app.log", logs),
        ]

        for (name, directory) in plan {
            let source = old.appendingPathComponent(name)
            let target = directory.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path),
                  !manager.fileExists(atPath: target.path) else { continue }
            try? manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            do {
                try manager.moveItem(at: source, to: target)
                moved.append(name)
            } catch {
                // A move can fail across volumes even though a copy would work. Falling
                // back keeps the settings; the original is then removed so there is
                // still only one live copy.
                if (try? manager.copyItem(at: source, to: target)) != nil {
                    try? manager.removeItem(at: source)
                    moved.append(name)
                }
            }
        }
        return moved
    }
}
