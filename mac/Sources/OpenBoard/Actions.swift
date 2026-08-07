import AppKit
import Foundation
import OpenBoardKit

/**
 What the action keys do.

 Ported from `lib/actions.cjs` and `lib/respond.cjs`, including the caveats each one
 earned. Everything here posts synthetic input, which needs **Accessibility** — a
 separate grant from Automation, and the one whose absence is hardest to diagnose:
 keys that only read the pad keep working while keys that emit input silently do
 nothing.
 */
enum Actions {
    struct Result {
        let ok: Bool
        let detail: String

        static let done = Result(ok: true, detail: "")
        static func failed(_ detail: String) -> Result { Result(ok: false, detail: detail) }
    }

    // MARK: - typing

    /// Type text at the cursor.
    ///
    /// Deliberately does not focus anything first — the point is to insert into
    /// whatever you are already looking at. Also deliberately does not press Enter: it
    /// leaves the text and the cursor so you can edit or discard it.
    static func typeSnippet(_ text: String) -> Result {
        guard !text.isEmpty else { return .failed("no text configured") }
        // AppleScript string literal: backslashes first, then quotes.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return run("tell application \"System Events\" to keystroke \"\(escaped)\"")
    }

    /// Open a new Terminal tab.
    ///
    /// Cmd-T against the frontmost window rather than `do script`, which would open a
    /// new *window* and lose the working directory.
    static func newTerminalTab() -> Result {
        run("""
        tell application "Terminal"
          activate
          delay 0.15
          tell application "System Events" to keystroke "t" using command down
        end tell
        """)
    }

    /// macOS virtual key codes.
    private static let keySpace = 49
    private static let keyReturn = 36
    private static let keyEscape = 53

    /**
     Tap space once: starts dictation, or stops and submits it.

     Strongly preferred over holding a key. `key down` is OS-level state that outlives
     this process, so a crash mid-hold leaves space logically down and silently
     corrupts every keystroke afterwards. A tap cannot get stuck.

     Caveat worth knowing: space only triggers voice when the chat input is **empty**.
     Otherwise it types a space — the same binding doing its other job.
     */
    static func tapVoice() -> Result {
        run("tell application \"System Events\" to key code \(keySpace)")
    }

    /// Toggle voice mode by typing `/voice`.
    static func toggleVoice() -> Result {
        let typed = typeSnippet("/voice")
        guard typed.ok else { return typed }
        // A slash command needs a beat before Enter. Sending it immediately submits
        // the text as an ordinary message instead of invoking the command — which is
        // exactly what happened the first time, and "/voice" arrived in the chat as a
        // user message.
        Thread.sleep(forTimeInterval: 0.4)
        return run("tell application \"System Events\" to key code \(keyReturn)")
    }

    // MARK: - the encoder

    /**
     Synthesise a real scroll-wheel event.

     A wheel event rather than key presses because Claude Code binds scrolling to
     wheel-up/wheel-down, and the alternatives are worse: page keys jump a whole screen,
     and arrows mean something else in a chat input — up is history, not scroll.

     `CGEvent` directly rather than the Node version's `tools/scroll` helper binary:
     the same two API calls, minus spawning a process per tick. At a fast turn that is
     several spawns a second, each costing more than the event it sends.

     Positive scrolls up. Posted to the HID tap so it lands wherever a real wheel would.
     */
    @discardableResult
    static func scroll(lines: Int) -> Result {
        guard lines != 0 else { return Result(ok: true, detail: "") }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: Int32(clamping: lines),
            wheel2: 0,
            wheel3: 0
        ) else {
            return Result(ok: false, detail: "could not create a scroll event")
        }
        event.post(tap: .cghidEventTap)
        return Result(ok: true, detail: "")
    }

    // MARK: - push to talk

    /**
     Hold space down, and release it.

     **This is the dangerous one.** `keyDown` is OS-level state that outlives this
     process: crash or quit between the two and space is logically held forever,
     silently corrupting every keystroke on the machine until the user works out what
     happened. That is why `tapVoice` is the default and why the caller pairs every
     hold with a timer and a release on termination.

     `CGEvent` rather than System Events, so the release does not depend on a
     subprocess launching successfully at exactly the moment things are going wrong.
     */
    @discardableResult
    static func holdSpace(down: Bool) -> Result {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keySpace),
            keyDown: down
        ) else {
            return Result(ok: false, detail: "could not create a key event")
        }
        event.post(tap: .cghidEventTap)
        return Result(ok: true, detail: "")
    }

    // MARK: - the joystick

    private static let keyUpArrow: CGKeyCode = 126
    private static let keyDownArrow: CGKeyCode = 125
    private static let keyLeftBracket: CGKeyCode = 33
    private static let keyRightBracket: CGKeyCode = 30

    /**
     Send a key to whatever is focused.

     `CGEvent` rather than System Events: these fire from a joystick that can be pushed
     repeatedly and quickly, and spawning an `osascript` per nudge would lag behind the
     stick the way the encoder did before it was moved off a helper binary.
     */
    @discardableResult
    static func sendKey(_ code: CGKeyCode, flags: CGEventFlags = []) -> Result {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        else {
            return Result(ok: false, detail: "could not create a key event")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return Result(ok: true, detail: "")
    }

    /// ⌘⇧] and ⌘⇧[ — the closest thing macOS has to a universal next/previous tab.
    /// Terminal, Safari, Finder and most editors honour it; anything that does not
    /// simply ignores it rather than doing something surprising.
    @discardableResult
    static func nextTab() -> Result {
        sendKey(keyRightBracket, flags: [.maskCommand, .maskShift])
    }

    @discardableResult
    static func previousTab() -> Result {
        sendKey(keyLeftBracket, flags: [.maskCommand, .maskShift])
    }

    private static let keyLeftArrow: CGKeyCode = 123
    private static let keyRightArrow: CGKeyCode = 124

    @discardableResult
    static func arrow(_ direction: Joystick.Direction) -> Result {
        switch direction {
        case .up: sendKey(keyUpArrow)
        case .down: sendKey(keyDownArrow)
        case .left: sendKey(keyLeftArrow)
        case .right: sendKey(keyRightArrow)
        }
    }

    // MARK: - answering a prompt

    enum RespondOutcome: Equatable {
        case sent(slot: Int)
        case nothingPending
        /// Two or more sessions are blocked. Refused rather than guessed.
        case ambiguous(slots: [Int])
        case focusFailed(slot: Int, reason: String)
        case failed(String)
    }

    /**
     Answer the one blocked session, if there is exactly one.

     Two rules carried over, both load-bearing:

     - **Refuse to guess.** With more than one session waiting, this does nothing and
       says which slots. Pressing that session's own Agent Key is unambiguous; guessing
       would answer a prompt the user never read.
     - **Confirm focus before typing.** An earlier version waited a flat 250ms and fired
       blind. A raise that had not landed yet sent the keystroke into whatever was in
       front — which looks exactly like "the dialog ignored Escape" and sends you
       chasing the wrong cause. Verifying turns a silent misdelivery into a reported
       failure.
     */
    static func respond(_ decision: Decision, slots: [SlotView]) -> RespondOutcome {
        let pending = slots.filter { $0.state?.isAttention == true }
        guard !pending.isEmpty else { return .nothingPending }
        guard pending.count == 1 else {
            return .ambiguous(slots: pending.map(\.slot))
        }

        let target = pending[0]
        let raised = Focus.raise(target)
        guard case .raised = raised else {
            return .focusFailed(slot: target.slot, reason: "\(raised)")
        }

        guard confirmFrontmost(tty: target.surface) else {
            return .focusFailed(slot: target.slot, reason: "never became frontmost")
        }

        let code = decision == .approve ? keyReturn : keyEscape
        let result = run("tell application \"System Events\" to key code \(code)")
        return result.ok ? .sent(slot: target.slot) : .failed(result.detail)
    }

    enum Decision: Equatable { case approve, reject }

    /// Poll until the target tab is actually frontmost, or give up.
    ///
    /// Bounded: a raise that never lands must not hang the key press.
    private static func confirmFrontmost(tty: String?, timeout: TimeInterval = 1.5) -> Bool {
        guard let tty else { return false }
        let wanted = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = run("""
            tell application "Terminal"
              repeat with w from 1 to count of windows
                if frontmost of window w then return tty of selected tab of window w
              end repeat
              return ""
            end tell
            """)
            if result.ok, result.detail == wanted { return true }
            Thread.sleep(forTimeInterval: 0.08)
        }
        return false
    }

    // MARK: - plumbing

    @discardableResult
    private static func run(_ script: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failed(error.localizedDescription) }
        process.waitUntilExit()

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            /*
             Name the permission rather than pass the code through.

             These have four different fixes and are indistinguishable as raw numbers.
             Keeping only execFile's message — which echoes the command back and says
             nothing about why — is what made an earlier round of this undiagnosable
             for hours.
             */
            if detail.contains("1002") || detail.contains("-25211")
                || detail.lowercased().contains("not allowed") {
                return .failed("Accessibility not granted — keystrokes are being dropped")
            }
            if detail.contains("-1743") {
                return .failed("Automation not granted for that app")
            }
            return .failed(detail.split(separator: "\n").first.map(String.init) ?? "unknown")
        }
        return Result(ok: true, detail: text)
    }
}
