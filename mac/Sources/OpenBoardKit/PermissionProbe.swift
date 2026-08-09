import Foundation
import IOKit.hid
import ApplicationServices
import CoreBluetooth

/**
 What the operating system will actually let this app do.

 Several separately-granted permissions, each producing a differently-shaped *silent*
 failure — and they do not imply one another: Input Monitoring and Bluetooth are both
 "talking to the pad" and are granted independently. The app cannot grant any of them, so the least it can do is say precisely
 which one is missing — the alternative is a board that looks fine and does nothing,
 which is how most of this project's support burden started.

 ## Two rules learned the hard way

 **Never ask a proxy.** The Node version first probed Accessibility with AppleScript's
 `UI elements enabled`, which reports *System Events'* trust, not the caller's. It
 returned a confident green while every keystroke this app sent was refused with
 error 1002. A probe that can report someone else's state is not a probe.

 **Never probe by doing.** The obvious test — post a keystroke, see if it lands — is
 the one thing that must not happen, because on an ungranted system it either triggers
 a permission prompt out of nowhere or types into whatever is frontmost. Every check
 below is read-only and prompt-free.
 */
public enum PermissionProbe {
    public enum Status: String, Sendable, Equatable {
        case granted, denied, unknown
        /**
         macOS cannot be asked right now — which is not the same as a missing grant.

         Automation is the only permission with this problem. `AEDeterminePermission‑
         ToAutomateTarget` answers about a *running* target, and System Events is a
         launch-on-demand helper that macOS shuts down when idle. So the row flipped
         between "granted" and an alarming orange depending on whether an Apple
         background process happened to be alive — nothing to do with the user's grant,
         and nothing they could act on.

         Reported distinctly so the UI can say "cannot tell" instead of "not asked",
         which reads as *denied by omission* and sends someone to a settings pane where
         the switch is already on.
         */
        case unavailable

        public var isGranted: Bool { self == .granted }
        /// Worth showing as a problem. `unavailable` is not: nothing is known to be
        /// wrong, and there is no action to take.
        public var isProblem: Bool { self == .denied || self == .unknown }
    }

    public struct Report: Sendable, Equatable {
        public let inputMonitoring: Status
        public let accessibility: Status
        public let bluetooth: Status
        public let automation: [String: Status]
        public let checkedAt: Date

        public init(
            inputMonitoring: Status,
            accessibility: Status,
            bluetooth: Status,
            automation: [String: Status],
            checkedAt: Date
        ) {
            self.inputMonitoring = inputMonitoring
            self.accessibility = accessibility
            self.bluetooth = bluetooth
            self.automation = automation
            self.checkedAt = checkedAt
        }

        /// Everything lighting and key handling needs. Automation is for the
        /// nice-to-have "jump to that chat", and Bluetooth only for the battery
        /// readout, so neither gates readiness.
        public var coreIsReady: Bool {
            inputMonitoring.isGranted && accessibility.isGranted
        }

        public var missing: [String] {
            var names: [String] = []
            if !inputMonitoring.isGranted { names.append("Input Monitoring") }
            if !accessibility.isGranted { names.append("Accessibility") }
            if !bluetooth.isGranted { names.append("Bluetooth") }
            // Only what is actually known to be a problem: an automation target that is
            // merely not running is not a missing permission.
            names += automation.filter { $0.value.isProblem }.keys.sorted().map { "Automation → \($0)" }
            return names
        }
    }

    /// Bundle ids the "jump to a chat" action drives.
    public static let automationTargets: [(name: String, bundleID: String)] = [
        ("System Events", "com.apple.systemevents"),
        ("Terminal", "com.apple.Terminal"),
        // Fun mode drives QuickTime, and reports a permission problem rather than
        // silently doing nothing when this is missing.
        ("QuickTime Player", "com.apple.QuickTimePlayerX"),
    ]

    /**
     Reading the pad — HID input, hence every light and every keypress.

     `IOHIDCheckAccess` is the direct question, and unlike opening the device it does
     not prompt. `.unknown` genuinely happens: the app has not been asked yet, and it
     is not the same as denied.
     */
    public static func inputMonitoring() -> Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .unknown
        }
    }

    /**
     Posting synthetic input — snippets, ⏎, ⎋, scrolling.

     `kAXTrustedCheckOptionPrompt: false` is load-bearing. Passing true turns a status
     check into a modal dialog, which would fire every time the Settings window opened.

     There is no tri-state here: the API cannot distinguish "denied" from "never asked".
     Both report untrusted, which is the right conservative answer either way — the app
     will be refused.
     */
    public static func accessibility() -> Status {
        // The constant itself is a global `var` in the SDK and so is not concurrency-safe
        // to reference; its value is this fixed string.
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
    }

    /**
     Reading the pad's battery.

     The battery lives in the standard GATT Battery Service, and reaching it means
     acting as a Bluetooth central — which macOS gates separately from Input Monitoring,
     even though both are "talking to the same device". Granting one says nothing about
     the other.

     `CBManager.authorization` is a plain read and does **not** prompt. Constructing a
     `CBCentralManager` is what prompts, which is why that happens after launch rather
     than during it — see `BatteryMonitor`.

     `.notDetermined` is reported as `.unknown` rather than denied: nobody has been
     asked yet, and the first popover will ask.
     */
    public static func bluetooth() -> Status {
        switch CBManager.authorization {
        case .allowedAlways: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }

    /**
     Driving another app by Apple event.

     `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false` asks TCC the
     question directly — no `osascript` subprocess, no 10-second timeout, and no prompt.

     `procNotFound` means the target is not running, which is not a permission answer,
     so it reports `.unknown` rather than a red that would send someone to a settings
     pane where the app is not even listed.
     */
    public static func automation(bundleID: String) -> Status {
        var target = AEAddressDesc()
        let created = bundleID.withCString { pointer in
            AECreateDesc(
                typeApplicationBundleID, pointer, strlen(pointer), &target
            )
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, false
        )
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        /*
         The target is not running, so there is nothing to ask about.

         System Events is the case that matters: macOS launches it on demand and stops
         it when idle, so this is the *usual* answer for a permission that is very often
         granted. Reporting it as "not asked" was simply wrong — sending any Apple event
         starts the process and the same probe then returns `granted`.
         */
        case OSStatus(procNotFound): return .unavailable
        // Genuinely no decision recorded yet. The first use will prompt.
        case OSStatus(errAEEventWouldRequireUserConsent): return .unknown
        default: return .unknown
        }
    }

    /**
     Ask for automation consent, showing the system dialog if there is no answer yet.

     The same call as `automation(bundleID:)` with the one flag flipped. That flag is
     the only way to raise the consent dialog: there is no "request access" API for
     Automation the way there is for the camera or the microphone. macOS shows it when
     something actually tries to drive the target, and this is that attempt, minus the
     side effect of sending a real command.

     **Blocks while the dialog is up.** Calling it on the main thread freezes the app
     behind a dialog it is itself responsible for — call it off the main thread and hand
     the result back.

     Still returns `.unavailable` for a target that is not running. The flag controls
     whether macOS *asks*, not whether it can ask about a process that does not exist,
     so the caller has to start the target first — see `AutomationRequest` in the app,
     which is where launching another application belongs.
     */
    public static func requestAutomation(bundleID: String) -> Status {
        var target = AEAddressDesc()
        let created = bundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, true
        )
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .unavailable
        // Should not survive askUserIfNeeded, but a user who dismisses the dialog
        // without choosing lands here rather than on a decision.
        case OSStatus(errAEEventWouldRequireUserConsent): return .unknown
        default: return .unknown
        }
    }

    /// Everything at once. Cheap enough to call whenever the pane appears — no
    /// subprocesses, no waiting.
    public static func inspect(now: Date = Date()) -> Report {
        var automations: [String: Status] = [:]
        for target in automationTargets {
            automations[target.name] = automation(bundleID: target.bundleID)
        }
        return Report(
            inputMonitoring: inputMonitoring(),
            accessibility: accessibility(),
            bluetooth: bluetooth(),
            automation: automations,
            checkedAt: now
        )
    }

    /// The System Settings pane that grants each one. Opening the right pane directly
    /// is most of the value: these are several levels deep and easy to confuse.
    public static func settingsURL(forPane pane: String) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}
