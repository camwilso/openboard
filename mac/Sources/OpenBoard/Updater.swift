import Foundation
import Sparkle
import SwiftUI
import OpenBoardKit

/**
 In-app updates.

 ## Why an updater at all, rather than "download the new one"

 This app holds Input Monitoring and Accessibility grants, and macOS ties both to the
 bundle's path *and* its code signature. Sparkle replaces the bundle in place, under
 the same Developer ID, so the grants survive an update and the user is never sent back
 to System Settings. Dragging a fresh copy over the old one usually works and sometimes
 does not — a `.app` that arrived in Finder is quarantined, and a partially replaced
 bundle is a signature that matches nothing.

 The same argument covers the two other pieces of state that point at the bundle by
 path: the login-item registration, and the `openboard-hook` command written into
 `~/.claude/settings.json`. An in-place update leaves both correct. Anything that moves
 the bundle breaks both silently — the app still launches, and nothing ever lights.

 ## Why it can be off

 `SUPublicEDKey` is empty in a local build, because signing the feed needs a private key
 that lives on one machine. Starting the updater without it produces a check that fails
 every time with a signature error nobody can act on, so the updater simply does not
 start. `isEnabled` is what the UI asks rather than hiding the failure behind a button
 that does nothing.
 */
@MainActor
final class Updater: ObservableObject {
    /// Mirrors the controller so SwiftUI can disable the button while a check is in
    /// flight. Sparkle publishes this on the updater; it is republished here so the
    /// view does not have to import Sparkle.
    @Published private(set) var canCheck: Bool = false

    /// Whether this build can check at all — see the note on `SUPublicEDKey` above.
    ///
    /// Static because the answer is a property of the bundle, not of any instance, and
    /// the UI needs it while building the command table before an updater exists.
    static var isAvailable: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").isEmpty
    }

    private let controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    init() {
        guard Self.isAvailable else {
            controller = nil
            Log.write("updates: disabled — this build has no SUPublicEDKey (local build)")
            return
        }

        // `startingUpdater: true` schedules the background check on Sparkle's own
        // timer, which respects SUScheduledCheckInterval from Info.plist. There is no
        // reason to hand-roll that: it already handles a machine that was asleep at the
        // appointed hour, which a naive timer does not.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        if let updater = controller?.updater {
            canCheck = updater.canCheckForUpdates
            observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.canCheck = value }
            }
        }
    }

    /**
     Check now, because the user asked.

     `NSApp.activate` first, and it is not cosmetic. The app runs as `.accessory` with
     no Dock icon, so Sparkle's window opens behind whatever is frontmost — the user
     clicks Check for Updates, nothing appears to happen, and the dialog is discovered
     ten minutes later underneath a terminal.
     */
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Whether Sparkle is checking on its own schedule. Two-way so the settings toggle
    /// can drive it; Sparkle persists the answer in user defaults itself.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    /// When Sparkle last completed a check, for the settings row. Nil before the first.
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}
