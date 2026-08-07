import Foundation

/**
 The wiring in `~/.claude/settings.json` that makes any of this happen.

 Without a hook entry per event the board simply never hears about a session. That
 failure is completely silent — the app runs, the pad connects, nothing ever lights —
 so this audits the wiring and names the specific event that is missing.

 ## Why this only ever reads, unless told otherwise

 `settings.json` affects *every* Claude Code session on the machine, not just this app.
 So `audit` is read-only and runs freely; `install` writes only when a person presses
 the button, and takes a timestamped backup first. Nothing here writes on launch.

 ## The failure this exists to catch

 A hook command is an absolute path to a binary inside the app bundle. Move, rename or
 reinstall the app and every hook still *looks* configured while silently failing —
 Claude Code does not report a hook that will not execute. `.stalePath` is that case,
 and it is the reason the audit checks the file exists rather than just comparing text.
 */
public enum HookInstall {
    /**
     Hooks in the schema that are deliberately **not** wired, and why.

     Carried across from `hooks/settings-block.json` in the retired Node repo, where it
     was the only record. Without it the next person to read Claude Code's hook list
     sees an obviously relevant event, wires it up, and re-derives the same dead end.

     - `PermissionDenied`: exists in the schema and was traced across many real
       rejections without firing once. Rejections are observed through the *absence* of
       an approval instead — `PostToolUse` arriving is what proves a prompt was answered.
     */
    public static let deliberatelyUnwired = ["PermissionDenied"]

    /// The events the board needs, and the matcher each carries.
    /// `Notification`'s matcher is a filter: without it every subtype fires a hook,
    /// including ones that map to no state at all.
    public static let events: [(name: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("Notification", "permission_prompt|agent_needs_input|idle_prompt"),
        ("Stop", nil),
        ("SessionEnd", nil),
        ("PostToolUse", nil),
        ("PostToolUseFailure", nil),
        ("PermissionRequest", nil),
    ]

    public enum EventStatus: Equatable, Sendable {
        case ok
        case missing
        /// Wired, but to a binary that is not there any more.
        case stalePath(String)
        /// Wired to a different OpenBoard binary than this build uses.
        case otherPath(String)

        public var isHealthy: Bool { self == .ok }
    }

    public struct Audit: Equatable, Sendable {
        public let statuses: [String: EventStatus]
        public let settingsExists: Bool

        public init(statuses: [String: EventStatus], settingsExists: Bool) {
            self.statuses = statuses
            self.settingsExists = settingsExists
        }

        public var isHealthy: Bool {
            settingsExists && statuses.values.allSatisfy(\.isHealthy)
        }

        public var problems: [String] {
            statuses
                .filter { !$0.value.isHealthy }
                .keys.sorted()
        }
    }

    /// The hook binary that ships beside the running app.
    public static func hookCommandPath(bundlePath: String? = nil) -> String {
        if let bundlePath {
            return bundlePath + "/Contents/MacOS/openboard-hook"
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/openboard-hook").path
    }

    public static func settingsURL(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = env["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /**
     Check the wiring without touching it.

     - Parameter fileExists: injected so the audit stays testable — the stale-path case
       is the whole point and cannot be exercised against a real bundle.
     */
    public static func audit(
        settings: [String: Any]?,
        expectedCommand: String,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Audit {
        guard let settings else {
            return Audit(
                statuses: Dictionary(uniqueKeysWithValues: events.map { ($0.name, .missing) }),
                settingsExists: false
            )
        }
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var statuses: [String: EventStatus] = [:]

        for event in events {
            let commands = commandStrings(in: hooks[event.name])
            // Any OpenBoard hook counts as "wired" — matching on the whole command
            // would report a false miss the moment a flag changes.
            guard let found = commands.first(where: { $0.contains("openboard-hook") }) else {
                statuses[event.name] = .missing
                continue
            }
            let binary = executablePath(from: found)
            if binary == expectedCommand {
                statuses[event.name] = .ok
            } else if !fileExists(binary) {
                statuses[event.name] = .stalePath(binary)
            } else {
                statuses[event.name] = .otherPath(binary)
            }
        }
        return Audit(statuses: statuses, settingsExists: true)
    }

    /// Pull every `command` string out of one event's hook groups.
    private static func commandStrings(in node: Any?) -> [String] {
        guard let groups = node as? [[String: Any]] else { return [] }
        return groups.flatMap { group -> [String] in
            let hooks = group["hooks"] as? [[String: Any]] ?? []
            return hooks.compactMap { $0["command"] as? String }
        }
    }

    /// The binary out of `"/path/to/openboard-hook --event Stop"`. Split on the first
    /// ` --` so a path containing spaces survives, which `/Applications` paths do.
    public static func executablePath(from command: String) -> String {
        guard let range = command.range(of: " --") else {
            return command.trimmingCharacters(in: .whitespaces)
        }
        return String(command[command.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
    }

    /**
     The settings document with this build's hooks wired in.

     Returns a *new* dictionary — every unrelated key is preserved untouched, because
     this file holds the user's own configuration for every session on the machine.
     Only OpenBoard's own entries are replaced.
     */
    public static func wiring(
        into settings: [String: Any],
        command: String
    ) -> [String: Any] {
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in events {
            // Preserve any non-OpenBoard hook groups on this event; someone else's
            // tooling may share it, and dropping their entry would break their setup.
            let existing = (hooks[event.name] as? [[String: Any]] ?? []).filter { group in
                let commands = (group["hooks"] as? [[String: Any]] ?? [])
                    .compactMap { $0["command"] as? String }
                return !commands.contains { $0.contains("openboard-hook") }
            }

            var group: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": "\(command) --event \(event.name)",
                    // 5s is generous for a socket write; the hook is fail-open anyway.
                    "timeout": 5,
                    // Never make a person wait on the lights.
                    "async": true,
                ]]
            ]
            if let matcher = event.matcher { group["matcher"] = matcher }
            hooks[event.name] = existing + [group]
        }

        result["hooks"] = hooks
        return result
    }

    public enum InstallError: Error, LocalizedError {
        case unreadable
        public var errorDescription: String? {
            "settings.json could not be read as JSON — refusing to overwrite it."
        }
    }

    /**
     Write the wiring, after backing up.

     Only ever called from an explicit button press. The backup is not optional: this
     file is not ours, and a bug here costs someone every hook they have configured.
     */
    @discardableResult
    public static func install(
        command: String,
        url: URL? = nil
    ) throws -> URL {
        let target = url ?? settingsURL()
        var existing: [String: Any] = [:]

        if let data = try? Data(contentsOf: target), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { throw InstallError.unreadable }
            existing = parsed

            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = target.deletingLastPathComponent()
                .appendingPathComponent("settings.backup-\(stamp).json")
            try? data.write(to: backup)
        }

        let updated = wiring(into: existing, command: command)
        let data = try JSONSerialization.data(
            withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: target, options: [.atomic])
        return target
    }

    public static func loadSettings(url: URL? = nil) -> [String: Any]? {
        let target = url ?? settingsURL()
        guard let data = try? Data(contentsOf: target) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
