import AppKit
import Foundation
import OpenBoardKit

/**
 Asking macOS for Automation consent, for targets that are not running.

 ## Why this is more than one call

 Automation has no "request access" API. macOS raises the consent dialog when something
 tries to drive the target, and `AEDeterminePermissionToAutomateTarget(askUserIfNeeded:)`
 is that attempt without the side effect of sending a real command. But it can only ask
 about a *running* process: System Events is launch-on-demand and QuickTime Player is
 not running unless you opened it, so the honest answer for both is usually "cannot
 tell", and no dialog ever appears.

 So the sequence is: start the target, ask, put it back. Each step exists because
 skipping it produces a permission that can never be granted from inside the app —
 which is how these two rows sat at "not running" indefinitely with an Open button that
 led to a System Settings pane where OpenBoard was not yet listed.

 ## Leaving things as they were found

 A target this launched is quit again afterwards; a target that was already running is
 left alone. Quitting QuickTime out from under someone watching a video would be a
 worse bug than the permission it was fixing.

 QuickTime is launched hidden and without activation. It still briefly exists — there
 is no way to drive an app that is not running — but it does not steal focus, and it is
 gone by the time the sheet closes.
 */
@MainActor
enum AutomationRequest {
    /// One target's outcome, for the summary the UI shows afterwards.
    struct Result: Equatable {
        let name: String
        let status: PermissionProbe.Status
    }

    /**
     Walk every automation target that is not already granted and ask for each.

     Sequential rather than concurrent, deliberately: these raise system dialogs, and
     two at once stack on top of each other with no indication that answering one leaves
     another behind it.
     */
    static func requestAll(
        targets: [(name: String, bundleID: String)] = PermissionProbe.automationTargets,
        current: [String: PermissionProbe.Status]
    ) async -> [Result] {
        var results: [Result] = []
        for target in targets {
            if current[target.name]?.isGranted == true {
                results.append(Result(name: target.name, status: .granted))
                continue
            }
            results.append(Result(name: target.name, status: await request(target)))
        }
        return results
    }

    private static func request(_ target: (name: String, bundleID: String)) async -> PermissionProbe.Status {
        let wasRunning = isRunning(bundleID: target.bundleID)
        if !wasRunning {
            guard await launchQuietly(bundleID: target.bundleID) else {
                Log.write("automation: could not launch \(target.name) to ask for consent")
                return .unavailable
            }
        }

        // Off the main thread: the call blocks for as long as the dialog is up, and
        // blocking the main thread behind a dialog this app is responsible for is a
        // hang, not a wait.
        let status = await Task.detached(priority: .userInitiated) {
            PermissionProbe.requestAutomation(bundleID: target.bundleID)
        }.value

        Log.write("automation: \(target.name) -> \(status.rawValue)")

        if !wasRunning { quit(bundleID: target.bundleID) }
        return status
    }

    private static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /**
     Start the target without it taking over the screen.

     System Events has no interface and appears nowhere. QuickTime Player does, so it is
     hidden and not activated — the window exists for the second or two this takes and
     never comes forward.
     */
    private static func launchQuietly(bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false

        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            Log.write("automation: launching \(bundleID) failed — \(error.localizedDescription)")
            return false
        }

        // Registering with the Apple Event system trails the process existing, so
        // asking immediately gets procNotFound for an app that did start. Poll rather
        // than sleep a flat guess: usually one pass, and never longer than it needs.
        for _ in 0..<20 {
            if isRunning(bundleID: bundleID) {
                try? await Task.sleep(for: .milliseconds(150))
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// `terminate`, not `forceTerminate`: this is an app that was not running a moment
    /// ago and has nothing to save, and forcing it would be rude for no gain.
    private static func quit(bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }
}
