import Foundation
import OpenBoardKit

/**
 The permission list has to keep up with what the app actually uses.

 Adding a capability and not adding its permission is a silent failure by construction:
 the pane exists precisely to say which grant is missing, so a grant it does not know
 about cannot be reported. Bluetooth was added for the battery readout and initially
 missed here.
 */
func runPermissionCoverageTests() {
    test("every permission the app needs is in the report") {
        let report = PermissionProbe.inspect()
        // Reading the pad, posting input, and reading its battery. If a capability is
        // added without a probe, this is the test that should have to change.
        _ = report.inputMonitoring
        _ = report.accessibility
        _ = report.bluetooth
        expect(report.automation.keys.contains("Terminal"))
        expect(report.automation.keys.contains("QuickTime Player"))
    }

    test("Bluetooth is not required for the board to work") {
        // It only buys the battery readout. Gating readiness on it would tell someone
        // their board is broken when every key is lighting correctly.
        let noBluetooth = PermissionProbe.Report(
            inputMonitoring: .granted, accessibility: .granted, bluetooth: .denied,
            automation: [:], checkedAt: Date()
        )
        expect(noBluetooth.coreIsReady)
        expect(noBluetooth.missing.contains("Bluetooth"), "it should still be listed")
    }

    test("a missing core permission is still reported as not ready") {
        let noInput = PermissionProbe.Report(
            inputMonitoring: .denied, accessibility: .granted, bluetooth: .granted,
            automation: [:], checkedAt: Date()
        )
        expect(!noInput.coreIsReady)
        expectEqual(noInput.missing, ["Input Monitoring"])
    }
}

/**
 "Not asked" and "cannot ask" are different answers.

 Automation is the only permission macOS answers about a *running* target, and System
 Events is a launch-on-demand helper it shuts down when idle. So a granted permission
 reported as an orange "not asked" — for a reason that has nothing to do with the grant
 and nothing the user can act on.
 */
func runPermissionStatusTests() {
    test("only a real problem counts as missing") {
        let report = PermissionProbe.Report(
            inputMonitoring: .granted,
            accessibility: .granted,
            bluetooth: .granted,
            automation: [
                "System Events": .unavailable,   // asleep, almost certainly granted
                "Terminal": .granted,
                "QuickTime Player": .denied,
            ],
            checkedAt: Date()
        )
        expectEqual(report.missing, ["Automation → QuickTime Player"])
        expect(report.coreIsReady, "automation must not gate lighting or keys")
    }

    test("a target that has never been asked is still surfaced") {
        // The case that is genuinely actionable, and must not be swallowed by the fix
        // for the case that is not.
        expect(PermissionProbe.Status.unknown.isProblem)
        expect(PermissionProbe.Status.denied.isProblem)
        expect(!PermissionProbe.Status.unavailable.isProblem)
        expect(!PermissionProbe.Status.granted.isProblem)
    }

    test("a running target answers, and the answer is not unavailable") {
        // System Events is running by the time this runs — any AppleScript starts it,
        // and this test suite is launched from a shell session that has used one. If it
        // is genuinely absent the probe is allowed to say so.
        guard isRunning("System Events.app") else {
            skip("System Events is not running")
            return
        }
        let status = PermissionProbe.automation(bundleID: "com.apple.systemevents")
        expect(
            status != .unavailable,
            "System Events is running but the probe still cannot see it"
        )
    }
}

/// Whether a process is running. Kept local to the test: the app has no reason to ask,
/// and a helper in shipping code that only tests use is dead weight in the binary.
///
/// The first version of this returned the opposite of its name and was then negated at
/// the call site, so the assertion ran only when it could not hold — and passed for a
/// week because System Events happened to be up, which made it skip.
private func isRunning(_ pattern: String) -> Bool {
    let output = Process()
    output.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    output.arguments = ["-f", pattern]
    let pipe = Pipe()
    output.standardOutput = pipe
    output.standardError = FileHandle.nullDevice
    try? output.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    output.waitUntilExit()
    return !data.isEmpty
}
