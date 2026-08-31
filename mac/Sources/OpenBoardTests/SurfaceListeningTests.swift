import Foundation
import OpenBoardKit

/**
 iTerm2 as a named host, and the per-surface listening switches.

 These two arrived together for one reason: a switch can only exist for a surface the
 board can *identify*. Jumping to iTerm2 has worked for a while — the tty walk falls
 through to it after Terminal misses — but nothing knew a session was *in* iTerm2, so
 there was no row to put a switch beside and no host to match a mute against.
 */
func runSurfaceListeningTests() {
    test("the parent chain identifies iTerm2, which a tty alone cannot") {
        // iTerm2's bundle is `iTerm.app` and its executable is `iTerm2`; both spellings
        // are matched because the name is not ours and has changed once already.
        let chain: [Int: (parent: Int, path: String)] = [
            5100: (5099, "/Users/x/.local/bin/claude"),
            5099: (5098, "-/bin/zsh"),
            5098: (1, "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        ]
        expectEqual(ProcessAncestry.host(ofPID: 5100, parentOf: { chain[$0] }), .iterm2)
        expectEqual(
            SessionOrigin.from(entrypoint: "cli", tty: "/dev/ttys004", host: .iterm2), .iterm2
        )
        expectEqual(SessionOrigin.iterm2.rawValue, "iTerm2")
    }

    test("an iTerm2 host survives a round trip through the registry file") {
        expectEqual(ProcessAncestry.Host(rawValue: "iterm2"), .iterm2)
        expectEqual(ProcessAncestry.Host.iterm2.rawValue, "iterm2")
    }

    // MARK: - the preference

    test("absent means listening, so a new surface arrives switched on") {
        // The same rule `events` uses. A missing key that meant "off" would silently
        // stop the board watching a host it had always watched, the first time someone
        // ran a build that knew about one more surface than their config file did.
        let prefs = Preferences.default
        for host in ProcessAncestry.Host.allCases {
            expect(prefs.listens(to: host), "\(host.rawValue) should be listened to by default")
        }
    }

    test("a muted surface is refused, and only that surface") {
        var prefs = Preferences.default
        prefs.surfaces["cmux"] = false
        expect(!prefs.listens(to: .cmux))
        expect(prefs.listens(to: .terminal))
        expect(prefs.listens(to: .iterm2))
        expect(prefs.listens(to: .vscode))
    }

    test("an unidentified host is always listened to, and cannot be switched off") {
        // A session whose owner could not be resolved is still a real session someone is
        // sitting in front of. A switch that quietly covered "everything I could not
        // name" would be the opposite of the fail-closed rule it looks like.
        var prefs = Preferences.default
        prefs.surfaces["unknown"] = false
        expect(prefs.listens(to: .unknown), "unknown must stay listened to even if written false")
    }

    test("the switches survive the config round trip") {
        var prefs = Preferences.default
        prefs.surfaces = ["cmux": false, "terminal": true]
        let reloaded = Preferences.merging(prefs.json)
        expectEqual(reloaded.surfaces["cmux"], false)
        expectEqual(reloaded.surfaces["terminal"], true)
        expect(!reloaded.listens(to: .cmux))
        expect(reloaded.listens(to: .terminal))
    }

    // MARK: - enforcement

    test("discovery consults the switch before claiming") {
        // `reconnect` resolves each candidate's host from the real process table, which
        // this suite cannot stand in for — so what is checked is that the predicate is
        // consulted at all, and that the default is permissive.
        let found = [
            Discovery.Found(pid: 100, tty: "/dev/ttys001", cwd: "/a"),
            Discovery.Found(pid: 200, tty: "/dev/ttys002", cwd: "/b"),
        ]
        var open = SessionRegistry()
        expectEqual(open.reconnect(found, isAlive: { _ in true }), 2)

        var closed = SessionRegistry()
        expectEqual(
            closed.reconnect(found, isAlive: { _ in true }, isListening: { _ in false }), 0,
            "a refused surface must not be seeded onto the board"
        )
        expect(closed.entries.isEmpty)
    }

    /// A board whose entries carry hosts, built the way the app really builds one: from
    /// the stored document. `entries` has no public setter, and that is correct — the
    /// app reaches this state through `RegistryStore`, so the test should too.
    func stored(_ hosts: [(slot: Int, session: String, host: String?)]) -> SessionRegistry {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-surfaces-\(UUID().uuidString).json")
        let now = ISO8601DateFormatter().string(from: Date())
        var entries: [[String: Any]] = []
        for (index, row) in hosts.enumerated() {
            var entry: [String: Any] = [
                "slot": row.slot,
                "sessionID": row.session,
                "pid": 900 + index,
                "tty": "/dev/ttys00\(row.slot)",
                "state": "idle",
                "claimSeq": index + 1,
                "claimedAt": now,
                "updatedAt": now,
            ]
            if let host = row.host { entry["host"] = host }
            entries.append(entry)
        }
        let document: [String: Any] = ["version": 1, "cursor": hosts.count, "entries": entries]
        try? JSONSerialization.data(withJSONObject: document).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return RegistryStore.load(url: url, isAlive: { _ in true })
    }

    test("muting retroactively frees the keys that surface was holding") {
        // The keys are the whole point of muting. A switch that only stopped *future*
        // sessions would leave the ones already on the board until they ended, which
        // reads as the switch not working.
        var registry = stored([
            (slot: 1, session: "a", host: "cmux"),
            (slot: 2, session: "b", host: "terminal"),
        ])
        expectEqual(registry.entries.count, 2, "the stored document did not load")

        let freed = registry.releaseUnlistened { $0 != .cmux }
        expectEqual(freed, [1])
        expectEqual(registry.entries.count, 1)
        expectEqual(registry.entries.first?.host, .terminal)
    }

    test("a sweep with nothing muted frees nothing") {
        var registry = stored([(slot: 1, session: "a", host: "cmux")])
        expect(registry.releaseUnlistened { _ in true }.isEmpty)
        expectEqual(registry.entries.count, 1)
    }

    test("a session whose host is unknown is never swept off the board") {
        // `Preferences.listens(to:)` never mutes `.unknown`, so this can only happen if
        // a caller invents its own rule — and the cost would be a key vanishing from a
        // session someone is sitting in front of.
        var registry = stored([(slot: 1, session: "a", host: nil)])
        expectEqual(registry.entries.first?.host, .unknown)
        expect(Preferences.default.listens(to: .unknown))
    }

    // MARK: - the pane and the plumbing

    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("OpenBoard")

    func read(_ name: String) -> String {
        (try? String(contentsOf: sources.appendingPathComponent("\(name).swift"), encoding: .utf8)) ?? ""
    }

    let pane = read("HarnessPane")
    let controller = read("BoardController")
    let focus = read("Focus")

    test("the scan reads the files it checks") {
        expect(!pane.isEmpty, "HarnessPane.swift did not read — the scan is checking nothing")
        expect(!controller.isEmpty, "BoardController.swift did not read")
        expect(!focus.isEmpty, "Focus.swift did not read")
    }

    test("every surface that names a host is listed, and offers a switch") {
        let hosted = OpenBoardKit.Harness.claudeCode.surfaces.compactMap(\.host)
        expectEqual(Set(hosted), Set([.terminal, .iterm2, .cmux, .vscode]))
        // And the rows that describe a rule rather than an app offer none: a switch
        // there would be a control that does nothing.
        for surface in OpenBoardKit.Harness.claudeCode.surfaces where surface.unsupported != nil {
            expectEqual(surface.host, nil, "\(surface.id) must not offer a switch")
        }
    }

    test("the pane's switch writes the preference and applies it immediately") {
        expect(pane.contains("Toggle(\"\", isOn: listeningBinding(host))"))
        expect(pane.contains("board.surfaces[host.rawValue] = $0"))
        expect(
            pane.contains("commands.bindingsChanged()"),
            "without this the switch saves nothing and frees no keys"
        )
    }

    test("a muted row stops claiming a jump it will not perform") {
        expect(pane.contains("Not listening — sessions here get no key."))
    }

    test("the controller enforces the switch on both paths, and sweeps after") {
        expect(
            controller.contains("registry.reconnect(found, isListening: { host in")
                && controller.contains("self.model.preferences.listens(to: host)"),
            "discovery must not seed the board with a muted surface"
        )
        expect(
            controller.contains("not listened to"),
            "the reconnect line must say how many were refused, or the switch looks inert"
        )
        expect(
            controller.contains("Log.write(\"hook \\(event.name): refused (not listening to that surface)\")"),
            "the hook path must refuse a muted surface before it claims a key"
        )
        expect(controller.contains("private func sweepUnlistened()"))
        expect(controller.contains("mutedPIDs.removeAll()"), "a surface switched back on must claim again")
    }

    test("a known iTerm2 session does not send an Apple event to Terminal") {
        // For someone who only uses iTerm2 that would be a consent prompt for Terminal
        // they have no reason to grant.
        expect(focus.contains("if slot.origin == .iterm2 { return focusITerm2(tty: path) }"))
    }
}
