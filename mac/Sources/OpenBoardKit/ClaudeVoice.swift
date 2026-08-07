import Foundation

/**
 Reads Claude Code's voice mode out of `~/.claude/settings.json`.

 `voice.mode` decides whether Space records while held or between two taps, which in
 turn decides whether the pad's `voice-tap` or `voice-talk` binding will actually work.
 The two knobs are set in different files by different apps; the point of reading this
 is to detect the mismatch before the user finds it by wondering why nothing recorded.

 Read on demand rather than cached: the file is edited by hand and by `/voice`, and the
 pane that displays this refreshes on appear.
 */
public enum ClaudeVoice {
    public static let settingsPath = "~/.claude/settings.json"

    /// The current value of `voice.mode`, or `nil` if the file is missing, unreadable,
    /// or does not carry that key. `nil` is a valid state — Claude Code defaults to a
    /// mode when the key is absent, but from OpenBoard's side "not set" is what to
    /// display.
    public static func readMode() -> String? {
        let url = URL(fileURLWithPath: (settingsPath as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voice = root["voice"] as? [String: Any],
              let mode = voice["mode"] as? String
        else { return nil }
        return mode
    }
}

/**
 The rules that decide whether a Claude voice mode and a pad voice binding will work
 together. Pure and enum-based so a test can pin the whole table.

 The names are ours, from `KeyAction`:

 - `voice-tap`   — pad sends one Space keystroke on press.
 - `voice-talk`  — pad presses Space on key-down, releases on key-up (push-to-talk).
 - `voice-toggle` — pad sends the `/voice` slash command, which toggles voice on/off.

 Claude Code's mode names:

 - `hold`   — records while Space is held down.
 - `tap`    — records between two Space taps.
 - `toggle` — records between two `/voice` invocations, or similar app-level toggle.
 */
public enum VoiceMatch {
    public struct Verdict: Equatable, Sendable {
        public let isMatch: Bool
        public let detail: String
    }

    public static func evaluate(action: KeyAction, claudeMode: String?) -> Verdict {
        guard let claudeMode else {
            return Verdict(
                isMatch: false,
                detail: "Claude's voice.mode is unset — set it to match this binding."
            )
        }
        switch (action, claudeMode) {
        case (.voiceTap, "tap"), (.voiceTalk, "hold"), (.voiceToggle, "toggle"):
            return Verdict(isMatch: true, detail: "matches Claude's \(claudeMode) mode")
        case (.voiceTap, "hold"):
            return Verdict(
                isMatch: false,
                detail: "tap won't hold Space long enough — rebind to voice-talk, or /voice tap"
            )
        case (.voiceTap, "toggle"):
            return Verdict(
                isMatch: false,
                detail: "tap sends Space; toggle mode needs /voice — rebind to voice-toggle, or /voice tap"
            )
        case (.voiceTalk, "tap"):
            return Verdict(
                isMatch: false,
                detail: "hold starts a recording that never ends — rebind to voice-tap, or /voice hold"
            )
        case (.voiceTalk, "toggle"):
            return Verdict(
                isMatch: false,
                detail: "hold sends key-down; toggle needs /voice — rebind to voice-toggle, or /voice hold"
            )
        case (.voiceToggle, "hold"):
            return Verdict(
                isMatch: false,
                detail: "/voice would flip Claude's mode off — rebind to voice-talk, or /voice toggle"
            )
        case (.voiceToggle, "tap"):
            return Verdict(
                isMatch: false,
                detail: "/voice would flip Claude's mode off — rebind to voice-tap, or /voice toggle"
            )
        default:
            return Verdict(
                isMatch: false,
                detail: "Claude's mode is '\(claudeMode)' — no pad binding maps to that."
            )
        }
    }
}
