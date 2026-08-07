import Foundation
import OpenBoardKit

/**
 The joystick, decoded from the stream everyone thought was empty.

 The angles below are from a real 30-second capture: pushing each direction produced a
 tight cluster at 0.005, 0.234, 0.495 and 0.775 — evenly spaced quarter turns, with
 opposite directions exactly half a turn apart. Rolling it round the rim swept the
 angle continuously through everything between.
 */
func runJoystickTests() {
    test("a v.oai.rad line parses, and a keypress does not") {
        // The whole reason the stick looked dead: it does not speak `v.oai.hid`, and
        // the parser that only accepts `v.oai.hid` silently discarded every sample.
        let sample = try Harness.require(
            Joystick.parse(Data(#"{"m":"v.oai.rad","p":{"a":0.234,"d":1}}"#.utf8))
        )
        expectEqual(sample.angle, 0.234)
        expectEqual(sample.deflection, 1)

        expect(Joystick.parse(Data(#"{"m":"v.oai.hid","p":{"k":"AG00","act":1}}"#.utf8)) == nil)
        expect(Joystick.parse(Data(#"{"ok":1,"id":7}"#.utf8)) == nil)
        expect(Joystick.parse(Data("not json".utf8)) == nil)
    }

    test("the four captured clusters map to four distinct directions") {
        // Whatever the orientation turns out to be, the cardinals must not collide.
        let stick = Joystick(northAngle: 0)
        let captured = [0.005, 0.234, 0.495, 0.775]
        let directions = captured.map { stick.direction(for: $0) }
        expectEqual(Set(directions).count, 4, "two directions landed on the same cardinal")
    }

    test("opposite pushes give opposite directions") {
        let stick = Joystick(northAngle: 0)
        expect(stick.direction(for: 0.005) != stick.direction(for: 0.495))
        expect(stick.direction(for: 0.234) != stick.direction(for: 0.775))
    }

    test("each cardinal owns the arc around it, not after it") {
        // A push a hair short of a cardinal must read as that cardinal. Without the
        // eighth-turn offset, 0.995 reads as the neighbour rather than as north.
        let stick = Joystick(northAngle: 0)
        expectEqual(stick.direction(for: 0.0), .up)
        expectEqual(stick.direction(for: 0.995), .up, "just short of north read as its neighbour")
        expectEqual(stick.direction(for: 0.12), .up)
        expectEqual(stick.direction(for: 0.13), .right)
    }

    test("orientation is applied, so north can be any of the four") {
        // Which angle is physically "up" is a property of the hardware, not of the
        // numbers — all four are evenly spaced. Getting it wrong swaps the axes.
        for north in [0.0, 0.25, 0.5, 0.75] {
            let stick = Joystick(northAngle: north)
            expectEqual(stick.direction(for: north), .up, "north \(north) did not read as up")
            expectEqual(
                stick.direction(for: (north + 0.5).truncatingRemainder(dividingBy: 1)), .down
            )
        }
    }

    test("handedness mirrors left and right without touching up and down") {
        let cw = Joystick(northAngle: 0, clockwise: true)
        let ccw = Joystick(northAngle: 0, clockwise: false)
        expectEqual(cw.direction(for: 0.25), .right)
        expectEqual(ccw.direction(for: 0.25), .left)
        // The axis through north is unaffected by which way the angle runs.
        expectEqual(cw.direction(for: 0), .up)
        expectEqual(ccw.direction(for: 0), .up)
        expectEqual(cw.direction(for: 0.5), .down)
        expectEqual(ccw.direction(for: 0.5), .down)
    }

    test("one push is one action, however many samples it emits") {
        // The real capture shows a single push producing three to eight samples, and
        // a held stick thirty. Acting on each would fire dozens of keystrokes from one
        // nudge — the same mistake as debouncing the encoder wrongly, inverted.
        var stick = Joystick(northAngle: 0)
        expectEqual(stick.update(angle: 0.234, deflection: 0.72), .right)
        for _ in 0..<20 {
            expect(stick.update(angle: 0.238, deflection: 1) == nil, "a held stick repeated")
        }
    }

    test("returning to centre re-arms it") {
        var stick = Joystick(northAngle: 0)
        expectEqual(stick.update(angle: 0.005, deflection: 1), .up)
        expect(stick.update(angle: 0, deflection: 0) == nil)
        expectEqual(stick.update(angle: 0.005, deflection: 1), .up, "the second push was lost")
    }

    test("a sloppy release still re-arms") {
        // The stick does not always report a clean {a:0,d:0} on the way back. Requiring
        // exactly zero would leave it engaged forever after one imperfect release.
        var stick = Joystick(northAngle: 0)
        expectEqual(stick.update(angle: 0.495, deflection: 1), .down)
        expect(stick.update(angle: 0.49, deflection: 0.016) == nil)
        expectEqual(stick.update(angle: 0.495, deflection: 1), .down)
    }

    test("a light touch is not a push") {
        // Real returns-to-centre pass through 0.016 and 0.064. A low threshold turns
        // the release of one push into a second event in the opposite direction.
        var stick = Joystick(northAngle: 0)
        expect(stick.update(angle: 0.824, deflection: 0.016) == nil)
        expect(stick.update(angle: 0.926, deflection: 0.064) == nil)
        expect(stick.update(angle: 0.809, deflection: 0.49) == nil)
        expectEqual(stick.update(angle: 0.775, deflection: 0.56), .left)
    }

    test("rolling the rim does not spray every direction") {
        // Gesture 21 of the capture: thirty samples sweeping the angle while held. It
        // is one continuous push, so it is one action.
        var stick = Joystick(northAngle: 0)
        var fired = 0
        for step in 0..<30 {
            let angle = Double(step) / 30
            if stick.update(angle: angle, deflection: 1) != nil { fired += 1 }
        }
        expectEqual(fired, 1, "a roll around the rim fired \(fired) actions")
    }

    test("the shipped bindings are the ones asked for") {
        let stick = Preferences.default.joystick
        expectEqual(stick.left, .tabBack)
        expectEqual(stick.right, .tabForward)
        expectEqual(stick.up, .arrowUp)
        expectEqual(stick.down, .arrowDown)
    }

    test("the bindings survive the config round trip") {
        let prefs = Preferences.merging([
            "joystick": [
                "up": "arrow-up", "down": NSNull(),
                "left": "tab-back", "right": "tab-forward",
                "northAngle": 0.25, "clockwise": false, "threshold": 0.7,
            ]
        ])
        expectEqual(prefs.joystick.up, .arrowUp)
        expect(prefs.joystick.down == nil, "an explicit unbind did not survive")
        expectEqual(prefs.joystick.northAngle, 0.25)
        expectEqual(prefs.joystick.clockwise, false)
        expectEqual(prefs.joystick.threshold, 0.7)
        // Bounded: a threshold at 0 fires on noise, at 1 never fires at all.
        expectEqual(Preferences.merging(["joystick": ["threshold": 0.0]]).joystick.threshold, 0.1)
        expectEqual(Preferences.merging(["joystick": ["threshold": 5.0]]).joystick.threshold, 0.95)
    }

    test("the stick offers navigation, not everything") {
        let offered = Set(KeyAction.forJoystick)
        // Things that make sense four of, one per direction.
        for action: KeyAction in [.arrowUp, .arrowDown, .arrowLeft, .arrowRight,
                                  .tabBack, .tabForward, .prevSession, .nextSession] {
            expect(offered.contains(action), "\(action.rawValue) should be offered")
        }
        // Things that do not.
        for action: KeyAction in [.countdown, .reset, .off, .settings, .popover, .sync] {
            expect(!offered.contains(action), "\(action.rawValue) should not be on a stick")
        }
    }

    test("every direction has an arrow to bind") {
        // The design offers "arrow key" on all four; left and right did not exist.
        let offered = Set(KeyAction.forJoystick)
        for direction in Joystick.Direction.allCases {
            let arrow: KeyAction = switch direction {
            case .up: .arrowUp
            case .down: .arrowDown
            case .left: .arrowLeft
            case .right: .arrowRight
            }
            expect(offered.contains(arrow), "no arrow for \(direction.rawValue)")
        }
    }
}
