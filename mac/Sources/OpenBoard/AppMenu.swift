import AppKit

/**
 The application menu bar.

 Built by hand because there is no SwiftUI scene to build it. `MenuBarExtra` supplies
 no menu bar, and the `Settings` scene that used to supply one is gone — so without
 this the app is `.regular` with a window on screen and **no menus at all**.

 That is not only a missing ⌘,. The **Edit menu is what makes ⌘C, ⌘V, ⌘A and ⌘Z work
 in a text field** — AppKit routes those through the responder chain from menu items,
 not from the field itself. Without an Edit menu the hex color field and the snippet
 field silently refuse to paste, which reads as the field being broken.

 The menu is installed once at launch rather than when the window opens: building it
 lazily means the first window comes up with an empty menu bar for a frame.
 */
enum AppMenu {
    static func install(target: AnyObject, openSettings: Selector) {
        let main = NSMenu()

        // MARK: OpenBoard
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About OpenBoard",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: openSettings, keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(settings)

        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide OpenBoard",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit OpenBoard",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        // MARK: Edit
        //
        // The reason this file exists as much as ⌘, is. Cut/copy/paste/undo in a
        // NSTextField are driven by these menu items through the responder chain; with
        // no Edit menu the settings window's text fields cannot be pasted into.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = edit
        main.addItem(editItem)

        // MARK: View — carries the full-screen item, which is the point of having a
        // real window rather than a settings panel.
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let fullScreen = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fullScreen)
        viewItem.submenu = view
        main.addItem(viewItem)

        // MARK: Window
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        window.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        window.addItem(.separator())
        window.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
        // Lets AppKit put the standard window list under Window automatically.
        NSApp.windowsMenu = window
    }
}
