import Foundation
import OpenBoardKit

/**
 The board across restarts.

 Every test here is really the same question: **is this still true?** A restored entry
 is a claim made in the past, and the app may have been closed for a week. Restoring a
 lie is worse than restoring nothing — the board's entire value is that a glance can be
 trusted.
 */
func runRegistryStoreTests() {
    func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-registry-\(UUID().uuidString).json")
    }

    func board(now: Date, states: [(Int, SessionState)]) -> SessionRegistry {
        var registry = SessionRegistry()
        for (index, pair) in states.enumerated() {
            _ = registry.claim(
                sessionID: "session-\(pair.0)",
                cwd: "/Users/someone/project-\(pair.0)",
                pid: 1000 + index,
                tty: "/dev/ttys00\(pair.0)",
                entrypoint: "cli",
                state: pair.1,
                now: now,
                isAlive: { _ in true }
            )
        }
        return registry
    }

    test("a session keeps its key across a restart") {
        // The whole point. If slots are reshuffled on relaunch then "my main project is
        // key 2" is wrong, and a physical board stops being worth having.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()

        let saved = board(now: now, states: [(1, .idle), (2, .awaiting), (3, .idle)])
        RegistryStore.save(saved, url: url)

        let loaded = RegistryStore.load(url: url, now: now, isAlive: { _ in true })
        expectEqual(loaded.entries.count, 3)
        for entry in saved.entries {
            let restored = loaded.entry(forSession: entry.sessionID)
            expectEqual(restored?.slot, entry.slot, "\(entry.sessionID) moved key")
            expectEqual(restored?.cwd, entry.cwd)
            expectEqual(restored?.tty, entry.tty, "the tty is what makes a jump exact")
        }
    }

    test("a dead process does not come back") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        RegistryStore.save(board(now: now, states: [(1, .idle), (2, .idle)]), url: url)

        // Nothing is alive any more — every key should be free.
        let loaded = RegistryStore.load(url: url, now: now, isAlive: { _ in false })
        expect(loaded.entries.isEmpty, "restored \(loaded.entries.count) dead session(s)")
    }

    test("an old entry is dropped even when its pid looks alive") {
        // Pids are reused. After a reboot a matching pid is coincidence, and restoring
        // it puts a stranger's process on your board.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let then = Date().addingTimeInterval(-13 * 3600)
        RegistryStore.save(board(now: then, states: [(1, .idle)]), url: url)

        let loaded = RegistryStore.load(
            url: url, staleInterval: 12 * 3600, now: Date(), isAlive: { _ in true }
        )
        expect(loaded.entries.isEmpty, "a 13h-old entry survived a 12h window")

        // Inside the window it is kept.
        let fresh = RegistryStore.load(
            url: url, staleInterval: 24 * 3600, now: Date(), isAlive: { _ in true }
        )
        expectEqual(fresh.entries.count, 1)
    }

    test("a turn in progress does not survive the restart") {
        // Nothing was happening while the app was closed, so `working` would claim a
        // turn that cannot be running. `viewing` is decided live from focus.
        expectEqual(RegistryStore.settled(.working), .idle)
        expectEqual(RegistryStore.settled(.viewing), .idle, "focus is decided live")
    }

    test("a finished session comes back finished") {
        // A completion nobody has been back to is still unseen — the app restarting
        // says nothing about whether you saw it. The stale window drops anything
        // genuinely old.
        expectEqual(RegistryStore.settled(.done), .done)
    }

    test("an attention state does survive") {
        // If a session was blocked on a prompt when the app closed, it almost certainly
        // still is. Wrongly clearing that is the one error this board must never make.
        expectEqual(RegistryStore.settled(.awaiting), .awaiting)
        expectEqual(RegistryStore.settled(.stalled), .stalled)
        expectEqual(RegistryStore.settled(.error), .error)
    }

    test("a blocked session comes back blocked, on the same key") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        RegistryStore.save(
            board(now: now, states: [(1, .working), (2, .awaiting)]), url: url
        )

        let loaded = RegistryStore.load(url: url, now: now, isAlive: { _ in true })
        expectEqual(loaded.entry(forSession: "session-2")?.state, .awaiting)
        expectEqual(loaded.entry(forSession: "session-1")?.state, .idle, "working survived")
    }

    test("the claim counter never goes backwards") {
        // claimSeq is what makes "oldest claim" meaningful. A cursor behind the restored
        // entries hands the next session a number that is already taken, and eviction
        // then picks the wrong key.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let saved = board(now: now, states: [(1, .idle), (2, .idle), (3, .idle)])
        RegistryStore.save(saved, url: url)

        var loaded = RegistryStore.load(url: url, now: now, isAlive: { _ in true })
        let highest = loaded.entries.map(\.claimSeq).max() ?? 0
        expect(loaded.cursor >= highest, "cursor \(loaded.cursor) is behind \(highest)")

        // A new claim gets a fresh, larger sequence rather than colliding.
        let result = loaded.claim(
            sessionID: "new", pid: 9999, now: now, isAlive: { _ in true }
        )
        expect((result.entry?.claimSeq ?? 0) > highest)
    }

    test("a missing file is an empty board, not a crash") {
        let loaded = RegistryStore.load(url: tempURL(), isAlive: { _ in true })
        expect(loaded.entries.isEmpty)
    }

    test("a corrupt file is an empty board, not a wedged app") {
        // The cost of starting empty is one relearned board; the cost of refusing to
        // start is the whole product.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not json at all".utf8).write(to: url)
        expect(RegistryStore.load(url: url, isAlive: { _ in true }).entries.isEmpty)

        // Valid JSON of the wrong shape is the likelier corruption, and must also be
        // survivable.
        try Data("{\"version\":1,\"entries\":\"nope\"}".utf8).write(to: url)
        expect(RegistryStore.load(url: url, isAlive: { _ in true }).entries.isEmpty)
    }

    test("an unknown state name is skipped, not fatal") {
        // A registry written by a newer version must not stop an older one starting.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"version":1,"cursor":2,"entries":[
          {"slot":1,"sessionID":"a","state":"transcending","claimSeq":1,
           "claimedAt":"2026-07-30T12:00:00Z","updatedAt":"2026-07-30T12:00:00Z"},
          {"slot":2,"sessionID":"b","state":"idle","claimSeq":2,
           "claimedAt":"2026-07-30T12:00:00Z","updatedAt":"2026-07-30T12:00:00Z"}]}
        """
        try Data(json.utf8).write(to: url)

        let loaded = RegistryStore.load(
            url: url,
            staleInterval: .greatestFiniteMagnitude,
            now: Date(timeIntervalSince1970: 1_785_000_000),
            isAlive: { _ in true }
        )
        expectEqual(loaded.entries.count, 1, "the good entry was lost with the bad one")
        expectEqual(loaded.entries.first?.sessionID, "b")
    }

    test("the file is not world-readable") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // It carries working directory paths, which say what someone is working on.
        RegistryStore.save(board(now: Date(), states: [(1, .idle)]), url: url)
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }?.intValue ?? 0
        expectEqual(mode & 0o077, 0)
    }

    test("it lives beside the other state, under OPENBOARD_HOME") {
        expectEqual(
            RegistryStore.url(env: ["OPENBOARD_HOME": "/tmp/ob"]).path,
            "/tmp/ob/registry.json"
        )
    }
}

/**
 Green holds.

 A session that finished while you were elsewhere is exactly the one you need to be
 told about. A timer means the board quietly forgets it before you look, which turns
 finished work invisible.
 */
func runDoneHoldsTests() {
    func board(state: SessionState, at now: Date) -> SessionRegistry {
        var registry = SessionRegistry()
        _ = registry.claim(
            sessionID: "s", pid: 1, state: state, now: now, isAlive: { _ in true }
        )
        return registry
    }

    test("done never expires by default") {
        let start = Date()
        var registry = board(state: .done, at: start)
        // Hours later, and after a working day.
        for hours in [1.0, 8.0, 48.0] {
            _ = registry.decay(now: start.addingTimeInterval(hours * 3600))
            expectEqual(
                registry.entry(forSession: "s")?.state, .done,
                "green cleared itself after \(hours)h"
            )
        }
        expectEqual(Preferences.default.doneDecaySeconds, 0, "the shipped default is never")
    }

    test("a configured timer still works") {
        // The behaviour is a default, not a removal — someone who wants the old 90s can
        // have it back.
        let start = Date()
        var registry = board(state: .done, at: start)
        _ = registry.decay(doneAfter: 90, now: start.addingTimeInterval(89))
        expectEqual(registry.entry(forSession: "s")?.state, .done)
        _ = registry.decay(doneAfter: 90, now: start.addingTimeInterval(91))
        expectEqual(registry.entry(forSession: "s")?.state, .idle)
    }

    test("sending a new message is what clears it") {
        // The intended way out: go back to that session and say something.
        var registry = board(state: .done, at: Date())
        registry.setState(sessionID: "s", to: .working)
        expectEqual(registry.entry(forSession: "s")?.state, .working)
        expectEqual(EventMapper.state(for: "UserPromptSubmit"), .working)
    }

    test("attention is held until answered, and expires only if asked") {
        // The hooks already clear it the moment the prompt is answered — PostToolUse
        // arriving *is* the answer — so the timer only ever covered a prompt answered
        // somewhere OpenBoard cannot see. That is a choice now, not a quiet deadline.
        let start = Date()
        var registry = board(state: .awaiting, at: start)
        _ = registry.decay(now: start.addingTimeInterval(901))
        expectEqual(registry.entry(forSession: "s")?.state, .awaiting)

        _ = registry.decay(holdAttention: false, now: start.addingTimeInterval(901))
        expectEqual(registry.entry(forSession: "s")?.state, .idle)
    }

    test("looking at a finished session does not clear it") {
        // `viewing` only ever promotes idle, so focus cannot quietly discard the one
        // signal you came back for.
        expectEqual(Viewing.display(.done, isFocused: true), .done)
    }
}
