import Foundation
import OpenBoardKit

/**
 The ring.

 It is the one surface visible from across the room, so it answers a different question
 from the keys: *does anything want me?* — not *what is each session doing?* Everything
 here follows from that.
 */
func runAmbientTests() {
    let appearances = SessionState.defaultAppearances

    func resolve(
        _ states: [SessionState?],
        mode: Ambient.Mode = .aggregate
    ) -> Ambient.Resolution? {
        Ambient.resolve(states: states, mode: mode, appearances: appearances)
    }

    test("the most urgent state on the board wins") {
        // Not the newest, not the first — the ring summarises, and a single blocked
        // session must not be hidden behind five that are merely working.
        expectEqual(resolve([.working, .working, .awaiting, .idle, nil, nil])?.state, .awaiting)
        expectEqual(resolve([.working, .done, .idle, nil, nil, nil])?.state, .working)
        expectEqual(resolve([.done, .idle, nil, nil, nil, nil])?.state, .done)
        expectEqual(resolve([.idle, nil, nil, nil, nil, nil])?.state, .idle)
    }

    test("the priority order is exactly the one the board was designed around") {
        expectEqual(Ambient.priority, [.awaiting, .error, .working, .done, .idle])
        // Attention outranks error: a failed turn has already happened, a blocked one
        // is still waiting on you.
        expectEqual(resolve([.error, .awaiting, nil, nil, nil, nil])?.state, .awaiting)
    }

    test("states that are distinct on a key collapse on the ring") {
        // stalled and awaiting both mean a human is needed. The distinction matters on
        // the key you are about to press, not from across the room.
        expectEqual(Ambient.normalise(.stalled), .awaiting)
        expectEqual(resolve([.stalled, nil, nil, nil, nil, nil])?.state, .awaiting)

        // viewing is idle with a window focused, which nobody across the room can act on.
        expectEqual(Ambient.normalise(.viewing), .idle)
        expectEqual(resolve([.viewing, nil, nil, nil, nil, nil])?.state, .idle)
    }

    test("a closed session is not board activity") {
        // Otherwise the ring stays lit after the last session ends, which reads as
        // "something is still running" when nothing is.
        expect(Ambient.normalise(.ended) == nil)
        let onlyEnded = resolve([.ended, .ended, nil, nil, nil, nil])
        expect(onlyEnded?.state == nil)
        expectEqual(onlyEnded?.appearance, .off)
    }

    test("an empty board is dark") {
        let empty = resolve([nil, nil, nil, nil, nil, nil])
        expect(empty?.state == nil)
        expectEqual(empty?.appearance, .off)
    }

    test("events mode leaves the ring dark, and is the default") {
        // The ring is a notification surface, not a second status display. A lap fires
        // on a transition and then it goes back to nothing — that is what makes a lap
        // mean anything at all.
        let busy: [SessionState?] = [.awaiting, .working, .error, nil, nil, nil]
        expectEqual(resolve(busy, mode: .events)?.appearance, .off)
        expectEqual(Preferences.default.ambient.mode, "events")
        // Same board in aggregate mode does light, so the difference is the mode and
        // not the board.
        expect(resolve(busy, mode: .aggregate)?.appearance != .off)
    }

    test("off and events both paint dark but differ on laps") {
        let busy: [SessionState?] = [.awaiting, nil, nil, nil, nil, nil]
        expectEqual(resolve(busy, mode: .off)?.appearance, .off)
        expectEqual(resolve(busy, mode: .events)?.appearance, .off)
        // The difference is what *else* may light the ring.
        expect(Ambient.lapsAllowed(in: .events))
        expect(!Ambient.lapsAllowed(in: .off))
        expect(Ambient.lapsAllowed(in: .aggregate), "a held color and a lap do not conflict")
    }

    test("fixed mode holds its color regardless of the board") {
        let held = Appearance(color: RGB(0x7B2FF7), effect: .solid, brightness: 0.5, speed: 0)
        for board: [SessionState?] in [[.awaiting], [nil], [.working, .error]] {
            expectEqual(
                Ambient.resolve(
                    states: board, mode: .fixed, appearances: appearances, fixed: held
                )?.appearance,
                held
            )
        }
    }

    test("an unknown mode falls back rather than going dark forever") {
        // A hand-edited config with a typo must not silently kill the ring.
        expect(Ambient.Mode(rawValue: "aggregrate") == nil)
    }
}

/**
 Laps — the one rule that matters is that they fire on a **transition**.

 Firing on every paint turns the ring into a strobe and, worse, teaches you that a lap
 means nothing. The re-assert loop repaints every 10s, so this is not a theoretical
 concern: getting it wrong lights a lap six times a minute per session.
 */
func runLapTests() {
    let settings = Preferences.Ambient()

    test("a lap fires on the change, and never on a repaint") {
        expectEqual(Laps.show(from: .working, to: .done, settings: settings), "completion")
        // The same state again is a repaint, which is what the re-assert loop does
        // every ten seconds.
        expect(Laps.show(from: .done, to: .done, settings: settings) == nil)
        expect(Laps.show(from: .awaiting, to: .awaiting, settings: settings) == nil)
    }

    test("each state that earns a lap gets its own") {
        expectEqual(Laps.show(from: .working, to: .done, settings: settings), "completion")
        expectEqual(Laps.show(from: .working, to: .awaiting, settings: settings), "question")
        expectEqual(Laps.show(from: .working, to: .error, settings: settings), "error")
        // stalled earns the same lap as awaiting: both mean a human is needed.
        expectEqual(Laps.show(from: .working, to: .stalled, settings: settings), "question")
    }

    test("states nobody needs to be told about earn nothing") {
        expect(Laps.show(from: .idle, to: .working, settings: settings) == nil)
        expect(Laps.show(from: .done, to: .idle, settings: settings) == nil)
        expect(Laps.show(from: .working, to: .viewing, settings: settings) == nil)
        expect(Laps.show(from: .working, to: .ended, settings: settings) == nil)
    }

    test("a first sighting still fires") {
        // A session adopted mid-flight has no previous state. Requiring one would mean
        // the board never laps for a session it did not watch start — which is every
        // session after an app restart.
        expectEqual(Laps.show(from: nil, to: .done, settings: settings), "completion")
        expectEqual(Laps.show(from: nil, to: .awaiting, settings: settings), "question")
    }

    test("each lap can be turned off on its own") {
        var muted = Preferences.Ambient()
        muted.completionLap = false
        expect(Laps.show(from: .working, to: .done, settings: muted) == nil)
        expectEqual(Laps.show(from: .working, to: .awaiting, settings: muted), "question",
                    "muting one lap silenced another")

        muted.questionLap = false
        expect(Laps.show(from: .working, to: .awaiting, settings: muted) == nil)
        expectEqual(Laps.show(from: .working, to: .error, settings: muted), "error")

        muted.errorPulse = false
        expect(Laps.show(from: .working, to: .error, settings: muted) == nil)
    }

    test("ambient off silences every lap") {
        // `off` means the ring never lights, so it has to beat the individual toggles
        // rather than sit alongside them.
        var quiet = Preferences.Ambient()
        quiet.mode = "off"
        expect(Laps.show(from: .working, to: .done, settings: quiet) == nil)
        expect(Laps.show(from: .working, to: .awaiting, settings: quiet) == nil)
        expect(Laps.show(from: .working, to: .error, settings: quiet) == nil)
    }

    test("aggregate mode still laps") {
        // A ring holding a color and a ring flashing a lap are different signals.
        var aggregate = Preferences.Ambient()
        aggregate.mode = "aggregate"
        expectEqual(Laps.show(from: .working, to: .done, settings: aggregate), "completion")
    }

    test("every lap name resolves to a real show") {
        // A name with no show behind it fails silently — the transition happens and
        // nothing lights, which is indistinguishable from the lap being muted.
        var settings = Preferences.Ambient()
        settings.mode = "aggregate"
        for target: SessionState in [.done, .awaiting, .stalled, .error] {
            guard let name = Laps.show(from: .working, to: target, settings: settings) else {
                expect(false, "\(target.rawValue) earned no lap")
                continue
            }
            expect(Shows.show(named: name) != nil, "no show named \(name)")
        }
    }
}

/**
 The two gaps the plan's table still listed open, found by auditing it rather than
 trusting the phase notes.
 */
func runAuditFollowUpTests() {
    test("fixed mode actually holds a color") {
        // It was documented in Preferences, offered by the resolver, and unreachable:
        // no config field existed and the caller passed no color, so `fixed` resolved
        // to nothing and the ring went dark. A mode that is selectable and silently
        // does nothing is the exact failure this project keeps having.
        let held = Preferences.default.ambient.fixed
        expect(held.effect != .off, "the default fixed color is dark")

        let resolved = Ambient.resolve(
            states: [.awaiting, .working, nil, nil, nil, nil],
            mode: .fixed,
            appearances: SessionState.defaultAppearances,
            fixed: held
        )
        expectEqual(resolved?.appearance, held, "the board overrode the fixed color")
    }

    test("a fixed color survives the config round trip, partially specified") {
        let prefs = Preferences.merging([
            "ambient": ["mode": "fixed", "fixed": ["color": 8388736]]
        ])
        expectEqual(prefs.ambient.mode, "fixed")
        expectEqual(prefs.ambient.fixed.color.hex, "#800080")
        // Same partial-override rule as a state: naming only the color keeps the rest.
        expectEqual(prefs.ambient.fixed.effect, Preferences.default.ambient.fixed.effect)
        expectEqual(prefs.ambient.fixed.brightness, Preferences.default.ambient.fixed.brightness)
    }

    test("releasing one slot frees only that slot") {
        // The CLI had `release --slot N`; the app only had "forget all", which is a
        // poor answer to one row being wrong.
        var registry = SessionRegistry()
        let now = Date()
        for index in 1...3 {
            _ = registry.claim(
                sessionID: "s\(index)", pid: 100 + index, now: now, isAlive: { _ in true }
            )
        }
        let target = try Harness.require(registry.entry(forSession: "s2"))

        expect(registry.release(sessionID: "s2"))
        expect(registry.entry(forSession: "s2") == nil, "the slot was not freed")
        expectEqual(registry.entries.count, 2)
        expect(registry.entry(forSession: "s1") != nil, "an unrelated session was dropped")
        expect(registry.entry(forSession: "s3") != nil)

        // Releasing something that is not there is not an error.
        expect(!registry.release(sessionID: "nobody"))

        // The freed key is reusable, and the claim counter never rewinds — claimSeq
        // must stay monotonic or eviction starts choosing the wrong key.
        let result = registry.claim(
            sessionID: "s4", pid: 999, now: now, isAlive: { _ in true }
        )
        expectEqual(result.entry?.slot, target.slot, "the freed key was not reused")
        expect((result.entry?.claimSeq ?? 0) > target.claimSeq, "claimSeq went backwards")
    }
}
