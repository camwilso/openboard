import Foundation
import OpenBoardKit

/**
 Where things live, and getting an existing installation there.

 The move out of `~/.claude/openboard` is the kind of change that is fine until it is
 catastrophic: a settings file that ends up in neither place, or a hook helper writing
 to a socket nobody is listening on — which does not error, it just makes the board
 stop updating for reasons no one can see.
 */
func runAppPathsTests() {
    func tempHome() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    test("state and logs are separate, and named for this app") {
        let state = AppPaths.state(env: [:]).path
        let logs = AppPaths.logs(env: [:]).path
        expect(state.contains("Application Support/OpenBoard"), state)
        expect(logs.contains("Library/Logs/OpenBoard"), logs)
        expect(state != logs, "logs must be discardable without losing settings")
        // The thing being moved away from.
        expect(!state.contains(".claude"), "state is still in Claude Code's directory")
        expect(!logs.contains(".claude"), "logs are still in Claude Code's directory")
    }

    test("the override still collapses everything into one directory") {
        // A scratch run has to be entirely self-contained, or a test writes into the
        // real installation.
        let env = ["OPENBOARD_HOME": "/tmp/ob-scratch"]
        expectEqual(AppPaths.state(env: env).path, "/tmp/ob-scratch")
        expectEqual(AppPaths.logs(env: env).path, "/tmp/ob-scratch")
        expectEqual(AppPaths.socket(env: env).path, "/tmp/ob-scratch/hook.sock")
        expectEqual(Calibration.defaultStateDirectory(env: env).path, "/tmp/ob-scratch")
    }

    test("the media library sits inside state, and is created before it is needed") {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["OPENBOARD_HOME": home.path]

        expectEqual(AppPaths.media(env: env).path, home.appendingPathComponent("Media").path)
        expect(!FileManager.default.fileExists(atPath: AppPaths.media(env: env).path))
        expectEqual(AppPaths.mediaLibrary(env: env), [], "a missing folder is not an error")

        AppPaths.ensureMedia(env: env)
        expect(FileManager.default.fileExists(atPath: AppPaths.media(env: env).path))
        AppPaths.ensureMedia(env: env)  // twice, because launch is not once per machine
        expectEqual(AppPaths.mediaLibrary(env: env), [])
    }

    test("the library lists video folders, sorted, and nothing else") {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["OPENBOARD_HOME": home.path]
        let root = AppPaths.ensureMedia(env: env)

        for name in ["sandstorm", "africa", ".DS_Store_dir"] {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        // A loose file is not a video folder: it cannot hold both halves.
        try? Data().write(to: root.appendingPathComponent("README.txt"))
        try? Data().write(to: root.appendingPathComponent(".DS_Store"))

        expectEqual(AppPaths.mediaLibrary(env: env), ["africa", "sandstorm"])
    }

    test("the socket path fits in a sockaddr_un") {
        // 104 bytes, and a path over it does not error — it truncates, and the helper
        // connects somewhere else entirely.
        expect(AppPaths.socket(env: [:]).path.utf8.count < 104, AppPaths.socket(env: [:]).path)
    }

    test("an existing installation is moved across, once") {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appendingPathComponent(".claude/openboard")
        let new = home.appendingPathComponent("state")
        let logs = home.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)

        try? Data("{\"scrollLines\":9}".utf8)
            .write(to: old.appendingPathComponent("config.json"))
        try? Data("old log\n".utf8).write(to: old.appendingPathComponent("app.log"))
        // Node-era leftovers, whose purpose this app does not know.
        try? Data("x".utf8).write(to: old.appendingPathComponent("watch.log"))

        let moved = AppPaths.migrate(from: old, state: new, logs: logs)
        expect(moved.contains("config.json"), "the settings did not move")
        expect(moved.contains("app.log"), "the log did not move")

        expect(
            FileManager.default.fileExists(atPath: new.appendingPathComponent("config.json").path),
            "config.json is not at the destination"
        )
        expect(
            FileManager.default.fileExists(atPath: logs.appendingPathComponent("app.log").path),
            "app.log went to the state directory instead of Logs"
        )
        // Moved, not copied: two copies of a settings file means editing one and
        // reading the other, and nothing you change appears to take.
        expect(
            !FileManager.default.fileExists(atPath: old.appendingPathComponent("config.json").path),
            "the old config.json is still there"
        )
        // Untouched, because sweeping up files whose purpose is not understood is how
        // a migration destroys something.
        expect(
            FileManager.default.fileExists(atPath: old.appendingPathComponent("watch.log").path),
            "an unrelated file was taken"
        )
    }

    test("migrating twice never overwrites what is already there") {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appendingPathComponent(".claude/openboard")
        let new = home.appendingPathComponent("state")
        try? FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        try? Data("old".utf8).write(to: old.appendingPathComponent("config.json"))
        try? Data("current".utf8).write(to: new.appendingPathComponent("config.json"))

        let moved = AppPaths.migrate(from: old, state: new, logs: new)
        expect(moved.isEmpty, "a live config was overwritten by a stale one")
        expectEqual(
            try? String(contentsOf: new.appendingPathComponent("config.json"), encoding: .utf8),
            "current"
        )
    }

    test("a missing old directory is not an error") {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        expectEqual(
            AppPaths.migrate(
                from: home.appendingPathComponent("nothing-here"),
                state: home.appendingPathComponent("state"),
                logs: home.appendingPathComponent("logs")
            ),
            []
        )
    }

    test("the hook helper looks where the app actually listens") {
        /*
         The helper deliberately does not link OpenBoardKit — it runs on every hook of
         every session, and pulling in IOKit and CoreBluetooth would put dyld work on
         the critical path of a prompt. So it repeats these paths as literals, and this
         is what keeps the copy honest.

         Getting it wrong is silent: hooks connect to nothing, no error is reported into
         the session, and the board simply stops updating.
         */
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("openboard-hook/main.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            skip("helper source not readable")
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for expected in [AppPaths.socket(env: [:]).path, AppPaths.legacyState(env: [:]).path + "/hook.sock"] {
            // Compared as the suffix after the home directory, because the helper builds
            // it from `homeDirectoryForCurrentUser` at runtime.
            let relative = String(expected.dropFirst(home.count + 1))
            expect(
                source.contains(relative),
                "the helper does not look in \(relative) — hooks would land nowhere"
            )
        }
    }
}


/**
 Which physical key is slot 1.

 This used to be a hard gate: nothing painted until a person had named all six colors.
 The rule behind it — never assume slot order — is right, and the gate was the wrong way
 to enforce it, because of one fact that only turned up when the evidence was gathered.

 **Every mapping either implementation has ever produced is identity.** The Node
 version's `calibrate --rows` wrote `identityMapping()` *regardless of what the operator
 reported*, so no other mapping has ever existed on any pad. The gate charged every new
 user a dark board and six dropdowns to write down an answer already known.

 So identity is the default, and what remains guarded is the part that could still lie:
 a record that exists but does not cover a slot.
 */
func runKeyOrderTests() {
    test("a pad with no record lights on the standard order") {
        // The whole point: a fresh install is not a dark board.
        let calibration = Calibration.loadDefault(env: ["OPENBOARD_HOME": "/nonexistent/openboard"])
        expectEqual(calibration.physicalSlot(for: 1), 1)
        expectEqual(calibration.physicalSlot(for: 6), 6)
        expect(calibration.isAssumed, "an un-recorded pad must know it is assuming")
    }

    test("assumed and confirmed are distinguishable") {
        // The UI offers to check the order only while it is a guess, so this is what
        // stops it nagging someone who has already looked — and what stops it staying
        // quiet for someone who has not.
        expect(Calibration.identity.isAssumed)
        let confirmed = Calibration(
            mapping: Calibration.identity.mapping,
            rows: CalibrationCapture.defaultRows,
            recordedAt: Date()
        )
        expect(!confirmed.isAssumed, "a recorded identity is a confirmation, not a guess")
    }

    test("a recorded mapping still wins over the assumption") {
        let json = #"{"mapping":{"1":3,"2":1,"3":2,"4":6,"5":4,"6":5},"recordedAt":"2026-01-01T00:00:00Z"}"#
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-cal-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let calibration = try Harness.require(try Calibration.load(from: url))
        expectEqual(calibration.physicalSlot(for: 1), 3)
        expect(!calibration.isAssumed)
    }

    test("a slot the record does not cover is still refused") {
        // The invariant that survives. Identity is a default for a *missing* record,
        // never a patch over a partial one — silently completing a half-written mapping
        // is exactly the confidently-wrong light the gate existed to prevent.
        let partial = Calibration(mapping: [1: 1, 2: 2])
        expectEqual(partial.physicalSlot(for: 1), 1)
        expect(partial.physicalSlot(for: 5) == nil, "an uncovered slot must not be guessed")
    }

    test("confirming the standard order records it as confirmed") {
        // What the sheet's "Yes, that is the order" button saves. Identity in, identity
        // out — and a timestamp, which is what turns the guess into an answer.
        let record = try CalibrationCapture.record(
            observed: Array(1...BoardLayout.slotCount), now: Date()
        )
        expectEqual(record.physicalSlot(for: 1), 1)
        expectEqual(record.physicalSlot(for: 6), 6)
        expect(!record.isAssumed)
    }
}

/**
 Is this session mid-turn?

 The board has to answer this on restart, and used to guess: `working` settled to
 `idle` because "nothing was happening while the app was closed". True of the app,
 false of the session — Claude Code is a separate process that kept going, so any
 session mid-turn during a relaunch came back saying nothing was happening. Its key
 went from blue to idle white while work continued.

 The transcript is the answer, and these are the shapes it takes.
 */
func runTurnStateTests() {
    // Shapes taken from a real transcript, not invented: an assistant entry always
    // carries a stop reason, and `tool_use` is the overwhelmingly common one.
    let assistant = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}"#
    let waiting = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#
    let user = #"{"type":"user","message":{"role":"user","content":"go"}}"#

    test("a transcript ending on a user entry is mid-turn") {
        // Either a human just typed, or a tool result just came back. Both mean the
        // assistant owes a reply.
        expectEqual(TurnState.isWorking(inTail: "\(assistant)\n\(user)"), true)
        expectEqual(TurnState.isWorking(inTail: user), true)
    }

    test("a transcript ending on a finished assistant entry is not") {
        expectEqual(TurnState.isWorking(inTail: "\(user)\n\(assistant)"), false)
        let stopped = assistant.replacingOccurrences(of: "end_turn", with: "stop_sequence")
        expectEqual(TurnState.isWorking(inTail: "\(user)\n\(stopped)"), false)
    }

    test("waiting on a tool is still working") {
        /*
         The case the first version of this got wrong, and the common one: between
         asking for a tool and the result arriving, the transcript ends on `assistant`.
         Reading only the role called that finished, so a session running a long tool
         call would have come back idle — the exact bug this was written to fix.

         Caught by checking the live transcript rather than these fixtures, which
         agreed with the wrong rule because the same person wrote both.
         */
        expectEqual(TurnState.isWorking(inTail: "\(user)\n\(waiting)"), true)
        expectEqual(TurnState.isWorking(inTail: "\(assistant)\n\(user)\n\(waiting)"), true)
    }

    test("an assistant entry with no stop reason is treated as finished") {
        // Conservative on purpose: claiming a turn is running is the error that leaves
        // a key lit for a session that has stopped.
        let bare = #"{"type":"assistant","message":{"role":"assistant","content":[]}}"#
        expectEqual(TurnState.isWorking(inTail: "\(user)\n\(bare)"), false)
    }

    test("a subagent's turn is not the session's turn") {
        // Sidechain entries interleave into the same file. A subagent still running
        // says nothing about the main thread, which is the same reason subagents never
        // take a key of their own.
        let sidechain = #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"x"}}"#
        expectEqual(TurnState.isWorking(inTail: "\(user)\n\(assistant)\n\(sidechain)"), false)
    }

    test("summaries and unknown entries are not turn boundaries") {
        let summary = #"{"type":"summary","summary":"Fix the parser"}"#
        let future = #"{"type":"something-new"}"#
        expectEqual(TurnState.isWorking(inTail: "\(user)\n\(assistant)\n\(summary)\n\(future)"), false)
    }

    test("no answer is not the same as no") {
        // Nil must stay distinct from false: an unreadable transcript is missing
        // information, and acting on it would be the guess this replaced.
        expect(TurnState.isWorking(inTail: "") == nil)
        expect(TurnState.isWorking(inTail: "not json\n{}\n") == nil)
        expect(TurnState.isWorking(transcriptPath: nil) == nil)
        expect(TurnState.isWorking(transcriptPath: "/nonexistent/x.jsonl") == nil)
    }

    test("a half line at the head of the tail is dropped") {
        // Reading the last 64KB almost always cuts the first line in half. Parsing a
        // fragment cannot distinguish "broken" from "a type we ignore".
        let fragment = #"ssage":{"role":"user"}}"#
        expectEqual(
            TurnState.isWorking(inTail: "\(fragment)\n\(assistant)", isWholeFile: false), false
        )
    }

    test("a restored working session keeps its state when the turn is still running") {
        // The whole point, end to end through the settle rule.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-turn-\(UUID().uuidString).jsonl")
        try Data("\(assistant)\n\(user)\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        expectEqual(RegistryStore.settled(.working, transcriptPath: url.path), .working)

        try Data("\(user)\n\(assistant)\n".utf8).write(to: url)
        expectEqual(RegistryStore.settled(.working, transcriptPath: url.path), .idle)
    }

    test("with no transcript, working still settles rather than claiming a turn") {
        expectEqual(RegistryStore.settled(.working, transcriptPath: nil), .idle)
        // And the states that were always kept are still kept.
        expectEqual(RegistryStore.settled(.done, transcriptPath: nil), .done)
        expectEqual(RegistryStore.settled(.awaiting, transcriptPath: nil), .awaiting)
        expectEqual(RegistryStore.settled(.viewing, transcriptPath: nil), .idle)
    }

    test("this session's own transcript reads as mid-turn") {
        // Live check against the real format, since every fixture above is my idea of
        // what Claude Code writes rather than what it actually writes.
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil
        ), !dirs.isEmpty else {
            skip("no transcripts on this machine")
            return
        }
        var newest: (URL, Date)?
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if newest == nil || date > newest!.1 { newest = (file, date) }
            }
        }
        guard let (file, _) = newest else {
            skip("no transcript files")
            return
        }
        expect(
            TurnState.isWorking(transcriptPath: file.path) != nil,
            "the newest transcript gave no answer — the JSONL shape has changed"
        )
    }
}

/**
 A tool ran, so the session is working.

 `PostToolUse` used to be treated as *only* an attention-clear: it set `working` if the
 session was asking for something and returned otherwise. That made a key stick on the
 wrong color for a whole turn. Once anything moved a working session to `idle` — an
 `idle_prompt` notification, or a relaunch — `PostToolUse` was the only hook firing for
 the rest of that turn, and it did nothing.

 Observed live: `updatedAt` frozen at the last prompt while forty tool calls logged
 "-> working" and changed nothing.
 */
func runToolProgressTests() {
    func registry(state: SessionState) -> SessionRegistry {
        var registry = SessionRegistry()
        _ = registry.claim(sessionID: "s1", cwd: "/tmp", pid: 1, state: state)
        return registry
    }

    test("a tool call moves an idle session back to working") {
        // The bug, exactly. Nothing else fires during a long turn.
        var live = registry(state: .idle)
        live.setState(sessionID: "s1", to: .working)
        expectEqual(live.entry(forSession: "s1")?.state, .working)
    }

    test("a tool call still clears an attention state") {
        // The behaviour the old guard existed for, which must survive the fix: an
        // answered prompt stops asking.
        var live = registry(state: .awaiting)
        expect(live.entry(forSession: "s1")?.state.isAttention == true)
        live.setState(sessionID: "s1", to: .working)
        expectEqual(live.entry(forSession: "s1")?.state, .working)
    }

    test("PostToolUse is a state-bearing event, not only an attention-clear") {
        // The mapping was never the problem — the controller's branch was. Pinned so
        // the mapping cannot quietly become nil and take the fix with it.
        expectEqual(
            EventMapper.state(for: "PostToolUse", notifications: EventMapper.defaultNotifications),
            .working
        )
        expect(EventMapper.clearsAttention.contains("PostToolUse"))
        expect(EventMapper.clearsAttention.contains("PostToolUseFailure"))
    }

    test("an idle_prompt notification is what moved a working session to idle") {
        // Unmapped by default, which is why this only bites someone who has mapped it.
        // Kept as a test because it is half the reproduction: without it, the stuck
        // key needs a relaunch to start.
        expect(EventMapper.defaultNotifications["idle_prompt"] == nil)
        expectEqual(
            EventMapper.state(
                for: "Notification", matcher: "idle_prompt",
                notifications: ["idle_prompt": .idle]
            ),
            .idle
        )
    }
}

/**
 Holding a color until it means something else.

 Both timers were the same mistake in different clothes: a duration, in seconds, for a
 thing whose real answer is an event. Green already waits for you to come back; orange
 now waits for the prompt to be answered.
 */
func runHoldTests2() {
    test("attention is held by default") {
        expect(Preferences.default.holdAttention)
    }

    test("an old document's timeout is read as the decision it encoded") {
        // Only a value that differs from the old shipped default is a decision. Almost
        // every existing file says 900 because that is what was written on first
        // launch — migrating those would hand the whole installed base the opposite of
        // the new behaviour on the strength of a number nobody typed.
        expectEqual(Preferences.merging(["attentionTimeoutSeconds": 900]).holdAttention, true)
        expectEqual(Preferences.merging(["attentionTimeoutSeconds": 0]).holdAttention, true)
        // Deliberately shortened, which is a request to keep expiring.
        expectEqual(Preferences.merging(["attentionTimeoutSeconds": 120]).holdAttention, false)
        // An explicit new setting wins over the legacy one, whatever it says.
        expectEqual(
            Preferences.merging(["attentionTimeoutSeconds": 900, "holdAttention": true])
                .holdAttention,
            true
        )
    }

    test("the fixed net is the timeout that used to be configurable") {
        // 15 minutes, unchanged — it just stopped being a slider, because nobody can
        // answer "how long should I wait for something that should not happen?".
        expectEqual(SessionRegistry.attentionTimeout, 900)
    }
}

/**
 The ring while dictating.

 Voice cannot be *detected*: tapping space starts or stops dictation depending on what
 is already happening, and nothing reports back. So the app tracks its own belief, and
 the tests that matter are the ones about the belief going wrong.
 */
func runVoiceRingTests() {
    test("the spin is on by default and round-trips") {
        expect(Preferences.default.ambient.voiceRainbow)
        expectEqual(
            Preferences.merging(["ambient": ["voiceRainbow": false]]).ambient.voiceRainbow,
            false
        )
        var prefs = Preferences.default
        prefs.ambient.voiceRainbow = false
        expectEqual(Preferences.merging(prefs.json).ambient.voiceRainbow, false)
    }

    test("a document that says nothing keeps the other ambient settings") {
        // The field is new, so every existing config.json omits it — it must merge in
        // without disturbing the modes and laps already there.
        let prefs = Preferences.merging(["ambient": ["mode": "fixed", "completionLap": false]])
        expect(prefs.ambient.voiceRainbow)
        expectEqual(prefs.ambient.mode, "fixed")
        expectEqual(prefs.ambient.completionLap, false)
    }

    test("rainbow is a real effect the firmware knows") {
        // The ring is written as a lighting side, not a show, so it holds until the
        // belief ends rather than running for a fixed duration.
        expectEqual(LEDEffect.rainbow.deviceCode, 3)
        expect(LEDEffect.rainbow.isAnimated)
        expectEqual(CodexProtocol.Effect(rawValue: LEDEffect.rainbow.deviceCode), .rainbow)
    }
}

/**
 The agent the board is watching, described in one place.

 The Agents pane renders `Harness`, which means the pane can now be wrong in a new way:
 by describing a harness the app does not implement, or by describing this one
 inaccurately. Both are the failure this project keeps finding — a screen that explains
 behaviour nothing produces — so the description is checked against the code it claims
 to describe.

 Qualified as `OpenBoardKit.Harness` throughout: this test target has a `Harness` of its
 own — the thing that runs these assertions — and an unqualified name resolves to that
 one, with an error that names a missing member rather than the collision.
 */
func runHarnessTests() {
    test("every listed harness is wired, or is not listed") {
        // Three now, and the bar did not move: a harness appears here only if its
        // events reach the board. What differs between them is how they are *set up*,
        // and each says which.
        expect(OpenBoardKit.Harness.all.count >= 3)
        expect(
            OpenBoardKit.Harness.all.allSatisfy(\.isSupported),
            "an unsupported harness is listed"
        )
        expectEqual(
            Set(OpenBoardKit.Harness.all.map(\.id)),
            ["claude-code", "hermes", "pi"]
        )
    }

    test("a harness OpenBoard cannot configure hands over the exact text") {
        // The alternative was editing somebody's YAML by machine, or writing a
        // TypeScript module into their extension directory. Both are the app taking a
        // liberty with a file it does not own.
        for harness in OpenBoardKit.Harness.all {
            switch harness.setup {
            case .automatic:
                expectEqual(harness.id, "claude-code", "only Claude Code's file is JSON we merge")
            case let .manual(path, snippet):
                expect(!path.isEmpty, "\(harness.name) says paste it, but not where")
                expect(
                    snippet.contains("OPENBOARD"),
                    "\(harness.name)'s snippet has no placeholder for the helper path"
                )
                // Both parts, not the joined string: the YAML form writes
                // `--harness hermes` while the TypeScript form passes
                // `["--harness", "pi"]`, and only one of those contains the other.
                expect(
                    snippet.contains("--harness") && snippet.contains(harness.id),
                    "\(harness.name)'s snippet does not identify itself, so eligibility "
                        + "would refuse every event it sends"
                )
            }
        }
    }

    test("every harness event maps to a state") {
        // The pane draws one row per event against the state it produces. An event
        // listed here that the mapper ignores is a row promising a color that never
        // arrives — and for these two there is no Notification exception.
        for harness in OpenBoardKit.Harness.all where harness.id != "claude-code" {
            for event in harness.events {
                expect(
                    EventMapper.state(for: event.name) != nil,
                    "\(harness.name) lists \(event.name), which maps to nothing"
                )
            }
        }
    }

    test("a harness names the states it can never reach") {
        // Hermes has no completion event and Pi no approval event. Those are colors
        // that will never appear on the board, which is not a footnote.
        let produced = { (harness: OpenBoardKit.Harness) -> Set<SessionState> in
            Set(harness.events.compactMap { EventMapper.state(for: $0.name) })
        }
        expect(
            !produced(.hermes).contains(.done),
            "Hermes gained a completion event — its limitation should go"
        )
        expect(!OpenBoardKit.Harness.hermes.limitations.isEmpty, "and it must say so")

        expect(
            !produced(.pi).contains(.awaiting),
            "Pi gained an approval event — its limitation should go"
        )
        expect(!OpenBoardKit.Harness.pi.limitations.isEmpty, "and it must say so")

        // Claude Code reaches every state, which is why it has nothing to declare.
        expect(OpenBoardKit.Harness.claudeCode.limitations.isEmpty)
    }

    test("another harness's events are admitted, and still fail closed") {
        // Eligibility is keyed on CLAUDE_CODE_ENTRYPOINT, which these never set. The
        // hook command names the harness instead — and an unknown name is still refused.
        let payload = Eligibility.Payload(sessionID: "s1")
        expect(Eligibility.evaluate(env: [:], payload: payload, harness: "hermes").eligible)
        expect(Eligibility.evaluate(env: [:], payload: payload, harness: "pi").eligible)
        expect(!Eligibility.evaluate(env: [:], payload: payload, harness: "made-up").eligible)
        // A session id is still required, whoever sent it.
        expect(
            !Eligibility.evaluate(env: [:], payload: Eligibility.Payload(), harness: "pi").eligible
        )
        // And a subagent is a subagent regardless of harness.
        expect(
            !Eligibility.evaluate(
                env: [:],
                payload: Eligibility.Payload(sessionID: "s1", agentType: "Explore"),
                harness: "hermes"
            ).eligible
        )
    }

    test("the described events are the events actually wired") {
        // Two lists that must agree is one list and a bug waiting. The hook audit owns
        // it, because the audit is what writes the file.
        expectEqual(OpenBoardKit.Harness.claudeCode.events.count, HookInstall.events.count)
        for (described, wired) in zip(OpenBoardKit.Harness.claudeCode.events, HookInstall.events) {
            expectEqual(described.name, wired.name)
            expectEqual(described.matcher, wired.matcher)
        }
    }

    test("every described event actually maps to something") {
        // A row on screen for an event the mapper ignores would be a promise the board
        // does not keep. Notification is the exception: it maps per subtype.
        for event in OpenBoardKit.Harness.claudeCode.events where event.name != "Notification" {
            expect(
                EventMapper.state(for: event.name) != nil,
                "\(event.name) is listed but maps to no state"
            )
        }
        expect(
            EventMapper.state(for: "Notification") == nil,
            "Notification without a subtype must stay unmapped"
        )
    }

    test("the described entry points are the ones eligibility allows") {
        expectEqual(
            Set(OpenBoardKit.Harness.claudeCode.entrypoints),
            Eligibility.defaultEntrypoints,
            "the pane lists surfaces the allowlist does not admit"
        )
    }

    test("the surfaces it refuses are refused for stated reasons") {
        let refused = OpenBoardKit.Harness.claudeCode.surfaces.filter { $0.unsupported != nil }
        expect(refused.count >= 3, "subagents, SDK clients and remote are all refused")
        for surface in refused {
            expect(
                !(surface.unsupported ?? "").isEmpty,
                "\(surface.name) is marked unsupported with no reason"
            )
        }
        // And the two that work say how a key press reaches them, which is the part
        // nobody can discover by looking at the pad.
        for surface in OpenBoardKit.Harness.claudeCode.surfaces where surface.unsupported == nil {
            expect(!surface.jump.isEmpty, "\(surface.name) does not say what its key does")
            expect(!surface.detection.isEmpty, "\(surface.name) does not say how it is found")
        }
    }
}

/**
 Which agents are actually here.

 The pane used to show Claude Code as connected whether or not it existed, because
 "connected" meant "OpenBoard supports this" — a claim about the app rather than about
 the machine, and true regardless. Every row is now a probe that ran.
 */
func runAgentDetectionTests() {
    func scratch() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-agents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    test("an empty machine has nothing installed") {
        // The case that matters: absent must read as absent, not as "we did not look".
        let home = scratch()
        let applications = scratch()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: applications)
        }
        for agent in HarnessDetector.known {
            expect(
                !HarnessDetector.isInstalled(
                    agent, home: home, applications: applications, env: ["PATH": ""], extraPaths: []
                ),
                "\(agent.name) reported installed on an empty machine"
            )
        }
    }

    test("a config directory is enough") {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try? FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true
        )
        let claude = try Harness.require(HarnessDetector.known.first { $0.id == "claude" })
        expect(HarnessDetector.isInstalled(claude, home: home, applications: home, env: ["PATH": ""], extraPaths: []))

        let hermes = try Harness.require(HarnessDetector.known.first { $0.id == "hermes" })
        expect(
            !HarnessDetector.isInstalled(hermes, home: home, applications: home, env: ["PATH": ""], extraPaths: []),
            "one agent's directory made another look installed"
        )
    }

    test("a command on PATH is enough, and it must be executable") {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let hermes = try Harness.require(HarnessDetector.known.first { $0.id == "hermes" })

        // A file with the right name that cannot run is not an installation.
        let command = bin.appendingPathComponent("hermes")
        try Data("not a binary".utf8).write(to: command)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: command.path)
        expect(!HarnessDetector.isInstalled(hermes, home: home, applications: home, env: ["PATH": bin.path], extraPaths: []))

        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        expect(HarnessDetector.isInstalled(hermes, home: home, applications: home, env: ["PATH": bin.path], extraPaths: []))
    }

    test("every listed agent is answerable") {
        // The entry criterion: a provider with nothing to look for would sit
        // permanently grey, reading as absent while meaning unknown.
        for agent in HarnessDetector.known {
            expect(
                !(agent.homePaths.isEmpty && agent.bundles.isEmpty && agent.commands.isEmpty),
                "\(agent.name) is listed with nothing to probe"
            )
        }
    }

    test("every harness has an agent that can find it") {
        // Otherwise a harness could be permanently "not found" while working perfectly.
        for harness in OpenBoardKit.Harness.all {
            expect(
                HarnessDetector.known.contains { $0.harnessID == harness.id },
                "\(harness.name) has no detector, so it can never show as connected"
            )
        }
    }

    test("this machine finds Claude Code") {
        // A live check: the fixtures above are my idea of an installation, and this is
        // the machine's.
        let claude = try Harness.require(HarnessDetector.known.first { $0.id == "claude" })
        expect(
            HarnessDetector.isInstalled(claude),
            "Claude Code is running this test and was not detected"
        )
    }
}

/**
 A harness that has never reported.

 "Connected" is about now; this is the weaker and more useful question for a settings
 window — has this ever worked here? The pane's tables describe what a harness *does*,
 and one that has never sent an event has done nothing to describe.
 */
func runHarnessSeenTests() {
    test("nothing has been seen by default") {
        expect(Preferences.default.harnessesSeen.isEmpty)
    }

    test("an older document's list is merged, not replaced") {
        // A config written before a harness existed knows about fewer of them.
        // Replacing would put a working harness back into its empty state.
        var prefs = Preferences.default
        prefs.harnessesSeen = ["claude-code"]
        let merged = Preferences.merging(["harnessesSeen": ["hermes"]], over: prefs)
        expectEqual(merged.harnessesSeen, ["claude-code", "hermes"])
    }

    test("it round-trips, because forgetting it resets the pane") {
        var prefs = Preferences.default
        prefs.harnessesSeen = ["claude-code", "pi"]
        expectEqual(Preferences.merging(prefs.json).harnessesSeen, ["claude-code", "pi"])
    }

    test("an event names its harness, and Claude Code is the default") {
        // The helper omits `--harness` for Claude Code, so every settings.json written
        // before harnesses existed keeps working — and its events still have to count
        // as Claude Code having reported.
        let claude = HookServer.Event(raw: ["hook_event_name": "Stop", "session_id": "s"])
        expect(claude.harness == nil, "an unmarked event must not claim a harness")

        let hermes = HookServer.Event(
            raw: ["hook_event_name": "post_tool_call", "session_id": "s", "harness": "hermes"]
        )
        expectEqual(hermes.harness, "hermes")
    }
}
