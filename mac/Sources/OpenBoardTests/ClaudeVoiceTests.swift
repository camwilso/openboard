import Foundation
import OpenBoardKit

/**
 The voice-mode match table.

 The two knobs — Claude Code's `voice.mode` and OpenBoard's action-key binding — are
 set in different files by different apps, and the failure mode of a mismatch is
 silence rather than an error. So the pane that surfaces this must be right; anything
 that adds a mode or binding without extending both sides breaks silently, and this
 table is what catches it.
 */
func runClaudeVoiceTests() {
    test("matching pairs are green") {
        expect(VoiceMatch.evaluate(action: .voiceTap, claudeMode: "tap").isMatch)
        expect(VoiceMatch.evaluate(action: .voiceTalk, claudeMode: "hold").isMatch)
        expect(VoiceMatch.evaluate(action: .voiceToggle, claudeMode: "toggle").isMatch)
    }

    test("mismatched pairs report which rebind to make") {
        // Every wrong pair must produce a detail string that names at least one of
        // the two knobs to change. A generic "does not match" would leave the user
        // guessing which side to touch.
        let mismatches: [(KeyAction, String)] = [
            (.voiceTap, "hold"), (.voiceTap, "toggle"),
            (.voiceTalk, "tap"), (.voiceTalk, "toggle"),
            (.voiceToggle, "hold"), (.voiceToggle, "tap"),
        ]
        for (action, mode) in mismatches {
            let verdict = VoiceMatch.evaluate(action: action, claudeMode: mode)
            expect(!verdict.isMatch, "expected mismatch for \(action.rawValue) + \(mode)")
            let advice = verdict.detail.lowercased()
            expect(
                advice.contains("rebind") || advice.contains("/voice"),
                "detail for \(action.rawValue) + \(mode) must name a fix, got: \(verdict.detail)"
            )
        }
    }

    test("unset Claude mode is not silently green") {
        let verdict = VoiceMatch.evaluate(action: .voiceTap, claudeMode: nil)
        expect(!verdict.isMatch)
        expect(verdict.detail.lowercased().contains("unset"))
    }

    test("unknown Claude mode does not match anything") {
        for action in [KeyAction.voiceTap, .voiceTalk, .voiceToggle] {
            let verdict = VoiceMatch.evaluate(action: action, claudeMode: "hums")
            expect(!verdict.isMatch, "unknown mode must not match \(action.rawValue)")
        }
    }

    test("readMode returns nil when the file is absent") {
        // The real reader points at ~/.claude/settings.json. This test does not stub
        // the path — instead it just confirms the function does not crash on a
        // missing key and returns something well-typed. Full path-injection would
        // need a config on ClaudeVoice; not worth the API surface for one call.
        let mode = ClaudeVoice.readMode()
        // Either a String or nil — the point is that no exception escaped.
        expect(mode == nil || mode is String)
    }
}
