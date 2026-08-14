import Foundation
import OpenBoardKit

/**
 The belief, corroborated.

 `VoiceSignal` is where a keypress belief meets the microphone's actual running
 state, and every transition here is one the ring will paint. The clock is injected
 throughout, so the cases that used to need a stopwatch — grace expiry, the
 180-second backstop — are plain assertions.
 */
func runVoiceSignalTests() {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    test("a fresh belief shows during grace, unconfirmed") {
        var signal = VoiceSignal()
        signal.begin(now: t0)
        expect(signal.isActive(now: t0))
        expect(signal.isActive(now: t0.addingTimeInterval(2.9)))
        expectEqual(signal.micConfirmed, false)
    }

    test("no mic within grace puts the light out") {
        // The tap typed a space instead of starting dictation: a blink, not three
        // minutes of rainbow.
        var signal = VoiceSignal()
        signal.begin(now: t0)
        expectEqual(signal.isActive(now: t0.addingTimeInterval(3)), false)
    }

    test("a mic start confirms, and the belief outlives grace") {
        var signal = VoiceSignal()
        signal.begin(now: t0)
        expectEqual(signal.micChanged(running: true, now: t0.addingTimeInterval(1)), nil)
        expect(signal.micConfirmed)
        expect(signal.isActive(now: t0.addingTimeInterval(60)))
    }

    test("a mic stop ends a confirmed belief, whoever stopped it") {
        // Second tap, Escape, submit — none of them report back, all of them stop
        // the mic.
        var signal = VoiceSignal()
        signal.begin(now: t0)
        _ = signal.micChanged(running: true, now: t0.addingTimeInterval(1))
        expectEqual(signal.micChanged(running: false, now: t0.addingTimeInterval(30)), "mic stopped")
        expectEqual(signal.isActive(now: t0.addingTimeInterval(30)), false)
    }

    test("a mic stop before confirmation is someone else's, and ignored") {
        // Another app releasing the mic during our grace window says nothing about
        // dictation — the grace window is already the judge of that case.
        var signal = VoiceSignal()
        signal.begin(now: t0)
        expectEqual(signal.micChanged(running: false, now: t0.addingTimeInterval(1)), nil)
        expect(signal.isActive(now: t0.addingTimeInterval(2)))
    }

    test("a mic start after grace expiry does not resurrect a dead tap") {
        // A call starting minutes after a failed tap must not light the ring.
        var signal = VoiceSignal()
        signal.begin(now: t0)
        _ = signal.micChanged(running: true, now: t0.addingTimeInterval(30))
        expectEqual(signal.micConfirmed, false)
        expectEqual(signal.isActive(now: t0.addingTimeInterval(30)), false)
    }

    test("the limit still bounds a confirmed belief") {
        // The degraded case: a call holds the mic open past dictation's end, so a
        // stop is never observed. The old absolute backstop applies unchanged.
        var signal = VoiceSignal()
        signal.begin(now: t0)
        _ = signal.micChanged(running: true, now: t0.addingTimeInterval(1))
        expect(signal.isActive(now: t0.addingTimeInterval(179)))
        expectEqual(signal.isActive(now: t0.addingTimeInterval(180)), false)
    }

    test("mic events with no belief say nothing") {
        var signal = VoiceSignal()
        expectEqual(signal.micChanged(running: true, now: t0), nil)
        expectEqual(signal.micChanged(running: false, now: t0), nil)
        expectEqual(signal.isActive(now: t0), false)
    }

    test("a new belief starts unconfirmed, whatever the last one saw") {
        var signal = VoiceSignal()
        signal.begin(now: t0)
        _ = signal.micChanged(running: true, now: t0.addingTimeInterval(1))
        signal.end()
        signal.begin(now: t0.addingTimeInterval(10))
        expectEqual(signal.micConfirmed, false)
        expect(signal.isActive(now: t0.addingTimeInterval(10)))
    }
}
