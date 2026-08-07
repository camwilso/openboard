import Foundation

/**
 What the outer ring should show.

 The ring's value is that it is visible from across the room, where six small keys are
 not. So it **summarises rather than duplicates**: the most urgent state anywhere on the
 board wins, which answers "does anything want me?" without reading individual keys.

 Ported from `lib/ambient.cjs`, and pure, so the priority rules can be checked without a
 pad.
 */
public enum Ambient {
    /// Most urgent first. `stalled` folds into `awaiting` — both mean a human is needed.
    public static let priority: [SessionState] = [.awaiting, .error, .working, .done, .idle]

    /**
     Collapse the states that are distinct on a key but not on the ring.

     The ring has one LED strip and one question to answer. `viewing` is idle with a
     window focused, which nobody across the room can act on; `ended` is not board
     activity at all and must not hold the ring lit after a session closes.
     */
    public static func normalise(_ state: SessionState?) -> SessionState? {
        switch state {
        case .stalled: .awaiting
        case .viewing: .idle
        case .ended: nil
        default: state
        }
    }

    public enum Mode: String, Sendable, CaseIterable {
        /// Dark, except for laps. The ring is a notification surface, not a status
        /// display — a lap fires on a transition and then it goes back to nothing.
        case events
        /// Continuously shows the most urgent state on the board.
        case aggregate
        /// One color, always.
        case fixed
        /// Never lights.
        case off
    }

    public struct Resolution: Equatable, Sendable {
        /// The state that won, or nil in the modes that do not summarise.
        public let state: SessionState?
        public let appearance: Appearance

        public init(state: SessionState?, appearance: Appearance) {
            self.state = state
            self.appearance = appearance
        }
    }

    /**
     What the ring should be showing right now.

     - Parameter states: one per slot, nil for a free slot.
     - Returns: nil means *leave the ring alone* — distinct from `.off`, which means
       actively paint it dark. A lap in progress relies on that difference.
     */
    public static func resolve(
        states: [SessionState?],
        mode: Mode,
        appearances: [SessionState: Appearance],
        fixed: Appearance? = nil
    ) -> Resolution? {
        switch mode {
        case .events, .off:
            // Both paint dark. They differ in what *else* may light the ring: `events`
            // still fires laps, `off` never does.
            return Resolution(state: nil, appearance: .off)
        case .fixed:
            return Resolution(state: nil, appearance: fixed ?? .off)
        case .aggregate:
            break
        }

        let present = Set(states.compactMap { normalise($0) })
        guard let winner = priority.first(where: { present.contains($0) }) else {
            // An empty board is dark, not "the least urgent thing that could be true".
            return Resolution(state: nil, appearance: .off)
        }
        guard let appearance = appearances[winner] else { return nil }
        return Resolution(state: winner, appearance: appearance)
    }

    /// Whether laps may fire at all in this mode.
    ///
    /// `aggregate` deliberately keeps them: the ring holding a color and the ring
    /// flashing a lap are different signals and do not conflict.
    public static func lapsAllowed(in mode: Mode) -> Bool {
        mode != .off
    }
}

/**
 Which show a state change should fire, if any.

 Pure and separate from the controller so the one rule that matters — **laps fire on a
 transition, never on a repaint** — is testable. Firing on every paint turns the ring
 into a strobe, and worse, teaches you that a lap means nothing.
 */
public enum Laps {
    public static func show(
        from previous: SessionState?,
        to next: SessionState?,
        settings: Preferences.Ambient
    ) -> String? {
        // A repaint is not an event. This is the whole rule.
        guard previous != next else { return nil }
        guard let mode = Ambient.Mode(rawValue: settings.mode),
              Ambient.lapsAllowed(in: mode) else { return nil }

        switch next {
        case .done:
            return settings.completionLap ? "completion" : nil
        case .awaiting, .stalled:
            // Both mean a human is needed, and both earn the same lap — the distinction
            // matters on the key, not from across the room.
            return settings.questionLap ? "question" : nil
        case .error:
            return settings.errorPulse ? "error" : nil
        default:
            return nil
        }
    }
}
