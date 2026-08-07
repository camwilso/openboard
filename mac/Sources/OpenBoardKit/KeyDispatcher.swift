import Foundation

/**
 Turns raw key events into intents.

 Pure and time-injected, so the awkward parts — debounce windows, a keycap that
 reports twice, an encoder that must never be debounced — can be tested without a pad
 or a stopwatch. The side effects live in the app; only the decisions live here.

 The pad broadcasts every press on the vendor channel, which is what lets it stay on
 Layer 1 with Codex's locked keycodes and still mean something to us. Nothing is
 remapped; meaning is assigned here.
 */
public struct KeyDispatcher {
    public enum Intent: Equatable, Sendable {
        /// Raise the window hosting this slot's session.
        case jump(slot: Int)
        /// Run the action bound to this key.
        case action(KeyAction, key: String)
        /// A held key was released — only push-to-talk cares.
        case release(key: String)
        /// Encoder rotation, in discrete ticks.
        case scroll(lines: Int)
        /// The dial's button went down. Which action it means depends on how long it
        /// stays down, so the caller times it.
        case encoderPressed
    }

    /// Repeats of the same key inside this window are dropped.
    ///
    /// This mattered little when approve sent `y` — a no-op in a select dialog — but
    /// it sends Return now, and a burst can accept a prompt and then submit empty
    /// input to the session behind it.
    public var debounce: TimeInterval = 0.4

    /// What each action key is bound to.
    public var actions: [String: KeyAction]
    /// What clicking the encoder does.
    public var encoderClick: KeyAction?
    /// Lines per encoder tick.
    public var scrollLines = 3
    /**
     Which way a clockwise turn scrolls.

     Configurable because there is no correct answer. macOS ships "natural" scrolling on
     by default and a great many people turn it off, so the direction someone expects
     from a physical dial depends on a system setting this app cannot read reliably —
     and an encoder that scrolls the wrong way is not a preference, it is a broken dial.

     Stored as `encoder.cw` / `encoder.cc` in the config, matching the Node schema.
     */
    public var clockwiseScrollsUp = true

    private var lastFired: [String: Date] = [:]

    public init(actions: [String: KeyAction] = KeyAction.defaults, encoderClick: KeyAction? = nil) {
        self.actions = actions
        self.encoderClick = encoderClick ?? actions["ENC"]
    }

    /// Encoder rotation. `act: 2`, with no matching release.
    private static let encoderTicks: [String: Int] = ["ENC_CW": 1, "ENC_CC": -1]
    private static let encoderClickKey = "ENC_CLK"

    /**
     Decide what a key event means, or nil for nothing.

     - Parameter now: injected so debounce behaviour is testable.
     */
    public mutating func intent(for event: KeyEvent, now: Date = Date()) -> Intent? {
        // Rotation first, and deliberately before every other rule: ticks are not
        // presses, they have no release, and debouncing them would drop most of a
        // fast turn — which makes the encoder feel broken rather than sensitive.
        if event.action == .tick, let direction = Self.encoderTicks[event.key] {
            // Positive is up. Inverting flips both directions together — binding cw and
            // cc to the *same* direction would give a dial that only scrolls one way.
            let sign = clockwiseScrollsUp ? 1 : -1
            return .scroll(lines: direction * sign * scrollLines)
        }

        // A wide keycap reports two switch names milliseconds apart. Collapse them
        // before debouncing, or the debounce never sees a repeat and both fire —
        // and when one of them holds a key down, the other types into it.
        let key = BoardLayout.canonical(event.key)

        // Releases are delivered raw: never debounced, never deduplicated. A dropped
        // release leaves a key held down indefinitely, which is invisible until every
        // subsequent keystroke is wrong.
        if event.action == .up {
            guard BoardLayout.slot(forKey: key) == nil else { return nil }
            return .release(key: key)
        }

        guard event.action == .down else { return nil }

        if let previous = lastFired[key], now.timeIntervalSince(previous) < debounce {
            return nil
        }
        lastFired[key] = now

        if let slot = BoardLayout.slot(forKey: key) {
            return .jump(slot: slot)
        }
        // The dial's click is not decided here. It has two bindings — press and
        // press-and-hold — and which one applies is not known until either the hold
        // threshold passes or the button comes back up. The controller owns that timer;
        // this reports the edge.
        if key == Self.encoderClickKey {
            return .encoderPressed
        }
        guard let action = actions[key] else { return nil }
        return .action(action, key: key)
    }

    /// Forget debounce history — used when bindings change, so a rebind is not
    /// swallowed by the previous key's window.
    public mutating func reset() { lastFired.removeAll() }
}
