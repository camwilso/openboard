import Foundation

/**
 Where Claude Code's hooks report to.

 A Unix domain socket at `~/.claude/openboard/hook.sock`, one JSON object per
 connection. Chosen over a TCP port for three reasons that all matter here: it cannot
 be reached from off-host at all (the Node version needed an explicit non-local `Host`
 rejection to get the same property), it is protected by ordinary filesystem
 permissions, and it cannot collide with whatever else is listening on 4455.

 ## Why the hooks do not talk to this directly

 A Claude Code hook is a shell command. It cannot open a socket on its own, so a tiny
 helper still stands between them — but the helper does nothing except forward stdin
 and exit, which means `hooks/install.cjs` only ever needs its target path changed.

 That indirection buys something real: hooks run *inline with the session*, so
 anything slow or wedged there is felt by the user as a stalled prompt. A helper that
 writes to a socket and exits cannot block on device I/O, a write lock, or a pad that
 has gone to sleep. The Node version ran the whole registry update and a device
 repaint inside the hook.

 ## Fail-open, always

 Every path here is best-effort. A status light must never be able to break a
 session — if the app is not running, the socket is not there, or the payload is
 malformed, the helper exits 0 and the session carries on unaware.
 */
public actor HookServer {
    public struct Event: Sendable {
        public let name: String
        public let sessionID: String?
        public let cwd: String?
        public let transcriptPath: String?
        public let entrypoint: String?
        public let toolName: String?
        public let source: String?
        public let matcher: String?
        /// Which agent sent this, named by the hook command. Nil means Claude Code —
        /// every settings.json written before harnesses existed omits it.
        public let harness: String?
        /// The pid of the process that spawned the hook helper — its parent, so
        /// usually a shell (`sh -c "openboard-hook …"`) or the `claude` binary
        /// itself. The app walks up from here to find the `claude` ancestor's
        /// pid + tty, which is the only reliable way to jump-to-slot on a
        /// running-but-adopted session. Claude Code does not export CLAUDE_PID.
        public let hookPPID: Int?
        /**
         The original payload, kept as bytes.

         `[String: Any]` is not Sendable and this crosses actor boundaries, so the
         dictionary is decoded on demand rather than stored. Lossless either way, and
         it keeps every field the rules have not learned about yet available instead
         of silently dropping them at the door.
         */
        public let rawJSON: Data
        private let agentIDValue: String?
        private let agentTypeValue: String?
        private let envValue: [String: String]

        /// The payload as a dictionary. Decoded per call; only used off hot paths.
        public var raw: [String: Any] {
            ((try? JSONSerialization.jsonObject(with: rawJSON)) as? [String: Any]) ?? [:]
        }

        public init(raw: [String: Any]) {
            self.rawJSON = (try? JSONSerialization.data(withJSONObject: raw)) ?? Data()
            self.agentIDValue = raw["agent_id"] as? String
            self.agentTypeValue = raw["agent_type"] as? String
            self.envValue = (raw["env"] as? [String: String]) ?? [:]
            self.name = (raw["hook_event_name"] as? String) ?? ""
            self.sessionID = raw["session_id"] as? String
            self.cwd = raw["cwd"] as? String
            self.transcriptPath = raw["transcript_path"] as? String
            self.entrypoint = raw["entrypoint"] as? String
            self.toolName = raw["tool_name"] as? String
            self.source = raw["source"] as? String
            // Notification subtype: permission_prompt, idle_prompt, and friends.
            self.matcher = (raw["matcher"] as? String) ?? (raw["notification_type"] as? String)
            self.harness = raw["harness"] as? String
            // JSONSerialization gives back NSNumber for numeric JSON — try both int
            // and string forms so a future change to how the helper serialises it
            // does not silently blank this field.
            self.hookPPID = (raw["hook_ppid"] as? Int)
                ?? (raw["hook_ppid"] as? NSNumber)?.intValue
                ?? (raw["hook_ppid"] as? String).flatMap(Int.init)
        }

        /// The subset eligibility cares about.
        public var eligibilityPayload: Eligibility.Payload {
            Eligibility.Payload(
                sessionID: sessionID,
                agentID: agentIDValue,
                agentType: agentTypeValue
            )
        }

        /// Hooks inherit the session's environment, and the helper forwards the
        /// handful of variables the rules depend on. Without these, eligibility
        /// cannot tell a human session from a subagent.
        public var environment: [String: String] { envValue }
    }

    public typealias Handler = @Sendable (Event) async -> Void

    private let url: URL
    private var listener: Int32 = -1
    private var handler: Handler?
    private var running = false

    public init(url: URL? = nil) {
        self.url = url ?? AppPaths.socket()
    }

    public var socketPath: String { url.path }

    public func start(handler: @escaping Handler) throws {
        guard !running else { return }
        self.handler = handler

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // A socket file left behind by a crash makes bind() fail with EADDRINUSE
        // forever. Removing it is safe: if another instance is genuinely listening,
        // the bind below is what will fail, not this.
        try? FileManager.default.removeItem(at: url)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HookError.cannotListen(String(cString: strerror(errno))) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw HookError.pathTooLong(url.path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0 else {
            close(listener)
            listener = -1
            throw HookError.cannotListen(String(cString: strerror(errno)))
        }

        // Only this user may report events; the socket can run shell-visible actions
        // downstream, so it is 0600 rather than world-writable.
        chmod(url.path, 0o600)
        guard listen(listener, 32) == 0 else {
            close(listener)
            listener = -1
            throw HookError.cannotListen(String(cString: strerror(errno)))
        }

        running = true
        Task.detached { [listener, weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    // The listener was closed underneath us: that is a stop, not a fault.
                    if errno == EBADF || errno == EINVAL { return }
                    continue
                }
                await self?.serve(client)
            }
        }
    }

    private func serve(_ client: Int32) async {
        defer { close(client) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            // A hook payload is small. Anything past this is not one, and reading it
            // would let a runaway writer exhaust memory.
            if data.count > 1_000_000 { return }
        }

        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        await handler?(Event(raw: object))
    }

    public func stop() {
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        running = false
        try? FileManager.default.removeItem(at: url)
    }

    public enum HookError: Error, LocalizedError {
        case cannotListen(String)
        case pathTooLong(String)

        public var errorDescription: String? {
            switch self {
            case let .cannotListen(detail): "could not listen on the hook socket: \(detail)"
            case let .pathTooLong(path): "socket path is too long for sockaddr_un: \(path)"
            }
        }
    }
}
