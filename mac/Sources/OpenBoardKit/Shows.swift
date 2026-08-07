import Foundation

/**
 Ring animations.

 Ported from `lib/shows.cjs` with the timings intact, because the timings *are* the
 design. Two things learned there that a rewrite would otherwise undo:

 - **Each step is asserted once and then left alone.** The firmware runs the animation
   itself; re-sending the same config restarts it from the beginning, which is what
   made a 4s snake look like flashing instead of one smooth lap.
 - **Speed decides how many laps fit in the window**, so the snake speeds are
   deliberately low. At 0.6 the snake lapped several times and read as a strobe.

 Because a single write has to survive for the length of a step, the board's
 re-assertion has to leave the ring alone while one plays — see `ringLockedUntil`.
 */
public struct Show: Sendable {
    public struct Step: Sendable {
        public let side: CodexProtocol.LightingSide
        public let milliseconds: Int
    }

    public let name: String
    public let label: String
    public let description: String
    /// Fires by itself on a board event, rather than only when asked.
    public let auto: Bool
    public let steps: [Step]

    public var duration: Duration {
        .milliseconds(steps.reduce(0) { $0 + $1.milliseconds })
    }
}

public enum Shows {
    private static func side(
        _ color: UInt32, _ effect: CodexProtocol.Effect,
        _ brightness: Double = 1, _ speed: Double = 0.5
    ) -> CodexProtocol.LightingSide {
        CodexProtocol.LightingSide(
            color: RGB(color), brightness: brightness, effect: effect, speed: speed
        )
    }

    private static func step(
        _ color: UInt32, _ effect: CodexProtocol.Effect,
        _ brightness: Double, _ speed: Double, _ ms: Int
    ) -> Show.Step {
        Show.Step(side: side(color, effect, brightness, speed), milliseconds: ms)
    }

    /**
     A fade to dark: many short steps rather than few long ones.

     Steppiness comes from the step *duration*, not the count — at 320ms each you see
     the individual levels. Short steps read as continuous, so more of them over less
     total time is both smoother and quicker.

     Brightness follows a curve because perceived brightness is non-linear; an even
     ramp appears to hang at the top and then drop off a cliff.
     */
    private static func fadeOut(
        _ color: UInt32, from: Double = 0.55, steps count: Int = 12, ms: Int = 70
    ) -> [Show.Step] {
        var levels: [Double] = []
        for index in 1...count {
            let t = Double(index) / Double(count)
            // Rounded to the device's useful precision, then deduplicated: the tail of
            // the curve otherwise repeats a value, which renders as a pause.
            let level = (from * pow(1 - t, 1.8) * 100).rounded() / 100
            if level <= 0 { break }
            if levels.last == level { continue }
            levels.append(level)
        }
        return levels.map { step(color, .solid, $0, 0, ms) }
            + [step(0x000000, .off, 0, 0, 80)]
    }

    private static let red: UInt32 = 0xFF0000
    private static let orange: UInt32 = 0xFF6A00
    private static let green: UInt32 = 0x09B821
    private static let blue: UInt32 = 0x0C47E9
    private static let cyan: UInt32 = 0x00FFFF
    private static let magenta: UInt32 = 0xFF00FF
    private static let white: UInt32 = 0xFFFFFF

    public static let all: [Show] = [
        Show(
            name: "completion", label: "Completion lap",
            description: "A green snake lap, then a slow fade to dark.",
            auto: true,
            // One slow lap. At 0.6 the snake lapped several times and read as flashing.
            steps: [step(green, .snake, 1, 0.12, 4200)]
                // Fade rather than cut: snapping to dark reads as a glitch. Solid,
                // because a snake mid-fade looks like it is failing rather than ending.
                + fadeOut(green)
        ),
        Show(
            name: "error", label: "Error heartbeat",
            description: "Red double-beats — fires when a turn fails.",
            auto: true,
            // A different *shape*, not just a different hue, so a failure is not
            // mistakable for a completion out of the corner of an eye.
            steps: (0..<3).flatMap { _ in
                [
                    step(red, .solid, 1, 0, 130),
                    step(red, .solid, 0.12, 0, 110),
                    step(red, .solid, 1, 0, 130),
                    step(red, .solid, 0.05, 0, 620),
                ]
            }
        ),
        Show(
            name: "question", label: "Question lap",
            description: "An orange snake lap, then a slow fade to dark.",
            auto: true,
            steps: [step(orange, .snake, 1, 0.16, 3200)]
                + fadeOut(orange, from: 0.5, steps: 10, ms: 65)
        ),
        Show(
            name: "rainbow", label: "Rainbow spin",
            description: "The full hue wheel, fast.",
            auto: false,
            steps: [step(white, .rainbow, 1, 0.95, 6000)]
        ),
        Show(
            name: "police", label: "Police lights",
            description: "Red and blue, alternating hard.",
            auto: false,
            steps: (0..<12).map { step($0 % 2 == 1 ? blue : red, .solid, 1, 0, 260) }
        ),
        Show(
            name: "chase", label: "Snake chase",
            description: "A slow snake through five colors, each one lap.",
            auto: false,
            // Matched to the completion lap: one unhurried lap per color, not a blur.
            steps: [orange, magenta, cyan, green, blue].map { step($0, .snake, 1, 0.12, 2600) }
        ),
        Show(
            name: "sunrise", label: "Sunrise",
            description: "Deep red climbing to daylight, slow.",
            auto: false,
            steps: [
                step(0x2A0000, .solid, 0.35, 0, 900),
                step(0x8A1A00, .solid, 0.55, 0, 900),
                step(0xD44B00, .solid, 0.75, 0, 900),
                step(orange, .solid, 0.9, 0, 900),
                step(0xFFD9A0, .breath, 1, 0.2, 2600),
            ]
        ),
        Show(
            name: "heartbeat", label: "Heartbeat",
            description: "Two quick beats, then a rest. Repeats.",
            auto: false,
            steps: (0..<4).flatMap { _ in
                [
                    step(red, .solid, 1, 0, 130),
                    step(red, .solid, 0.12, 0, 110),
                    step(red, .solid, 1, 0, 130),
                    step(red, .solid, 0.05, 0, 700),
                ]
            }
        ),
        Show(
            name: "strobe", label: "Strobe",
            description: "White, hard on and off. Brief on purpose.",
            auto: false,
            steps: (0..<14).map { step(white, .solid, $0 % 2 == 1 ? 0 : 1, 0, 90) }
        ),
        Show(
            name: "breathe", label: "Slow breathe",
            description: "Cyan to magenta, long and calm.",
            auto: false,
            steps: [
                step(cyan, .breath, 0.9, 0.16, 4000),
                step(magenta, .breath, 0.9, 0.16, 4000),
            ]
        ),
    ]

    public static func show(named name: String) -> Show? {
        all.first { $0.name == name }
    }
}

extension Duration {
    /// Seconds as a Double, for sleeps and deadlines.
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
