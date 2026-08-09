import AppKit
import SwiftUI
import OpenBoardKit

/**
 The settings window, owned outright rather than declared as a SwiftUI scene.

 ## Why not the `Settings` scene

 It was one, and it behaved like a modal utility panel: it could not go full screen, it
 did not appear in the window list or the app switcher, and — verified by logging
 `NSApp.windows` while it was open — it is not in the application's window list at all.
 That last part is not cosmetic. It means nothing in the app can find it, raise it, or
 ask whether it is already open; a "bring the existing window forward" path written
 against it could never run.

 An `NSWindowController` gives an ordinary window: front-most when asked, resizable,
 full-screenable, in the window list, and findable.

 ## The activation policy is the other half

 The app is `.accessory` — no Dock icon, no app switcher entry — because it is an
 ambient status tool and a Dock icon for it would be noise. But an accessory app cannot
 take full screen and cannot properly own the menu bar, so the policy is raised to
 `.regular` while this window is open and dropped back when it closes.

 The effect is what people expect from a menu bar app with a real settings window: no
 Dock presence day to day, a normal app while you are configuring it.
 */
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let board: BoardModel
    private let commands: BoardCommands
    /// Injected rather than reached for: the settings window shows update status, and
    /// there is exactly one updater, owned by the app delegate.
    private let updater: Updater
    private let setup: SetupState

    init(board: BoardModel, commands: BoardCommands, updater: Updater, setup: SetupState) {
        self.board = board
        self.commands = commands
        self.updater = updater
        self.setup = setup
    }

    /// Open it, or bring it forward if it is already up.
    func show() {
        if let window {
            raise(window)
            // Logged because a silent raise is indistinguishable from doing nothing,
            // which is how the dial appeared broken for an afternoon. It is also the
            // branch the old Settings scene could never take: it was not in
            // NSApp.windows, so there was never a window here to find.
            Log.write("window: raised the existing one")
            return
        }

        /*
         An ordinary opaque title bar.

         It was `fullSizeContentView` with `titlebarAppearsTransparent`, which extends
         the content under the title bar — the look a window wants when it has its own
         header art to show through. This one does not: it has a scroll view, so the
         pane's content slid up behind the title and was legible through it.

         Without `fullSizeContentView` the content starts below the bar, and the bar
         draws its own material, so nothing shows through at any scroll position.
        */
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        created.title = "OpenBoard"
        // Without this the green button zooms rather than going full screen, which is
        // the specific thing the Settings scene could not do.
        created.collectionBehavior.insert(.fullScreenPrimary)
        created.isReleasedWhenClosed = false
        created.delegate = self
        created.setContentSize(NSSize(width: 860, height: 620))
        created.minSize = NSSize(width: 720, height: 520)
        created.center()
        // Remembered across launches, so it opens where it was left.
        created.setFrameAutosaveName("OpenBoardMainWindow")

        /*
         A material behind the content, so the glass has something to refract.

         Liquid Glass samples what is behind it. Over a flat opaque window background it
         has nothing to work with and degrades to a slightly tinted rectangle — the
         effect reads as "grey box" and the whole point is lost. An `NSVisualEffectView`
         under the hosting view gives it the desktop and whatever is behind the window,
         which is what the material was designed to sit on.

         `.sidebar` blending, `behindWindow`: the window becomes a lens rather than a
         surface. `titlebar` state `.followsWindowActiveState` so an inactive window
         recedes the way every other macOS window does.
        */
        let backdrop = NSVisualEffectView()
        // `.windowBackground`, not `.sidebar`. Now that the split view's own backdrops
        // are cleared, this one material runs edge to edge under both halves — and
        // sidebar material behind a *content* pane is the wrong tone for reading.
        backdrop.material = .windowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        backdrop.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(
            rootView: SettingsWindow()
                .environmentObject(board)
                .environmentObject(updater)
                .environmentObject(setup)
                .environment(\.boardCommands, commands)
                .tint(SystemColors.selectedRow)
        )
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = backdrop.bounds
        backdrop.addSubview(hosting)
        created.contentView = backdrop

        window = created
        raise(created)
        // Confirms the thing the Settings scene could not do: this window is in the
        // application's window list, so it can be found, raised and asked about.
        Log.write(
            "window: opened — policy=\(NSApp.activationPolicy() == .regular ? "regular" : "accessory")"
                + ", fullScreenCapable=\(created.collectionBehavior.contains(.fullScreenPrimary))"
                + ", inWindowList=\(NSApp.windows.contains(created))"
        )
    }

    private func raise(_ window: NSWindow) {
        // Regular *before* activating: an accessory app cannot become front-most in the
        // way a window needs, and the order matters — raising first leaves the window
        // visible but behind whatever was already there.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Back to an ambient tool when the window goes away.
    func windowWillClose(_ notification: Notification) {
        window = nil
        Log.write("window: closed — back to accessory")
        // Deferred: dropping the policy while the close is still in flight leaves the
        // menu bar in a half-torn-down state, and the next open comes up without focus.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    var isOpen: Bool { window?.isVisible == true }
}
