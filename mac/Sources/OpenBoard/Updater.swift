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
 start. `isAvailable` is what the UI asks rather than hiding the failure behind a button
 that does nothing.

 ## Why this tracks its own state

 Sparkle drives its own windows, and for the *user-initiated* check that is the whole
 job — you click, a dialog appears. But a background check that quietly finds something
 has nowhere to say so, and this app is a menu bar item with no Dock badge to mark. The
 status published here is what lets the popover mention an update without Sparkle
 needing to interrupt anybody.
 */
@MainActor
final class Updater: NSObject, ObservableObject {
    /**
     What the UI is allowed to say about updates.

     `notChecked` and `upToDate` are deliberately distinct. "Never checked this launch"
     and "checked, nothing there" look the same in a status line that only knows a
     boolean, and the difference is the whole question when someone is wondering why
     they have not been offered a version they know exists.
     */
    enum Status: Equatable {
        case disabled
        case notChecked
        case checking
        case upToDate
        case available(version: String)
        case failed(String)

        var updateVersion: String? {
            if case .available(let v) = self { return v }
            return nil
        }

        /// Only a genuine failure is worth colouring red. "Disabled" is a property of
        /// the build, not a fault, and a local build showing an error every launch
        /// would train people to ignore the line.
        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status
    @Published private(set) var lastCheck: Date?

    /// Whether this build can check at all — see the note on `SUPublicEDKey` above.
    ///
    /// Static because the answer is a property of the bundle, not of any instance, and
    /// the UI needs it while building the command table before an updater exists.
    static var isAvailable: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").isEmpty
    }

    private var controller: SPUStandardUpdaterController?

    override init() {
        status = Self.isAvailable ? .notChecked : .disabled
        super.init()

        guard Self.isAvailable else {
            Log.write("updates: disabled — this build has no SUPublicEDKey (local build)")
            return
        }

        // `startingUpdater: true` schedules the background check on Sparkle's own timer,
        // which respects SUScheduledCheckInterval from Info.plist. There is no reason to
        // hand-roll that: it already handles a machine that was asleep at the appointed
        // hour, which a naive timer does not.
        //
        // Passing self as the updater delegate is what makes the background check
        // visible — without it, a check that finds an update on a timer has no way to
        // tell the popover.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        lastCheck = controller?.updater.lastUpdateCheckDate
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
        status = .checking
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /**
     Show the update Sparkle already found.

     The same call as `checkForUpdates` — Sparkle has the appcast item cached, so this
     reopens its dialog rather than making a second request. Distinct method because the
     caller's intent is different and the status line should not flick through
     "checking" for something already known.
     */
    func showAvailableUpdate() {
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
}

// MARK: - SPUUpdaterDelegate
//
// Sparkle documents these as called on the main thread, and the type is @MainActor, so
// the isolation lines up without a hop. Worth stating because it is load-bearing: these
// assign to @Published properties, and if Sparkle ever called one off the main thread
// the failure would be a SwiftUI update from the wrong actor rather than anything that
// names the cause.

extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available(version: item.displayVersionString)
        lastCheck = updater.lastUpdateCheckDate
        Log.write("updates: \(item.displayVersionString) available")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        // Not an error worth surfacing: "no update found" arrives here as one, and
        // saying so would turn the ordinary case into a red status line.
        status = .upToDate
        lastCheck = updater.lastUpdateCheckDate
    }

    /**
     The end of every check, successful or not.

     This is where a *real* failure surfaces — no network, a feed that will not parse, a
     signature that does not verify. The message is kept rather than reduced to a
     boolean because "could not connect" and "signature did not verify" want very
     different responses, and only one of them is the user's problem.
     */
    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        lastCheck = updater.lastUpdateCheckDate
        guard let error else {
            // An update that was found stays found — the cycle finishing cleanly after
            // the user dismissed the dialog must not reset the popover to "up to date".
            if case .available = status {} else { status = .upToDate }
            return
        }
        let code = (error as NSError).code
        // The user closing the dialog is not a failure.
        if code == Int(Sparkle.SUError.noUpdateError.rawValue) {
            status = .upToDate
            return
        }
        if code == Int(Sparkle.SUError.installationCanceledError.rawValue) { return }
        status = .failed(error.localizedDescription)
        Log.write("updates: check failed — \(error.localizedDescription)")
    }
}
