import Foundation

/**
 The one line in `~/.claude/keybindings.json` that makes the ⌃Y voice chord work.

 The `voiceChord` preference switches the voice key from tapping space to tapping
 ⌃Y — but ⌃Y does nothing until Claude Code binds it to `voice:pushToTalk`. That
 failure is silent in the worst way: the key types nothing (the whole point) and
 also *does* nothing, which reads as a dead key rather than a missing binding.

 Follows `HookInstall`'s discipline exactly, and for the same reason: this file
 belongs to the user and affects every Claude Code session on the machine. `audit`
 is read-only and runs freely; `install` writes only from an explicit button press,
 backs up first, and touches nothing but its own entry. A chord the user already
 bound to something else is reported, never overwritten.
 */
public enum KeybindingInstall {
    public static let chord = "ctrl+y"
    public static let action = "voice:pushToTalk"
    public static let context = "Chat"

    public enum Status: Equatable, Sendable {
        case ok
        case missing
        /// The chord is bound, but to someone else's action. Overwriting it would
        /// trade our silent failure for breaking a binding the user chose.
        case conflict(String)

        public var isHealthy: Bool { self == .ok }
    }

    public struct Audit: Equatable, Sendable {
        public let status: Status
        public let fileExists: Bool

        public init(status: Status, fileExists: Bool) {
            self.status = status
            self.fileExists = fileExists
        }

        /// A missing file is not unhealthy — install creates it.
        public var isHealthy: Bool { status.isHealthy }
    }

    public static func url(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = env["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("keybindings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/keybindings.json")
    }

    public static func load(url: URL? = nil) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url ?? self.url()) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func audit(document: [String: Any]?) -> Audit {
        guard let document else {
            return Audit(status: .missing, fileExists: false)
        }
        // Later entries win when a context appears twice, so the last value of the
        // chord across every Chat block is the one Claude Code acts on.
        var bound: String?
        for block in contextBlocks(in: document) {
            if let value = block[chord] as? String { bound = value }
        }
        switch bound {
        case nil: return Audit(status: .missing, fileExists: true)
        case action: return Audit(status: .ok, fileExists: true)
        case let other?: return Audit(status: .conflict(other), fileExists: true)
        }
    }

    private static func contextBlocks(in document: [String: Any]) -> [[String: Any]] {
        let bindings = document["bindings"] as? [[String: Any]] ?? []
        return bindings
            .filter { $0["context"] as? String == context }
            .compactMap { $0["bindings"] as? [String: Any] }
    }

    /**
     The document with the chord bound, everything else untouched.

     The chord lands in the *last* Chat block so it wins over any earlier one, or in
     a fresh Chat block when none exists. A brand-new document gets the `$schema`
     and `$docs` fields the file format asks for.
     */
    public static func wiring(into document: [String: Any]) -> [String: Any] {
        var result = document
        if result.isEmpty {
            result["$schema"] = "https://www.schemastore.org/claude-code-keybindings.json"
            result["$docs"] = "https://code.claude.com/docs/en/keybindings"
        }
        var blocks = result["bindings"] as? [[String: Any]] ?? []

        if let index = blocks.lastIndex(where: { $0["context"] as? String == context }) {
            var bindings = blocks[index]["bindings"] as? [String: Any] ?? [:]
            bindings[chord] = action
            blocks[index]["bindings"] = bindings
        } else {
            blocks.append(["context": context, "bindings": [chord: action]])
        }
        result["bindings"] = blocks
        return result
    }

    public enum InstallError: Error, LocalizedError {
        case unreadable
        case conflict(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                "keybindings.json could not be read as JSON — refusing to overwrite it."
            case .conflict(let action):
                "⌃Y is already bound to \(action) — not overwriting a binding you chose."
            }
        }
    }

    /// Write the binding, after backing up. Only ever called from an explicit
    /// button press, and never when the chord already means something else.
    @discardableResult
    public static func install(url: URL? = nil) throws -> URL {
        let target = url ?? self.url()
        var existing: [String: Any] = [:]

        if let data = try? Data(contentsOf: target), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { throw InstallError.unreadable }
            existing = parsed

            if case .conflict(let other) = audit(document: parsed).status {
                throw InstallError.conflict(other)
            }

            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = target.deletingLastPathComponent()
                .appendingPathComponent("keybindings.backup-\(stamp).json")
            try? data.write(to: backup)
        }

        let updated = wiring(into: existing)
        let data = try JSONSerialization.data(
            withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: target, options: [.atomic])
        return target
    }
}
