import AppKit
import OpenBoardKit
import SwiftUI

/**
 The window guided setup lives in.

 Its own window rather than a sheet on the settings window, because the popover offers
 setup at a moment when the settings window does not exist — and opening a whole control
 panel in order to hang a sheet on it is a great deal of furniture for four checkboxes.

 Small, non-resizable, and centred. There is one column of content and no reason to drag
 it wider; a resizable window here only offers people the chance to make it look wrong.

 The activation policy dance matches MainWindowController's. An `.accessory` app cannot
 bring a window properly forward — it opens behind whatever is frontmost, which for a
 window someone just asked for reads as the click having been ignored.
 */
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let commands: BoardCommands
    /// Needed for the calibration step: whether the order has been confirmed, and
    /// whether the pad is open enough to check it.
    private let board: BoardModel
    private let setup: SetupState

    init(commands: BoardCommands, board: BoardModel, setup: SetupState) {
        self.commands = commands
        self.board = board
        self.setup = setup
        super.init()
    }

    func show() {
        if let window {
            raise(window)
            return
        }

        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        created.title = "Set up OpenBoard"
        created.titlebarAppearsTransparent = true
        created.isMovableByWindowBackground = true
        created.delegate = self
        // Not released on close: the controller keeps it, so reopening lands where it
        // was left rather than jumping back to centre every time.
        created.isReleasedWhenClosed = false

        let hosting = NSHostingView(
            rootView: SetupSheet()
                .environmentObject(board)
                .environmentObject(setup)
                .environment(\.boardCommands, commands)
                .tint(SystemColors.selectedRow)
        )
        hosting.autoresizingMask = [.width, .height]
        created.contentView = hosting
        created.center()

        window = created
        raise(created)
        Log.write("setup: window opened")
    }

    /// Raise properly from an accessory app: become regular first, or the window opens
    /// behind whatever is frontmost and the click looks ignored.
    private func raise(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Back to accessory when nothing is on screen — a menu bar tool with a Dock icon
    /// and no windows is a tool that looks like it failed to quit.
    func windowWillClose(_ notification: Notification) {
        Log.write("setup: window closed")
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
