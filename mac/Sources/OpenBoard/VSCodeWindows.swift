import AppKit
import ApplicationServices

/**
 Reading VS Code's windows.

 Terminal answers "which tab are you in?" through its AppleScript dictionary, which
 exposes a `tty` per tab. VS Code exposes nothing equivalent — no dictionary, no CLI
 flag, no way to ask which chat is open. What it does have is a window title, and by
 default that title leads with the active editor's name:

 ```
 Investigate VS Code event detection in openboard — Projects
 ```

 The Claude Code extension renames its tab to the session's own name — the same
 `ai-title` the board now shows in a row — so a focused chat puts its name in the
 window title, and the board can match a key to a window by reading it.

 ## Why the Accessibility API rather than AppleScript

 VS Code has no scripting dictionary, so `osascript` could only reach it through System
 Events, which means a subprocess per poll. This is an in-process call, and the app
 already holds the Accessibility grant for typing snippets and sending ⏎.

 An Electron app is usually a bad AX target: Chromium builds its tree only when an
 assistive client asks, and the cost of asking is real. None of that applies here. A
 window's title and position come from the native `NSWindow` underneath, which is always
 there — nothing in this file descends into the web contents, and it must stay that way.

 ## Fail quiet

 Every call returns nil rather than throwing or logging. Accessibility not granted, VS
 Code not running, a window with no title: all of them mean "cannot tell", and the
 caller's answer to that is the behaviour from before this file existed.
 */
enum VSCodeWindows {
    static let bundleID = "com.microsoft.VSCode"

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /**
     The title of the window you are looking at, read off the main thread.

     An AX call is a synchronous message to another process. VS Code answers in well
     under a millisecond, but an app that is beachballing answers when it feels like it —
     and this runs once a second for as long as VS Code is in front. The messaging
     timeout below bounds it, and the hop keeps even that off the main thread.
     */
    static func focusedTitle() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: focusedTitleNow())
            }
        }
    }

    /// The synchronous form. Used directly where the caller is already off the main
    /// thread and needs an answer inline — see `Actions.confirmFrontmost`.
    static func focusedTitleNow() -> String? {
        guard let application else { return nil }
        guard let window = element(application, kAXFocusedWindowAttribute) else { return nil }
        return string(window, kAXTitleAttribute)
    }

    /**
     Bring the window whose title contains `needle` to the front.

     Deliberately narrow: it raises a window that already exists and never opens
     anything. A miss returns false and leaves the screen exactly as it was, which is
     what lets the caller fall back to activating the app rather than guessing.

     `AXRaise` orders the window within its app; the app itself still has to be
     activated, or a raised window sits behind whatever you were using.
     */
    @discardableResult
    static func raise(titleContaining needle: String) -> Bool {
        guard !needle.isEmpty, let application else { return false }
        guard let windows = element(application, kAXWindowsAttribute, as: [AXUIElement].self)
        else { return false }

        for window in windows where string(window, kAXTitleAttribute)?.contains(needle) == true {
            guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
            else { continue }
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?
                .activate()
            return true
        }
        return false
    }

    // MARK: - plumbing

    private static var application: AXUIElement? {
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first
        else { return nil }
        let element = AXUIElementCreateApplication(running.processIdentifier)
        // A bound on every message sent through this element. Without it a wedged VS
        // Code stalls the caller indefinitely, and this is called on a timer.
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    /// A child element. The type check is not ceremony: `AXUIElement` is a CF type, so
    /// an unchecked cast of whatever came back is a crash rather than a nil.
    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func element<T>(
        _ parent: AXUIElement, _ name: String, as type: T.Type
    ) -> T? {
        attribute(parent, name) as? T
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) as? String, !value.isEmpty else { return nil }
        return value
    }
}
