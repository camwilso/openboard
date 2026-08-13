import Foundation

/**
 Which session owns which of the six keys.

 Ported from `lib/registry.cjs`, rule for rule. Deliberately a value type with pure
 transitions: every decision here is testable without a device, a session, or a clock,
 and each of these rules exists because of a specific way the board once lied.

 **Ephemeral by design.** Nothing is persisted. The registry is rebuilt from hooks, so
 "Forget all sessions" is simply emptying it — and a stale entry can never outlive a
 restart, which is what the Node version's on-disk registry allowed.
 */
public struct SessionRegistry: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var slot: Int
        public var sessionID: String
        public var cwd: String?
        public var pid: Int?
        /// Captured at claim time, not looked up later: the process may be gone when
        /// we want to raise its tab, and `ps` cannot resolve a tty for a dead pid.
        public var tty: String?
        /// Kept so a finished session's chat can still be named.
        public var transcriptPath: String?
        public var entrypoint: String?
        /// Which app owns the terminal this runs in. Captured once, because `ps` is not
        /// free and the answer cannot change for a live process.
        public var host: ProcessAncestry.Host = .unknown
        public var state: SessionState
        /// Which tool is asking. The dialogs differ — an AskUserQuestion accepts
        /// Enter but ignores Escape — so "reject" is not universally possible and
        /// the caller needs to know rather than send a key into the void.
        public var pendingTool: String?
        /// Count of in-flight background subagents for this session. Not persisted
        /// (`RegistryStore.StoredEntry` omits it, same precedent as `pendingTool`) —
        /// on relaunch it starts at 0 and self-heals on the next `Stop`'s reconcile
        /// (`BoardController.handle`'s `Stop` branch). A resumed/forked CLI session can
        /// also leave the live counter briefly stale; same self-heal applies.
        public var delegatedCount: Int = 0
        public var claimSeq: Int
        public var claimedAt: Date
        public var updatedAt: Date

        public var id: String { sessionID }
    }

    /// `internal` setter, not `private`: Discovery extends this type from another
    /// file in the same module. Still closed to the app, which must go through the
    /// transitions rather than editing the board directly.
    public internal(set) var entries: [Entry] = []
    /// Monotonic, so "oldest claim" survives slots being reused.
    public private(set) var cursor = 0

    /// Restore the claim counter after loading from disk.
    ///
    /// Must never go backwards: `claimSeq` is what makes "oldest claim" meaningful, so
    /// a cursor behind the restored entries would hand the next session a sequence
    /// number that is already taken and make eviction pick the wrong key.
    mutating func restoreCursor(_ value: Int) {
        cursor = max(cursor, value)
    }
    public let slotCount: Int

    /// Silence long enough to assume a terminal was killed without SessionEnd firing.
    ///
    /// Configurable via `staleHours`; the default matches the Node version. Set on the
    /// instance rather than read globally so the pure transitions stay pure.
    public static let defaultStaleInterval: TimeInterval = 12 * 3600
    public var staleInterval: TimeInterval = SessionRegistry.defaultStaleInterval

    public init(slotCount: Int = BoardLayout.slotCount) {
        self.slotCount = slotCount
    }

    // MARK: - lookup

    public func entry(forSession id: String) -> Entry? {
        entries.first { $0.sessionID == id }
    }

    public func entry(forSlot slot: Int) -> Entry? {
        entries.first { $0.slot == slot }
    }

    /// All six slots in order, occupied or not.
    public func occupancy() -> [(slot: Int, entry: Entry?)] {
        (1...slotCount).map { ($0, entry(forSlot: $0)) }
    }

    // MARK: - liveness

    /// Does this pid still exist? `EPERM` counts as alive: the process is there, it
    /// just belongs to someone else.
    public static func processIsAlive(_ pid: Int?) -> Bool {
        guard let pid, pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /**
     A slot may be taken when its session has ended, its process is gone, or it has
     been silent long enough to assume a killed terminal.

     Liveness is checked independently of `SessionEnd` because that hook is not
     guaranteed to fire — closing a terminal window does not run it.
     */
    public func isReclaimable(
        _ entry: Entry,
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> Bool {
        if entry.state == .ended { return true }
        if !isAlive(entry.pid) { return true }
        return now.timeIntervalSince(entry.updatedAt) > staleInterval
    }

    // MARK: - claiming

    public enum ClaimMode: String, Sendable {
        case kept          // already bound; state updated in place
        case sameHost      // same tab, new session id
        case unused
        case reclaimed
        case evicted
        case noSlot        // every key is asking for something
    }

    public struct ClaimResult: Sendable {
        public let entry: Entry?
        public let mode: ClaimMode
    }

    /**
     Pick a slot for a brand-new session, in strict priority order:

     1. an unused slot number
     2. a reclaimable slot, oldest claim first
     3. forced eviction, oldest claim first — **never** a slot wanting attention

     Returns nil when every slot is occupied by a session asking for something. That
     is deliberate: fail dark rather than steal the light you need in order to see.
     */
    private func pickSlot(now: Date, isAlive: (Int?) -> Bool) -> (slot: Int, mode: ClaimMode)? {
        for slot in 1...slotCount where entry(forSlot: slot) == nil {
            return (slot, .unused)
        }

        let byAge = { (a: Entry, b: Entry) in a.claimSeq < b.claimSeq }

        if let oldest = entries
            .filter({ isReclaimable($0, now: now, isAlive: isAlive) })
            .sorted(by: byAge).first {
            return (oldest.slot, .reclaimed)
        }

        if let oldest = entries
            .filter({ !$0.state.isAttention })
            .sorted(by: byAge).first {
            return (oldest.slot, .evicted)
        }

        return nil
    }

    public mutating func claim(
        sessionID: String,
        cwd: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        transcriptPath: String? = nil,
        entrypoint: String? = nil,
        state: SessionState = .idle,
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> ClaimResult {
        // Already bound: keep the slot, refresh what may have moved. A resumed
        // session can live in a different tab than it started in.
        if let index = entries.firstIndex(where: { $0.sessionID == sessionID }) {
            entries[index].state = state
            entries[index].pid = pid ?? entries[index].pid
            entries[index].cwd = cwd ?? entries[index].cwd
            entries[index].tty = tty ?? entries[index].tty
            entries[index].transcriptPath = transcriptPath ?? entries[index].transcriptPath
            entries[index].updatedAt = now
            return ClaimResult(entry: entries[index], mode: .kept)
        }

        /*
         One tab, one key.

         `/clear` mints a fresh session_id inside the same process, and so can a
         resume. Without this a single tab burns another key every time and the board
         fills with dead entries for a window you never left.

         Only a genuinely finished or gone session's slot is reused — otherwise this
         would steal a key from a live session sharing the tty.
         */
        let sameHost = entries.first { candidate in
            candidate.sessionID != sessionID
                && ((tty != nil && candidate.tty == tty) || (pid != nil && candidate.pid == pid))
                && isReclaimable(candidate, now: now, isAlive: isAlive)
        }

        let pick: (slot: Int, mode: ClaimMode)
        if let sameHost {
            pick = (sameHost.slot, .sameHost)
        } else if let chosen = pickSlot(now: now, isAlive: isAlive) {
            pick = chosen
        } else {
            return ClaimResult(entry: nil, mode: .noSlot)
        }

        cursor += 1
        let entry = Entry(
            slot: pick.slot,
            sessionID: sessionID,
            cwd: cwd,
            pid: pid,
            tty: tty,
            transcriptPath: transcriptPath,
            entrypoint: entrypoint,
            state: state,
            pendingTool: nil,
            claimSeq: cursor,
            claimedAt: now,
            updatedAt: now
        )
        entries.removeAll { $0.slot == pick.slot }
        entries.append(entry)
        return ClaimResult(entry: entry, mode: pick.mode)
    }

    // MARK: - transitions

    /// Update an already-bound session. Never allocates — an unknown session is
    /// ignored rather than given a key, or every stray event would claim one.
    @discardableResult
    public mutating func setState(
        sessionID: String,
        to state: SessionState,
        pendingTool: String? = nil,
        now: Date = Date()
    ) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.sessionID == sessionID }) else {
            return nil
        }
        guard SessionState.mayReplace(entries[index].state, with: state) else {
            return entries[index]
        }
        entries[index].state = state
        if let pendingTool { entries[index].pendingTool = pendingTool }
        // Leaving an attention state means nothing is pending any more.
        if !state.isAttention { entries[index].pendingTool = nil }
        entries[index].updatedAt = now
        return entries[index]
    }

    @discardableResult
    public mutating func markEnded(sessionID: String, now: Date = Date()) -> Entry? {
        setState(sessionID: sessionID, to: .ended, now: now)
    }

    /// Increment or decrement `delegatedCount` for `SubagentStart`/`SubagentStop`.
    /// Never allocates — mirrors `setState`'s own rule: an unknown `sessionID` is
    /// ignored rather than given a key, so a subagent event can never claim a slot.
    /// Floored at 0 on decrement, protecting against duplicate `SubagentStop` delivery.
    @discardableResult
    public mutating func adjustDelegation(sessionID: String, event: String) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.sessionID == sessionID }) else {
            return nil
        }
        switch event {
        case "SubagentStart":
            entries[index].delegatedCount += 1
        case "SubagentStop":
            entries[index].delegatedCount = max(0, entries[index].delegatedCount - 1)
        default:
            break
        }
        return entries[index]
    }

    /// Authoritative reconcile of `delegatedCount`, called on every `Stop`. Replaces
    /// whatever the `SubagentStart`/`SubagentStop` carve-out's incremental counter
    /// produced — never trusted as a running total across `Stop`s (proven necessary by
    /// out-of-order-finish and non-head array removal). Never allocates, same rule as
    /// `setState`/`adjustDelegation`.
    @discardableResult
    public mutating func reconcileDelegation(sessionID: String, count: Int) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.sessionID == sessionID }) else {
            return nil
        }
        entries[index].delegatedCount = count
        return entries[index]
    }

    /// Drop entries whose process is gone. A dead session holding a key makes the
    /// board claim activity that does not exist — the exact failure this project is
    /// meant to avoid.
    @discardableResult
    public mutating func prune(
        now: Date = Date(),
        isAlive: (Int?) -> Bool = SessionRegistry.processIsAlive
    ) -> Int {
        let before = entries.count
        entries.removeAll { entry in
            entry.pid != nil && !isAlive(entry.pid)
        }
        return before - entries.count
    }

    /**
     Age transient states back to rest.

     ## `done` does not expire by default

     Green means *this finished and you have not been back yet*. It is cleared by
     returning to the session and sending something — `UserPromptSubmit` moves it to
     `working` — not by a timer.

     An earlier version aged it out after 90s on the reasoning that green stops meaning
     anything if it is permanent. That reasoning was wrong about which failure costs
     more: a session that finished while you were elsewhere is exactly the one you need
     to be told about, and a timer means the board quietly forgets it before you look.
     The result was finished work becoming invisible, which is the opposite of the job.
     Six keys is a small enough board that "several are green" is information, not noise.

     Set `doneDecaySeconds` above zero to bring the timer back.

     `awaiting` is held by default and expires only when asked to. The hooks already
     clear it the moment the prompt is answered — `PostToolUse` arriving *is* the answer
     — so the timer was a safety net for a prompt answered somewhere OpenBoard cannot
     see. That is rare enough to be a choice rather than a permanent quiet deadline, and
     it was expressed as a duration in minutes, which is the wrong question to ask
     someone: nobody knows how long they want to wait for a thing that should not happen.

     `holdAttention: false` brings the net back, at a fixed 15 minutes. There is no
     slider, because the number never earned one.
     */
    public static let attentionTimeout: TimeInterval = 900

    @discardableResult
    public mutating func decay(
        doneAfter: TimeInterval = 0,
        holdAttention: Bool = true,
        now: Date = Date()
    ) -> Int {
        var changed = 0
        for index in entries.indices {
            let age = now.timeIntervalSince(entries[index].updatedAt)
            switch entries[index].state {
            // Zero, or anything below it, means never — the key holds until you go back.
            case .done where doneAfter > 0 && age > doneAfter:
                entries[index].state = .idle
                changed += 1
            case .awaiting, .stalled:
                if !holdAttention, age > Self.attentionTimeout {
                    entries[index].state = .idle
                    entries[index].pendingTool = nil
                    changed += 1
                }
            default:
                break
            }
        }
        return changed
    }

    /**
     Fill in details the entry does not have yet.

     Only ever *adds*. An entry can reach the board without them — discovered from the
     process table, or restored from disk written before a field existed — and every
     later hook takes the ordinary state-change path, which never revisits them. So a
     session could stay permanently unnamed while hooks for it arrived normally.

     Existing values are never overwritten: a hook that omits a field must not blank
     what is already known, and a `cwd` captured at claim time is as good as a later one.
     */
    @discardableResult
    public mutating func enrich(
        sessionID: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        entrypoint: String? = nil,
        tty: String? = nil,
        pid: Int? = nil
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.sessionID == sessionID }) else {
            return false
        }
        var changed = false
        if entries[index].cwd == nil, let cwd { entries[index].cwd = cwd; changed = true }
        if entries[index].transcriptPath == nil, let transcriptPath {
            entries[index].transcriptPath = transcriptPath
            changed = true
        }
        if entries[index].entrypoint == nil, let entrypoint {
            entries[index].entrypoint = entrypoint
            changed = true
        }
        if entries[index].tty == nil, let tty { entries[index].tty = tty; changed = true }
        if entries[index].pid == nil, let pid { entries[index].pid = pid; changed = true }
        // Asked once, when the pid first arrives: `ps` is not free, and which app owns
        // a live process cannot change.
        if entries[index].host == .unknown, let pid = entries[index].pid {
            let host = ProcessAncestry.host(ofPID: pid)
            if host != .unknown { entries[index].host = host; changed = true }
        }
        return changed
    }

    /**
     Forget one session, freeing its key.

     The cursor is deliberately **not** rewound: `claimSeq` must stay monotonic or the
     next claim reuses a number and "oldest claim" — which is how eviction chooses a
     victim — starts pointing at the wrong key.
     */
    @discardableResult
    public mutating func release(sessionID: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.sessionID == sessionID }
        return entries.count != before
    }

    /// Forget everything. The registry is ephemeral, so this is the whole operation.
    public mutating func reset() {
        entries.removeAll()
        cursor = 0
    }
}

// MARK: - event mapping

/**
 Which state a hook event means.

 Ported from `lib/render.cjs`. A muted event returns nil exactly like an unrecognised
 one — muting is a supported configuration, not a failure.
 */
public enum EventMapper {
    /// Notification subtypes that mean a human is being asked for something.
    ///
    /// `idle_prompt` is deliberately unmapped: it fires when a session has merely been
    /// sitting there, and mapping it lights the attention color with nothing to act
    /// on — which teaches you to ignore the one color that must never be ignored.
    public static let defaultNotifications: [String: SessionState] = [
        "permission_prompt": .awaiting,
        "agent_needs_input": .awaiting,
        "elicitation_dialog": .awaiting,
    ]

    /// Events that only mean anything as an attention-clear. Repainting on every one
    /// would write to the device on every tool call in every session.
    public static let clearsAttention: Set<String> = ["PostToolUse", "PostToolUseFailure"]

    public static func state(
        for event: String,
        matcher: String? = nil,
        enabledEvents: [String: Bool] = [:],
        notifications: [String: SessionState] = defaultNotifications
    ) -> SessionState? {
        if enabledEvents[event] == false { return nil }

        switch event {
        case "SessionStart":
            return .idle
        // Fires the instant a prompt appears. The Notification that also means
        // "awaiting" arrives ~6s later, measured — so this is what turns the key
        // orange promptly rather than after a visible lag.
        case "PermissionRequest":
            return .awaiting
        case "UserPromptSubmit":
            return .working
        case "Stop":
            return .done
        case "StopFailure":
            return .error
        case "SessionEnd":
            return .ended
        case "PostToolUse", "PostToolUseFailure":
            return .working

        /*
         Hermes Agent.

         Its shell hooks pipe JSON to stdin with `hook_event_name`, `session_id`, `cwd`
         and `tool_name` — the same four fields Claude Code sends, which is why the
         socket and the helper needed no changes at all. Only the names differ, and
         names are what this function is for.

         `pre_approval_request` is the one that matters. It is the whole product: the
         moment a session stops and waits for a human. Hermes fires it "before an
         approval decision is requested", and `post_approval_response` afterwards, which
         is the clear.
        */
        case "on_session_start":
            return .idle
        case "pre_tool_call", "post_tool_call", "post_approval_response":
            return .working
        case "pre_approval_request":
            return .awaiting
        case "on_session_end", "on_session_finalize":
            return .ended

        /*
         Pi.

         In-process TypeScript rather than shell hooks, so the extension does the
         forwarding — but it forwards the same shape, and these are its event names.
         `turn_end` is the one Claude calls `Stop`: a turn finished and nobody has been
         back to look at it yet.
        */
        case "turn_start", "agent_start":
            return .working
        case "turn_end", "agent_settled":
            return .done
        case "session_start":
            return .idle
        case "session_shutdown":
            return .ended
        case "Notification":
            guard let matcher else { return nil }
            // Anything absent is not per-session status — agent_completed and
            // auth_success are about the app, not about a key.
            return notifications[matcher]
        default:
            return nil
        }
    }
}
