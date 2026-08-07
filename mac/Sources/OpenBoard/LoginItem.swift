import Foundation
import ServiceManagement
import OpenBoardKit

/**
 Start at login.

 An ambient status board that you have to remember to launch is not ambient. This is
 the difference between a tool you glance at and a tool you first have to think about.

 ## `SMAppService` rather than a login-item plist

 The old approach — a `LaunchAgents` plist, or `SMLoginItemSetEnabled` — is deprecated
 and, worse, invisible: it leaves state in a place the user cannot easily inspect or
 revoke. `SMAppService.mainApp` registers the running bundle itself, so it appears in
 System Settings → General → Login Items under OpenBoard's own name, and can be turned
 off there without touching the app.

 ## The catch worth knowing

 Registration is tied to the bundle **path and code signature**. Move the app, or
 rebuild it with a different identity, and the registration goes stale — macOS reports
 `.notFound` or silently stops launching it. That is the same class of failure as the
 stale hook path, and it is checked the same way: the status is read live rather than
 remembered.
 */
enum LoginItem {
    enum Status: Equatable {
        case enabled
        case disabled
        /// Registered, but macOS is waiting for the user to approve it in System
        /// Settings. Distinct from disabled: the user has already said yes here, and
        /// telling them to click the toggle again is wrong.
        case awaitingApproval
        case unavailable(String)

        var isOn: Bool { self == .enabled }
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .awaitingApproval
        case .notFound:
            // The registration points at a bundle that is not there any more.
            .unavailable("the registered copy of OpenBoard is missing — re-enable to fix")
        @unknown default: .unavailable("unknown status")
        }
    }

    /// Only ever called from an explicit toggle. Registering something to run at login
    /// without being asked is not a decision an app gets to make.
    @discardableResult
    static func set(_ enabled: Bool) -> Result<Status, Error> {
        do {
            if enabled {
                // Registering when already registered throws rather than being a no-op,
                // and that error is not a failure worth showing anyone.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(status)
        } catch {
            return .failure(error)
        }
    }

    /// Whether this build can be registered at all.
    ///
    /// A bundle running from a build directory can be registered, but the registration
    /// breaks the moment the directory is cleaned — so it is worth saying that the app
    /// should live in /Applications first.
    static var isInstalledProperly: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }
}
