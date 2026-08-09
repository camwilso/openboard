import Foundation
import OpenBoardKit
import SwiftUI

/**
 One answer to "is this install finished", shared by everything that asks.

 Three surfaces need it — the popover decides whether to show the board at all, the
 settings panes decide whether they can mean anything, and the setup window is the list
 itself. Each of them probing independently would be three chances to disagree, and the
 one that disagreed would be the one showing a board that cannot paint or a colour
 picker that saves into the void.

 Refreshed on demand rather than polled. Every input changes outside this app — TCC in
 System Settings, hooks in a file, calibration in a sheet — so there is no event to
 subscribe to, and a timer would mean the answer is stale for exactly as long as someone
 is standing in System Settings waiting for it to notice.
 */
@MainActor
final class SetupState: ObservableObject {
    @Published private(set) var progress = SetupProgress(done: [])

    /// Setup just finished, and has never finished before. Drives the one-time
    /// congratulation — the moment worth marking, because everything up to it has been
    /// obligations and the next thing is the first one that is actually a choice.
    @Published var justCompleted = false

    /// The board, for the calibration step. Weak because the delegate owns both and a
    /// strong reference here would be a cycle for the lifetime of the app.
    private weak var board: BoardModel?

    init(board: BoardModel? = nil) {
        self.board = board
        refresh()
    }

    var isReady: Bool { progress.isReady }

    /**
     Whether the finished-setup moment has already been shown.

     A file in the state directory rather than UserDefaults, and that is deliberate:
     OPENBOARD_HOME redirects the state directory, so tools/test-onboarding.sh gets a
     genuinely fresh install — including this. A UserDefaults key would survive the
     scratch directory and quietly make the rehearsal untestable in exactly the place it
     is most needed.
     */
    private static var completionMarker: URL {
        AppPaths.state().appendingPathComponent(".setup-complete")
    }

    private static var completionSeen: Bool {
        FileManager.default.fileExists(atPath: completionMarker.path)
    }

    /// Written when the moment has actually been *shown*, not when it is detected.
    /// `refresh()` runs from the popover too, and marking it there would burn the one
    /// occasion on a window nobody had open.
    func markCompletionSeen() {
        try? Data().write(to: Self.completionMarker)
        justCompleted = false
    }

    func refresh() {
        let permissions = PermissionProbe.inspect()
        let hooks = HookInstall.audit(
            settings: HookInstall.loadSettings(),
            expectedCommand: HookInstall.hookCommandPath()
        )
        progress = SetupProgress(
            inputMonitoring: permissions.inputMonitoring,
            accessibility: permissions.accessibility,
            systemEvents: permissions.automation["System Events"] ?? .unknown,
            calibrationConfirmed: board?.isCalibrationConfirmed ?? false,
            hooksHealthy: hooks.isHealthy,
            opensAtLogin: LoginItem.status.isOn
        )
        noteCompletionIfNew()

        // System Events sleeps, and a sleeping helper reads as "cannot tell" rather
        // than as the grant it holds — which would block the board on a permission the
        // user has already given.
        if permissions.automation["System Events"] == .unavailable {
            Task { [weak self] in
                await AutomationRequest.wakeProbeableTargets()
                guard let self else { return }
                let woken = PermissionProbe.inspect()
                self.progress = SetupProgress(
                    inputMonitoring: woken.inputMonitoring,
                    accessibility: woken.accessibility,
                    systemEvents: woken.automation["System Events"] ?? .unknown,
                    calibrationConfirmed: self.board?.isCalibrationConfirmed ?? false,
                    hooksHealthy: hooks.isHealthy,
                    opensAtLogin: LoginItem.status.isOn
                )
                self.noteCompletionIfNew()
            }
        }
    }

    /// Fires once, ever. Gated on the *required* steps rather than every row: Open at
    /// login is a choice, and someone who declines it has still finished setting up —
    /// withholding the moment until they change their mind would be a strange reward.
    private func noteCompletionIfNew() {
        guard progress.isReady, !Self.completionSeen else { return }
        guard !justCompleted else { return }
        justCompleted = true
        Log.write("setup: complete")
    }
}
