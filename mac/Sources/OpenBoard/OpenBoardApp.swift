import OpenBoardKit
import SwiftUI

/**
 The app.

 `MenuBarExtra` with `.menuBarExtraStyle(.window)` gives the popover the design calls
 for — a real panel with rows, sections and buttons — rather than an NSMenu, which
 could not draw LED dots or a keycap grid.

 No Dock icon while it is just watching: this is an ambient status tool, and a Dock
 icon for one is noise. The settings window raises the app to `.regular` while it is
 open — an accessory app cannot take full screen or own a menu bar — and it drops back
 on close.

 The settings window is **not** a SwiftUI `Settings` scene. That scene could not go
 full screen, did not appear in the window list or the app switcher, and was not in
 `NSApp.windows` even while open, so nothing in the app could find or raise it. See
 `MainWindowController`.
 */
@main
struct OpenBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Built once by the delegate, so the popover, the settings window and the key
    /// dispatcher all drive the same controller through the same closures.
    private var commands: BoardCommands { delegate.commands }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(delegate.board)
                .environmentObject(delegate.battery)
                // As an object rather than through BoardCommands: the popover needs to
                // *observe* the update status, and BoardCommands is a struct of
                // closures with nothing for SwiftUI to watch.
                .environmentObject(delegate.updater)
                .environmentObject(delegate.setup)
                .environment(\.boardCommands, commands)
                .tint(SystemColors.selectedRow)
        } label: {
            StatusItemLabel()
                .environmentObject(delegate.board)
        }
        .menuBarExtraStyle(.window)

        // No `Settings` scene. It could not go full screen, did not appear in the
        // window list, and — verified by logging NSApp.windows while it was open — was
        // not in the application's window list at all. The window is owned outright
        // instead; see MainWindowController.
        
    }
}

/// What the popover can ask the controller to do, without the views holding a
/// reference to it.
struct BoardCommands: Sendable {
    var sync: @MainActor () -> Void = {}
    var forgetAll: @MainActor () -> Void = {}
    var playShow: @MainActor (String) -> Void = { _ in }
    var jump: @MainActor (Int) -> Void = { _ in }
    /// Called after any edit in the settings window: every change saves immediately
    /// and a repaint applies it, so there is no save button to forget.
    var bindingsChanged: @MainActor () -> Void = {}
    var reconnect: @MainActor () -> Void = {}
    /// Show one state on the pad. A color at 55% on an emissive key is not a swatch
    /// at 55% opacity, so the only honest preview is the hardware itself.
    var previewState: @MainActor (SessionState) -> Void = { _ in }
    var resetColors: @MainActor () -> Void = {}
    /// Paint the six legend colors and hold them while the capture sheet is open.
    var beginCalibration: @MainActor () -> Void = {}
    var endCalibration: @MainActor () -> Void = {}
    /// Returns false if the observation was rejected — a partial or contradictory
    /// capture must never be written.
    var saveCalibration: @MainActor ([Int]) -> Bool = { _ in false }
    /// Fun mode. Calling it while it runs cancels it.
    var playCountdown: @MainActor () -> Void = {}
    /// Free one key. The session keeps running — this forgets it, it does not stop it.
    var release: @MainActor (Int) -> Void = { _ in }
    /// Open the settings window, or bring it forward.
    var openSettings: @MainActor () -> Void = {}
    /// Open guided setup. Separate from openSettings because the popover offers it
    /// when nothing works yet, and dropping someone into a settings window at that
    /// moment is handing them a control panel instead of an answer.
    var openSetup: @MainActor () -> Void = {}
    /// Close the dropdown. Only ever called from a row *inside* it — the underlying
    /// click is a toggle, so calling it with nothing showing opens the menu instead.
    var dismissMenu: @MainActor () -> Void = {}

    /// Whether this build can update itself. False in a local build, which has no
    /// feed signing key — see Updater. The UI asks rather than offering a button that
    /// would fail with a signature error nobody can act on.
    var canUpdate: Bool = false
    /// Check now, because someone clicked.
    var checkForUpdates: @MainActor () -> Void = {}
    /// Reopen the dialog for an update Sparkle has already found.
    var showAvailableUpdate: @MainActor () -> Void = {}
    /// Sparkle's background-check preference, read and written through Sparkle rather
    /// than mirrored into our own config — it already persists the answer, and two
    /// copies of one setting is one copy too many.
    var automaticUpdates: @MainActor () -> Bool = { false }
    var setAutomaticUpdates: @MainActor (Bool) -> Void = { _ in }
}

private struct BoardCommandsKey: EnvironmentKey {
    static let defaultValue = BoardCommands()
}

extension EnvironmentValues {
    var boardCommands: BoardCommands {
        get { self[BoardCommandsKey.self] }
        set { self[BoardCommandsKey.self] = newValue }
    }
}

/**
 Owns the model and the controller, and starts them at launch.

 Not from the popover's `.task`: `MenuBarExtra` builds its content lazily, so that
 only runs the first time someone *clicks* the status item. Hook events, device
 polling and painting all have to happen whether the popover is ever opened or not —
 the whole point is a board you glance at, not one you have to open.
 */
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /**
     Move an older installation's files before anything reads them.

     `BoardModel()` loads the configuration in its own initializer, so this has to
     happen first — otherwise the app reads defaults out of an empty new directory and
     then saves them over the file it was about to migrate, losing every setting at
     exactly the moment it claimed to preserve them.

     Two things make the order hold, and both are deliberate:

     - `board` is `lazy`, so it is constructed on first *access* rather than during
       `init`. A stored property with an initializer would have run before this line —
       Swift initializes a subclass's own properties before `super.init()`.
     - This is a static call, which is why it is legal here at all.

     First access is from the scene body, long after the delegate exists.
     */
    /**
     Nothing has ever run here before.

     Read in `init`, and it has to be: the answer is "does the config file exist", and
     constructing `board` writes one. A moment later this is false for every install,
     including the one that has never been set up.
     */
    let isFirstLaunch: Bool

    override init() {
        isFirstLaunch = !FileManager.default.fileExists(atPath: PreferencesStore.url().path)
        AppPaths.migrateIfNeeded().forEach { name in
            Log.write("migrated \(name) out of ~/.claude/openboard")
        }
        // Exists before anyone is told to put anything in it.
        AppPaths.ensureMedia()
        super.init()
    }

    lazy var board = BoardModel()
    let battery = BatteryMonitor()
    /// Starts its own scheduled check in `init` when the build has a feed key, so it
    /// is constructed here rather than on first use — an updater nobody opens Settings
    /// to see is still the one that has to notice a release.
    let updater = Updater()
    /// One answer to "is this install finished", shared by the popover, the settings
    /// panes and the setup window. Lazy because it reads `board`.
    lazy var setup = SetupState(board: board)
    private(set) var controller: BoardController?

    /// The settings window, kept alive across opens so it remembers where it was.
    private(set) var mainWindow: MainWindowController?
    /// Guided setup. Also kept, so closing and reopening does not lose the position.
    private(set) var setupWindow: SetupWindowController?

    /**
     Everything the UI can ask for, in one place.

     Owned here rather than rebuilt in the `App` struct because the settings window is
     no longer a SwiftUI scene: the window controller needs the same closures the
     popover uses, and two independently-built copies would be two ways to reach the
     controller that could drift apart.

     `lazy` because the closures capture `self`.
     */
    lazy var commands: BoardCommands = BoardCommands(
        sync: { [weak self] in self?.controller?.sync() },
        forgetAll: { [weak self] in self?.controller?.forgetAllSessions() },
        playShow: { [weak self] name in
            guard let show = Shows.show(named: name) else { return }
            self?.controller?.play(show: show)
        },
        jump: { [weak self] slot in self?.controller?.jumpFromUI(slot) },
        bindingsChanged: { [weak self] in self?.controller?.bindingsChanged() },
        reconnect: { [weak self] in self?.controller?.reconnect() },
        previewState: { [weak self] state in self?.controller?.preview(state) },
        resetColors: { [weak self] in
            self?.board.resetToDefaults()
            self?.controller?.bindingsChanged()
        },
        beginCalibration: { [weak self] in self?.controller?.beginCalibrationCapture() },
        endCalibration: { [weak self] in self?.controller?.endCalibrationCapture() },
        saveCalibration: { [weak self] observed in
            self?.controller?.saveCalibration(observed: observed) ?? false
        },
        playCountdown: { [weak self] in self?.controller?.playCountdown() },
        release: { [weak self] slot in self?.controller?.release(slot: slot) },
        openSettings: { [weak self] in self?.showMainWindow() },
        openSetup: { [weak self] in self?.showSetup() },
        dismissMenu: { [weak self] in self?.controller?.dismissMenuBarPopover() },
        canUpdate: Updater.isAvailable,
        checkForUpdates: { [weak self] in self?.updater.checkForUpdates() },
        showAvailableUpdate: { [weak self] in self?.updater.showAvailableUpdate() },
        automaticUpdates: { [weak self] in self?.updater.automaticallyChecks ?? false },
        setAutomaticUpdates: { [weak self] on in self?.updater.automaticallyChecks = on }
    )

    /**
     Guided setup, in its own window.

     A window rather than a sheet on the settings window, because the popover offers it
     when the settings window does not exist — and opening a whole control panel just to
     hang a sheet on it is a lot of furniture for four checkboxes.
     */
    @objc func showSetup() {
        if setupWindow == nil {
            setupWindow = SetupWindowController(commands: commands, board: board, setup: setup)
        }
        setupWindow?.show()
    }

    @objc func showMainWindow() {
        if mainWindow == nil {
            mainWindow = MainWindowController(board: board, commands: commands, updater: updater, setup: setup)
        }
        mainWindow?.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no app switcher entry, until a window opens. The menu bar is
        // the whole surface the rest of the time.
        NSApp.setActivationPolicy(.accessory)

        // Installed at launch, not when a window opens: building it lazily leaves the
        // first window on screen with an empty menu bar for a frame.
        AppMenu.install(target: self, openSettings: #selector(showMainWindow))

        let created = BoardController(model: board)
        created.openSettings = { [weak self] in self?.showMainWindow() }
        controller = created
        created.start()
        battery.start()

        /*
         Open setup on the very first launch, and only then.

         The app is `.accessory`: no Dock icon, no window, nothing in the app switcher.
         So a first run looked exactly like a failed one — you double-click the app you
         just downloaded and the only evidence it worked is a new icon among the twenty
         already in your menu bar. Every later step was discoverable; this one asked you
         to guess that anything had happened at all.

         Once only. An install that is *unfinished* already says so in the popover, and
         a window that reopens every launch until you comply is a nag rather than a
         welcome — someone who chose to defer has made a decision worth respecting.
        */
        if isFirstLaunch {
            Log.write("setup: first launch — opening setup")
            showSetup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        battery.stop()
        controller?.stop()
    }

    /// Closing the settings window is not quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /**
     Opening the app when it is already running shows Settings.

     Without this, double-clicking OpenBoard in Finder — or `open -a OpenBoard` — does
     nothing at all, because the app is already up and has no windows to restore. That
     reads as the app being broken, and it is the first thing anyone tries when they
     cannot find a menu bar item among twenty others.
     */
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }
}

/**
 The status item: six live dots, one per session key.

 No count and no text — the pad is the thing you look at, and this is its shadow. The
 dots carry state by color exactly as the keys do, so a glance at either answers the
 same question.

 It swaps to a single pulsing warning glyph when the pad is unusable, because at that
 point every dot would be a lie about hardware that is not listening.
 */
struct StatusItemLabel: View {
    @EnvironmentObject private var board: BoardModel

    var body: some View {
        // Image, not shapes: MenuBarExtra's label only reliably renders Text and
        // Image. See StatusItemImage for what that cost to find out.
        Image(nsImage: StatusItemImage.make(slots: board.slots, usable: board.device.isUsable))
    }
}

extension Color {
    /// Bridge a hardware color to SwiftUI without letting it become a theme color.
    init(_ rgb: RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

extension RGB {
    /**
     The other direction, for `ColorPicker`.

     Converted through **sRGB explicitly**. A picked color can arrive in the display's
     own wide-gamut space, and reading its components raw would send the device numbers
     that mean a different color than the one on screen — the swatch and the key would
     disagree, which is the one thing the color model here must never do.

     Returns nil if the conversion fails rather than substituting a color, so a failure
     leaves the existing value alone instead of silently repainting the ring.
     */
    init?(_ color: Color) {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) -> UInt32 in
            UInt32(max(0, min(255, (value * 255).rounded())))
        }
        self.init(
            channel(converted.redComponent) << 16
                | channel(converted.greenComponent) << 8
                | channel(converted.blueComponent)
        )
    }
}
