import Foundation
import OpenBoardKit

/**
 The configuration file.

 It controls everything, so the failure modes matter more than the happy path: a
 *partial* document must merge rather than replace, an existing Node-era file must be
 picked up unchanged, and a hand edit must never be silently discarded.

 The fixture below is this machine's actual `config.json` — a rewrite reading a
 different path or schema would have ignored every setting in it.
 */
func runPreferencesTests() {
    func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-config-\(UUID().uuidString).json")
    }

    test("the file lives where the Node version put it") {
        // Anything else silently abandons every existing installation's settings.
        expectEqual(PreferencesStore.url(env: ["OPENBOARD_HOME": "/tmp/ob"]).path, "/tmp/ob/config.json")
    }

    test("defaults cover every state, action key and notification") {
        let defaults = Preferences.default
        for state in SessionState.allCases {
            expectEqual(defaults.appearance(for: state), state.defaultAppearance)
        }
        expectEqual(defaults.keyActions["ACT06"], .approve)
        expectEqual(defaults.notificationStates["permission_prompt"], .awaiting)
        // Means "sitting idle", not "needs you" — mapping it lights the attention
        // color with nothing to act on.
        expect(defaults.notificationStates["idle_prompt"] == nil)
        expectEqual(defaults.encoder.cw, "scroll-up")
        expectEqual(defaults.ambient.mode, "events")
        expectEqual(defaults.countdown.leadMs, 70)
        expectEqual(defaults.maxHoldSeconds, 60)
    }

    test("this machine's real config.json loads exactly as written") {
        let real = """
        {"notifications":{"idle_prompt":"idle"},
         "states":{"ended":{"effect":"off"},
                   "idle":{"color":16777215,"brightness":0.2,"effect":"solid","speed":0},
                   "working":{"effect":"shallow-breath"},
                   "awaiting":{"effect":"shallow-breath"}},
         "actionKeys":{"ACT08":"snippet","ACT09":"newtab","ACT10":"voice-tap","ACT11":null},
         "snippets":{"ACT08":"/start-ticket"},
         "encoder":{"cc":"scroll-down","cw":"scroll-up","click":"ui"},
         "ambient":{"mode":"events","completionLap":true,"questionLap":true},
         "countdown":{"leadMs":70,"introFlashSec":13.2,"introFlashColor":16723349}}
        """
        let json = try Harness.require(
            (try? JSONSerialization.jsonObject(with: Data(real.utf8))) as? [String: Any]
        )
        let prefs = Preferences.merging(json)

        // Colors are numbers on disk. 16777215 is white.
        expectEqual(prefs.appearance(for: .idle).color.hex, "#FFFFFF")
        expectEqual(prefs.appearance(for: .idle).brightness, 0.2)
        expectEqual(prefs.appearance(for: .working).effect, .shallowBreath)
        expectEqual(prefs.notificationStates["idle_prompt"], .idle)
        expectEqual(prefs.encoder.click, .settings)
        expectEqual(prefs.countdown.introFlashColor.hex, "#FF2D95")
    }

    test("a state override merges field by field, not wholesale") {
        // `{"working":{"effect":"shallow-breath"}}` must keep working's color and
        // brightness. Replacing the object instead turns a one-line override into a
        // half-configured state.
        let prefs = Preferences.merging(["states": ["working": ["effect": "shallow-breath"]]])
        let working = prefs.appearance(for: .working)
        expectEqual(working.effect, .shallowBreath)
        expectEqual(working.color.hex, "#0C47E9", "color must survive")
        expectEqual(working.brightness, 0.75, "brightness must survive")
        expectEqual(working.speed, 0.45, "speed must survive")
        // A state the document never mentions is untouched.
        expectEqual(prefs.appearance(for: .awaiting), SessionState.awaiting.defaultAppearance)
    }

    test("an explicitly unassigned key stays unassigned") {
        // `"ACT11": null` is a decision. Dropping it lets the key revert to its default
        // on the next launch, so clearing a binding would silently undo itself.
        let prefs = Preferences.merging(["actionKeys": ["ACT11": NSNull()]])
        expect(prefs.keyActions["ACT11"] == nil)
        expect(prefs.actionKeys["ACT11"] != nil, "the decision itself is recorded")
    }

    test("a shortcut without a key code is skipped, not fatal") {
        let prefs = Preferences.merging(["shortcuts": [
            "ACT08": ["keyCode": 49, "modifiers": ["control"], "key": "Space", "mode": "hold"],
            "ENC": ["modifiers": ["command"]],
        ]])
        expectEqual(
            prefs.shortcuts["ACT08"],
            Shortcut(keyCode: 49, modifiers: [.control], key: "Space", mode: .hold)
        )
        expect(prefs.shortcuts["ENC"] == nil, "an entry with nothing to send was kept")
    }

    test("a color may be a number or a hex string") {
        // Numbers are what Node wrote; hex is what a person types.
        expectEqual(
            Preferences.merging(["states": ["idle": ["color": 16711680]]])
                .appearance(for: .idle).color.hex, "#FF0000"
        )
        expectEqual(
            Preferences.merging(["states": ["idle": ["color": "#00FF00"]]])
                .appearance(for: .idle).color.hex, "#00FF00"
        )
        // Nonsense leaves the default rather than blanking the key.
        expectEqual(
            Preferences.merging(["states": ["idle": ["color": "puce"]]])
                .appearance(for: .idle).color.hex, "#2E4A6B"
        )
    }

    test("an empty or unknown document is still valid") {
        expectEqual(Preferences.merging([:]), Preferences.default)
        expectEqual(Preferences.merging(["somethingNew": 42]), Preferences.default)
        // A state name this version does not know is skipped, not fatal.
        expectEqual(
            Preferences.merging(["states": ["frobnicated": ["effect": "solid"]]]),
            Preferences.default
        )
    }

    test("a document round-trips through disk unchanged") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PreferencesStore()

        var prefs = store.load(url: url)
        prefs.setAppearance(
            Appearance(color: RGB(0x7B2FF7), effect: .breath, brightness: 0.42, speed: 0.3),
            for: .working
        )
        prefs.actionKeys["ACT06"] = KeyAction?.none
        prefs.events["Stop"] = false
        prefs.notifications["idle_prompt"] = SessionState.awaiting
        store.save(prefs, url: url, immediately: true)

        let reloaded = PreferencesStore().load(url: url)
        let working = reloaded.appearance(for: .working)
        expectEqual(working.color.hex, "#7B2FF7")
        expectEqual(working.effect, .breath)
        expectEqual(working.brightness, 0.42)
        expect(reloaded.keyActions["ACT06"] == nil, "unassigned did not survive")
        expectEqual(reloaded.events["Stop"], false)
        expectEqual(reloaded.notificationStates["idle_prompt"], .awaiting)
    }

    test("every single setting survives a save and reload") {
        /*
         The exhaustive one.

         The round trip above checks a handful of fields, which is the shape of test
         that passes while a whole section is missing from `json` or from `merging` —
         and a setting that does not round-trip is a control that appears to work and
         forgets. So this moves *every* field off its default, writes, reloads, and
         compares the whole document.

         Values are chosen inside the clamps the reader applies (gain 0.25–4,
         longPressMs 150–2000, threshold 0.1–0.95, brightness and speed 0–1). A value
         outside them would come back legitimately different and this would be
         asserting the clamp instead of the round trip.
         */
        var prefs = Preferences.default

        for state in SessionState.allCases {
            prefs.setAppearance(
                Appearance(color: RGB(0x123456), effect: .breath, brightness: 0.41, speed: 0.29),
                for: state
            )
        }
        prefs.actionKeys["ACT06"] = KeyAction?.none          // explicitly unassigned
        prefs.actionKeys["ACT07"] = .snippet
        prefs.snippets["ACT07"] = "/review"
        prefs.shortcuts["ACT08"] = Shortcut(
            keyCode: 49, modifiers: [.control, .option], key: "Space", mode: .hold
        )
        prefs.shortcuts["JOY.up"] = Shortcut(keyCode: 16, modifiers: [.command], key: "Y")
        prefs.caps["ACT07"] = "MAGIC"
        prefs.events["Stop"] = false
        prefs.notifications["idle_prompt"] = SessionState.awaiting
        prefs.notifications["permission_prompt"] = SessionState?.none

        prefs.encoder.cw = "scroll-down"
        prefs.encoder.cc = "scroll-up"
        prefs.encoder.click = .settings
        prefs.encoder.longPress = nil
        prefs.encoder.longPressMs = 700

        prefs.joystick.up = .tabForward
        prefs.joystick.down = nil
        prefs.joystick.left = .arrowUp
        prefs.joystick.right = .arrowDown
        prefs.joystick.northAngle = 0.125
        prefs.joystick.clockwise = false
        prefs.joystick.threshold = 0.65

        prefs.ambient.mode = "fixed"
        prefs.ambient.completionLap = false
        prefs.ambient.questionLap = false
        prefs.ambient.errorPulse = false
        prefs.ambient.fixed = Appearance(
            color: RGB(0x00C8D7), effect: .shallowBreath, brightness: 0.22, speed: 0.11
        )

        prefs.countdown.leadMs = 95
        prefs.countdown.introFlashSec = 9.5
        prefs.countdown.introFlashColor = RGB(0xE81CA8)
        prefs.countdown.introEnabled = false
        prefs.countdown.introColorKeys = RGB(0x1B2A6B)
        prefs.countdown.introBrightness = 0.44
        prefs.countdown.introTrail = 0.33
        prefs.countdown.gain = 1.55
        prefs.countdown.mediaDir = "/tmp/openboard-media"

        prefs.entrypoints = ["cli", "vscode"]
        prefs.scrollLines = 7
        prefs.staleHours = 24
        prefs.doneDecaySeconds = 120
        prefs.holdAttention = false
        prefs.maxHoldSeconds = 45

        expect(prefs != Preferences.default, "the fixture never left the defaults")

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        PreferencesStore().save(prefs, url: url, immediately: true)
        let reloaded = PreferencesStore().load(url: url)

        expectEqual(reloaded, prefs)
    }

    test("the file is written on first load, and is not world-readable") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = PreferencesStore().load(url: url)
        expect(FileManager.default.fileExists(atPath: url.path), "no file was created")

        // 0600, like the Node version and the calibration record beside it. An atomic
        // write replaces the inode, so the mode has to be reapplied every save.
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }?.intValue ?? 0
        expectEqual(mode & 0o077, 0, "group or other can read it")
    }

    test("a corrupt file falls back rather than stopping the app") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ this is not json".utf8).write(to: url)

        let prefs = PreferencesStore().load(url: url)
        expectEqual(prefs.appearance(for: .idle).color.hex, "#2E4A6B")
    }

    test("writes are atomic") {
        // A crash mid-write must not truncate the file that controls everything.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PreferencesStore()
        var prefs = store.load(url: url)

        for level in stride(from: 0.0, through: 1.0, by: 0.1) {
            prefs.setAppearance(
                Appearance(color: RGB(0x0C47E9), effect: .breath, brightness: level, speed: 0),
                for: .working
            )
            store.save(prefs, url: url, immediately: true)
        }

        let data = try Harness.require(try? Data(contentsOf: url))
        expect(
            ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) != nil,
            "the file on disk is not valid JSON"
        )
    }

    test("the daylight lift is fixed, but still readable from disk") {
        // The slider is gone: the answer is "bright enough for the room you are in",
        // which is one decision per room rather than per viewing. 2 is what this pad
        // was tuned to, and it is what a document saying nothing gets.
        expectEqual(Preferences.default.countdown.gain, 2)
        expectEqual(Preferences.merging(["countdown": ["leadMs": 70]]).countdown.gain, 2)

        // Still honoured for a genuinely darker or brighter room, and still bounded:
        // a hand-edited 0 would blank the show and a 20 would flatten it.
        expectEqual(Preferences.merging(["countdown": ["gain": 1.5]]).countdown.gain, 1.5)
        expectEqual(Preferences.merging(["countdown": ["gain": 20.0]]).countdown.gain, 4)
        expectEqual(Preferences.merging(["countdown": ["gain": 0.01]]).countdown.gain, 0.25)
        // Nonsense leaves the default rather than blanking the pad.
        expectEqual(Preferences.merging(["countdown": ["gain": 0.0]]).countdown.gain, 2)
        expectEqual(Preferences.merging(["countdown": ["gain": -3.0]]).countdown.gain, 2)

        var next = Preferences.default
        next.countdown.gain = 1.75
        expectEqual(Preferences.merging(next.json).countdown.gain, 1.75)
    }

    test("timings come from the document, not from constants") {
        let prefs = Preferences.merging([
            "staleHours": 3, "doneDecaySeconds": 10,
            "holdAttention": false, "maxHoldSeconds": 5, "scrollLines": 7,
        ])
        expectEqual(prefs.staleHours, 3)
        expectEqual(prefs.staleInterval, 3 * 3600)
        expectEqual(prefs.doneDecaySeconds, 10)
        expectEqual(prefs.holdAttention, false)
        expectEqual(prefs.maxHoldSeconds, 5)
        expectEqual(prefs.scrollLines, 7)
    }

    test("a configured stale window actually reclaims") {
        // The registry used a hardcoded 12h. Wiring the value through is the point.
        var registry = SessionRegistry()
        registry.staleInterval = 60
        let start = Date()
        _ = registry.claim(sessionID: "a", pid: 1, now: start, isAlive: { _ in true })
        let entry = try Harness.require(registry.entry(forSession: "a"))

        expect(!registry.isReclaimable(entry, now: start, isAlive: { _ in true }))
        expect(
            registry.isReclaimable(entry, now: start.addingTimeInterval(120), isAlive: { _ in true }),
            "past the configured window it should be reclaimable"
        )
    }

    test("encoder direction is configurable, and the two ends stay opposite") {
        // A dial bound to the same direction at both ends scrolls one way whichever way
        // it is turned, which reads as broken hardware rather than as a setting.
        var encoder = Preferences.Encoder()
        expect(encoder.clockwiseScrollsUp, "the default matches macOS natural scrolling")

        encoder.clockwiseScrollsUp = false
        expectEqual(encoder.cw, "scroll-down")
        expectEqual(encoder.cc, "scroll-up")

        encoder.clockwiseScrollsUp = true
        expectEqual(encoder.cw, "scroll-up")
        expectEqual(encoder.cc, "scroll-down")

        // A hand-written document that sets both the same way is read as its cw value
        // rather than obeyed into a one-way dial.
        let both = Preferences.merging(["encoder": ["cw": "scroll-down", "cc": "scroll-down"]])
        expect(!both.encoder.clockwiseScrollsUp)
    }

    test("an inverted encoder survives a relaunch") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PreferencesStore()

        var prefs = store.load(url: url)
        prefs.encoder.clockwiseScrollsUp = false
        prefs.scrollLines = 8
        store.save(prefs, url: url, immediately: true)

        let reloaded = PreferencesStore().load(url: url)
        expect(!reloaded.encoder.clockwiseScrollsUp)
        expectEqual(reloaded.scrollLines, 8)
    }

    test("hex parsing accepts what a person would type") {
        expectEqual(RGB(hex: "#7B2FF7")?.hex, "#7B2FF7")
        expectEqual(RGB(hex: "7b2ff7")?.hex, "#7B2FF7")
        expectEqual(RGB(hex: "  #7B2FF7  ")?.hex, "#7B2FF7")
        expect(RGB(hex: "#7B2FF") == nil)
        expect(RGB(hex: "purple") == nil)
        expect(RGB(hex: "") == nil)
    }
}

/**
 Event gating — the Events pane was decorative until this.

 `EventMapper.state` accepted `enabledEvents:` and `notifications:` and the caller
 passed neither, so every toggle in the pane changed nothing.
 */
func runEventGatingTests() {
    test("muting an event stops it repainting") {
        expectEqual(EventMapper.state(for: "Stop", enabledEvents: [:]), .done)
        expect(EventMapper.state(for: "Stop", enabledEvents: ["Stop": false]) == nil)
        // Absent means enabled: muting is opt-in, so an untouched document behaves
        // exactly like the defaults.
        expectEqual(EventMapper.state(for: "Stop", enabledEvents: ["SessionStart": false]), .done)
    }

    test("a configured notification mapping is honoured") {
        // This machine maps idle_prompt to idle rather than leaving it unmapped.
        expectEqual(
            EventMapper.state(
                for: "Notification", matcher: "idle_prompt", notifications: ["idle_prompt": .idle]
            ),
            .idle
        )
        expect(EventMapper.state(for: "Notification", matcher: "idle_prompt") == nil)
    }

    test("mapping idle_prompt to awaiting makes an idle prompt orange") {
        // The plan's acceptance test for gap 2.
        let state = EventMapper.state(
            for: "Notification", matcher: "idle_prompt", notifications: ["idle_prompt": .awaiting]
        )
        expectEqual(state, .awaiting)
        expect(state?.isAttention == true)
    }

    test("an unmapped subtype still repaints nothing") {
        // agent_completed and auth_success are about the app, not about a key.
        expect(
            EventMapper.state(
                for: "Notification", matcher: "agent_completed",
                notifications: EventMapper.defaultNotifications
            ) == nil
        )
    }
}

/**
 What the tool-use events actually mean.

 The Events pane described `PostToolUseFailure` as "sets error" for as long as it has
 existed, and that was never what it does. Pinned here so the copy and the behaviour
 cannot drift apart again.
 */
func runToolEventTests() {
    test("a failed tool call is not a failed session") {
        // Claude retries and the turn carries on. Mapping this to error would flash the
        // key red on every retry, which teaches you to ignore red.
        expectEqual(EventMapper.state(for: "PostToolUseFailure"), .working)
        expectEqual(EventMapper.state(for: "PostToolUse"), .working)
    }

    test("both tool events clear a stuck prompt") {
        // Their real job: a permission prompt answered outside OpenBoard leaves the key
        // orange, and the next tool call is the proof it was answered.
        expect(EventMapper.clearsAttention.contains("PostToolUse"))
        expect(EventMapper.clearsAttention.contains("PostToolUseFailure"))
    }

    test("the turn failing is what sets error") {
        // The distinction the pane copy blurred.
        expectEqual(EventMapper.state(for: "StopFailure"), .error)
        expectEqual(EventMapper.state(for: "Stop"), .done)
        expect(!EventMapper.clearsAttention.contains("StopFailure"))
    }
}
