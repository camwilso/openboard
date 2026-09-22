import Foundation

/**
 Everything the user can change, in the file they already have.

 `~/.claude/openboard/config.json` — the **same path and same schema** the Node version
 wrote, so an existing configuration is picked up unchanged. That is not a nicety: this
 machine's file already carries a white `idle` at 0.2, `working` and `awaiting` on
 shallow-breath, `idle_prompt` mapped to `idle`, and `ACT11` explicitly unassigned. A
 rewrite that quietly ignored all of it would look like the app was broken.

 Named `Preferences` rather than `Settings` because SwiftUI owns that name for the
 settings *scene*, and the collision is silent until it is not.

 ## Stored documents are partial, and merged field by field

 The file holds **overrides only** — `lib/config.cjs` deep-merges it over the built-in
 defaults, so a state may specify just `effect` and inherit its color, brightness and
 speed. Anything less granular would turn a one-line override into a half-configured
 state.

 ## Colors are numbers on disk

 The Node version stored `0xRRGGBB` as a JSON number, so `16777215` is white. Hex
 strings are accepted too, because they are what a person types when hand-editing, and
 numbers are written back so the file stays readable by either implementation.
 */
public struct Preferences: Equatable, Sendable {
    public var states: [String: Appearance]
    /// Action key bindings. A key present with `nil` is *explicitly* unassigned, which
    /// is different from a key that is absent and inherits its default.
    public var actionKeys: [String: KeyAction?]
    public var snippets: [String: String]
    /// Chords for keys bound to `.shortcut`, keyed like `snippets` — plus `ENC`,
    /// `ENC.long` and `JOY.up`… for the controls whose bindings share one name.
    public var shortcuts: [String: Shortcut]
    /// Keycap icon per key. New in the app; absent from Node documents, which is fine.
    public var caps: [String: String]
    /**
     What you call your pad, by hardware serial.

     Every Codex Micro reports the same product name, so "Connected to Codex Micro"
     says nothing to someone with two of them — and macOS's own disambiguation is a
     pairing counter, "#1" and "#3", which is about this Mac's pairing history rather
     than about the object.

     Keyed by `kIOHIDSerialNumberKey` because that is the only identifier that belongs
     to the device: it survives re-pairing, moving between machines, and the switch
     between Bluetooth and USB.
     */
    public var deviceNames: [String: String]
    /**
     Harnesses that have ever reported an event, by id.

     Not "connected right now" — that is answerable from the hooks and the process
     table. This is the weaker, more useful question for a settings window: has this
     thing *ever* worked here? A harness that has never sent an event has nothing to
     say about its own behaviour, so the pane shows setup instead of tables describing
     events it has not seen.

     Written the first time one arrives and never cleared. A harness that worked last
     month and is quiet today is set up; it is simply not running.
     */
    public var harnessesSeen: [String]
    public var events: [String: Bool]
    public var notifications: [String: SessionState?]
    public var encoder: Encoder
    public var joystick: Joystick
    public var ambient: Ambient
    public var countdown: Countdown
    public var entrypoints: [String]
    public var scrollLines: Int
    public var staleHours: Int
    public var doneDecaySeconds: Int
    /// Whether a session waiting on you keeps its color until the prompt is answered.
    ///
    /// Replaced `attentionTimeoutSeconds`, which asked how many minutes to wait before
    /// giving up on a prompt — a question with no good answer, about an event that
    /// should not happen. Off restores the old safety net at a fixed 15 minutes.
    public var holdAttention: Bool
    public var maxHoldSeconds: Int
    /// Whether the voice keys drive dictation through the `voice:pushToTalk`
    /// keybinding chord (⌃Y) instead of tapping space. Space is overloaded — with
    /// text in the chat input it types a space instead of starting dictation — and
    /// a bound chord types nothing, ever. Off by default because it only works once
    /// the chord is added to `~/.claude/keybindings.json`.
    public var voiceChord: Bool

    public struct Encoder: Equatable, Sendable {
        /// `scroll-up` or `scroll-down`, per direction.
        public var cw: String
        public var cc: String
        public var click: KeyAction?
        /// What holding the dial does. The dial is the one control you reach for
        /// without looking, so it is worth more than a single binding.
        public var longPress: KeyAction?
        /// How long is "held", in milliseconds.
        public var longPressMs: Int

        public init(
            cw: String = "scroll-up",
            cc: String = "scroll-down",
            click: KeyAction? = .popover,
            longPress: KeyAction? = .settings,
            longPressMs: Int = 450
        ) {
            self.cw = cw
            self.cc = cc
            self.click = click
            self.longPress = longPress
            self.longPressMs = longPressMs
        }

        public var longPressInterval: TimeInterval { Double(longPressMs) / 1000 }

        /// The two directions collapsed to the one bit the dispatcher needs.
        ///
        /// Only `cw` is consulted. The schema stores both, but a document setting them
        /// to the same direction describes a dial that scrolls one way whichever way it
        /// is turned — so `cc` is treated as the mirror of `cw` rather than obeyed
        /// literally into a state no one would want.
        public var clockwiseScrollsUp: Bool {
            get { cw != "scroll-down" }
            set {
                cw = newValue ? "scroll-up" : "scroll-down"
                cc = newValue ? "scroll-down" : "scroll-up"
            }
        }
    }

    /// The joystick: four directions, each bindable, plus the orientation needed to
    /// know which reported angle is which physical direction.
    public struct Joystick: Equatable, Sendable {
        public var up: KeyAction?
        public var down: KeyAction?
        public var left: KeyAction?
        public var right: KeyAction?
        /// The angle the stick reports when pushed up. Not guessable from the numbers —
        /// the four cardinals are evenly spaced, so which is "up" is a fact about the
        /// hardware, and getting it wrong swaps the axes.
        public var northAngle: Double
        public var clockwise: Bool
        public var threshold: Double

        public init(
            up: KeyAction? = .arrowUp,
            down: KeyAction? = .arrowDown,
            left: KeyAction? = .tabBack,
            right: KeyAction? = .tabForward,
            northAngle: Double = 0,
            clockwise: Bool = true,
            threshold: Double = 0.5
        ) {
            self.up = up
            self.down = down
            self.left = left
            self.right = right
            self.northAngle = northAngle
            self.clockwise = clockwise
            self.threshold = threshold
        }

        public func action(for direction: OpenBoardKit.Joystick.Direction) -> KeyAction? {
            switch direction {
            case .up: up
            case .down: down
            case .left: left
            case .right: right
            }
        }
    }

    public struct Ambient: Equatable, Sendable {
        /// `events` · `aggregate` · `fixed` · `off`
        public var mode: String
        public var completionLap: Bool
        public var questionLap: Bool
        public var errorPulse: Bool
        /// Spin the ring while dictation is believed to be running. Overrides every
        /// mode, including `off` — see `BoardController.ambientSide`.
        public var voiceRainbow: Bool
        /// What `fixed` mode holds. Without this the mode is documented, selectable and
        /// silently dark — the resolver has nothing to return.
        public var fixed: Appearance

        public init(
            mode: String = "events",
            completionLap: Bool = true,
            questionLap: Bool = true,
            errorPulse: Bool = true,
            voiceRainbow: Bool = true,
            fixed: Appearance = Appearance(
                color: RGB(0x2E4A6B), effect: .solid, brightness: 0.35, speed: 0
            )
        ) {
            self.mode = mode
            self.completionLap = completionLap
            self.questionLap = questionLap
            self.errorPulse = errorPulse
            self.voiceRainbow = voiceRainbow
            self.fixed = fixed
        }
    }

    public struct Countdown: Equatable, Sendable {
        /// Fires each cue early, to cancel a ~86ms ring write plus audio latency.
        public var leadMs: Int
        public var introFlashSec: Double
        public var introFlashColor: RGB
        /// The pre-flash countdown bar on the keys.
        ///
        /// Cold and dim on purpose: it has to build toward the flash and then lose to
        /// it, so it must never approach the reveal's brightness or its hue.
        public var introEnabled: Bool
        public var introColorKeys: RGB
        public var introBrightness: Double
        public var introTrail: Double
        /// Lifts every brightness in the show for a lit room. See `Countdown.lift` for
        /// why this is a gamma curve and not a multiplier.
        ///
        /// No longer has a control. It was a slider nobody moves twice — the answer is
        /// "bright enough for the room you are in", which is one decision per room, not
        /// per viewing. Fixed at the value this pad was tuned to, and still readable
        /// from `config.json` for a genuinely darker or brighter one.
        public var gain: Double
        /// Where the video and its analysis live. Empty means "work it out" — beside
        /// the app, then the source tree it was built from.
        public var mediaDir: String

        public init(
            leadMs: Int = 70,
            introFlashSec: Double = 13.2,
            introFlashColor: RGB = RGB(0xFF2D95),
            introEnabled: Bool = true,
            introColorKeys: RGB = RGB(0x1B2A6B),
            // 0.6, matching `Countdown.introFrame`'s own default and the reasoning in
            // its comment. This shipped as 0.3 — the value lib/countdown.cjs passed —
            // and at 0.3 the bar renders *backwards* on offbeats: the leading key is
            // 0.3 x 0.6 = 0.18 against a 0.2 trail, so the front edge is dimmer than
            // its own tail on half the frames. At 0.6 the lead, the trail and the empty
            // keys land in three different `step()` buckets on every frame.
            introBrightness: Double = 0.6,
            introTrail: Double = 0.2,
            // 2, not the authored 1. The show is watched in a lit room with the pad an
            // arm's length away, and at 1 the quiet passages are invisible from there.
            // The curve is what makes this safe to raise: it lifts the quiet end without
            // crushing the loud one, so the dynamics survive. See `Countdown.lift`.
            gain: Double = 2,
            mediaDir: String = ""
        ) {
            self.leadMs = leadMs
            self.introFlashSec = introFlashSec
            self.introFlashColor = introFlashColor
            self.introEnabled = introEnabled
            self.introColorKeys = introColorKeys
            self.introBrightness = introBrightness
            self.introTrail = introTrail
            self.gain = gain
            self.mediaDir = mediaDir
        }
    }

    public static let `default` = Preferences(
        states: Dictionary(
            uniqueKeysWithValues: SessionState.allCases.map { ($0.rawValue, $0.defaultAppearance) }
        ),
        actionKeys: KeyAction.defaults.mapValues { Optional($0) },
        snippets: ["ACT08": "/start-ticket"],
        caps: KeycapCatalog.defaultCaps,
        deviceNames: [:],
        harnessesSeen: [],
        events: [:],
        notifications: EventMapper.defaultNotifications.mapValues { Optional($0) },
        encoder: Encoder(),
        joystick: Joystick(),
        ambient: Ambient(),
        countdown: Countdown(),
        entrypoints: Array(Eligibility.defaultEntrypoints).sorted(),
        scrollLines: 3,
        staleHours: 12,
        // 0 means never: green holds until you go back to that session and send
        // something. See SessionRegistry.decay.
        doneDecaySeconds: 0,
        holdAttention: true,
        maxHoldSeconds: 60
    )

    public init(
        states: [String: Appearance],
        actionKeys: [String: KeyAction?],
        snippets: [String: String],
        shortcuts: [String: Shortcut] = [:],
        caps: [String: String],
        deviceNames: [String: String] = [:],
        harnessesSeen: [String] = [],
        events: [String: Bool],
        notifications: [String: SessionState?],
        encoder: Encoder,
        joystick: Joystick,
        ambient: Ambient,
        countdown: Countdown,
        entrypoints: [String],
        scrollLines: Int,
        staleHours: Int,
        doneDecaySeconds: Int,
        holdAttention: Bool = true,
        maxHoldSeconds: Int,
        voiceChord: Bool = false
    ) {
        self.states = states
        self.actionKeys = actionKeys
        self.snippets = snippets
        self.shortcuts = shortcuts
        self.caps = caps
        self.deviceNames = deviceNames
        self.harnessesSeen = harnessesSeen
        self.events = events
        self.notifications = notifications
        self.encoder = encoder
        self.joystick = joystick
        self.ambient = ambient
        self.countdown = countdown
        self.entrypoints = entrypoints
        self.scrollLines = scrollLines
        self.staleHours = staleHours
        self.doneDecaySeconds = doneDecaySeconds
        self.holdAttention = holdAttention
        self.maxHoldSeconds = maxHoldSeconds
        self.voiceChord = voiceChord
    }

    // MARK: - typed accessors

    public func appearance(for state: SessionState) -> Appearance {
        states[state.rawValue] ?? state.defaultAppearance
    }

    public mutating func setAppearance(_ appearance: Appearance, for state: SessionState) {
        states[state.rawValue] = appearance
    }

    /// Bindings that are actually set. An explicit `nil` drops out here, which is what
    /// "unassigned" means to a caller looking one up.
    public var keyActions: [String: KeyAction] {
        actionKeys.compactMapValues { $0 }
    }

    public var notificationStates: [String: SessionState] {
        notifications.compactMapValues { $0 }
    }

    public var staleInterval: TimeInterval { TimeInterval(staleHours) * 3600 }
}

// MARK: - JSON, in the Node document's shape

extension Preferences {
    /**
     Merge a stored document over the defaults, field by field.

     Mirrors `lib/config.cjs`'s `deepMerge`: a nested object merges into its default
     rather than replacing it, so `{"states":{"working":{"effect":"shallow-breath"}}}`
     keeps working's color, brightness and speed.
     */
    public static func merging(
        _ json: [String: Any],
        over base: Preferences = .default
    ) -> Preferences {
        var result = base

        if let states = json["states"] as? [String: Any] {
            for (name, raw) in states {
                guard let fields = raw as? [String: Any],
                      let state = SessionState(rawValue: name) else { continue }
                var appearance = result.states[name] ?? state.defaultAppearance
                if let color = parseColor(fields["color"]) { appearance.color = color }
                if let effect = fields["effect"] as? String,
                   let parsed = LEDEffect(rawValue: effect) { appearance.effect = parsed }
                if let brightness = fields["brightness"] as? Double {
                    appearance.brightness = min(max(brightness, 0), 1)
                }
                if let speed = fields["speed"] as? Double {
                    appearance.speed = min(max(speed, 0), 1)
                }
                result.states[name] = appearance
            }
        }

        if let keys = json["actionKeys"] as? [String: Any] {
            for (key, raw) in keys {
                // `null` is an explicit unassign and must survive as one, or the key
                // silently reverts to its default on the next launch.
                if raw is NSNull { result.actionKeys[key] = KeyAction?.none; continue }
                guard let name = raw as? String,
                      let action = KeyAction(rawValue: name) else { continue }
                result.actionKeys[key] = action
            }
        }

        if let snippets = json["snippets"] as? [String: String] {
            result.snippets.merge(snippets) { _, new in new }
        }
        if let shortcuts = json["shortcuts"] as? [String: Any] {
            // An entry without a key code is skipped, not fatal — like an unknown
            // action name in `actionKeys`.
            for (key, raw) in shortcuts {
                guard let fields = raw as? [String: Any],
                      let shortcut = Shortcut(json: fields) else { continue }
                result.shortcuts[key] = shortcut
            }
        }
        if let caps = json["caps"] as? [String: String] {
            result.caps.merge(caps) { _, new in new }
        }
        if let names = json["deviceNames"] as? [String: String] {
            result.deviceNames.merge(names) { _, new in new }
        }
        if let seen = json["harnessesSeen"] as? [String] {
            // Merged rather than replaced, like everything else here: a document
            // written by an older build knows about fewer harnesses, and forgetting one
            // would put a working harness back into its empty state.
            result.harnessesSeen = Array(Set(result.harnessesSeen).union(seen)).sorted()
        }
        if let events = json["events"] as? [String: Bool] {
            result.events.merge(events) { _, new in new }
        }

        if let notifications = json["notifications"] as? [String: Any] {
            for (kind, raw) in notifications {
                if raw is NSNull { result.notifications[kind] = SessionState?.none; continue }
                guard let name = raw as? String,
                      let state = SessionState(rawValue: name) else { continue }
                result.notifications[kind] = state
            }
        }

        if let encoder = json["encoder"] as? [String: Any] {
            if let cw = encoder["cw"] as? String { result.encoder.cw = cw }
            if let cc = encoder["cc"] as? String { result.encoder.cc = cc }
            if encoder["click"] is NSNull {
                result.encoder.click = nil
            } else if let click = encoder["click"] as? String {
                result.encoder.click = KeyAction(rawValue: click)
            }
            if encoder["longPress"] is NSNull {
                result.encoder.longPress = nil
            } else if let long = encoder["longPress"] as? String {
                result.encoder.longPress = KeyAction(rawValue: long)
            }
            if let ms = encoder["longPressMs"] as? Int {
                // Bounded: below ~150ms an ordinary click trips it, and above a couple
                // of seconds the hold feels like the app has hung.
                result.encoder.longPressMs = min(2000, max(150, ms))
            }
        }

        if let stick = json["joystick"] as? [String: Any] {
            for (name, path) in [
                ("up", \Joystick.up), ("down", \Joystick.down),
                ("left", \Joystick.left), ("right", \Joystick.right),
            ] as [(String, WritableKeyPath<Joystick, KeyAction?>)] {
                if stick[name] is NSNull {
                    result.joystick[keyPath: path] = nil
                } else if let raw = stick[name] as? String {
                    result.joystick[keyPath: path] = KeyAction(rawValue: raw)
                }
            }
            if let angle = stick["northAngle"] as? Double {
                result.joystick.northAngle = angle
            }
            if let cw = stick["clockwise"] as? Bool { result.joystick.clockwise = cw }
            if let t = stick["threshold"] as? Double {
                result.joystick.threshold = min(0.95, max(0.1, t))
            }
        }

        if let ambient = json["ambient"] as? [String: Any] {
            if let mode = ambient["mode"] as? String { result.ambient.mode = mode }
            if let lap = ambient["completionLap"] as? Bool { result.ambient.completionLap = lap }
            if let lap = ambient["questionLap"] as? Bool { result.ambient.questionLap = lap }
            if let pulse = ambient["errorPulse"] as? Bool { result.ambient.errorPulse = pulse }
            if let spin = ambient["voiceRainbow"] as? Bool { result.ambient.voiceRainbow = spin }
            // Same partial-override rule as a state: a document naming only the color
            // keeps the default effect and brightness.
            if let fields = ambient["fixed"] as? [String: Any] {
                if let color = parseColor(fields["color"]) { result.ambient.fixed.color = color }
                if let effect = fields["effect"] as? String,
                   let parsed = LEDEffect(rawValue: effect) { result.ambient.fixed.effect = parsed }
                if let value = fields["brightness"] as? Double {
                    result.ambient.fixed.brightness = value
                }
                if let value = fields["speed"] as? Double { result.ambient.fixed.speed = value }
            }
        }

        if let countdown = json["countdown"] as? [String: Any] {
            if let lead = countdown["leadMs"] as? Int { result.countdown.leadMs = lead }
            if let sec = countdown["introFlashSec"] as? Double {
                result.countdown.introFlashSec = sec
            }
            if let color = parseColor(countdown["introFlashColor"]) {
                result.countdown.introFlashColor = color
            }
            // Clamped on the way in: a stored 0 would blank the entire show, and a
            // hand-edited 20 would flatten it to maximum on every beat.
            if let value = countdown["gain"] as? Double, value > 0 {
                result.countdown.gain = min(4, max(0.25, value))
            }
            // Nested one level down, matching lib/countdown.cjs's `cfg.intro`.
            if let intro = countdown["intro"] as? [String: Any] {
                if let enabled = intro["enabled"] as? Bool { result.countdown.introEnabled = enabled }
                if let color = parseColor(intro["color"]) { result.countdown.introColorKeys = color }
                if let value = intro["brightness"] as? Double {
                    result.countdown.introBrightness = value
                }
                if let value = intro["trail"] as? Double { result.countdown.introTrail = value }
            }
            if let dir = countdown["mediaDir"] as? String {
                result.countdown.mediaDir = dir
            }
        }

        if let entrypoints = json["entrypoints"] as? [String] { result.entrypoints = entrypoints }
        if let value = json["scrollLines"] as? Int { result.scrollLines = value }
        if let value = json["staleHours"] as? Int { result.staleHours = value }
        if let value = json["doneDecaySeconds"] as? Int { result.doneDecaySeconds = value }
        if let value = json["holdAttention"] as? Bool { result.holdAttention = value }
        /*
         An old document's timeout, read as the decision it encoded.

         Only a value that *differs* from the old shipped default is one. Almost every
         existing file carries 900 because that is what was written on first launch, not
         because anyone chose it — migrating those to "expire" would hand the entire
         installed base the opposite of the new behaviour on the strength of a number
         they never typed. 0 already meant never expire.
        */
        let oldDefault = 900
        if json["holdAttention"] == nil, let legacy = json["attentionTimeoutSeconds"] as? Int {
            result.holdAttention = legacy <= 0 || legacy == oldDefault
        }
        if let value = json["maxHoldSeconds"] as? Int { result.maxHoldSeconds = value }
        if let value = json["voiceChord"] as? Bool { result.voiceChord = value }

        return result
    }

    /// A color is a packed number on disk, but a hand-editor reaches for hex.
    private static func parseColor(_ raw: Any?) -> RGB? {
        if raw is NSNull { return nil }
        if let number = raw as? NSNumber {
            let value = number.intValue
            guard value >= 0, value <= 0xFF_FFFF else { return nil }
            return RGB(UInt32(value))
        }
        if let text = raw as? String { return RGB(hex: text) }
        return nil
    }

    /// The document to write. Numbers for colors, matching what Node wrote, so the
    /// file stays readable by either implementation.
    public var json: [String: Any] {
        var states: [String: Any] = [:]
        for (name, appearance) in self.states {
            states[name] = [
                "color": Int(appearance.color.value),
                "effect": appearance.effect.rawValue,
                "brightness": appearance.brightness,
                "speed": appearance.speed,
            ]
        }

        var keys: [String: Any] = [:]
        for (key, action) in actionKeys { keys[key] = action?.rawValue ?? NSNull() }

        var notifications: [String: Any] = [:]
        for (kind, state) in self.notifications {
            notifications[kind] = state?.rawValue ?? NSNull()
        }

        return [
            "states": states,
            "actionKeys": keys,
            "snippets": snippets,
            "shortcuts": shortcuts.mapValues(\.json),
            "caps": caps,
            "deviceNames": deviceNames,
            "harnessesSeen": harnessesSeen,
            "events": events,
            "notifications": notifications,
            "encoder": [
                "cw": encoder.cw,
                "cc": encoder.cc,
                "click": encoder.click?.rawValue ?? NSNull(),
                "longPress": encoder.longPress?.rawValue ?? NSNull(),
                "longPressMs": encoder.longPressMs,
            ],
            "joystick": [
                "up": joystick.up?.rawValue ?? NSNull(),
                "down": joystick.down?.rawValue ?? NSNull(),
                "left": joystick.left?.rawValue ?? NSNull(),
                "right": joystick.right?.rawValue ?? NSNull(),
                "northAngle": joystick.northAngle,
                "clockwise": joystick.clockwise,
                "threshold": joystick.threshold,
            ],
            "ambient": [
                "mode": ambient.mode,
                "completionLap": ambient.completionLap,
                "questionLap": ambient.questionLap,
                "errorPulse": ambient.errorPulse,
                "voiceRainbow": ambient.voiceRainbow,
                "fixed": [
                    "color": Int(ambient.fixed.color.value),
                    "effect": ambient.fixed.effect.rawValue,
                    "brightness": ambient.fixed.brightness,
                    "speed": ambient.fixed.speed,
                ],
            ],
            "countdown": [
                "leadMs": countdown.leadMs,
                "introFlashSec": countdown.introFlashSec,
                "introFlashColor": Int(countdown.introFlashColor.value),
                "gain": countdown.gain,
                "mediaDir": countdown.mediaDir,
                "intro": [
                    "enabled": countdown.introEnabled,
                    "color": Int(countdown.introColorKeys.value),
                    "brightness": countdown.introBrightness,
                    "trail": countdown.introTrail,
                ],
            ],
            "entrypoints": entrypoints,
            "scrollLines": scrollLines,
            "staleHours": staleHours,
            "doneDecaySeconds": doneDecaySeconds,
            "holdAttention": holdAttention,
            "maxHoldSeconds": maxHoldSeconds,
            "voiceChord": voiceChord,
        ]
    }
}

/**
 Reads and writes `config.json`.

 Atomic, debounced, and mode `0600` — the same as the Node version and the calibration
 record beside it. A brightness slider emits a change per pixel; undebounced that is a
 file write per frame, and without atomicity a crash mid-write leaves a truncated
 document, which for the file that controls everything means coming back with nothing
 configured.
 */
public final class PreferencesStore: @unchecked Sendable {
    public static let shared = PreferencesStore()

    private let queue = DispatchQueue(label: "com.openboard.preferences")
    private var pendingWrite: DispatchWorkItem?
    private var cached: Preferences?

    public init() {}

    public static func url(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        // config.json, not settings.json: this is the file the Node version wrote and
        // the one users already have.
        Calibration.defaultStateDirectory(env: env).appendingPathComponent("config.json")
    }

    @discardableResult
    public func load(url: URL? = nil) -> Preferences {
        let target = url ?? Self.url()
        if let cached, url == nil { return cached }

        guard let data = try? Data(contentsOf: target),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // No file, or an unreadable one. Defaults, written out so there is always a
            // real document to open rather than settings that exist only in code.
            let fresh = Preferences.default
            save(fresh, url: target, immediately: true)
            if url == nil { cached = fresh }
            return fresh
        }

        let merged = Preferences.merging(json)
        if url == nil { cached = merged }
        return merged
    }

    /// Queue a write. Coalesced, so dragging a slider costs one write rather than fifty.
    public func save(_ preferences: Preferences, url: URL? = nil, immediately: Bool = false) {
        let target = url ?? Self.url()
        if url == nil { cached = preferences }

        pendingWrite?.cancel()

        // Synchronously when asked, so "immediately" means the file exists on return.
        // Dispatching async here once made first-run creation race its own caller.
        if immediately {
            pendingWrite = nil
            queue.sync { Self.write(preferences, to: target) }
            return
        }

        let work = DispatchWorkItem { Self.write(preferences, to: target) }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }

    private static func write(_ preferences: Preferences, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONSerialization.data(
            withJSONObject: preferences.json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        // Atomic, or a crash mid-write truncates the file that controls everything.
        try? data.write(to: url, options: [.atomic])
        // 0600, matching the Node version and the calibration record. An atomic write
        // replaces the inode, so the mode is reapplied after every save.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func reset(url: URL? = nil) -> Preferences {
        let fresh = Preferences.default
        save(fresh, url: url, immediately: true)
        cached = fresh
        return fresh
    }
}
