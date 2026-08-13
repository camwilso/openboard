import Foundation

/**
 The six-plus-two state vocabulary the whole product is built on.

 Ported verbatim from `lib/config.cjs`. The colors are **hardware** colors: they
 are what the LED is told to emit, not a theme. They must never be restyled to match
 a window's appearance — a swatch in the settings window and the key on the pad are
 the same value, and the moment they diverge the window is lying about the device.

 Two rules from the design brief survive here as invariants rather than prose:

 - Orange belongs to `awaiting` alone. It is the only color that means *act now*,
   and nothing else may compete for that register.
 - `idle` must not be near-white. The pad's own resting state is white, so a white
   key is indistinguishable from an unlit one — and most sessions sit at idle most
   of the time.
 */
public enum SessionState: String, CaseIterable, Sendable, Codable {
    case idle
    case viewing
    case working
    case awaiting
    case stalled
    case done
    case error
    case ended

    /// Display order in the settings window. Not alphabetical: it walks from
    /// "nothing happening" through to "something went wrong".
    /// The states worth giving a color picker to.
    ///
    /// `viewing` is not one of them: it is idle plus the focus pulse, and it takes
    /// idle's color rather than holding one of its own — see `Viewing.appearance`. A
    /// control that edits a value nothing reads is worse than no control at all.
    public static let displayOrder: [SessionState] = [
        .idle, .working, .awaiting, .stalled, .done, .error, .ended,
    ]

    public var label: String {
        switch self {
        case .idle: "idle"
        case .viewing: "viewing"
        case .working: "working"
        case .awaiting: "awaiting"
        case .stalled: "stalled"
        case .done: "done"
        case .error: "error"
        case .ended: "ended"
        }
    }

    public var means: String {
        switch self {
        case .idle: "Session open, nothing running."
        case .viewing: "Idle, and the chat you are looking at."
        case .working: "A turn — or a delegated subagent — is running."
        case .awaiting: "Blocked on a permission prompt."
        case .stalled: "An idle prompt fired."
        case .done: "Finished, and you have not been back yet."
        case .error: "The turn failed."
        case .ended: "Session closed."
        }
    }

    /**
     Whether a new state is allowed to replace the current one.

     Almost always yes. The exception is **`idle` must not overwrite `done`**, because
     `done` already means idle *and* carries something you have not seen yet — that a
     turn finished while you were elsewhere.

     This is not hypothetical. Claude Code fires an `idle_prompt` notification about 60
     seconds after a turn ends, and a configuration that maps that to `idle` repaints
     straight over the green:

         17:59:15  Stop         -> done
         18:00:15  Notification -> idle

     Which looked exactly like a decay timer that had been switched off but was somehow
     still running. It was a hook, arriving on a schedule, doing what it was told.

     Handled here rather than by unmapping `idle_prompt` in one machine's config: any
     mapping that resolves to `idle` has the same effect, and the rule that a completion
     survives until you go back to it should not depend on a notification's wiring.
     */
    public static func mayReplace(_ current: SessionState, with next: SessionState) -> Bool {
        guard next == .idle, current == .done else { return true }
        return false
    }

    /// States that mean a human is being waited on. The popover's orange row and the
    /// status item's color both key off this, so they cannot disagree.
    public var isAttention: Bool { self == .awaiting || self == .stalled }
}

/// How a key is lit: color, motion and level. Mirrors the device's own vocabulary.
public enum LEDEffect: String, CaseIterable, Sendable, Codable {
    case off
    case solid
    case breath
    case shallowBreath = "shallow-breath"
    case rainbow
    case snake
    case gradient

    /// The firmware's numeric codes, established by probing the device.
    public var deviceCode: UInt8 {
        switch self {
        case .off: 0
        case .solid: 1
        case .snake: 2
        case .rainbow: 3
        case .breath: 4
        case .gradient: 5
        case .shallowBreath: 6
        }
    }

    /// Whether `speed` means anything. On a solid or dark key it does not, and a
    /// speed control there implies motion that will never happen.
    public var isAnimated: Bool {
        switch self {
        case .off, .solid: false
        case .breath, .shallowBreath, .rainbow, .snake, .gradient: true
        }
    }

    /// Spatial effects need more than one LED to mean anything. On a single key
    /// `snake` and `gradient` render dark, so they are offered for the ring only —
    /// `ColorsPane` lists the per-key set explicitly rather than using `allCases`.
    public var isSpatial: Bool {
        self == .snake || self == .gradient
    }

    /// What a single key can usefully show.
    public static var perKey: [LEDEffect] {
        allCases.filter { !$0.isSpatial }
    }
}

/// A color as the device understands it: 0xRRGGBB, no alpha.
public struct RGB: Equatable, Sendable, Codable {
    public var value: UInt32

    public init(_ value: UInt32) { self.value = value & 0xFF_FFFF }

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let parsed = UInt32(text, radix: 16) else { return nil }
        self.value = parsed
    }

    public var hex: String { String(format: "#%06X", value) }

    public var red: Double { Double((value >> 16) & 0xFF) / 255 }
    public var green: Double { Double((value >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(value & 0xFF) / 255 }

    /// Near-white keys read as unlit against the pad's white resting state.
    /// Surfaced in the settings window rather than silently corrected — it is the
    /// user's color to choose, they just need to know what it will look like.
    public var isNearWhite: Bool {
        ((value >> 16) & 0xFF) > 224 && ((value >> 8) & 0xFF) > 224 && (value & 0xFF) > 224
    }
}

/// What a state looks like on a key.
public struct Appearance: Equatable, Sendable, Codable {
    public var color: RGB
    public var effect: LEDEffect
    public var brightness: Double
    public var speed: Double

    public init(color: RGB, effect: LEDEffect, brightness: Double, speed: Double = 0) {
        self.color = color
        self.effect = effect
        self.brightness = brightness
        self.speed = speed
    }

    /// A dark surface. Not the same as brightness 0 on a lit effect — the firmware
    /// treats effect 0 as "stop animating" rather than "animate at zero".
    public static let off = Appearance(color: RGB(0), effect: .off, brightness: 0, speed: 0)
}

extension SessionState {
    /// The shipped defaults, byte-identical to `lib/config.cjs`.
    ///
    /// `speed` is carried even though the settings window does not expose it: the
    /// device takes it, the Node version set it, and dropping it here would quietly
    /// change how every breathing key looks.
    public static let defaultAppearances: [SessionState: Appearance] = [
        .idle: Appearance(color: RGB(0x2E4A6B), effect: .solid, brightness: 0.55, speed: 0),
        .viewing: Appearance(color: RGB(0x2E4A6B), effect: .shallowBreath, brightness: 0.85, speed: 0.25),
        .working: Appearance(color: RGB(0x0C47E9), effect: .breath, brightness: 0.75, speed: 0.45),
        .awaiting: Appearance(color: RGB(0xFF6A00), effect: .breath, brightness: 0.95, speed: 0.75),
        .stalled: Appearance(color: RGB(0xFF6A00), effect: .shallowBreath, brightness: 0.5, speed: 0.3),
        .done: Appearance(color: RGB(0x09B821), effect: .solid, brightness: 0.7, speed: 0),
        .error: Appearance(color: RGB(0xD41145), effect: .breath, brightness: 0.9, speed: 0.8),
        .ended: Appearance(color: RGB(0x000000), effect: .off, brightness: 0, speed: 0),
    ]

    public var defaultAppearance: Appearance {
        SessionState.defaultAppearances[self] ?? Appearance(color: RGB(0), effect: .off, brightness: 0)
    }
}

/**
 `viewing` — the session you are actually looking at.

 Deliberately **derived at render time and never stored**. Focus changes constantly;
 writing it into the registry would mean every switch away has to correctly restore
 whatever the real state was, and one missed restore leaves a session permanently
 mislabelled. Keeping it an overlay makes that class of bug impossible.
 */
public enum Viewing {
    /**
     What a slot should display, given whether it is the focused one.

     Only `idle` is promoted. A focused session that is working, waiting or failed
     already says something more useful than "you are looking at it" — and overwriting
     `awaiting` in particular would hide the one color that must never be hidden.
     */
    public static func display(_ state: SessionState, isFocused: Bool) -> SessionState {
        guard isFocused, state == .idle else { return state }
        return .viewing
    }

    /**
     Make the focused key findable, whatever it is showing.

     `viewing` handles the idle case by swapping state — same blue, but breathing. That
     leaves every other focused key looking exactly like the five you are not in. The
     one you notice is a finished session: green, solid, and indistinguishable from a
     green key across the board.

     So focus adds **motion**, never a color. A finished-and-focused key is still green
     — it has to be, because green is the thing you came back for — it just breathes,
     which is the same signal `viewing` already uses for "you are here".

     Only applied to states that are not already animated. `awaiting` and `error`
     breathe on their own and are the loudest things on the board; making them breathe
     differently because you happen to be looking at one would be motion competing with
     motion for no gain.
     */
    public static func focused(_ appearance: Appearance, isFocused: Bool) -> Appearance {
        guard isFocused, appearance.effect == .solid, appearance.brightness > 0 else {
            return appearance
        }
        var pulsed = appearance
        pulsed.effect = .shallowBreath
        // The same treatment `viewing` gets over `idle`: a little brighter, gently
        // paced, so it reads as attention rather than as activity.
        pulsed.brightness = min(1, appearance.brightness + 0.15)
        pulsed.speed = 0.25
        return pulsed
    }

    /**
     What a slot actually emits — the one place focus is resolved.

     `viewing` deliberately has **no color of its own**. It is idle-with-your-attention,
     so it takes idle's *configured* appearance and adds the pulse. It used to be a
     separately configured state, and that is exactly the bug this fixes: idle was set
     to white, `viewing` still held the shipped slate blue, and the key you were looking
     at breathed a color nothing else on the board was showing.

     A focus overlay must never carry a color. The moment it does, it contradicts
     whatever the user chose for the state underneath it — and the user's answer is the
     one that has to win, because they are the one who picked it.

     Every surface goes through here — pad, menu-bar dot, popover swatch — so none of
     them can describe a key the hardware is not showing.
     */
    public static func appearance(
        _ state: SessionState,
        isFocused: Bool,
        from appearances: [SessionState: Appearance] = SessionState.defaultAppearances
    ) -> Appearance {
        // `viewing` is only ever produced by `display` for a focused idle session, so
        // it carries its own focus regardless of what the caller passes.
        let underlying: SessionState = state == .viewing ? .idle : state
        let configured = appearances[underlying] ?? underlying.defaultAppearance
        return focused(configured, isFocused: isFocused || state == .viewing)
    }
}
