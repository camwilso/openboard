import Foundation
import OpenBoardKit

func runPortFidelityTests() {

/**
 These tests exist to catch *drift from the Node implementation*, not to check that
 Swift works. The port is only worth anything if the rules came across exactly, and
 the rules that matter here were each learned the hard way — the surface allowlist
 stops a fan-out eating all six keys, the wide-cap collapse stops one press firing
 two actions, and the hardware colors are what the LED actually emits.
 */

// MARK: - State vocabulary

test("LED colors are the hardware values, not a palette") {
    // If any of these change, the window and the pad disagree about what a state
    // looks like — and the window is the one that is wrong.
    expect(SessionState.idle.defaultAppearance.color.hex == "#2E4A6B")
    expect(SessionState.viewing.defaultAppearance.color.hex == "#2E4A6B")
    expect(SessionState.working.defaultAppearance.color.hex == "#0C47E9")
    expect(SessionState.awaiting.defaultAppearance.color.hex == "#FF6A00")
    expect(SessionState.stalled.defaultAppearance.color.hex == "#FF6A00")
    expect(SessionState.done.defaultAppearance.color.hex == "#09B821")
    expect(SessionState.error.defaultAppearance.color.hex == "#D41145")
    expect(SessionState.ended.defaultAppearance.effect == .off)
}

test("orange belongs to awaiting and stalled alone") {
    // The one color that means "act now". Anything else wearing it makes the
    // signal that this whole product exists to deliver unreadable.
    let orange = RGB(0xFF6A00)
    let wearers = SessionState.allCases.filter { $0.defaultAppearance.color == orange }
    expect(Set(wearers) == Set([.awaiting, .stalled]))
    for state in wearers { expect(state.isAttention) }
}

test("idle is not near-white") {
    // The pad's resting state is white, so a white key reads as unlit — and most
    // sessions sit at idle most of the time. The live config had drifted into
    // exactly this before.
    expect(!SessionState.idle.defaultAppearance.color.isNearWhite)
    expect(RGB(0xFFFFFF).isNearWhite)
    expect(RGB(0xF0F0F0).isNearWhite)
    expect(!RGB(0x2E4A6B).isNearWhite)
}

test("effect codes match the firmware") {
    // Measured against the firmware. Getting these wrong makes a key animate as something
    // else entirely, with no error anywhere.
    expect(LEDEffect.off.deviceCode == 0)
    expect(LEDEffect.solid.deviceCode == 1)
    expect(LEDEffect.rainbow.deviceCode == 3)
    expect(LEDEffect.breath.deviceCode == 4)
    expect(LEDEffect.shallowBreath.deviceCode == 6)
}

test("hex round-trips both ways") {
    expect(RGB(hex: "#FF6A00")?.value == 0xFF6A00)
    expect(RGB(hex: "ff6a00")?.value == 0xFF6A00)
    expect(RGB(hex: "#GGGGGG") == nil)
    expect(RGB(hex: "#FFF") == nil)
    expect(RGB(0x0C47E9).hex == "#0C47E9")
}

// MARK: - Eligibility

let cliEnv = ["CLAUDE_CODE_ENTRYPOINT": "cli"]
let payload = Eligibility.Payload(sessionID: "abc-123")

test("an ordinary CLI session gets a key") {
    let verdict = Eligibility.evaluate(env: cliEnv, payload: payload)
    expect(verdict.eligible)
    expect(verdict.reason == .ok)
}

test("the allowlist is fail-closed") {
    // An unrecognised surface gets nothing. Not a warning, not a key — nothing.
    for entrypoint in ["cowork", "sdk", "web", "", "CLI"] {
        let verdict = Eligibility.evaluate(
            env: ["CLAUDE_CODE_ENTRYPOINT": entrypoint],
            payload: payload
        )
        expect(!verdict.eligible, "\(entrypoint) must not get a key by default")
    }
    expect(Eligibility.evaluate(env: [:], payload: payload).reason == .unknownEntrypoint)
    expect(Eligibility.defaultEntrypoints == ["cli", "claude-vscode"])
}

test("subagents never take a key") {
    // A single parallel fan-out would otherwise exhaust all six at once.
    expect(
        !Eligibility.evaluate(
            env: cliEnv,
            payload: Eligibility.Payload(sessionID: "a", agentType: "Explore")
        ).eligible
    )
    expect(
        !Eligibility.evaluate(
            env: cliEnv,
            payload: Eligibility.Payload(sessionID: "a", agentID: "x")
        ).eligible
    )
    expect(
        !Eligibility.evaluate(
            env: cliEnv.merging(["CLAUDE_AGENT_ID": "x"]) { a, _ in a },
            payload: payload
        ).eligible
    )
}

test("embedded SDK clients never take a key") {
    // Ten of these were observed running under an unrelated VS Code extension, all
    // firing user-level hooks. They would have taken every key before a human
    // session appeared.
    let verdict = Eligibility.evaluate(
        env: cliEnv.merging(["CLAUDE_AGENT_SDK_CLIENT_APP": "agentforce-vibes"]) { a, _ in a },
        payload: payload
    )
    expect(!verdict.eligible)
    expect(verdict.reason == .embeddedSDK)
    expect(verdict.detail.contains("agentforce-vibes"))
}

test("a session with no id is refused") {
    expect(Eligibility.evaluate(env: cliEnv, payload: Eligibility.Payload()).reason == .noSessionID)
}

test("the environment override wins, but cannot lock everything out") {
    let allowed = Eligibility.allowedEntrypoints(env: ["OPENBOARD_ENTRYPOINTS": "cli,cowork"])
    expect(allowed == ["cli", "cowork"])

    // An override that resolves to nothing falls back rather than blacking out the
    // whole board.
    expect(
        Eligibility.allowedEntrypoints(env: ["OPENBOARD_ENTRYPOINTS": " , ,"])
            == Eligibility.defaultEntrypoints
    )
    expect(Eligibility.allowedEntrypoints(env: [:]) == Eligibility.defaultEntrypoints)
}

test("a subagent of an embedded SDK client reports as a subagent") {
    // Both are true; the Node version checks subagent first and the more specific
    // answer is the more useful one. Pinned so a reordering is deliberate.
    let verdict = Eligibility.evaluate(
        env: cliEnv.merging(["CLAUDE_AGENT_SDK_CLIENT_APP": "x"]) { a, _ in a },
        payload: Eligibility.Payload(sessionID: "a", agentType: "Explore")
    )
    expect(verdict.reason == .subagent)
}

// MARK: - Board layout

test("the board is the pad, in reading order") {
    expect(BoardLayout.cells.count == 15, "13 keys with ACT10+ACT11 merged, plus 3 elements")
    expect(BoardLayout.cells.filter(\.isAgent).count == 6)
    expect(BoardLayout.cells.filter(\.isAction).count == 6)
    expect(BoardLayout.agentKeys == ["AG00", "AG01", "AG02", "AG03", "AG04", "AG05"])
}

test("the wide cap is one key, not two") {
    // ACT10 and ACT11 are two switches under one keycap and report a few ms apart.
    // Untreated this fired two actions per press — and when one held a key down,
    // the other typed into it.
    expect(BoardLayout.canonical("ACT11") == "ACT10")
    expect(BoardLayout.canonical("ACT10") == "ACT10")
    expect(BoardLayout.canonical("ACT12") == "ACT12")

    let wide = BoardLayout.cell(id: "ACT10")
    expect(wide?.span == 2)
    expect(wide?.members == ["ACT10", "ACT11"])
    expect(BoardLayout.cell(id: "ACT11") == nil, "ACT11 has no cell of its own")
}

test("slots and keys map both ways") {
    expect(BoardLayout.slot(forKey: "AG00") == 1)
    expect(BoardLayout.slot(forKey: "AG05") == 6)
    expect(BoardLayout.slot(forKey: "ACT06") == nil)
    expect(BoardLayout.key(forSlot: 1) == "AG00")
    expect(BoardLayout.key(forSlot: 6) == "AG05")
    expect(BoardLayout.key(forSlot: 7) == nil)
    expect(BoardLayout.key(forSlot: 0) == nil)
}

test("the dial, stick and touch sensor never take a keycap") {
    // They are drawn because the pad has them, not because they can be bound.
    for id in ["ENC", "JOY", "TOUCH"] {
        expect(BoardLayout.cell(id: id)?.acceptsKeycap == false)
    }
    expect(BoardLayout.cell(id: "ACT06")?.acceptsKeycap == true)
    expect(BoardLayout.cell(id: "AG00")?.acceptsKeycap == true)
}

test("reject carries both of its meanings") {
    // It rejects a pending prompt *and* cancels fun mode. The label has to say so.
    expect(KeyAction.reject.long.contains("fun mode"))
    expect(KeyAction.approve.hint == "⏎")
    expect(KeyAction.reject.hint == "⎋")
    expect(KeyAction.sync.hint == nil)
    expect(KeyAction.snippet.needsSnippetText)
}

// MARK: - Keycaps

test("the whole catalog came across") {
    expect(KeycapCatalog.caps.count == 38)
    expect(KeycapCatalog.icons.count == 30)
    // Every cap resolves to artwork, or it renders as a blank square on the pad.
    for cap in KeycapCatalog.caps where cap.icon != "empty" {
        expect(KeycapCatalog.icons[cap.icon] != nil, "cap \(cap.id) has no icon \(cap.icon)")
    }
}

test("every default cap exists in the catalog") {
    for (key, capID) in KeycapCatalog.defaultCaps {
        expect(KeycapCatalog.cap(id: capID) != nil, "\(key) defaults to unknown cap \(capID)")
    }
    // Session keys default to no icon: the LED is the signal, and a glyph competes.
    for key in BoardLayout.agentKeys {
        expect(KeycapCatalog.defaultCaps[key] == nil)
    }
}

test("icons carry their viewBox so they scale without distortion") {
    for (name, icon) in KeycapCatalog.icons {
        expect(icon.width > 0 && icon.height > 0, "\(name) has no viewBox")
        expect(!icon.paths.isEmpty, "\(name) has no paths")
    }
}

// MARK: - Calibration

test("the existing calibration file still loads") {
    // Recalibrating means sitting there pressing keys against colored lights.
    // A rewrite is not a good enough reason to make someone redo it.
    let json = """
    {"version":1,"recordedAt":"2026-07-28T17:07:09.483Z","confirmedBy":"operator",
     "rows":[[1,2],[3,4,5,6]],
     "mapping":{"1":1,"2":2,"3":3,"4":4,"5":5,"6":6}}
    """
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ob-cal-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let calibration = try Harness.require(try Calibration.load(from: url))
    expect(calibration.physicalSlot(for: 1) == 1)
    expect(calibration.physicalSlot(for: 6) == 6)
    expect(calibration.rows == [[1, 2], [3, 4, 5, 6]])
    expect(calibration.recordedAt != nil)
}

test("a non-identity mapping is honoured, not assumed away") {
    let json = #"{"mapping":{"1":3,"2":1,"3":2,"4":6,"5":4,"6":5}}"#
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ob-cal-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let calibration = try Harness.require(try Calibration.load(from: url))
    expect(calibration.physicalSlot(for: 1) == 3)
    expect(calibration.physicalSlot(for: 4) == 6)
}

test("a missing or malformed record parses as nil, never as a guess") {
    // `load` still refuses to invent a mapping. What changed is what the *app* does
    // with that nil — see runKeyOrderTests — not what the parser reports.
    let missing = URL(fileURLWithPath: "/nonexistent/openboard/calibration.json")
    expect(try Calibration.load(from: missing) == nil)

    for bad in ["{}", "not json", #"{"mapping":"nope"}"#, #"{"rows":[[1,2]]}"#] {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-bad-\(UUID().uuidString).json")
        try Data(bad.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        expect(try Calibration.load(from: url) == nil, "should reject: \(bad)")
    }
}

test("OPENBOARD_HOME redirects the state directory") {
    let dir = Calibration.defaultStateDirectory(env: ["OPENBOARD_HOME": "/tmp/ob-test"])
    expect(dir.path == "/tmp/ob-test")
    // A deliberate divergence from the Node version, and the one place this port does
    // not follow it. `~/.claude/openboard` is Claude Code's directory; for something
    // other people install, its own data belongs in its own folder. An existing
    // installation is moved across on first launch — see AppPaths.
    expect(Calibration.defaultStateDirectory(env: [:]).path.hasSuffix("Application Support/OpenBoard"))
    expect(AppPaths.legacyState(env: [:]).path.hasSuffix(".claude/openboard"))
}

}
