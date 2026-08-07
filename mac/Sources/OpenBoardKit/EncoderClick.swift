import Foundation

/**
 One button, two actions: press and press-and-hold.

 The dial is the only control on the pad you reach for without looking, so it is worth
 more than one binding. A short press opens the menu; holding it opens Settings.

 ## Why the long action fires while still held

 The obvious implementation classifies on *release* — measure how long the button was
 down, then act. It feels broken. You hold the dial, nothing happens, you let go, and
 the window appears after the fact; there is no way to tell whether you have held it
 long enough, so people release early and get the wrong action.

 Firing *at* the threshold, while the button is still down, means the hold has visible
 feedback and the release is a no-op. That is how every long-press on the platform
 behaves, and it is why this is a small state machine rather than a subtraction.

 Kept pure — the caller owns the timer — so the ordering rules can be tested without
 waiting in real time for anything.
 */
public struct EncoderClick: Sendable {
    /// How long the dial must be held before the long action takes over.
    ///
    /// 450ms: long enough that an ordinary click never trips it, short enough that the
    /// hold does not feel like a hang. macOS uses roughly this for its own press-and-hold.
    public var threshold: TimeInterval

    private var pressedAt: Date?
    private var longFired = false

    public init(threshold: TimeInterval = 0.45) {
        self.threshold = threshold
    }

    public enum Release: Equatable, Sendable {
        /// A short press. Fire the click action.
        case short
        /// The long action already fired while the button was held; releasing does
        /// nothing. Without this the dial would fire *both* actions on every hold.
        case handled
        /// A release with no matching press — a dropped report, or a press that
        /// arrived before the app was listening. Not an action.
        case spurious
    }

    public var isPressed: Bool { pressedAt != nil }

    /// The instant the long action becomes due, or nil if nothing is held.
    public var longPressDeadline: Date? {
        pressedAt.map { $0.addingTimeInterval(threshold) }
    }

    public mutating func press(now: Date = Date()) {
        pressedAt = now
        longFired = false
    }

    /**
     Whether the long action should fire now.

     Returns true exactly once per press. A timer can be late, or fire after the button
     is already up — both would otherwise open a second window.
     */
    public mutating func shouldFireLong(now: Date = Date()) -> Bool {
        guard let pressedAt, !longFired else { return false }
        guard now.timeIntervalSince(pressedAt) >= threshold else { return false }
        longFired = true
        return true
    }

    public mutating func release(now: Date = Date()) -> Release {
        defer {
            pressedAt = nil
            longFired = false
        }
        guard pressedAt != nil else { return .spurious }
        return longFired ? .handled : .short
    }

    /// Forget a press without acting on it — used when the bindings change underneath,
    /// so a dial held across a rebind does not fire the old action.
    public mutating func reset() {
        pressedAt = nil
        longFired = false
    }
}
