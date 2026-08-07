import AppKit
import Foundation
import OpenBoardKit

/**
 Which session you are actually looking at.

 `viewing` is idle-with-your-attention-on-it. Without it, the chat in front of you looks
 exactly like the five you are not reading, and the board answers "what is running?"
 without ever answering "and which of these am I in?".

 ## Why this is not a 4Hz poll

 The Node version ran a long-lived AppleScript that asked Terminal for the frontmost
 tty every 250ms, forever — one Apple Event four times a second for the entire life of
 the app, whether or not Terminal was even open.

 `NSWorkspace` publishes app activation for free, so the expensive question is only
 asked when it can have changed:

 - the frontmost app changes → check once
 - Terminal is frontmost → poll slowly, because switching *tabs* raises no notification
 - anything else is frontmost → do not poll at all

 A tab switch is the only case that needs polling, and a second of latency on an
 ambient indicator is imperceptible.
 */
@MainActor
final class FocusWatcher {
    /// Terminal is the only surface where a session maps to a window exactly, via the
    /// tty. VS Code's windows do not expose which chat is open, so a focused VS Code
    /// deliberately reports nothing rather than guessing at one of several sessions.
    private static let terminalBundleID = "com.apple.Terminal"

    private let onChange: (String?) -> Void
    private var pollTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var lastTTY: String??

    init(onChange: @escaping (String?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontmostChanged() }
        }
        frontmostChanged()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    private var terminalIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.terminalBundleID
    }

    private func frontmostChanged() {
        guard terminalIsFrontmost else {
            // Stop asking, and clear the indicator. Leaving it set would keep a key
            // breathing for a window that is no longer in front of you.
            pollTask?.cancel()
            pollTask = nil
            publish(nil)
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.terminalIsFrontmost else { break }
                self.publish(await Self.frontmostTTY())
                // Only a tab switch can change this without an activation
                // notification, so a slow poll is enough.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Deduplicated: this drives a repaint, and repainting the pad every second
    /// because nothing changed is exactly the write traffic the board avoids.
    private func publish(_ tty: String?) {
        guard lastTTY != .some(tty) else { return }
        lastTTY = .some(tty)
        onChange(tty)
    }

    /// The tty of Terminal's frontmost tab.
    ///
    /// Needs Automation → Terminal. Returns nil when it is refused, which reads as
    /// "nothing focused" — the same as any other app being in front, and the right
    /// failure: a missing permission should cost the indicator, not the board.
    private static func frontmostTTY() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let script = """
                tell application "Terminal"
                  repeat with w from 1 to count of windows
                    if frontmost of window w then
                      return tty of selected tab of window w
                    end if
                  end repeat
                end tell
                """
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil); return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(
                    returning: (output?.hasPrefix("/dev/") == true) ? output : nil
                )
            }
        }
    }
}


/**
 Terminal's tab titles, by tty.

 One Apple Event returns every tab at once, which is why this is a map rather than a
 per-session lookup: asking six times costs six round trips, and the answer for all of
 them arrives in the same call.

 Needs Automation → Terminal, the same grant the jump already uses. Without it this
 returns nothing and session names fall back to the first message, which is a worse
 name rather than a broken app.
 */
enum TerminalTitles {
    static func read() async -> [String: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let script = """
                tell application "Terminal"
                  set out to ""
                  repeat with w from 1 to count of windows
                    repeat with t from 1 to count of tabs of window w
                      try
                        set out to out & (tty of tab t of window w) & " || " ¬
                          & (custom title of tab t of window w) & linefeed
                      end try
                    end repeat
                  end repeat
                  return out
                end tell
                """
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: [:]); return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: TerminalTitle.parse(text))
            }
        }
    }
}
