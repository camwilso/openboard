import AppKit
import Foundation
import OpenBoardKit

/**
 What is in front of you, in terms a session can be matched against.

 Two surfaces, two handles, and neither is interchangeable with the other: a Terminal tab
 is identified by its tty, a VS Code window by its title. Keeping them as separate cases
 rather than flattening both to a string is what stops a tty being compared against a
 window title and matching nothing for reasons nobody can see.
 */
enum FocusedSurface: Equatable {
    case terminal(tty: String)
    /// The title of VS Code's focused window, which leads with the active tab's name —
    /// and the Claude Code extension names its tabs after the session. See
    /// `VSCodeWindows`.
    case vscode(windowTitle: String)
    case elsewhere
}

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
 - a surface we can read is frontmost → poll slowly, because switching *tabs* raises no
   notification in either app
 - anything else is frontmost → do not poll at all

 A tab switch is the only case that needs polling, and a second of latency on an
 ambient indicator is imperceptible.

 VS Code was excluded from this for a long time, on the grounds that its windows do not
 say which chat is open and a guess is worse than nothing. That was true of AppleScript
 and is not true of the window title — so it is read here too, and a VS Code chat can
 finally be the one you are looking at.
 */
@MainActor
final class FocusWatcher {
    private static let terminalBundleID = "com.apple.Terminal"

    private let onChange: (FocusedSurface) -> Void
    private var pollTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var last: FocusedSurface?

    init(onChange: @escaping (FocusedSurface) -> Void) {
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

    /// Which app is in front, if it is one whose windows we can read.
    private static var readableFrontmost: String? {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return [terminalBundleID, VSCodeWindows.bundleID].contains(frontmost) ? frontmost : nil
    }

    private func frontmostChanged() {
        guard Self.readableFrontmost != nil else {
            // Stop asking, and clear the indicator. Leaving it set would keep a key
            // breathing for a window that is no longer in front of you.
            pollTask?.cancel()
            pollTask = nil
            publish(.elsewhere)
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let frontmost = Self.readableFrontmost else { break }
                self.publish(await Self.surface(of: frontmost))
                // Only a tab switch can change this without an activation
                // notification, so a slow poll is enough.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Ask whichever app is in front for its handle. Both reads can fail — a refused
    /// Automation grant, a missing Accessibility grant — and both failures mean the same
    /// thing as any other app being in front.
    private static func surface(of bundleID: String) async -> FocusedSurface {
        switch bundleID {
        case terminalBundleID:
            guard let tty = await frontmostTTY() else { return .elsewhere }
            return .terminal(tty: tty)
        case VSCodeWindows.bundleID:
            guard let title = await VSCodeWindows.focusedTitle() else { return .elsewhere }
            return .vscode(windowTitle: title)
        default:
            return .elsewhere
        }
    }

    /// Deduplicated: this drives a repaint, and repainting the pad every second
    /// because nothing changed is exactly the write traffic the board avoids.
    private func publish(_ surface: FocusedSurface) {
        guard last != surface else { return }
        last = surface
        onChange(surface)
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
