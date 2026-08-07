import Foundation

/**
 The joystick, which was never inert — it was reporting somewhere nobody looked.

 The pad broadcasts it as `v.oai.rad` ("radial"), not `v.oai.hid`. `KeyEvent.parse`
 accepts only `v.oai.hid` and returns nil for everything else, and the listener then
 dropped nils silently — so every joystick event was discarded before anything could
 see it. Both this project and its Node predecessor concluded the stick "reports
 nothing", on the strength of a capture that was itself filtered to `v.oai.hid`.

 A 30-second capture of the raw stream found 134 events and not one keypress.

 ## What it actually sends

 `{"m":"v.oai.rad","p":{"a":0.234,"d":1}}`

 - `a` — angle around the rim, 0…1 for a full turn
 - `d` — deflection, 0 at rest to 1 at the stop
 - `{a:0, d:0}` is the released reading

 It is **analog**, not four switches: pushing it produces a stream of samples with the
 angle wobbling by a few thousandths, and rolling it round the rim sweeps `a`
 continuously. So a direction is a *decision* about a continuous signal rather than a
 name read off the wire, which is what this type is for.
 */
public struct Joystick: Sendable {
    public enum Direction: String, Sendable, Equatable, CaseIterable {
        case up, down, left, right
    }

    /**
     Which angle the stick reports when pushed **up**.

     Configurable rather than assumed. The four cardinals land on 0.00, 0.25, 0.50 and
     0.75, but which one is physically "up" cannot be read off the numbers — it is a
     property of how the hardware is oriented, and guessing it wrong swaps the user's
     axes in a way that feels broken rather than mis-configured.
     */
    public var northAngle: Double

    /// Whether the angle increases clockwise as seen by the user.
    public var clockwise: Bool

    /**
     How far it must be pushed to count.

     0.5 because the samples show a real push saturating at 1.0 almost immediately,
     while returning to centre passes through small values like 0.016 and 0.064. A low
     threshold turns the *release* of one push into a second event.
     */
    public var threshold: Double

    /// True once a push has been reported, until the stick returns to centre. One push
    /// is one event: a held stick emits a stream of samples, and acting on each would
    /// fire dozens of keystrokes from a single nudge.
    private var engaged = false

    public init(
        northAngle: Double = 0,
        clockwise: Bool = true,
        threshold: Double = 0.5
    ) {
        self.northAngle = northAngle
        self.clockwise = clockwise
        self.threshold = threshold
    }

    /**
     Feed one sample. Returns a direction only on the edge that begins a push.

     - Returns: the direction on the first sample past the threshold; nil for every
       sample after it, and nil while the stick is returning to rest.
     */
    public mutating func update(angle: Double, deflection: Double) -> Direction? {
        guard deflection >= threshold else {
            // Released. Re-arm, so the next push reports.
            //
            // A margin below the threshold rather than requiring exactly zero: the
            // stick does not always report a clean `{a:0,d:0}` on the way back, and a
            // strict test would leave it permanently engaged after one sloppy release.
            if deflection < threshold * 0.6 { engaged = false }
            return nil
        }
        guard !engaged else { return nil }
        engaged = true
        return direction(for: angle)
    }

    /// The nearest cardinal to this angle, in the pad's own frame.
    public func direction(for angle: Double) -> Direction {
        // Normalise into 0..<1 relative to whichever angle is "up", then optionally
        // mirror so the quadrants run the way the user's hand does.
        var turned = (angle - northAngle).truncatingRemainder(dividingBy: 1)
        if turned < 0 { turned += 1 }
        if !clockwise { turned = (1 - turned).truncatingRemainder(dividingBy: 1) }

        // Quarter turns, offset by an eighth so each cardinal owns the arc *around* it
        // rather than the arc after it. Without the offset, a push a hair short of
        // north reads as the neighbouring direction.
        let quadrant = Int(((turned + 0.125) * 4).rounded(.down)) % 4
        switch quadrant {
        case 0: return .up
        case 1: return .right
        case 2: return .down
        default: return .left
        }
    }

    /// Forget a push in progress — used when bindings change, so a stick held across a
    /// rebind does not fire the old action on release.
    public mutating func reset() { engaged = false }
}

extension Joystick {
    /// Parse a `v.oai.rad` line. Returns nil for anything else, including the
    /// `v.oai.hid` keypresses that share the stream.
    public static func parse(_ data: Data) -> (angle: Double, deflection: Double)? {
        struct Envelope: Decodable {
            struct Payload: Decodable {
                let a: Double
                let d: Double
            }
            let m: String
            let p: Payload
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.m == "v.oai.rad"
        else { return nil }
        return (envelope.p.a, envelope.p.d)
    }
}
