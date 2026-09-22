import Foundation
import OpenBoardKit
import SwiftUI

/**
 The part that makes it an app rather than a set of parts.

 Owns the registry, listens on the hook socket, paints the pad, and publishes what the
 menu bar and settings window read. One object, so there is a single answer to "what is
 the board doing" and the three surfaces cannot disagree.

 Two behaviours carried over from the Node version because they were the difference
 between a board you trust and one you don't:

 - **Re-assert on an interval.** There is no lighting readback — device state can only
   be asserted, never queried — and the ChatGPT app repaints these LEDs on its own
   schedule. A single write is correct only at the instant it lands.
 - **Poll faster while the pad is missing.** ~2s while absent so a reconnect is caught
   promptly, ~10s while present where it is only drift repair. On Bluetooth LE, which
   is how this pad attaches, disappearing and reappearing is normal rather than
   exceptional.
 */
@MainActor
final class BoardController: ObservableObject {
    private let model: BoardModel
    private let device = HIDDevice()
    private let hooks = HookServer()

    private var registry = SessionRegistry()
    private var dispatcher = KeyDispatcher()
    private var reassertTask: Task<Void, Never>?
    /// Holds the calibration legend on the keys while the capture sheet is open.
    private var calibrationTask: Task<Void, Never>?
    /// Fun mode, while it owns the pad.
    private var countdown: CountdownPlayer?
    private lazy var pushToTalk = PushToTalk(log: { Log.write($0) })
    private var focusWatcher: FocusWatcher?
    /// What is in front of you — a Terminal tab by tty, or a VS Code window by title.
    /// Drives `viewing`, and is never written into the registry — see `Viewing`.
    private var focused: FocusedSurface = .elsewhere
    /// Tab titles by tty. Claude Code writes a summary of the session there, and it
    /// stays current as the work changes — unlike anything in the transcript.
    private var terminalTitles: [String: String] = [:]
    /// How to show the settings window. Injected by the delegate that owns it.
    var openSettings: (() -> Void)?
    /// Press versus press-and-hold on the dial.
    private var encoderClick = EncoderClick()
    private var encoderHoldTask: Task<Void, Never>?
    /// Accumulated so one turn logs one line rather than one per tick.
    private var scrolledLines = 0
    private var scrollSummary: Task<Void, Never>?
    /// Raw capture, for discovering what an unmapped control actually emits.
    private var joystick = Joystick()
    private var captureUntil: Date?
    private var captureCount = 0
    private var deviceIsOpen = false
    /// Last logged values, so a 10s poll does not fill the log with "still fine".
    private var lastOpenLog: String?
    private var lastPresenceLog: String?
    private var lastPaintLog: String?
    private var lastAmbientLog: String?
    private var lastPresenceReason: String?
    /// `paint` is async and reentrant; these serialise it. See the comment there.
    private var isPainting = false
    private var repaintWanted = false

    /**
     Whether dictation is believed to be running — believed, and now corroborated.

     Claude Code still reports nothing back: the press is the only way to know
     recording was *asked for*. What changed is that the ring is painted from the
     microphone's own running state (`MicActivity`, the truth behind the orange
     menu-bar dot), gated by the belief. A tap never lights the ring by itself —
     the rainbow arrives when the mic actually starts, and leaves the moment it
     stops, however it was stopped. The conjunction and its bounds live in
     `VoiceSignal`; this class owns the wiring and the repaints.
     */
    private var voice = VoiceSignal()
    private let micActivity = MicActivity()
    /// Sweeps a belief whose grace window expired with the mic never starting — the
    /// tap typed a space. Nothing was lit, so this is bookkeeping, not a repaint.
    private var voiceGraceTask: Task<Void, Never>?

    private var voiceIsActive: Bool {
        // A held custom shortcut is not dictation; only the voice key's hold counts.
        if let key = pushToTalk.heldBy, model.actions[key] == .voiceTalk { return true }
        return voice.isActive()
    }

    private func setVoice(_ active: Bool, why: String) {
        let was = voiceIsActive
        voiceGraceTask?.cancel()
        if active {
            voice.begin()
            // A mic already running counts as confirmation now: dictation joining an
            // ongoing recording cannot flip a flag that is already up, so this is the
            // only chance to see it. The cost is the old degraded bounds if the tap
            // failed — never worse than the belief-only version.
            if micActivity.isRunning { _ = voice.micChanged(running: true) }
            scheduleVoiceGraceSweep()
            Log.write(
                voice.micConfirmed
                    ? "voice: on (\(why), mic already running)"
                    : "voice: believed (\(why)) — awaiting mic"
            )
        } else {
            voice.end()
            Log.write("voice: off (\(why))")
        }
        guard was != voiceIsActive else { return }
        Task { await paint() }
    }

    private func scheduleVoiceGraceSweep() {
        let grace = voice.grace
        voiceGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace) + .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            guard self.voice.since != nil, !self.voice.micConfirmed else { return }
            self.voice.end()
            Log.write("voice: belief expired (mic never started — the tap typed a space)")
        }
    }

    /// While a show owns the ring, the re-assert loop must leave it alone: each step
    /// is asserted once and re-sending restarts the firmware's animation from the
    /// beginning, which turns a 4s lap into flashing.
    private var ringBusyUntil: Date = .distantPast
    private var runningShow: String?


    /// While absent, a reconnect should be noticed in about this long.
    private let absentInterval: Duration = .seconds(2)
    /// While present this is drift repair, and can be lazy.
    private let presentInterval: Duration = .seconds(10)

    init(model: BoardModel) {
        self.model = model
    }

    /// Re-read anything the settings window can change.
    ///
    /// The dispatcher holds its own copy of the bindings, and the debounce history is
    /// cleared so a rebind is not swallowed by the previous key's window.
    func bindingsChanged() {
        applyPreferences()

        // Every write saves immediately; the debounce lives in the store, so dragging
        // a slider costs one file write rather than one per frame.
        model.persist()
        Task { await paint() }
    }

    /**
     Show one state across all six keys for a moment, then restore the board.

     Brightness and effect only mean anything on the hardware — an emissive key at 55%
     is not a swatch at 55% opacity — so this is the only preview that tells the truth.
     */
    func preview(_ state: SessionState) {
        guard deviceIsOpen else { return }
        let calibration = model.calibration
        let appearance = model.appearances[state] ?? state.defaultAppearance

        Task { [weak self] in
            guard let self else { return }
            var batch: [[Data]] = []
            batch.append(self.device.prepare(
                lighting: CodexProtocol.LightingConfig(keys: .off, ambient: .off)
            ))
            for slot in 1...BoardLayout.slotCount {
                guard let physical = calibration.physicalSlot(for: slot) else { continue }
                guard let thread = try? CodexProtocol.ThreadState(
                    physicalSlot: physical,
                    color: appearance.color,
                    brightness: appearance.brightness,
                    effect: CodexProtocol.Effect(rawValue: appearance.effect.deviceCode) ?? .solid,
                    speed: appearance.speed
                ) else { continue }
                batch.append(self.device.prepare(threads: [thread]))
            }
            try? await self.device.write(batch: batch)
            Log.write("preview: \(state.rawValue)")
            try? await Task.sleep(for: .seconds(2))
            // Always hand the board back, or the preview becomes the board.
            await self.paint()
        }
    }

    /**
     Paint the calibration legend and hold it.

     Deliberately **bypasses the calibration mapping**: physical key *n* is painted the
     color of logical slot *n*, because the mapping is the thing being established. Any
     existing record must not influence the capture, or a wrong mapping would confirm
     itself — the pad would light in the order the record already claims.

     It is also the only paint path that runs before a calibration exists, so it cannot
     take the usual "no calibration, do not write" guard.

     Held rather than flashed: Codex repaints these LEDs on its own schedule, so a single
     write can be overwritten within a second or two, leaving someone staring at a pad
     that has gone dark mid-capture. Reasserting every second is what makes the colors
     stay put long enough to read them off.
     */
    func beginCalibrationCapture() {
        guard deviceIsOpen else { return }
        calibrationTask?.cancel()
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                var batch: [[Data]] = []
                batch.append(self.device.prepare(
                    lighting: CodexProtocol.LightingConfig(keys: .off, ambient: .off)
                ))
                for entry in CalibrationCapture.legend {
                    guard let thread = try? CodexProtocol.ThreadState(
                        physicalSlot: entry.slot,
                        color: entry.color,
                        // Full brightness, solid: the operator has to distinguish six
                        // hues by eye, and a breathing key at 40% is genuinely hard to
                        // name against another that is mid-fade.
                        brightness: 1.0,
                        effect: .solid,
                        speed: 0
                    ) else { continue }
                    batch.append(self.device.prepare(threads: [thread]))
                }
                try? await self.device.write(batch: batch)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Log.write("calibration: painting legend")
    }

    /// Stop the capture and hand the board back.
    func endCalibrationCapture() {
        calibrationTask?.cancel()
        calibrationTask = nil
        Task { await paint() }
    }

    /// Record what the operator saw, and adopt it immediately.
    func saveCalibration(observed: [Int]) -> Bool {
        guard let record = try? CalibrationCapture.record(observed: observed) else { return false }
        do { try record.save() } catch {
            Log.write("calibration: save failed — \(error.localizedDescription)")
            return false
        }
        model.calibration = record
        Log.write("calibration: saved \(record.rows.map { $0.map(String.init).joined(separator: ",") }.joined(separator: " / "))")
        endCalibrationCapture()
        return true
    }

    /**
     Seed the board from sessions that are already running.

     A hook only fires when a session *does* something, so a session sitting idle in
     another tab would be invisible until you went and typed in it — backwards for a
     board whose job is to tell you what is happening without being asked.
     */
    func reconnect() {
        let found = Discovery.runningSessions()
        let added = registry.reconnect(found)
        Log.write("reconnect: \(found.count) running session(s), \(added) added")
        publish()
        Task { await paint() }
    }

    /// Push configured values into the parts that hold their own copies.
    ///
    /// The dispatcher and the registry cache theirs so their logic stays pure and
    /// testable, which means a config change has to be pushed rather than read.
    private func applyPreferences() {
        let prefs = model.preferences
        dispatcher.actions = model.actions
        dispatcher.encoderClick = model.actions["ENC"]
        dispatcher.scrollLines = prefs.scrollLines
        dispatcher.clockwiseScrollsUp = prefs.encoder.clockwiseScrollsUp
        pushToTalk.maxHoldSeconds = prefs.maxHoldSeconds
        // Cleared so a rebind is not swallowed by the previous binding's window.
        dispatcher.reset()
        registry.staleInterval = prefs.staleInterval
    }

    func start() {
        // Say what was loaded, not just that something was. A config read from the
        // wrong path or merged wrongly is otherwise indistinguishable from defaults.
        let prefs = model.preferences
        Log.write(
            "OpenBoard starting (calibration: \(model.isCalibrationConfirmed ? "recorded" : "assumed"))"
        )
        Log.write(
            "config \(PreferencesStore.url().path): "
                + "idle=\(prefs.appearance(for: .idle).color.hex)/"
                + "\(prefs.appearance(for: .idle).effect.rawValue)@"
                + "\(Int(prefs.appearance(for: .idle).brightness * 100))%, "
                + "working=\(prefs.appearance(for: .working).effect.rawValue), "
                + "notifications=\(prefs.notificationStates.map { "\($0.key)->\($0.value.rawValue)" }.sorted().joined(separator: " ")), "
                + "muted=\(prefs.events.filter { !$0.value }.keys.sorted().joined(separator: ",") ) , "
                + "scroll=\(prefs.scrollLines)/"
                + "\(prefs.encoder.clockwiseScrollsUp ? "cw-up" : "cw-down") "
                + "stale=\(prefs.staleHours)h"
        )

        // Asked once at launch and logged, because these are the failures that look
        // like a broken app rather than a missing permission — and because a probe
        // that reports the wrong process's state (as the old AppleScript one did) is
        // only caught by comparing this line against what actually happens next.
        let permissions = PermissionProbe.inspect()
        Log.write(
            "permissions: input-monitoring=\(permissions.inputMonitoring.rawValue) "
                + "accessibility=\(permissions.accessibility.rawValue) "
                + "bluetooth=\(permissions.bluetooth.rawValue) "
                + permissions.automation
                    .map { "automation[\($0.key)]=\($0.value.rawValue)" }
                    .sorted().joined(separator: " ")
        )

        // The wiring the whole system depends on, and the only one that fails without
        // any symptom at all: a hook pointing at a moved bundle still looks configured.
        let audit = HookInstall.audit(
            settings: HookInstall.loadSettings(),
            expectedCommand: HookInstall.hookCommandPath()
        )
        Log.write(
            audit.isHealthy
                ? "hooks: all \(HookInstall.events.count) wired to this build"
                : "hooks: PROBLEM — \(audit.problems.map { "\($0) \(audit.statuses[$0].map(String.init(describing:)) ?? "?")" }.joined(separator: ", "))"
        )

        // Only when the preference asks for the chord: a missing binding then means
        // the voice key does nothing at all, which reads as a dead key, not a
        // missing line in a file the user may never have opened.
        if prefs.voiceChord {
            let chord = KeybindingInstall.audit(document: KeybindingInstall.load())
            Log.write(
                chord.isHealthy
                    ? "keybinding: ⌃Y wired to \(KeybindingInstall.action)"
                    : "keybinding: PROBLEM — ⌃Y \(chord.status), voice key is dead until repaired in Settings"
            )
        }

        applyPreferences()

        // Restore the board before anything reads it, so a session keeps the key it
        // had. Entries that cannot still be true are dropped rather than trusted —
        // see RegistryStore.
        registry = RegistryStore.load(staleInterval: prefs.staleInterval)
        registry.staleInterval = prefs.staleInterval
        if !registry.entries.isEmpty {
            Log.write(
                "registry: restored \(registry.entries.count) session(s) — "
                    + registry.entries
                        .sorted { $0.slot < $1.slot }
                        .map { "\($0.slot):\($0.state.rawValue)" }
                        .joined(separator: " ")
            )
        }

        startFocusWatcher()
        startKeyInterception()
        startMicWatcher()
        startHookServer()
        startResident()
        reconnect()
    }

    /// Feed mic transitions into the voice belief. The callback arrives on
    /// MicActivity's own queue; everything stateful happens back on the main actor.
    private func startMicWatcher() {
        micActivity.watch { [weak self] running in
            Task { @MainActor in
                guard let self else { return }
                let was = self.voiceIsActive
                let reason = self.voice.micChanged(running: running)
                let now = self.voiceIsActive
                guard now != was else { return }
                Log.write("voice: \(now ? "on" : "off") (\(reason ?? "mic"))")
                await self.paint()
            }
        }
    }

    // MARK: - key interception

    /**
     Give the pad's keys meaning.

     Layer 1's keycodes are locked by the Codex app and cannot be remapped — but the
     device broadcasts every press on the vendor channel, so meaning is assigned here
     instead. Nothing on the pad has to be reconfigured.

     Registered once, against the device's line stream. The stream survives
     reconnects because the resident reopens the handle, and the handler is attached
     to this object rather than to any particular handle.
     */
    private func startKeyInterception() {
        device.onLine { [weak self] line in
            // A control reporting under a method this app does not know is invisible
            // here — `KeyEvent.parse` returns nil and the guard below drops it. That is
            // how the joystick went unnoticed for months. `openboard-probe --listen`
            // prints the raw stream when a new control needs identifying.
            // The stick shares the stream with the keys but speaks a different
            // method, which is why it looked inert for so long.
            if let sample = Joystick.parse(line) {
                Task { @MainActor in
                    self?.handle(stickAngle: sample.angle, deflection: sample.deflection)
                }
                return
            }

            guard let event = KeyEvent.parse(line) else { return }
            Task { @MainActor in self?.handle(key: event) }
        }
    }


    /// One push of the stick is one action, however many samples it emits.
    private func handle(stickAngle angle: Double, deflection: Double) {
        joystick.northAngle = model.preferences.joystick.northAngle
        joystick.clockwise = model.preferences.joystick.clockwise
        joystick.threshold = model.preferences.joystick.threshold

        guard let direction = joystick.update(angle: angle, deflection: deflection) else {
            return
        }
        guard let action = model.preferences.joystick.action(for: direction) else {
            Log.write("stick \(direction.rawValue): unbound")
            return
        }
        // The angle is logged because the mapping from angle to direction is the one
        // part that cannot be verified by reading the code — it depends on how the
        // hardware is oriented.
        Log.write(String(format: "stick %@ (a=%.3f)", direction.rawValue, angle))
        perform(action, key: "JOY.\(direction.rawValue)")
    }

    private func handle(key event: KeyEvent) {
        guard let intent = dispatcher.intent(for: event) else { return }
        switch intent {
        case let .jump(slot):
            jump(to: slot)
        case let .action(action, key):
            perform(action, key: key)
        case .encoderPressed:
            encoderPressed()

        case let .release(key):
            // Only push-to-talk cares about the release edge, and only when the key
            // that was released is the one holding it — otherwise any other key's
            // release would end the dictation.
            if key == "ENC_CLK" {
                encoderReleased()
            } else if pushToTalk.heldBy == key {
                pushToTalk.end()
                Task { await paint() }
            }
        case let .scroll(lines):
            Actions.scroll(lines: lines)
            noteScroll(lines)
        }
    }

    private func jump(to slot: Int) {
        guard let view = model.slots.first(where: { $0.slot == slot }), view.isOccupied else {
            Log.write("key: slot \(slot) has no session")
            return
        }
        let outcome = Focus.raise(view)
        Log.write("key: jump to slot \(slot) -> \(outcome)")
    }

    private func perform(_ action: KeyAction, key: String) {
        Log.write("key \(key) -> \(action.rawValue)")
        switch action {
        case .sync:
            Task { await paint() }
        case .settings:
            openSettingsWindow()
        case .reset:
            forgetAllSessions()
        case .off:
            Task { await allKeysOff() }
        case .approve, .reject:
            // Reject doubles as the cancel while fun mode runs, and cancelling wins.
            // The pad is showing a light show rather than the board, so there is no
            // prompt visible to answer — sending ⎋ to whatever is behind the video
            // would reject something the user cannot see.
            if action == .reject, countdown?.isRunning == true {
                Log.write("key \(key): cancelling fun mode")
                countdown?.cancel()
                return
            }
            let decision: Actions.Decision = action == .approve ? .approve : .reject
            let outcome = Actions.respond(decision, slots: model.slots)
            switch outcome {
            case let .sent(slot):
                Log.write("key \(key): \(action.rawValue) sent to slot \(slot)")
            case .nothingPending:
                Log.write("key \(key): nothing is waiting")
            case let .ambiguous(slots):
                // Refusing is the feature. Guessing would answer a prompt the user
                // never read.
                Log.write(
                    "key \(key): refused — slots \(slots.map(String.init).joined(separator: ", ")) "
                        + "are both waiting; press one of those keys"
                )
            case let .focusFailed(slot, reason):
                Log.write("key \(key): slot \(slot) never came forward (\(reason)) — not sent")
            case let .failed(detail):
                Log.write("key \(key): \(detail)")
            }

        case .snippet:
            let text = model.snippets[key] ?? model.snippet
            let result = Actions.typeSnippet(text)
            Log.write(result.ok ? "key \(key): typed \(text)" : "key \(key): \(result.detail)")

        case .enter:
            let result = Actions.pressEnter()
            Log.write(result.ok ? "key \(key): sent ⏎" : "key \(key): \(result.detail)")

        case .shortcut:
            guard let shortcut = model.preferences.shortcuts[key] else {
                Log.write("key \(key): no shortcut recorded")
                return
            }
            // Hold needs a release edge, and only the action caps deliver one. The file
            // is hand-editable, so a hold on the dial or the stick is sent as a tap
            // rather than left to the 60s backstop.
            let canHold = BoardLayout.cells.contains { $0.isAction && $0.id == key }
            if shortcut.mode == .hold, canHold {
                pushToTalk.begin(shortcut, key: key)
            } else {
                if shortcut.mode == .hold { Log.write("key \(key): cannot hold here — tapping") }
                let result = Actions.press(shortcut)
                Log.write(result.ok ? "key \(key): sent \(shortcut.label)" : "key \(key): \(result.detail)")
            }

        case .newtab:
            let result = Actions.newTerminalTab()
            Log.write(result.ok ? "key \(key): opened a Terminal tab" : "key \(key): \(result.detail)")

        case .voiceTap:
            // The chord invokes `voice:pushToTalk` directly and types nothing; space
            // is the fallback that also types spaces when the input is not empty.
            let chord = model.preferences.voiceChord
            let result = chord ? Actions.tapVoiceChord() : Actions.tapVoice()
            Log.write(
                result.ok
                    ? "key \(key): voice tap (\(chord ? "⌃Y" : "space"))"
                    : "key \(key): \(result.detail)"
            )
            // The same tap starts and stops it, so the belief flips with the key.
            if result.ok { setVoice(!voiceIsActive, why: "tapped") }

        case .voiceTalk:
            // The release edge ends it — see PushToTalk for why this is never trusted
            // to happen on its own.
            pushToTalk.begin(key: key)

        case .voiceToggle:
            let result = Actions.toggleVoice()
            Log.write(result.ok ? "key \(key): toggled voice" : "key \(key): \(result.detail)")
            if result.ok { setVoice(!voiceIsActive, why: "/voice") }

        case .popover:
            openMenuBarPopover()

        case .tabForward:
            let result = Actions.nextTab()
            Log.write(result.ok ? "key \(key): next tab" : "key \(key): \(result.detail)")

        case .tabBack:
            let result = Actions.previousTab()
            Log.write(result.ok ? "key \(key): previous tab" : "key \(key): \(result.detail)")

        case .prevSession, .nextSession:
            stepSession(forward: action == .nextSession)

        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight:
            let direction: Joystick.Direction = switch action {
            case .arrowUp: .up
            case .arrowDown: .down
            case .arrowLeft: .left
            default: .right
            }
            let result = Actions.arrow(direction)
            Log.write(result.ok ? "key \(key): arrow \(direction.rawValue)"
                                : "key \(key): \(result.detail)")

        case .countdown:
            // Pressing it again stops it, so the key that starts the show can always
            // end it — `playCountdown` toggles.
            playCountdown()
        }
    }

    /**
     What the ring should be showing, as the device wants it.

     Dark in `events` mode, which is the default: the ring is a notification surface,
     not a second status display. A lap fires on a transition and it goes back to
     nothing — that is what makes a lap mean something.
     */
    /**
     Watch which session is in front of you.

     Started once, from `start()`. It was briefly created in `bindingsChanged()`
     instead, which never runs at launch and runs on every settings edit — so the
     indicator never appeared and each edit leaked another observer and poll loop.
     */
    private func startFocusWatcher() {
        let watcher = FocusWatcher { [weak self] surface in
            guard let self, self.focused != surface else { return }
            self.focused = surface
            // Which slot it matched, not just what was in front. A handle that matches
            // nothing looks identical in the log to one that matches — and "the
            // indicator does not work" is usually the session having no recorded tty or
            // no name yet, not the watcher.
            let matched = self.registry.entries.first {
                self.isFocused($0, name: self.name(of: $0))
            }
            // Including what the key is told to emit: "the pulse is the wrong color" is
            // otherwise indistinguishable in the log from "focus never matched".
            let emitted = matched.map { entry -> String in
                let shown = Viewing.display(entry.state, isFocused: true)
                let look = Viewing.appearance(shown, isFocused: true, from: self.model.appearances)
                return " -> slot \(entry.slot) (\(shown.rawValue)) "
                    + "\(look.color.hex)/\(look.effect.rawValue)@\(Int(look.brightness * 100))%"
            }
            Log.write("focus: \(Self.describe(surface))" + (emitted ?? ""))
            self.publish()
            Task { await self.paint() }
        }
        focusWatcher = watcher
        watcher.start()
    }

    /**
     Move to the next or previous occupied key, and raise it.

     Wraps, and skips empty slots — stepping through five free keys to reach the one
     other session would make the control useless on a board that is mostly empty,
     which is the normal case.

     Starts from whatever is focused, so it walks from where you are rather than from
     slot 1 every time.
     */
    private func stepSession(forward: Bool) {
        let occupied = model.slots.filter(\.isLive).map(\.slot).sorted()
        guard !occupied.isEmpty else {
            Log.write("key JOY: no sessions to step to")
            return
        }
        // The published flag rather than a second comparison of its own: this used to
        // match a tty by suffix while `publish` matched it exactly, so the two could
        // disagree about which slot you were in, and only one of them painted.
        let current = model.slots.first { slot in
            slot.isLive && slot.cwd != nil && slot.isFocused
        }?.slot

        let next: Int
        if let current, let index = occupied.firstIndex(of: current) {
            let step = forward ? 1 : -1
            next = occupied[(index + step + occupied.count) % occupied.count]
        } else {
            next = forward ? occupied.first! : occupied.last!
        }
        Log.write("key JOY: session \(next)")
        jump(to: next)
    }

    /// Re-read the tab titles, and republish only if one changed.
    ///
    /// On the presence cycle rather than on every repaint: it is an Apple Event per
    /// call, and a title changes when a session changes topic — minutes, not frames.
    private func refreshTerminalTitles() async {
        let titles = await TerminalTitles.read()
        guard titles != terminalTitles else { return }
        terminalTitles = titles
        publish()
    }

    /**
     Whether this entry is the session in front of you.

     Two surfaces, matched on what each one actually exposes. A Terminal tab carries the
     session's tty, which is exact. A VS Code window carries its active tab's name, and
     the extension names that tab after the session — so the match is on the name the
     board is already showing in the row, and a chat too young to have been named simply
     does not match rather than matching the wrong one.
     */
    private func isFocused(_ entry: SessionRegistry.Entry, name: String?) -> Bool {
        switch focused {
        case let .terminal(tty):
            return entry.tty == tty
        case let .vscode(windowTitle):
            guard entry.entrypoint == "claude-vscode", let name else { return false }
            return WindowTitle.names(name, in: windowTitle)
        case .elsewhere:
            return false
        }
    }

    /// What the row calls this session — the tab title where Terminal offers one, and
    /// Claude Code's own name otherwise. Shared by `publish` and the focus match so the
    /// two cannot disagree about what a session is called.
    private func name(of entry: SessionRegistry.Entry) -> String? {
        entry.tty.flatMap { terminalTitles[$0] }
            ?? SessionTitle.forSession(transcriptPath: entry.transcriptPath)
    }

    /// One line for the log. A window title is long and a tty is not, so the title is
    /// clipped rather than allowed to push the matched slot off the end of the line.
    private static func describe(_ surface: FocusedSurface) -> String {
        switch surface {
        case let .terminal(tty): return tty
        case let .vscode(windowTitle): return "vscode “\(windowTitle.prefix(60))”"
        case .elsewhere: return "elsewhere"
        }
    }

    private func ambientSide() -> CodexProtocol.LightingSide {
        /*
         Dictation owns the ring while it runs.

         Above every mode, `off` included: this is not a summary of the board, it is
         feedback that the machine is listening to you right now — the one moment where
         a light that is otherwise dark by design has something urgent to say. It ends
         the moment the belief does, and the belief is bounded. See `VoiceSignal`.
        */
        if model.preferences.ambient.voiceRainbow, voiceIsActive {
            lastAmbientLog = Log.changed("ring", last: lastAmbientLog, to: "voice: rainbow")
            return CodexProtocol.LightingSide(
                color: RGB(0xFFFFFF), brightness: 1, effect: .rainbow, speed: 0.75
            )
        }

        let mode = Ambient.Mode(rawValue: model.preferences.ambient.mode) ?? .events
        let states = registry.occupancy().map { $0.entry?.state }
        guard let resolved = Ambient.resolve(
            states: states, mode: mode, appearances: model.appearances,
            // Without this, `fixed` resolves to nothing and the ring is silently dark —
            // a mode that is documented, selectable, and does nothing.
            fixed: model.preferences.ambient.fixed
        ) else { return .off }

        // Logged on change, because a ring that is dark by design and one that is dark
        // by bug look identical — the same trap the config path fell into.
        lastAmbientLog = Log.changed(
            "ring", last: lastAmbientLog,
            // Describe the *appearance*, not the state: in fixed mode there is no
            // winning state, and reading "dark" beside a lit color is worse than no
            // log at all.
            to: resolved.appearance.effect == .off
                ? "\(mode.rawValue): dark"
                : "\(mode.rawValue): \(resolved.state?.rawValue ?? "held") "
                    + "\(resolved.appearance.color.hex)@"
                    + "\(Int(resolved.appearance.brightness * 100))% "
                    + "\(resolved.appearance.effect.rawValue)"
        )

        let appearance = resolved.appearance
        return CodexProtocol.LightingSide(
            color: appearance.color,
            brightness: appearance.brightness,
            effect: CodexProtocol.Effect(rawValue: appearance.effect.deviceCode) ?? .solid,
            speed: appearance.speed
        )
    }

    /**
     Bring the settings window up from a key press.

     `showSettingsWindow:` goes through the responder chain, and an `.accessory` app
     with no Dock icon and no key window frequently has nobody in that chain to receive
     it — `sendAction` returns false and nothing happens, silently. That is exactly what
     the dial did: the press was dispatched and logged, and no window appeared.
     Activating first puts something in the chain.

     There is deliberately **no fallback that hunts for the window and orders it front**.
     An earlier version had one, and logging the app's actual window list disproved it:
     even with Settings open, `NSApp.windows` holds only `NSStatusBarWindow` and
     `MenuBarExtraWindow`. SwiftUI's `Settings` scene simply is not there to be found,
     so that code could never have run — and a fallback that cannot fire is worse than
     none, because it reads as a safety net.
     */
    private func openSettingsWindow() {
        /*
         An injected closure, not `NSApp.delegate as? AppDelegate`.

         That cast silently returned nil from here — SwiftUI's
         `NSApplicationDelegateAdaptor` does not guarantee that `NSApp.delegate` is your
         own type — so the dial logged "settings: opened" and opened nothing. The same
         call worked from `applicationShouldHandleReopen`, which is *inside* the
         delegate and never needed the cast, and that difference is what made it look
         like the hold was broken rather than the plumbing.

         A closure cannot be nil-by-surprise: it is either wired at start or it is not,
         and the log says which.
         */
        guard let openSettings else {
            Log.write("settings: FAILED — no opener wired")
            return
        }
        openSettings()
    }

    /**
     Report a turn of the dial, once per gesture.

     Rotation was the only input that produced no trace at all, which made "did the
     encoder do anything?" unanswerable after the fact — the same blind spot that hid a
     dark ring and an unnamed session earlier.

     Summarised rather than logged per tick: a single turn emits ticks every few
     milliseconds, and one line each would bury everything else. The ticks are collected
     and written out once the turn stops.
     */
    private func noteScroll(_ lines: Int) {
        scrolledLines += lines
        scrollSummary?.cancel()
        scrollSummary = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, self.scrolledLines != 0 else { return }
            let total = self.scrolledLines
            self.scrolledLines = 0
            Log.write("encoder: scrolled \(abs(total)) lines \(total > 0 ? "up" : "down")")
        }
    }

    /**
     The dial went down.

     The long action fires *while still held* rather than on release. Classifying on
     release feels broken: you hold the dial, nothing happens, you let go, and the
     window appears afterwards — with no way to know whether you held it long enough,
     so people release early and get the wrong action.
     */
    private func encoderPressed() {
        encoderClick.threshold = model.preferences.encoder.longPressInterval
        encoderClick.press()
        encoderHoldTask?.cancel()
        encoderHoldTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.encoderClick.threshold))
            guard !Task.isCancelled, self.encoderClick.shouldFireLong() else { return }
            guard let action = self.model.preferences.encoder.longPress else { return }
            Log.write("key ENC: held past \(Int(self.encoderClick.threshold * 1000))ms")
            self.perform(action, key: "ENC.long")
        }
    }

    /// The dial came back up. Fires the press action only if the hold did not already
    /// take over — otherwise one press would fire both bindings.
    private func encoderReleased() {
        encoderHoldTask?.cancel()
        encoderHoldTask = nil
        switch encoderClick.release() {
        case .short:
            guard let action = model.preferences.encoder.click else { return }
            perform(action, key: "ENC")
        case .handled, .spurious:
            break
        }
    }

    /**
     Click the status item, so the dial opens the same panel a mouse would.

     `MenuBarExtra` gives no programmatic way to open its window — the scene owns the
     `NSStatusItem` and does not expose it. So the button is found in the status bar
     window and clicked, which is what a real click does and therefore behaves
     identically, including closing again on a second press.
     */
    private func openMenuBarPopover() {
        clickStatusItem(reason: "opened the dropdown")
    }

    /**
     Close the dropdown, for a row that opens one of *our* windows.

     Activating another application dismisses the panel by itself, which is why
     jumping to a chat needs nothing here. Settings does: it is this app's own window,
     the panel never resigns to it, and the menu is left hanging over the thing it just
     opened.

     A click, because the click is what the panel listens to — the same route the dial
     already uses, and the same reason: `MenuBarExtra` owns its `NSStatusItem` and
     exposes no way to close it.

     **Only safe from inside the open panel.** The click is a toggle, so calling this
     when nothing is showing would *open* the menu instead. That is why it is a
     separate command from `openSettings`, which the dial's long press also calls with
     no panel on screen.
     */
    func dismissMenuBarPopover() {
        clickStatusItem(reason: "closed the dropdown")
    }

    private func clickStatusItem(reason: String) {
        for window in NSApp.windows {
            guard let button = Self.statusButton(in: window.contentView) else { continue }
            button.performClick(nil)
            Log.write("menu: \(reason)")
            return
        }
        Log.write("menu: FAILED — no status item button found")
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for child in view.subviews {
            if let found = statusButton(in: child) { return found }
        }
        return nil
    }

    /// Every key dark, without forgetting anything.
    private func allKeysOff() async {
        guard deviceIsOpen else { return }
        let calibration = model.calibration
        var batch: [[Data]] = []
        for slot in 1...BoardLayout.slotCount {
            guard let physical = calibration.physicalSlot(for: slot) else { continue }
            if let thread = try? CodexProtocol.ThreadState(
                physicalSlot: physical, color: RGB(0), brightness: 0, effect: .off, speed: 0
            ) {
                batch.append(device.prepare(threads: [thread]))
            }
        }
        try? await device.write(batch: batch)
    }

    /// Release the socket and the device handle. Without this the socket file is left
    /// behind and the next launch has to clear it before it can bind.
    func stop() {
        reassertTask?.cancel()
        reassertTask = nil
        // Before anything else: a key left logically down outlives this process and
        // corrupts every keystroke on the machine afterwards.
        pushToTalk.releaseIfHeld()
        focusWatcher?.stop()
        // The board survives a restart. Saved on the way out *and* after every change,
        // because a crash never reaches this line.
        RegistryStore.save(registry)
        closeDeviceSync()
        Task { await hooks.stop() }
    }

    // MARK: - hooks

    private func startHookServer() {
        Task {
            do {
                try await hooks.start { [weak self] event in
                    await self?.handle(event)
                }
                Log.write("hook socket listening at \(await hooks.socketPath)")
            } catch {
                // The socket failing to bind is worth surfacing: it means no session
                // will ever report, and the board would sit empty looking healthy.
                Log.write("hook socket FAILED: \(error.localizedDescription)")
                await MainActor.run {
                    self.model.apply(device: .permissionDenied(missing: ["a usable hook socket"]))
                }
            }
        }
    }

    private func handle(_ event: HookServer.Event) async {
        /*
         Delegating-state carve-out, ahead of `Eligibility.evaluate`.

         `SubagentStart`/`SubagentStop` payloads carry `agent_id`/`agent_type` even
         though they describe the *parent* session's own bookkeeping, not a subagent
         process reporting in — `Eligibility.evaluate`'s first two checks would refuse
         both unconditionally otherwise (Eligibility.swift:79-86). This branch is keyed
         on the two literal event names only, never on "any event with an agent field",
         so a subagent's own PreToolUse/PostToolUse (which also carries those fields)
         still falls through to `Eligibility.evaluate` below and is refused exactly as
         today. `adjustDelegation` never allocates — an unknown `session_id` is
         ignored rather than given a key, so scarcity is preserved by construction.

         This also bypasses the CLAUDE_AGENT_ID/
         CLAUDE_AGENT_TYPE env checks Eligibility would otherwise apply, so a *nested*
         subagent's own SubagentStart could in principle reach `adjustDelegation` and
         over-count. Bounded by the authoritative reconcile on every `Stop` (below),
         which replaces the incremental count with the true `background_tasks` size
         regardless of how it got there.

         No `publish()`/`paint()` here: `SubagentStart` precedes the turn's own `Stop`
         by construction (spike-observed ordering), so there is no visible state change
         to paint at dispatch time — the effect surfaces the next time `Stop` reconciles
         and (possibly) overrides `.done` to `.working`, which already repaints.

         `agentID` (from the same `agent_id` field Eligibility would have rejected on)
         is what turns `delegatingAgentIDs` into a set rather than a bare counter — see
         `SessionRegistry.Entry.delegatingAgentIDs`'s doc comment for the race this
         closes. A missing/empty `agent_id` degrades to a no-op inside
         `adjustDelegation` itself, not here.
         */
        if event.name == "SubagentStart" || event.name == "SubagentStop",
           let sessionID = event.sessionID {
            registry.adjustDelegation(
                sessionID: sessionID, event: event.name,
                agentID: event.eligibilityPayload.agentID
            )
            return
        }

        // Fail-closed: an unrecognised surface gets no key. Applied here rather than
        // in the helper so the rules live in one place and can be reasoned about.
        let verdict = Eligibility.evaluate(
            env: event.environment,
            payload: event.eligibilityPayload,
            harness: event.harness
        )
        guard verdict.eligible, let sessionID = event.sessionID else {
            Log.write("hook \(event.name): refused (\(verdict.reason.rawValue) \(verdict.detail))")
            return
        }

        guard let state = EventMapper.state(
            for: event.name,
            matcher: event.matcher,
            enabledEvents: model.events,
            notifications: model.notifications
        ) else {
            Log.write("hook \(event.name): no state mapping\(event.matcher.map { " (\($0))" } ?? "")")
            return
        }
        /*
         Remember that this harness has ever worked here.

         Recorded from the first event rather than inferred from the config, because a
         wired hook proves nothing: the file can say all the right things while the
         binary path is stale, which is the exact failure `HookInstall` audits for. An
         event arriving is the only proof that the whole path works end to end.

         Written through `updatePreferences`, which saves — debounced, so a session
         firing a hook every few seconds costs one write rather than one per tool call.
        */
        let sender = event.harness ?? Harness.claudeCode.id
        if !model.preferences.harnessesSeen.contains(sender) {
            model.updatePreferences { $0.harnessesSeen = ($0.harnessesSeen + [sender]).sorted() }
            model.persist()
            Log.write("harness: \(sender) reported for the first time")
        }

        // What the event *maps to*, which is not always what gets applied — the
        // branches below can decline it. A line that reads like a state change while
        // nothing changed is how a stuck key stayed invisible for a whole session, so
        // anything that declines says so on its own line.
        Log.write("hook \(event.name) maps to \(state.rawValue) [\(sessionID.prefix(8))]")

        // Dictation ends when what it was dictating is sent.
        if event.name == "UserPromptSubmit", voiceIsActive {
            setVoice(false, why: "prompt submitted")
        }

        /*
         Session ended — drop the entry so the slot becomes reclaimable immediately.

         `.ended` renders as OFF (identical to an unused slot), and leaving the entry
         in place makes `pickSlot` prefer any other unused key over this one. So a
         Terminal tab you closed keeps its slot dark while the next session lights up
         somewhere else — which was the whole "slots crawl right until eviction takes
         over" behaviour that the reclaim path was supposed to prevent, but only
         gets to prevent once *all* slots are occupied.

         Dropping releases the slot at ordering 1 in `pickSlot` (unused wins), so the
         next new session lands here rather than somewhere new. `SessionTitle.forget`
         drops the cached transcript name too, or the reused slot would carry the
         old chat's title until the next enrich.
         */
        if state == .ended {
            if let entry = registry.entry(forSession: sessionID) {
                SessionTitle.forget(transcriptPath: entry.transcriptPath)
                registry.release(sessionID: sessionID)
                Log.write("hook \(event.name): released slot \(entry.slot) (\(sessionID.prefix(8)))")
                publish()
                await paint()
            }
            return
        }

        // Captured before anything mutates the registry: a lap fires on a *transition*,
        // never on a repaint. Reading it afterwards would compare a state to itself and
        // either fire on every hook or never fire at all.
        let previousState = registry.entry(forSession: sessionID)?.state

        /*
         Adopt a session we have never seen start, before anything else looks at it.

         The registry is rebuilt from hooks and `SessionStart` fires once, so a session
         already running when this app starts — after a restart, a rebuild, or the
         cutover from the Node CLI — would otherwise stay invisible forever.

         This runs *first* deliberately. It was originally placed after the
         attention-clear branch, which returns early for PostToolUse — so a session
         quietly working through tool calls, which is most of them, was never adopted
         and the board reported zero sessions while hooks arrived normally.

         Safe here because eligibility has already run: only `cli` and `claude-vscode`
         reach this point, never a subagent or an embedded SDK client.
         */
        // A discovered host holding a placeholder hands its slot over here, rather
        // than the session taking a second key and the board showing it twice.
        //
        // CLAUDE_PID first, because if Claude Code ever exports it that is
        // canonical. Fall back to walking up from the hook helper's parent — its
        // ppid is a shell or claude itself, and the claude ancestor's pid is what
        // Terminal's per-tab tty match needs. Without this fallback, every hook
        // arrives with pid=nil and every "jump to slot N" reports noWindow.
        let hookPID = event.environment["CLAUDE_PID"].flatMap(Int.init)
            ?? event.hookPPID.flatMap(Self.claudePID(fromAncestryOf:))
        if registry.adoptRealSessionID(
            sessionID,
            pid: hookPID,
            tty: hookPID.flatMap(Self.tty(forPID:)),
            cwd: event.cwd,
            transcriptPath: event.transcriptPath ?? SessionTranscript.locate(sessionID: sessionID),
            entrypoint: event.entrypoint
        ) {
            Log.write("hook \(event.name): matched a running session already on the board")
            registry.setState(sessionID: sessionID, to: state, pendingTool: event.toolName)
            publish()
            fireLap(from: previousState, sessionID: sessionID)
            await paint()
            return
        }

        if event.name != "SessionStart", registry.entry(forSession: sessionID) == nil {
            Log.write("hook \(event.name): adopting a session already in progress")
            // The tty is what makes a jump exact — Terminal's dictionary exposes it
            // per tab. Omitting it here meant an adopted session could be seen but not
            // raised: "jump to slot 1 -> noWindow".
            let adoptedPID = event.environment["CLAUDE_PID"].flatMap(Int.init)
            _ = registry.claim(
                sessionID: sessionID,
                cwd: event.cwd,
                pid: adoptedPID,
                tty: adoptedPID.flatMap(Self.tty(forPID:)),
                transcriptPath: event.transcriptPath
                    ?? SessionTranscript.locate(sessionID: sessionID),
                entrypoint: event.entrypoint,
                state: state
            )
            // Publish immediately.
            //
            // The branches below can return early — an attention-clear for a session
            // that is not asking for anything does — and a claim that never reaches
            // the model is invisible to everything that reads it. The pad painted
            // correctly from the registry while the menu bar showed nothing and
            // pressing the key reported "slot 1 has no session".
            publish()
        }

        /*
         Learn anything this entry is still missing, before any branch can return.

         A session restored from disk or discovered from the process table arrives with
         no transcript and no cwd, and nothing else revisits those fields. Placed at the
         bottom of this function it was unreachable for exactly the hook that fires most:
         `PostToolUse` returns early unless the session is in an attention state, so the
         board stayed unnamed while hooks arrived normally — the same trap that once made
         session adoption itself unreachable.
         */
        let transcript = event.transcriptPath
            ?? SessionTranscript.locate(sessionID: sessionID)
        if registry.enrich(
            sessionID: sessionID,
            cwd: event.cwd,
            transcriptPath: transcript,
            entrypoint: event.entrypoint,
            tty: hookPID.flatMap(Self.tty(forPID:)),
            pid: hookPID
        ) {
            // Logged once per session, when it happens: an unnamed row is otherwise
            // indistinguishable from a session that genuinely has no transcript.
            Log.write(
                "enriched \(sessionID.prefix(8)): "
                    + "transcript=\(transcript.map { ($0 as NSString).lastPathComponent } ?? "none") "
                    + "cwd=\(event.cwd.map { ($0 as NSString).lastPathComponent } ?? "none")"
            )
        }

        if event.name == "SessionStart" {
            let pid = event.environment["CLAUDE_PID"].flatMap(Int.init)
            _ = registry.claim(
                sessionID: sessionID,
                cwd: event.cwd,
                pid: pid,
                tty: pid.flatMap(Self.tty(forPID:)),
                transcriptPath: event.transcriptPath
                    ?? SessionTranscript.locate(sessionID: sessionID),
                entrypoint: event.entrypoint,
                state: state
            )
        } else if EventMapper.clearsAttention.contains(event.name) {
            /*
             A tool just ran, so this session is working — whatever it was showing.

             This used to require an attention state and return otherwise, on the
             reasoning that `PostToolUse` is only interesting as an attention-clear and
             repainting on every tool call would write to the device constantly. The
             optimisation was right and the guard implemented it wrongly: it conflated
             *do not repaint* with *do not record*.

             The consequence was a key stuck on the wrong color for a whole turn. Once
             anything moved a working session to `idle` — an `idle_prompt` notification,
             or a relaunch — `PostToolUse` was the only hook firing for the rest of that
             turn, and it did nothing. The board showed idle white through minutes of
             work, and the log said `PostToolUse -> working` the whole time because the
             line is written before this branch.

             Skipping when it is *already* working keeps the write traffic exactly where
             it was: that is the common case by a wide margin.
             */
            guard let existing = registry.entry(forSession: sessionID),
                  existing.state != .working
            else { return }
            registry.setState(sessionID: sessionID, to: .working)
            Log.write("hook \(event.name): \(existing.state.rawValue) -> working")
        } else {
            /*
             `idle_prompt` false-demotion guard, ahead of the delegating override below.

             Claude Code fires a Notification with subtype `idle_prompt` on an idle
             timer (~60s after a turn ends), independent of whether subagents are still
             running. A config that maps `idle_prompt` to any state (commonly `.idle`)
             would otherwise repaint a delegating `.working` key straight to slate —
             `mayReplace` only guards `done -> idle`, not `working -> idle`. Skipped
             entirely (no `setState`, no repaint) rather than re-applying `.working`,
             matching this function's own "a branch that declines says so on its own
             line, without touching the registry" precedent (`clearsAttention` above).
             */
            let delegatedBefore = registry.entry(forSession: sessionID)?.delegatingAgentIDs.count ?? 0
            if EventMapper.suppressesDelegating(
                eventName: event.name,
                matcher: event.matcher,
                delegatedCount: delegatedBefore
            ) {
                Log.write(
                    "hook \(event.name) idle_prompt suppressed (delegating, "
                        + "\(delegatedBefore) in flight) [\(sessionID.prefix(8))]"
                )
                return
            }

            /*
             Delegating-state override: a `Stop` that would paint `.done` paints
             `.working` instead while background subagents are still in flight.

             `background_tasks` (filtered to `type == "subagent"` by
             `backgroundSubagentIDs`) is authoritative and replaces the whole
             `delegatingAgentIDs` set wholesale — never trusted as a running total
             across `Stop`s. This is a no-op for every event that does not map to
             `.done` — Claude Code's `Stop` is the case this override exists for, but
             other harnesses' `.done`-mapped events (Pi's `turn_end`/`agent_settled`,
             `SessionRegistry.swift`) and a `Notification` subtype remapped to `.done`
             (`HarnessPane`'s picker) reach the same override too — so a plain turn with
             no subagents writes exactly the same `.done` it always has.

             No deferred-transition replay needed for the last agent landing: when the
             final background subagent finishes, the CLI has been observed to inject a
             synthetic `UserPromptSubmit` (its prompt begins with `<task-notification>`)
             followed by a real `Stop` — not a documented contract, but consistent
             across hardware validation. That follow-on `Stop` reconciles the count to
             zero and paints `.done` through this exact path — nothing needs to be
             stashed and replayed when the counter drops.
             */
            if state == .done {
                registry.reconcileDelegation(
                    sessionID: sessionID,
                    ids: event.backgroundSubagentIDs
                )
            }
            let delegatedCount = registry.entry(forSession: sessionID)?.delegatingAgentIDs.count ?? 0
            let delegating = delegatedCount > 0
            let applied = (state == .done && delegating) ? SessionState.working : state
            if state == .done, delegating {
                Log.write(
                    "hook \(event.name) deferred to working (delegating, "
                        + "\(delegatedCount) in flight) [\(sessionID.prefix(8))]"
                )
            }
            registry.setState(sessionID: sessionID, to: applied, pendingTool: event.toolName)
        }

        publish()
        fireLap(from: previousState, sessionID: sessionID)
        await paint()
    }

    /**
     Fire the ring lap a state change earns, if any.

     Separate from `handle` so the rule stays one line: **only a transition**. Firing on
     every paint turns the ring into a strobe and, worse, teaches you that a lap means
     nothing — which costs the one signal that is visible from across the room.
     */
    private func fireLap(from previous: SessionState?, sessionID: String) {
        let current = registry.entry(forSession: sessionID)?.state
        guard let name = Laps.show(
            from: previous, to: current, settings: model.preferences.ambient
        ) else { return }
        guard let show = Shows.show(named: name) else { return }
        Log.write("lap \(name): \(previous?.rawValue ?? "none") -> \(current?.rawValue ?? "none")")
        play(show: show)
    }

    /// The tty of a live process, so a key can raise the right tab later. Captured at
    /// claim time because `ps` cannot resolve one for a dead pid.
    /**
     Walk up from a pid until finding a `claude` process.

     Hooks run as children of the shell or of `claude` itself, so the ppid we get
     from the payload is one or two hops away from the session process. `ps -o
     comm=` on each ancestor tells us where in the chain the real `claude` sits.

     Bounded by depth: cyclic process tables are a `ps` bug, not a real state, but
     an unbounded loop here would freeze the hook path.
     */
    static func claudePID(fromAncestryOf pid: Int) -> Int? {
        var current = pid
        for _ in 0..<8 {
            guard let info = ProcessAncestry.defaultParentOf(current) else { return nil }
            // info.path is *current's* command, per `ps -o ppid=,comm=`.
            let comm = info.path.split(separator: "/").last.map(String.init) ?? info.path
            if comm == "claude" { return current }
            guard info.parent > 1 else { return nil }
            current = info.parent
        }
        return nil
    }

    private static func tty(forPID pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let raw = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "??" means no controlling terminal — normal for an extension-hosted session.
        guard !raw.isEmpty, raw != "??" else { return nil }
        return raw.hasPrefix("/dev/") ? raw : "/dev/\(raw)"
    }

    // MARK: - the resident loop

    private func startResident() {
        reassertTask = Task { [weak self] in
            var wasPresent: Bool?
            while !Task.isCancelled {
                guard let self else { return }
                let survey = HIDDevice.survey()
                let present = survey.found
                self.model.apply(isWired: survey.isWired)
                // Which pad, not just whether one is there: the name in the menu bar is
                // filed under this.
                self.model.apply(deviceSerial: survey.serial)
                self.lastPresenceLog = Log.changed("device present", last: self.lastPresenceLog, to: "\(present) (matched \(survey.matched), vendor \(survey.vendorInterfaces), transport \(survey.transport ?? "none"))"
                )
                let changed = present != wasPresent
                wasPresent = present

                if changed, present {
                    // A reconnect: repaint at once rather than waiting out a tick,
                    // then again shortly after, because Codex takes the LEDs back as
                    // it comes up and the first write can lose that race.
                    await self.reopen()
                    await self.paint()
                    try? await Task.sleep(for: .milliseconds(1500))
                    await self.paint()
                } else if present {
                    await self.paint()
                } else {
                    await self.closeDevice()
                }

                await self.refreshTerminalTitles()
                await self.publishDeviceStatus(present: present)
                try? await Task.sleep(for: present ? self.presentInterval : self.absentInterval)
            }
        }
    }

    private func reopen() async {
        closeDeviceSync()
        do {
            try device.open()
            deviceIsOpen = true
            lastOpenLog = Log.changed("device open", last: lastOpenLog, to: "yes")
        } catch {
            deviceIsOpen = false
            // The distinction that matters: denied is a permission the user can grant,
            // anything else is the pad not being there.
            lastOpenLog = Log.changed("device open", last: lastOpenLog, to: "NO — \(error.localizedDescription)")
        }
    }

    private func closeDevice() async { closeDeviceSync() }

    /// Drop a handle that is no longer working, so the next cycle reopens it.
    ///
    /// Separate from `closeDeviceSync` only to log it: "the pad stopped responding and
    /// the app noticed" and "the pad went away" look identical afterwards, and the
    /// first is the one that used to never happen.
    private func invalidateHandle() {
        guard deviceIsOpen else { return }
        Log.write("device handle dropped after a failed write — will reopen")
        closeDeviceSync()
    }

    private func closeDeviceSync() {
        guard deviceIsOpen else { return }
        device.close()
        deviceIsOpen = false
    }

    private func publishDeviceStatus(present: Bool) async {
        if !present {
            // Ask *why* only when something is already wrong: system_profiler takes
            // about a second, which is far too slow for the 2s presence poll and
            // pointless while the pad is working.
            let presence = DeviceDiagnostics.presence()
            lastPresenceReason = Log.changed("device missing", last: lastPresenceReason, to: String(describing: presence))
            switch presence {
            case .pairedButAsleep: model.apply(device: .bluetoothDisconnected)
            case .bluetoothOff: model.apply(device: .bluetoothOff)
            case .notPaired, .unknown, .connected: model.apply(device: .notFound)
            }
            return
        }
        if !deviceIsOpen {
            await reopen()
        }
        if deviceIsOpen {
            model.apply(device: .ready)
            return
        }
        // Do not guess. The pad being visible but unopenable was reported as
        // "Input Monitoring" regardless of whether that permission was actually the
        // problem, which sends people to a settings pane where the switch is already on.
        // Grant checked first: it is the durable problem, and the one with a settings
        // fix. Secure Keyboard Entry is checked next — it produces the identical
        // kIOReturnNotPermitted, but the remedy is whatever engaged it, not settings.
        let access = PermissionProbe.inputMonitoring()
        if !access.isGranted {
            model.apply(device: .permissionDenied(missing: ["Input Monitoring"]))
            return
        }
        let secure = PermissionProbe.secureInput()
        model.apply(device: secure.active
            ? .secureInputBlocked(holder: secure.holderDescription)
            : .inUseElsewhere)
    }

    // MARK: - painting

    /// Push the whole board to the pad.
    ///
    /// Nothing paints without calibration: slot order is never assumed, and a
    /// confidently wrong light is worse than no light.
    func paint() async {
        var painted = (written: 0, skipped: 0)
        /*
         Never two at once.

         `paint` is async and every caller can trigger it — the resident loop, each
         hook, a settings edit, the battery refresh. `@MainActor` does not prevent
         reentrancy: it only means one runs at a time *between* suspension points, and
         `await device.write` is a suspension point right in the middle. A second paint
         then enters while the first is parked and mutates `registry` through `prune`
         and `decay`, which is overlapping exclusive access to a struct — a hard trap,
         not a race that merely produces a wrong light.

         It crashed the app with `swift_beginAccess` from the resident loop. Coalescing
         is also simply correct: two repaints of the same board are one repaint, and the
         second would only re-send what the first already sent.
         */
        guard !isPainting else {
            repaintWanted = true
            return
        }
        isPainting = true
        defer {
            isPainting = false
            // Anything that asked while this was in flight gets exactly one follow-up,
            // so a burst of hooks collapses into a single extra repaint.
            if repaintWanted {
                repaintWanted = false
                Task { await paint() }
            }
        }

        guard deviceIsOpen else {
            lastPaintLog = Log.changed("paint", last: lastPaintLog, to: "skipped — device not open")
            return
        }
        let calibration = model.calibration
        // A capture owns the keys until it ends. Otherwise the re-assert loop repaints
        // the board over the legend a second after it appears, and the operator is
        // asked to name colors that are no longer there.
        guard calibrationTask == nil else {
            lastPaintLog = Log.changed("paint", last: lastPaintLog, to: "deferred — calibrating")
            return
        }
        // Fun mode owns the whole pad, status included. It was asked for explicitly and
        // it repaints the real board when it ends.
        guard countdown?.isRunning != true else {
            lastPaintLog = Log.changed("paint", last: lastPaintLog, to: "deferred — fun mode")
            return
        }

        /*
         Drop sessions whose process is gone, then age what is left.

         `prune` existed with exactly the right reasoning in its own doc comment — "a
         dead session holding a key makes the board claim activity that does not exist"
         — and was never called from anywhere. So a closed Terminal tab kept its key
         until the 12h stale window, and the header counted it as live.
         */
        var boardChanged = registry.prune() > 0
        if registry.decay(
            doneAfter: TimeInterval(model.preferences.doneDecaySeconds),
            holdAttention: model.preferences.holdAttention
        ) > 0 {
            boardChanged = true
        }
        if boardChanged { publish() }

        do {
            // Build the whole repaint first, then write it under a single lock. A board
            // update is one logical operation; taking the cross-process lock once per
            // key gave seven chances to collide with another writer.
            var batch: [[Data]] = []
            var written = 0
            var skipped = 0

            // Silence the layer's own backlight, or it floods the pad and buries every
            // per-key color. rgbcfg needs a complete config — both sides, always.
            // Silence the key backlight, or it floods the pad and buries per-key
            // color. Skipped entirely while a show owns the ring: this call carries
            // the ring config too, so sending it mid-show cuts the animation off.
            if Date() >= ringBusyUntil {
                batch.append(device.prepare(
                    lighting: CodexProtocol.LightingConfig(keys: .off, ambient: ambientSide())
                ))
            }

            for (slot, entry) in registry.occupancy() {
                // A slot the calibration does not cover is skipped rather than guessed.
                // Counted, because "every key went dark" and "the app wrote every key
                // and the pad ignored it" look identical from the outside and have
                // completely different causes.
                guard let physical = calibration.physicalSlot(for: slot) else {
                    skipped += 1
                    continue
                }
                // A free slot and a finished session both mean "nothing to look at".
                // `viewing` is applied here rather than stored — see Viewing.
                let viewing = entry.map { isFocused($0, name: name(of: $0)) } ?? false
                let state = entry.map { Viewing.display($0.state, isFocused: viewing) } ?? .ended
                let appearance = Viewing.appearance(
                    state,
                    isFocused: viewing,
                    from: model.appearances
                )
                let effect = CodexProtocol.Effect(rawValue: appearance.effect.deviceCode) ?? .solid
                let thread = try CodexProtocol.ThreadState(
                    physicalSlot: physical,
                    color: appearance.color,
                    brightness: appearance.brightness,
                    effect: effect,
                    speed: appearance.speed
                )
                batch.append(device.prepare(threads: [thread]))
                written += 1
            }

            try await device.write(batch: batch)
            painted = (written, skipped)
        } catch {
            // Never throw out of the loop: a failed repaint is a missed light, but a
            // dead loop is a board that stays wrong until someone restarts the app.
            // Logged, though — a silent swallow here is what made this undiagnosable.
            //
            // kIOReturnNotPermitted on an already-open handle is the Secure Keyboard
            // Entry signature — the periodic poll's disambiguation only covers the
            // *open* path, so a mid-session engage surfaces here first and used to be
            // logged as an Input Monitoring denial the settings pane would contradict.
            var failure = error.localizedDescription
            if case CodexError.accessDenied = error {
                let secure = PermissionProbe.secureInput()
                if secure.active {
                    failure += " — Secure Keyboard Entry is active (\(secure.holderDescription)), not an Input Monitoring problem"
                }
            }
            lastPaintLog = Log.changed("paint", last: lastPaintLog, to: "FAILED — \(failure)")
            /*
             A failed write means this handle is dead, whatever the survey says.

             Plugging the pad into USB while it is on Bluetooth removes one HID device
             and adds another. The survey counts the *new* one, so `present` stays true
             and never *changes* — which is the only thing that triggered a reopen. The
             app went on writing to the old handle indefinitely: every report refused,
             the pad dark and unresponsive, and the header still saying "connected"
             because `deviceIsOpen` was never falsified.

             So the write is the authority on whether the handle works, not the count of
             devices that look like a pad. Dropping it here also corrects the header,
             which reads `deviceIsOpen` — one flag, so the status cannot claim a
             connection the writes are not getting.
             */
            invalidateHandle()
            return
        }
        // The key count, not just the session count: a board that goes dark while this
        // says "6 keys" is the device dropping them, and one that says "0 keys" is us.
        lastPaintLog = Log.changed(
            "paint",
            last: lastPaintLog,
            to: "ok — \(painted.written) keys written"
                + (painted.skipped > 0 ? ", \(painted.skipped) uncalibrated" : "")
                + " (\(registry.entries.count) sessions)"
        )
    }

    // MARK: - commands

    func sync() { Task { await paint() } }

    /**
     Play a ring animation.

     One at a time — overlapping shows fight over a single light. The board keeps
     painting underneath: the ring and the six keys are separate RPCs, so status is
     never suspended for a show, only the ring is borrowed.
     */
    /**
     Fun mode.

     Owns the whole pad for the length of the song, status included. `paint()` stands
     down while it runs — the same rule the calibration capture uses, for the same
     reason: two writers produce a fight nobody can read.
     */
    func playCountdown() {
        guard deviceIsOpen else { return }
        if countdown?.isRunning == true {
            countdown?.cancel()
            return
        }
        let player = CountdownPlayer(
            device: device,
            log: { Log.write($0) },
            finished: { [weak self] in
                guard let self else { return }
                self.countdown = nil
                self.model.funModeRunning = false
                self.ringBusyUntil = .distantPast
                Task { await self.paint() }
            }
        )
        countdown = player
        model.funModeRunning = true
        // The ring belongs to the show for the duration; a status repaint mid-song
        // restarts the firmware's animation and reads as flicker.
        ringBusyUntil = Date().addingTimeInterval(400)
        player.start(preferences: model.preferences)
    }

    func play(show: Show) {
        guard runningShow == nil else {
            Log.write("show \(show.name): ignored, \(runningShow ?? "another") is playing")
            return
        }
        guard deviceIsOpen else { return }

        runningShow = show.name
        model.runningShow = show.name
        ringBusyUntil = Date().addingTimeInterval(show.duration.seconds + 0.8)
        Log.write("show \(show.name): starting (\(Int(show.duration.seconds * 1000))ms)")

        Task { [weak self] in
            guard let self else { return }
            for step in show.steps {
                guard self.runningShow == show.name else { break }
                // Asserted once, then left alone for the step's duration.
                try? await self.device.send(
                    lighting: CodexProtocol.LightingConfig(keys: .off, ambient: step.side)
                )
                try? await Task.sleep(for: .milliseconds(step.milliseconds))
            }
            // Hand the ring back rather than leaving whatever the last step wrote.
            try? await self.device.send(
                lighting: CodexProtocol.LightingConfig(keys: .off, ambient: .off)
            )
            self.runningShow = nil
            self.model.runningShow = nil
            self.ringBusyUntil = .distantPast
            Log.write("show \(show.name): done")
            await self.paint()
        }
    }

    /// Jump from a click in the popover, as opposed to a key press.
    func jumpFromUI(_ slot: Int) { jump(to: slot) }

    func stopShow() {
        runningShow = nil
        ringBusyUntil = .distantPast
    }

    /**
     Free one key.

     The session keeps running — this forgets the *binding*, it does not stop anything.
     Needed because a session whose process died without emitting `SessionEnd` holds its
     slot until the stale window expires, and "forget all" is a poor answer to one row
     being wrong.
     */
    func release(slot: Int) {
        guard let entry = registry.occupancy().first(where: { $0.slot == slot })?.entry else {
            return
        }
        // Drop the cached name too, or a key reused by a different chat keeps the old one.
        SessionTitle.forget(transcriptPath: entry.transcriptPath)
        registry.release(sessionID: entry.sessionID)
        Log.write("released slot \(slot) (\(entry.sessionID.prefix(8)))")
        publish()
        Task { await paint() }
    }

    func forgetAllSessions() {
        registry.reset()
        publish()
        Task { await paint() }
    }

    // MARK: - publishing

    private func publish() {
        let slots = registry.occupancy().map { slot, entry -> SlotView in
            guard let entry else { return SlotView(slot: slot) }
            // What you asked for, falling back to the folder. Two sessions in one repo
            // are otherwise identical rows.
            // The tab title first: Claude Code keeps it describing what the session
            // is *now*, where the first message describes what it was when it started.
            let name = self.name(of: entry)
            // Not `focused`: that is the property holding what is in front of you, and
            // shadowing it here reads as though the two are the same thing.
            let viewing = isFocused(entry, name: name)
            let shown = Viewing.display(entry.state, isFocused: viewing)
            return SlotView(
                slot: slot,
                state: shown,
                // What you asked for, falling back to the folder. Two sessions in one
                // repo are otherwise identical rows.
                title: name ?? entry.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                project: entry.cwd.map(Self.shorten),
                surface: entry.tty.map { $0.replacingOccurrences(of: "/dev/", with: "") }
                    ?? entry.entrypoint,
                age: Self.age(of: entry.updatedAt),
                sessionID: entry.sessionID,
                pendingTool: entry.pendingTool,
                origin: SessionOrigin.from(
                    entrypoint: entry.entrypoint, tty: entry.tty, host: entry.host
                ),
                entrypoint: entry.entrypoint,
                isNamed: name != nil,
                cwd: entry.cwd,
                // The same resolution the pad gets, from the same configured colors, so
                // the dot and the swatch cannot drift from the key.
                emitting: Viewing.appearance(shown, isFocused: viewing, from: model.appearances),
                isFocused: viewing
            )
        }
        model.apply(slots: slots)
        RegistryStore.save(registry)
    }

    private static func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func age(of date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
