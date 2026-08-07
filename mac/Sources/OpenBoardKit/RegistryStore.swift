import Foundation

/**
 The board, across restarts.

 Without this, quitting the app forgets which session owns which key. On the next
 launch every session that is still running gets a *different* slot — so the muscle
 memory of "my main project is key 2" is wrong, and the one thing a physical board is
 for is gone.

 ## What is deliberately not trusted on load

 A stored entry is a claim about the world made at some point in the past, and the app
 may have been closed for a week. Every entry is re-validated against the live process
 table before it is allowed back onto the board:

 - a **dead pid** is dropped — its key is free
 - an entry **older than the stale window** is dropped, even if the pid looks alive,
   because pids are reused and a matching one after a reboot is coincidence
 - a **turn in progress** does not survive: `working` from a previous run means a turn
   that can no longer be running

`done` and the attention states *are* restored. A completion nobody has been back to is
still unseen, and the app restarting says nothing about whether you saw it.

 Restoring a lie is worse than restoring nothing. The board's whole value is that it
 can be trusted at a glance.
 */
public struct RegistryStore: Sendable {
    public init() {}

    public static func url(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        Calibration.defaultStateDirectory(env: env).appendingPathComponent("registry.json")
    }

    /// The on-disk shape. Matches `lib/registry.cjs` field names so a registry written
    /// by either implementation is readable by the other.
    private struct Document: Codable {
        var version: Int
        var cursor: Int
        var entries: [StoredEntry]
    }

    private struct StoredEntry: Codable {
        var slot: Int
        var sessionID: String
        var cwd: String?
        var pid: Int?
        var tty: String?
        var transcriptPath: String?
        var entrypoint: String?
        var host: String?
        var state: String
        var claimSeq: Int
        var claimedAt: Date
        var updatedAt: Date
    }

    // MARK: - reading

    /**
     Load the board, dropping everything that cannot still be true.

     - Parameter isAlive: injected so the reclaim rules are testable without spawning
       processes or depending on what happens to be running.
     */
    public static func load(
        url target: URL? = nil,
        staleInterval: TimeInterval = 12 * 3600,
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> SessionRegistry {
        var registry = SessionRegistry()
        guard let data = try? Data(contentsOf: target ?? url()) else { return registry }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A corrupt registry must not wedge the app. The cost of starting empty is one
        // relearned board; the cost of refusing to start is the whole product.
        guard let document = try? decoder.decode(Document.self, from: data) else {
            return registry
        }

        var restored: [SessionRegistry.Entry] = []
        for stored in document.entries {
            guard let state = SessionState(rawValue: stored.state) else { continue }
            // A pid that is gone means the session is gone, whatever the file says.
            guard isAlive(stored.pid) else { continue }
            // Pids are reused. A live pid on a week-old entry is coincidence, not the
            // same session, and restoring it would put a stranger on your board.
            guard now.timeIntervalSince(stored.updatedAt) < staleInterval else { continue }

            restored.append(SessionRegistry.Entry(
                slot: stored.slot,
                sessionID: stored.sessionID,
                cwd: stored.cwd,
                pid: stored.pid,
                tty: stored.tty,
                transcriptPath: stored.transcriptPath,
                entrypoint: stored.entrypoint,
                host: stored.host.flatMap(ProcessAncestry.Host.init(rawValue:)) ?? .unknown,
                state: settled(state, transcriptPath: stored.transcriptPath),
                pendingTool: nil,
                claimSeq: stored.claimSeq,
                claimedAt: stored.claimedAt,
                updatedAt: stored.updatedAt
            ))
        }

        registry.entries = restored
        registry.restoreCursor(max(document.cursor, restored.map(\.claimSeq).max() ?? 0))
        return registry
    }

    /**
     What a restored state becomes.

     `viewing` is decided live from focus, so it is never restored.

     `done` and the attention states are kept. A completion nobody has been back to is
     still unseen, and a session blocked on a prompt very likely still is; the app being
     relaunched says nothing about either. Wrongly clearing them is the error this board
     must never make, and the stale window already drops anything genuinely old.

     **`working` is asked, not assumed.** It used to settle to `idle`, on the reasoning
     that nothing was happening while the app was closed. That is true of the app and
     false of the session — Claude Code kept running the whole time, and the app is only
     a light — so every session mid-turn during a relaunch came back claiming nothing
     was happening. Its own transcript says which it was, so that is what decides it.

     With no transcript to read, the old behaviour stands. An unanswerable question is
     not a licence to claim a turn is running.
     */
    public static func settled(
        _ state: SessionState,
        transcriptPath: String? = nil
    ) -> SessionState {
        switch state {
        case .viewing: return .idle
        case .working: return TurnState.isWorking(transcriptPath: transcriptPath) == true
            ? .working
            : .idle
        case .done, .awaiting, .stalled, .error, .idle, .ended: return state
        }
    }

    // MARK: - writing

    /// Persist the board. Atomic, mode 0600, and never fatal — losing the file costs
    /// one relearned board, and there is nothing useful to do about a failed write.
    public static func save(_ registry: SessionRegistry, url target: URL? = nil) {
        let destination = target ?? url()
        let document = Document(
            version: 1,
            cursor: registry.cursor,
            entries: registry.entries.map { entry in
                StoredEntry(
                    slot: entry.slot,
                    sessionID: entry.sessionID,
                    cwd: entry.cwd,
                    pid: entry.pid,
                    tty: entry.tty,
                    transcriptPath: entry.transcriptPath,
                    entrypoint: entry.entrypoint,
                    host: entry.host == .unknown ? nil : entry.host.rawValue,
                    state: entry.state.rawValue,
                    claimSeq: entry.claimSeq,
                    claimedAt: entry.claimedAt,
                    updatedAt: entry.updatedAt
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(document) else { return }

        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: destination, options: [.atomic])
        // An atomic write replaces the inode, so the mode is reapplied every time.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path
        )
    }
}
