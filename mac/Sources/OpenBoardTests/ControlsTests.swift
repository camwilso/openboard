import Foundation
import OpenBoardKit

/**
 `viewing` — the session you are looking at.

 Derived at render time and never stored. The tests below are mostly about what it must
 *not* overwrite.
 */
func runViewingTests() {
    test("only an idle session becomes viewing") {
        expectEqual(Viewing.display(.idle, isFocused: true), .viewing)
        expectEqual(Viewing.display(.idle, isFocused: false), .idle)
    }

    test("focus never hides a state that means something") {
        // A focused session that is working, waiting or failed already says something
        // more useful than "you are looking at it".
        for state: SessionState in [.working, .awaiting, .stalled, .done, .error, .ended] {
            expectEqual(
                Viewing.display(state, isFocused: true), state,
                "\(state.rawValue) was overwritten by focus"
            )
        }
    }

    test("focus must never hide awaiting") {
        // The one that would actually hurt: orange is the only color meaning act now,
        // and looking at a blocked session must not stop it saying so.
        let shown = Viewing.display(.awaiting, isFocused: true)
        expectEqual(shown, .awaiting)
        expect(shown.isAttention)
    }

    test("viewing is idle's color, distinguishable but not louder") {
        let idle = SessionState.idle.defaultAppearance
        let viewing = Viewing.appearance(.viewing, isFocused: true)
        expectEqual(viewing.color, idle.color, "a different hue would read as a new state")
        expect(viewing.effect != idle.effect, "nothing distinguishes it from idle")
        // Never competes with attention.
        expect(viewing.color != SessionState.awaiting.defaultAppearance.color)
    }

    test("viewing follows a customised idle color") {
        // The actual bug. Idle was set to white; `viewing` was a separately configured
        // state still holding the shipped slate blue, so the key you were looking at
        // breathed a color nothing else on the board was showing.
        var custom = SessionState.defaultAppearances
        custom[.idle] = Appearance(color: RGB(0xFFFFFF), effect: .solid, brightness: 0.7, speed: 0)
        let viewing = Viewing.appearance(.viewing, isFocused: true, from: custom)
        expectEqual(viewing.color.hex, "#FFFFFF", "the pulse ignored the configured idle color")
        expect(viewing.effect.isAnimated, "focus has to be visible")
    }

    test("no state offers a color picker that nothing reads") {
        // `viewing` takes idle's color, so an editor for it would write a value the
        // board never looks at — the settings-pane failure this project keeps finding.
        expect(
            !SessionState.displayOrder.contains(.viewing),
            "viewing is editable but its color is derived"
        )
    }

    test("every other state keeps its own configured color under focus") {
        // Focus adds motion, never a color: a focused done key is still the green the
        // user chose, not a focus hue.
        var custom = SessionState.defaultAppearances
        custom[.done] = Appearance(color: RGB(0x123456), effect: .solid, brightness: 0.6, speed: 0)
        let focused = Viewing.appearance(.done, isFocused: true, from: custom)
        expectEqual(focused.color.hex, "#123456")
        expect(focused.effect.isAnimated)
    }
}

/**
 The encoder, end to end from a tick to a scroll amount.

 The direction is a real setting because there is no correct answer — macOS ships
 natural scrolling on and plenty of people turn it off.
 */
func runScrollTests() {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    test("a tick becomes a scroll of the configured size and direction") {
        var dispatcher = KeyDispatcher(actions: KeyAction.defaults)
        dispatcher.scrollLines = 5
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CW", action: .tick), now: t0),
            .scroll(lines: 5)
        )
        dispatcher.clockwiseScrollsUp = false
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CC", action: .tick), now: t0),
            .scroll(lines: 5)
        )
    }

    test("zero lines is still a valid configuration") {
        // Someone setting 0 wants the dial inert, not a crash or a stuck default.
        var dispatcher = KeyDispatcher(actions: KeyAction.defaults)
        dispatcher.scrollLines = 0
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CW", action: .tick), now: t0),
            .scroll(lines: 0)
        )
    }

    test("the encoder click is not a scroll") {
        var dispatcher = KeyDispatcher(actions: KeyAction.defaults, encoderClick: .settings)
        let click = dispatcher.intent(for: KeyEvent(key: "ENC_CLK", action: .down), now: t0)
        expectEqual(click, .encoderPressed)
        // And its release is delivered, which is what ends the hold.
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ENC_CLK", action: .up), now: t0),
            .release(key: "ENC_CLK")
        )
    }
}

/**
 Hold-to-talk.

 Every case here is about the same failure: a `keyDown` with no matching `keyUp` is
 machine-wide state that outlives the process, and the user's only recourse is a reboot.
 */
func runHoldTests() {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    test("a hold produces both edges, and the release is not debounced") {
        var dispatcher = KeyDispatcher(actions: ["ACT10": .voiceTalk])
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT10", action: .down), now: t0),
            .action(.voiceTalk, key: "ACT10")
        )
        // Releases are delivered raw. A dropped release is what leaves a key held.
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT10", action: .up), now: t0.addingTimeInterval(0.01)),
            .release(key: "ACT10")
        )
    }

    test("a release always arrives, even inside the debounce window") {
        // The press debounce must never swallow the edge that ends a hold.
        var dispatcher = KeyDispatcher(actions: ["ACT10": .voiceTalk])
        _ = dispatcher.intent(for: KeyEvent(key: "ACT10", action: .down), now: t0)
        for offset in [0.001, 0.05, 0.1, 0.39] {
            var fresh = KeyDispatcher(actions: ["ACT10": .voiceTalk])
            _ = fresh.intent(for: KeyEvent(key: "ACT10", action: .down), now: t0)
            expectEqual(
                fresh.intent(
                    for: KeyEvent(key: "ACT10", action: .up),
                    now: t0.addingTimeInterval(offset)
                ),
                .release(key: "ACT10"),
                "the release at +\(offset)s was swallowed"
            )
        }
    }

    test("a custom shortcut has the same two edges as hold to dictate") {
        // The controller ends a hold on the release edge of whichever key began it,
        // so a shortcut bound key must report its release the same way.
        var dispatcher = KeyDispatcher(actions: ["ACT08": .shortcut])
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT08", action: .down), now: t0),
            .action(.shortcut, key: "ACT08")
        )
        expectEqual(
            dispatcher.intent(for: KeyEvent(key: "ACT08", action: .up), now: t0.addingTimeInterval(0.2)),
            .release(key: "ACT08")
        )
    }

    test("a wide keycap's release reports the owning key") {
        // ACT10 and ACT11 are one cap. If the release came back as ACT11 the hold
        // would never end, because the binding lives on ACT10.
        var dispatcher = KeyDispatcher(actions: ["ACT10": .voiceTalk])
        _ = dispatcher.intent(for: KeyEvent(key: "ACT10", action: .down), now: t0)
        expectEqual(
            dispatcher.intent(
                for: KeyEvent(key: "ACT11", action: .up), now: t0.addingTimeInterval(0.5)
            ),
            .release(key: "ACT10")
        )
    }

    test("the hold timeout is configurable and has a sane default") {
        expectEqual(Preferences.default.maxHoldSeconds, 60)
        expectEqual(Preferences.merging(["maxHoldSeconds": 5]).maxHoldSeconds, 5)
    }

    test("voiceTap and voiceTalk are genuinely different bindings") {
        // They behaved identically before this — a binding the picker offered and did
        // not honour.
        expect(KeyAction.voiceTap != KeyAction.voiceTalk)
        expectEqual(KeyAction.voiceTalk.rawValue, "voice-talk")
        expect(KeyAction.voiceTalk.long.contains("hold"))
    }
}

/**
 One button, two actions.

 The dial is the only control you reach for without looking, so it carries both a press
 and a press-and-hold. Every case here is about the two not stepping on each other.
 */
func runEncoderClickTests() {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    test("a quick press is short, a held one is long") {
        var click = EncoderClick(threshold: 0.45)
        click.press(now: t0)
        expect(!click.shouldFireLong(now: t0.addingTimeInterval(0.2)), "fired too early")
        expectEqual(click.release(now: t0.addingTimeInterval(0.2)), .short)

        click.press(now: t0)
        expect(click.shouldFireLong(now: t0.addingTimeInterval(0.45)), "the threshold is inclusive")
    }

    test("a hold fires the long action once and the release does nothing") {
        // Otherwise one press opens the menu *and* Settings.
        var click = EncoderClick(threshold: 0.45)
        click.press(now: t0)
        expect(click.shouldFireLong(now: t0.addingTimeInterval(0.5)))
        expect(!click.shouldFireLong(now: t0.addingTimeInterval(0.9)), "fired twice on one hold")
        expectEqual(click.release(now: t0.addingTimeInterval(2)), .handled)
    }

    test("a late timer after release does not fire") {
        // The timer is real and can be delivered after the button is already up. Acting
        // on it would open a window the user did not ask for, seconds later.
        var click = EncoderClick(threshold: 0.45)
        click.press(now: t0)
        expectEqual(click.release(now: t0.addingTimeInterval(0.1)), .short)
        expect(!click.shouldFireLong(now: t0.addingTimeInterval(0.5)))
    }

    test("a release with no press is not an action") {
        // A dropped report, or a press that landed before the app was listening.
        var click = EncoderClick()
        expectEqual(click.release(now: t0), .spurious)
    }

    test("each press starts clean") {
        var click = EncoderClick(threshold: 0.45)
        click.press(now: t0)
        expect(click.shouldFireLong(now: t0.addingTimeInterval(0.5)))
        _ = click.release(now: t0.addingTimeInterval(0.6))

        // A short press after a long one must not inherit `handled`.
        click.press(now: t0.addingTimeInterval(1))
        expectEqual(click.release(now: t0.addingTimeInterval(1.1)), .short)
    }

    test("the deadline is exposed so the caller can time it") {
        var click = EncoderClick(threshold: 0.45)
        expect(click.longPressDeadline == nil, "nothing is held")
        click.press(now: t0)
        expectEqual(click.longPressDeadline, t0.addingTimeInterval(0.45))
        expect(click.isPressed)
    }

    test("the shipped bindings are press-opens-menu, hold-opens-settings") {
        let encoder = Preferences.Encoder()
        expectEqual(encoder.click, .popover)
        expectEqual(encoder.longPress, .settings)
        expectEqual(encoder.longPressMs, 450)
        expectEqual(encoder.longPressInterval, 0.45)
    }

    test("the hold threshold is bounded to something usable") {
        // Below ~150ms an ordinary click trips it; above a couple of seconds the hold
        // reads as the app having hung.
        expectEqual(Preferences.merging(["encoder": ["longPressMs": 10]]).encoder.longPressMs, 150)
        expectEqual(Preferences.merging(["encoder": ["longPressMs": 99999]]).encoder.longPressMs, 2000)
        expectEqual(Preferences.merging(["encoder": ["longPressMs": 700]]).encoder.longPressMs, 700)
    }

    test("either binding can be cleared without disturbing the other") {
        let noLong = Preferences.merging(["encoder": ["longPress": NSNull()]])
        expect(noLong.encoder.longPress == nil)
        expectEqual(noLong.encoder.click, .popover, "clearing the hold unbound the press")

        let noClick = Preferences.merging(["encoder": ["click": NSNull()]])
        expect(noClick.encoder.click == nil)
        expectEqual(noClick.encoder.longPress, .settings)
    }
}

/**
 Finding the key you are looking at.

 `viewing` covers the idle case by swapping state. Every other focused key looked
 identical to the five you are not in — most visibly a finished session, which is green,
 solid, and indistinguishable from any other green key on the board.
 */
func runFocusPulseTests() {
    test("a focused finished session breathes deeper, and stays green") {
        // Green is the thing you came back for. The board rests on shallow-breath
        // now, so focus deepens the motion; it must not take the color away or the
        // signal is gone.
        let done = SessionState.done.defaultAppearance
        let focused = Viewing.focused(done, isFocused: true)
        expectEqual(focused.color, done.color, "the color changed")
        expectEqual(focused.effect, .breath)
        expect(focused.brightness > done.brightness, "a focused key should be a little brighter")
        expect(focused.speed > 0, "breath at speed 0 does not move")
    }

    test("a focused solid key starts breathing") {
        // The old rule, kept for anyone who configures a state back to solid.
        let solid = Appearance(color: RGB(0x09B821), effect: .solid, brightness: 0.7, speed: 0)
        let focused = Viewing.focused(solid, isFocused: true)
        expectEqual(focused.effect, .shallowBreath)
        expect(focused.speed > 0, "shallow-breath at speed 0 does not move")
        expect(focused.brightness > solid.brightness)
    }

    test("an unfocused key is untouched") {
        for state: SessionState in SessionState.allCases {
            let base = state.defaultAppearance
            expectEqual(Viewing.focused(base, isFocused: false), base, "\(state.rawValue)")
        }
    }

    test("the loudest effects are left alone") {
        // error already breathes deep and rainbow is the loudest thing the board can
        // do. Changing how they move because you happen to be looking at one is
        // motion competing with motion.
        let deep = SessionState.error.defaultAppearance
        expectEqual(Viewing.focused(deep, isFocused: true), deep, "error was re-animated by focus")
        let rainbow = Appearance(color: RGB(0xFFFFFF), effect: .rainbow, brightness: 1, speed: 0.75)
        expectEqual(Viewing.focused(rainbow, isFocused: true), rainbow, "rainbow was re-animated by focus")
    }

    test("a dark key stays dark") {
        // `ended` is off. Pulsing it would light a key for a session that has closed.
        let ended = SessionState.ended.defaultAppearance
        expectEqual(Viewing.focused(ended, isFocused: true), ended)
    }

    test("brightness never exceeds what the device accepts") {
        // The bump is additive, and a state configured at 0.95 would go over 1 —
        // which ThreadState rejects outright rather than clamping.
        let bright = Appearance(color: RGB(0x09B821), effect: .solid, brightness: 0.95, speed: 0)
        let focused = Viewing.focused(bright, isFocused: true)
        expect(focused.brightness <= 1, "brightness went to \(focused.brightness)")
        expect((try? CodexProtocol.ThreadState(
            physicalSlot: 1, color: focused.color, brightness: focused.brightness,
            effect: .shallowBreath, speed: focused.speed
        )) != nil, "the device would refuse this")
    }

    test("focus still never hides a state that means something") {
        // The rule that came first and still holds: looking at a blocked session must
        // not stop it saying it is blocked.
        expectEqual(Viewing.display(.awaiting, isFocused: true), .awaiting)
        expectEqual(Viewing.display(.done, isFocused: true), .done)
    }
}
