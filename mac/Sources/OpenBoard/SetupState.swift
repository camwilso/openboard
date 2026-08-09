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

    /// The board, for the calibration step. Weak because the delegate owns both and a
    /// strong reference here would be a cycle for the lifetime of the app.
    private weak var board: BoardModel?

    init(board: BoardModel? = nil) {
        self.board = board
        refresh()
    }

    var isReady: Bool { progress.isReady }

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
            }
        }
    }
}
