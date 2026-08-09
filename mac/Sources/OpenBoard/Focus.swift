import AppKit
import Foundation
import OpenBoardKit

/**
 Raise the window hosting a session.

 Ported from `lib/focus.cjs`, including the mistake it made. Two strategies, chosen by
 how the session runs:

 - **Terminal: exact.** Terminal's AppleScript dictionary exposes `tty` per tab, and a
   CLI session's process owns a tty, so the precise tab can be selected.
 - **VS Code: approximate.** An extension-hosted session has no tty, so the window for
   the workspace folder is raised. That focuses the right window, not the specific
   Claude panel inside it — an honest limit rather than a bug to chase.

 **A `cli` session with no tty gets nothing.** That is a detached background job: it
 was never hosted in a window, so there is nothing to raise. The earlier version read
 "no tty" as evidence of VS Code and opened the project as a *folder* in an editor
 unrelated to the session — a confident wrong answer to "jump to that chat", which is
 worse than admitting there is nowhere to go.

 Needs Automation permission for Terminal. Granted per app, and only after a restart.
 */
enum Focus {
    enum Outcome: Equatable {
        case raised(method: String)
        case noWindow
        case notFound
        case failed(String)
    }

    @discardableResult
    static func raise(_ slot: SlotView) -> Outcome {
        /*
         A session running in VS Code's integrated terminal has a real pty, so it used
         to take the Terminal branch, fail to find a matching tab — Terminal.app does
         not own that pty — and fall through to opening the session's *folder* in VS
         Code. Pressing "jump to this chat" opened an editor on a directory.

         Two things were wrong. It guessed at the host from the presence of a tty, and
         its fallback did something visible and unrelated rather than reporting that it
         could not get there. It now asks `origin`, which knows who owns the process.
         */
        if slot.origin == .vscode {
            if let session = slot.sessionID, slot.entrypoint == "claude-vscode" {
                return revealVSCodeSession(session)
            }
            return activateVSCode()
        }

        if let tty = slot.surface, tty.hasPrefix("ttys") || tty.hasPrefix("/dev/") {
            let path = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            return focusTerminal(tty: path)
        }

        return .noWindow
    }

    /**
     Reveal the tab holding one specific conversation.

     The Claude Code extension registers a URI handler, and `/open?session=` routes
     through `claude-vscode.primaryEditor.open` to a panel map keyed by session id: an
     id already on screen is `reveal()`ed rather than reopened. So the exact chat is
     reachable from outside VS Code, which no public API offers — the extension's own
     commands are the only thing that knows which panel is which.

     **Only for extension-hosted sessions.** A session in VS Code's integrated terminal
     is also `origin == .vscode` and has no panel, so this would miss the map and *create*
     one — a second, resumed view of a conversation that is already running in a terminal
     three feet away. That is the class of confident wrong answer this file exists to
     avoid, so the caller gates on the entry point rather than on the origin.

     A closed panel is reopened rather than revealed, which is the same thing the user
     asked for: the board only lists live sessions, so the conversation is still running.

     Undocumented, and therefore treated like the rest of this app's private
     dependencies: if the handoff fails, fall back to raising the app rather than
     leaving the press with nothing to show for it.
     */
    private static func revealVSCodeSession(_ sessionID: String) -> Outcome {
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "anthropic.claude-code"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            return activateVSCode()
        }
        return .raised(method: "vscode-session")
    }

    /**
     Bring VS Code forward, without opening anything.

     Deliberately not `code -r <folder>`. VS Code exposes no way to select a particular
     integrated terminal, so the best available is the app itself — and opening a folder
     is *not* a worse version of that, it is a different action that rearranges the
     user's editor. Given the choice between an approximate jump and an unrequested one,
     approximate wins.
     */
    private static func activateVSCode() -> Outcome {
        switch run("tell application \"Visual Studio Code\" to activate") {
        case .success:
            return .raised(method: "vscode-app")
        case let .failure(message):
            return .failed(message)
        }
    }

    /// Select the Terminal tab whose tty matches, and bring it forward.
    private static func focusTerminal(tty: String) -> Outcome {
        let escaped = tty.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
          repeat with w from 1 to count of windows
            repeat with t from 1 to count of tabs of window w
              if tty of tab t of window w is "\(escaped)" then
                set selected tab of window w to tab t of window w
                set index of window w to 1
                activate
                return "focused"
              end if
            end repeat
          end repeat
          return "not-found"
        end tell
        """
        let result = run(script)
        switch result {
        case let .success(output):
            return output == "focused" ? .raised(method: "terminal-tty") : .notFound
        case let .failure(message):
            return .failed(message)
        }
    }


    /// osascript's stdout, or the reason it failed. A plain pair rather than
    /// `Result`, whose failure type must be an `Error`.
    private enum ScriptResult {
        case success(String)
        case failure(String)
    }

    private static func run(_ script: String) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failure(error.localizedDescription) }
        process.waitUntilExit()

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            // -1743 is a refused Apple event: Automation has not been granted. Named
            // rather than passed through as a number, because the fix is specific.
            if detail.contains("-1743") {
                return .failure("not authorised to control Terminal — grant Automation")
            }
            return .failure(detail)
        }
        return .success(text)
    }
}
