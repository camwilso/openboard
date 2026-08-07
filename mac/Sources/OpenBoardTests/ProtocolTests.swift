import Foundation
import OpenBoardKit

/**
 The wire format, checked against the Node implementation.

 This protocol is undocumented and reverse-engineered. There is no spec to consult and
 no error when it is wrong — a malformed report is silently dropped by the firmware
 and the key simply does not light. So the framing is pinned by value here, and the
 fixtures are what `lib/hid.cjs` actually produces.
 */
func runProtocolTests() {
    test("a report is 64 bytes with a 3-byte header") {
        let reports = CodexProtocol.frame(Data("hello".utf8))
        expectEqual(reports.count, 1)
        let report = reports[0]
        expectEqual(report.count, 64, "the firmware expects exactly 64 bytes")
        expectEqual(report[0], 0x06, "report id")
        expectEqual(report[1], 0x02, "RPC channel")
        expectEqual(report[2], 5, "chunk length")
        expectEqual(String(data: report.subdata(in: 3..<8), encoding: .utf8), "hello")
        // The tail must be zero, not stale memory.
        expect(report.subdata(in: 8..<64).allSatisfy { $0 == 0 }, "padding must be zeroed")
    }

    test("a long message is chunked at 61 bytes, not 64") {
        // Three header bytes come out of the 64, and getting this off by even one
        // corrupts every message that crosses a chunk boundary.
        let payload = Data(repeating: 0x41, count: 130)
        let reports = CodexProtocol.frame(payload)
        expectEqual(reports.count, 3, "130 bytes = 61 + 61 + 8")
        expectEqual(reports[0][2], 61)
        expectEqual(reports[1][2], 61)
        expectEqual(reports[2][2], 8)
        for report in reports { expectEqual(report.count, 64) }

        // Reassembled, it must be the original.
        var joined = Data()
        for report in reports {
            joined.append(CodexProtocol.payload(ofReport: report) ?? Data())
        }
        expectEqual(joined, payload)
    }

    test("an exact multiple of the chunk size does not emit a trailing empty report") {
        let reports = CodexProtocol.frame(Data(repeating: 0x41, count: 61))
        expectEqual(reports.count, 1)
        expectEqual(reports[0][2], 61)
    }

    test("an empty payload still produces one report") {
        // The loop is repeat/while for this: a `while` would emit nothing at all.
        let reports = CodexProtocol.frame(Data())
        expectEqual(reports.count, 1)
        expectEqual(reports[0][2], 0)
    }

    test("a thread state carries the firmware's own field names") {
        // These are the firmware's keys, not abbreviations we chose. Renaming any of
        // them makes the call a no-op with no error.
        let state = try Harness.require(
            try? CodexProtocol.ThreadState(
                physicalSlot: 3,
                color: RGB(0xFF6A00),
                brightness: 0.95,
                effect: .breath,
                speed: 0.75
            )
        )
        let json = try Harness.require(
            try? JSONEncoder().encode(state)
        )
        let object = try Harness.require(
            try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        expectEqual(object["id"] as? Int, 2, "the firmware is zero-based; callers are not")
        expectEqual(object["c"] as? Int, 0xFF6A00)
        expectEqual(object["e"] as? Int, 4, "breath")
        expect(object["b"] != nil && object["s"] != nil, "brightness and speed")
        expectEqual(object["sk"] as? Int, 0)
        expectEqual(object["sa"] as? Int, 0)
    }

    test("slots outside 1…6 are refused rather than wrapped") {
        for slot in [0, 7, -1, 99] {
            var threw = false
            do { _ = try CodexProtocol.ThreadState(
                physicalSlot: slot, color: RGB(0), brightness: 0, effect: .off, speed: 0
            ) } catch { threw = true }
            expect(threw, "slot \(slot) must be refused")
        }
    }

    test("brightness and speed are clamped, never sent out of range") {
        let state = try Harness.require(
            try? CodexProtocol.ThreadState(
                physicalSlot: 1, color: RGB(0), brightness: 5, effect: .solid, speed: -3
            )
        )
        expectEqual(state.b, 1)
        expectEqual(state.s, 0)
    }

    test("effect codes are the firmware's, and spatial ones are flagged") {
        expectEqual(CodexProtocol.Effect.off.rawValue, 0)
        expectEqual(CodexProtocol.Effect.solid.rawValue, 1)
        expectEqual(CodexProtocol.Effect.snake.rawValue, 2)
        expectEqual(CodexProtocol.Effect.rainbow.rawValue, 3)
        expectEqual(CodexProtocol.Effect.breath.rawValue, 4)
        expectEqual(CodexProtocol.Effect.gradient.rawValue, 5)
        expectEqual(CodexProtocol.Effect.shallowBreath.rawValue, 6)
        // These render a single key dark; they only mean anything on the ring.
        expect(CodexProtocol.Effect.snake.isSpatial)
        expect(CodexProtocol.Effect.gradient.isSpatial)
        expect(!CodexProtocol.Effect.breath.isSpatial)
    }

    test("an RPC request has method, params and id") {
        let reports = try Harness.require(
            try? CodexProtocol.request(
                method: .rgbConfig,
                params: CodexProtocol.LightingConfig(keys: .off, ambient: .off),
                id: 42
            )
        )
        var joined = Data()
        for report in reports { joined.append(CodexProtocol.payload(ofReport: report) ?? Data()) }
        let text = String(data: joined, encoding: .utf8) ?? ""
        expect(text.contains("\"method\":\"v.oai.rgbcfg\""), "got: \(text)")
        expect(text.contains("\"id\":42"))
        expect(text.contains("\"keys\""), "rgbcfg needs a complete config, both sides")
        expect(text.contains("\"ambient\""))
    }

    test("a lighting side carries all five fields the firmware wants") {
        // `m` was missing at first. The device acknowledged the config with ok:1 and
        // then appeared not to act on it — an acknowledgement means the message
        // arrived, not that it was understood. Since `keys: off` is what suppresses
        // the layer backlight that otherwise buries per-key status, a silently
        // ignored config means nothing visible lights at all.
        let json = try Harness.require(try? JSONEncoder().encode(CodexProtocol.LightingSide.off))
        let object = try Harness.require(
            try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        expectEqual(Set(object.keys), Set(["e", "b", "s", "m", "c"]), "upstream sends five")
        expectEqual(object["m"] as? Int, 0, "mode is always 0 upstream")
    }

    test("a report on another channel is ignored")  {
        // Our own acknowledgements and anything else on the interface must not be
        // mistaken for RPC payload.
        var report = Data(count: 64)
        report[0] = 0x06
        report[1] = 0x09      // not the RPC channel
        report[2] = 4
        expect(CodexProtocol.payload(ofReport: report) == nil)
    }

    test("a truncated report is ignored rather than read past its end") {
        var report = Data(count: 10)
        report[0] = 0x06
        report[1] = 0x02
        report[2] = 200       // claims more than the report holds
        expect(CodexProtocol.payload(ofReport: report) == nil)
        expect(CodexProtocol.payload(ofReport: Data([0x06])) == nil)
        expect(CodexProtocol.payload(ofReport: Data()) == nil)
    }

    test("key presses parse off the broadcast channel") {
        // This is what lets the pad stay on Layer 1 with Codex's locked keycodes and
        // still mean something to us.
        let down = try Harness.require(
            KeyEvent.parse(Data(#"{"m":"v.oai.hid","p":{"k":"AG00","act":1}}"#.utf8))
        )
        expectEqual(down.key, "AG00")
        expectEqual(down.action, .down)

        let up = try Harness.require(
            KeyEvent.parse(Data(#"{"m":"v.oai.hid","p":{"k":"ACT08","act":0}}"#.utf8))
        )
        expectEqual(up.action, .up)

        // An encoder tick has no matching release and must never be debounced.
        let tick = try Harness.require(
            KeyEvent.parse(Data(#"{"m":"v.oai.hid","p":{"k":"ENC_CW","act":2}}"#.utf8))
        )
        expectEqual(tick.key, "ENC_CW")
        expectEqual(tick.action, .tick)
    }

    test("our own acknowledgements are not mistaken for key presses") {
        // Replies carry `result`, not `m`. Confusing the two would fire an action for
        // every LED write we make.
        expect(KeyEvent.parse(Data(#"{"result":{"ok":1},"id":492,"method":"v.oai.thstatus"}"#.utf8)) == nil)
        expect(KeyEvent.parse(Data(#"{"m":"something.else","p":{"k":"AG00","act":1}}"#.utf8)) == nil)
        expect(KeyEvent.parse(Data("not json".utf8)) == nil)
        expect(KeyEvent.parse(Data(#"{"m":"v.oai.hid","p":{"k":"AG00","act":9}}"#.utf8)) == nil)
    }

    test("the write lock is upstream's path, not ours") {
        // Both tools must contend for the SAME mutex: an RPC message spans several
        // reports, and two writers taking turns mid-message interleave into garbage.
        // A project-specific path would look tidier and make the tools invisible to
        // each other, which is the whole failure this prevents.
        let path = HIDWriteLock.defaultLockPath().path
        expect(path.contains("codex-micro-light-"), "must match upstream: \(path)")
        expect(path.hasSuffix("hid-write.lock"), path)
        expect(!path.lowercased().contains("openboard"), "must NOT be namespaced to us: \(path)")
    }

    test("a report id already in the body is not prepended twice") {
        // The bug this prevents: IOKit's docs read as though the id is stripped and
        // returned separately, so it was prepended — shifting every byte by one and
        // silently corrupting every message. Writes still succeeded, so the only
        // symptom was the device's acknowledgements never arriving.
        // Shaped like a real captured report, whose header read `06 02 2C` — the
        // length byte must match the payload actually present or this is a truncation
        // test by accident.
        let body = Data(#"{"m":"v.oai.hid"}"#.utf8)
        let captured = Data([0x06, 0x02, UInt8(body.count)]) + body
        let normalised = CodexProtocol.normaliseReport(captured, reportID: 0x06)
        expectEqual(normalised, captured, "already framed — must be left alone")
        expect(CodexProtocol.payload(ofReport: normalised) != nil, "must still parse")
    }

    test("a report id missing from the body is restored") {
        // The other shape, handled so this is not rediscovered on a firmware update.
        let stripped = Data([0x02, 0x04]) + Data("test".utf8)
        let normalised = CodexProtocol.normaliseReport(stripped, reportID: 0x06)
        expectEqual(normalised[normalised.startIndex], 0x06)
        expectEqual(normalised.count, stripped.count + 1)
        expectEqual(
            String(data: CodexProtocol.payload(ofReport: normalised) ?? Data(), encoding: .utf8),
            "test"
        )
    }

    test("the device identity matches the hardware") {
        expectEqual(CodexProtocol.vendorID, 0x303A)
        expectEqual(CodexProtocol.productID, 0x8360)
        // Matching on vendor+product alone finds four interfaces; only the
        // vendor-defined one speaks the RPC, and writing to the others silently
        // does nothing.
        expectEqual(CodexProtocol.usagePage, 0xFF00)
    }
}

/**
 The write lock, under concurrency.

 Written after it deadlocked the machine. The descriptor was actor state mutated
 across an `await`; actors are reentrant, so a second caller entering during the
 first's suspension overwrote it, and the first descriptor was leaked still holding
 its flock. Nothing could take the lock again — not OpenBoard, not the Node CLI,
 which timed out after 20s waiting for a writer that was never going to let go.

 A single-threaded test passes happily against that bug, which is why this one is
 concurrent.
 */
func runLockTests() async {
    test("the lock survives overlapping holders") {
        // Ten concurrent acquisitions. With the descriptor leak this hangs at the
        // second and never recovers.
        let done = DispatchSemaphore(value: 0)
        Task {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        do {
                            return try await HIDWriteLock.shared.withLock(timeout: 5) {
                                // Suspend while holding it: this is the window where a
                                // reentrant caller used to clobber the descriptor.
                                try? await Task.sleep(for: .milliseconds(5))
                                return true
                            }
                        } catch {
                            return false
                        }
                    }
                }
                var succeeded = 0
                for await ok in group where ok { succeeded += 1 }
                expectEqual(succeeded, 10, "every caller should get the lock in turn")
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 30) == .timedOut {
            expect(false, "the lock deadlocked — the descriptor is leaking again")
        }
    }

    test("the lock is released even when the body throws") {
        struct Boom: Error {}
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                _ = try await HIDWriteLock.shared.withLock(timeout: 2) { throw Boom() }
            } catch {}
            // If the failing call kept the lock, this one cannot get it.
            do {
                let ok = try await HIDWriteLock.shared.withLock(timeout: 3) { true }
                expect(ok, "the lock was still held after a throwing body")
            } catch {
                expect(false, "the lock was not released after a throwing body")
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 20) == .timedOut {
            expect(false, "timed out — the lock was not released on throw")
        }
    }
}

/**
 The write shape, pinned.

 Every write succeeded and the pad never changed — for hours. The payload was
 byte-identical to the implementation that works, so the fault was not in what was
 sent but in *how*.
 */
func runWriteShapeTests() {
    test("a framed report keeps its id byte in the buffer") {
        // hidapi — which node-hid uses, and which drives this device correctly — only
        // strips the leading byte when the report id is 0x00. For a numbered report
        // like this one it passes the full buffer *including* the id, and sets the id
        // argument too. Stripping it produced 63-byte writes that were accepted with
        // ok:1 and did nothing at all.
        let reports = CodexProtocol.frame(Data("x".utf8))
        let report = reports[0]
        expectEqual(report.count, 64, "the whole buffer goes to the device")
        expectEqual(report[0], CodexProtocol.reportID, "id stays in the payload")
        expect(CodexProtocol.reportID != 0, "the 0x00 case would behave differently")
    }

    test("the wire format is symmetric") {
        // Reports arrive with the id still in the body, and go out the same way.
        // Discovering that asymmetry the hard way once was enough.
        let outgoing = CodexProtocol.frame(Data("hello".utf8))[0]
        let echoed = CodexProtocol.normaliseReport(outgoing, reportID: CodexProtocol.reportID)
        expectEqual(echoed, outgoing, "what we send is shaped like what we receive")
        expectEqual(
            String(data: CodexProtocol.payload(ofReport: echoed) ?? Data(), encoding: .utf8),
            "hello"
        )
    }

    test("field order matches upstream, since the firmware cares") {
        // Not merely equivalent JSON: the request is assembled by hand because
        // JSONEncoder's ordering cannot be controlled, and this parser is not one to
        // make assumptions about.
        let state = try Harness.require(try? CodexProtocol.ThreadState(
            physicalSlot: 1, color: RGB(0x0C47E9), brightness: 0.75, effect: .breath, speed: 0.45
        ))
        expectEqual(
            state.json,
            #"{"id":0,"c":804841,"b":0.75,"e":4,"s":0.45,"sk":0,"sa":0}"#
        )
        expectEqual(
            CodexProtocol.LightingSide.off.json,
            #"{"e":0,"b":0,"s":0,"m":0,"c":0}"#
        )
        let request = CodexProtocol.requestJSON(method: .threadStatus, params: "[]", id: 123)
        expectEqual(
            String(data: request, encoding: .utf8),
            #"{"method":"v.oai.thstatus","params":[],"id":123}"#
        )
    }

    test("numbers are formatted the way JSON.stringify does") {
        // Integral values without a decimal point, matching the bytes known to work.
        expectEqual(CodexProtocol.number(1), "1")
        expectEqual(CodexProtocol.number(0), "0")
        expectEqual(CodexProtocol.number(0.75), "0.75")
        expectEqual(CodexProtocol.number(0.45), "0.45")
        expectEqual(CodexProtocol.number(0.5), "0.5")
    }
}

/**
 The shows, whose timings *are* the design.

 Each of these numbers was arrived at by watching the ring and adjusting. A rewrite is
 exactly where they get rounded off, so they are pinned.
 */
func runShowTests() {
    test("every show the Node version had came across") {
        let names = Shows.all.map(\.name).sorted()
        expectEqual(names, [
            "breathe", "chase", "completion", "error", "heartbeat",
            "police", "question", "rainbow", "strobe", "sunrise",
        ])
    }

    test("three shows fire by themselves; the rest are toys") {
        let auto = Shows.all.filter(\.auto).map(\.name).sorted()
        expectEqual(auto, ["completion", "error", "question"])
    }

    test("durations match the Node implementation") {
        // Off-by-a-few is fine; off by a lot means a step was dropped or a count changed.
        let expected: [String: Int] = [
            "completion": 5050, "error": 2970, "question": 3865, "rainbow": 6000,
            "police": 3120, "chase": 13000, "sunrise": 6200, "heartbeat": 4280,
            "strobe": 1260, "breathe": 8000,
        ]
        for show in Shows.all {
            guard let want = expected[show.name] else { continue }
            let got = show.steps.reduce(0) { $0 + $1.milliseconds }
            expect(abs(got - want) <= 60, "\(show.name): \(got)ms vs \(want)ms")
        }
    }

    test("the snake laps slowly, on purpose") {
        // Speed decides how many laps fit in the window. At 0.6 the snake lapped
        // several times and read as a strobe rather than one smooth pass.
        let completion = try Harness.require(Shows.show(named: "completion"))
        let lap = try Harness.require(completion.steps.first)
        expectEqual(lap.side.e, CodexProtocol.Effect.snake.rawValue)
        expect(lap.side.s <= 0.2, "speed \(lap.side.s) is too fast to read as one lap")
        expectEqual(lap.milliseconds, 4200)
    }

    test("the fade is many short steps, not few long ones") {
        // Steppiness comes from step *duration*: at 320ms each you see the levels.
        let completion = try Harness.require(Shows.show(named: "completion"))
        let fade = completion.steps.dropFirst()
        expect(fade.count >= 6, "a fade needs enough steps to read as continuous")
        for step in fade { expect(step.milliseconds <= 90, "\(step.milliseconds)ms is visibly steppy") }
        // And it ends dark rather than merely dim.
        expectEqual(completion.steps.last?.side.e, CodexProtocol.Effect.off.rawValue)
    }

    test("error differs in shape, not only in hue") {
        // A failure must not be mistakable for a completion out of the corner of an eye.
        let error = try Harness.require(Shows.show(named: "error"))
        let completion = try Harness.require(Shows.show(named: "completion"))
        expect(error.steps.count > completion.steps.count / 2, "a heartbeat has many beats")
        expect(
            error.steps.allSatisfy { $0.side.e != CodexProtocol.Effect.snake.rawValue },
            "error must not be a lap"
        )
    }
}
