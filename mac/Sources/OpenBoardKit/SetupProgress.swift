import Foundation

/**
 What a new install still has to do, and how much of it is done.

 ## Why a checklist and not a wizard

 Granting Input Monitoring requires restarting the app. So does Accessibility. A linear
 "next, next, finish" flow is destroyed by its own first step — the process running the
 wizard is the process that has to die for the grant to take effect, and whatever page
 it was on dies with it.

 A checklist survives that. It is recomputed from the world every time it is shown, so
 quitting halfway through and coming back lands exactly where you were, and a user who
 already granted something months ago sees it ticked rather than being walked through
 it again.

 ## Why the steps are ordered but not gated

 `inputMonitoring` first because nothing lights without it, `hooks` last because it is
 the only one that changes a file. But none of them block the others: someone who wires
 hooks before granting anything has done a useful thing, and refusing the click would be
 pedantry. The order is advice.

 ## Why calibration counts

 The board runs on the order every pad so far reports, so an unchecked install lights
 perfectly well — which is exactly why this is easy to get wrong. Board and Colors let
 you assign a colour to *slot 3*, and if slot 3 is not the key you think it is, every
 choice you make there lands somewhere else. Ten seconds of confirming beats a
 configuration that is quietly wrong.

 ## What is not here

 Layer 1 and pairing the pad. Neither is detectable — the pad reports nothing about its
 layer, and "paired" is indistinguishable from "paired and asleep" — so presenting them
 as checkboxes would mean showing a permanent unticked box for something that may well
 be fine. They belong in the instructions beside the list, not in it.
 */
public struct SetupProgress: Equatable, Sendable {
    public enum Step: String, CaseIterable, Sendable {
        case inputMonitoring
        case accessibility
        case automation
        // After the permissions and before hooks, because it needs the first one:
        // the check paints six colours on the pad, which cannot happen until macOS
        // lets the app open it.
        case calibration
        case hooks
        case openAtLogin

        /// Whether the board is unusable without it. The recommended ones still appear
        /// — turning them off is a choice, and a choice is not made by hiding it — but
        /// they do not count against "ready".
        public var isRequired: Bool {
            switch self {
            case .inputMonitoring, .accessibility, .automation, .calibration, .hooks: true
            case .openAtLogin: false
            }
        }

        /// Whether granting it takes effect only after OpenBoard restarts. macOS reads
        /// these at launch, so the app has to be told to say so — a grant that appears
        /// to do nothing is the single most common reason someone concludes the app is
        /// broken and stops.
        public var needsRestart: Bool {
            switch self {
            case .inputMonitoring, .accessibility: true
            case .automation, .calibration, .hooks, .openAtLogin: false
            }
        }
    }

    public let done: Set<Step>

    public init(done: Set<Step>) {
        self.done = done
    }

    /**
     Work out what is left.

     Takes the answers rather than fetching them: the probes live in the app layer and
     touch TCC, the filesystem and ServiceManagement, none of which belong in something
     a test has to run a thousand times.
     */
    public init(
        inputMonitoring: PermissionProbe.Status,
        accessibility: PermissionProbe.Status,
        systemEvents: PermissionProbe.Status,
        calibrationConfirmed: Bool,
        hooksHealthy: Bool,
        opensAtLogin: Bool
    ) {
        var done: Set<Step> = []
        if inputMonitoring.isGranted { done.insert(.inputMonitoring) }
        if accessibility.isGranted { done.insert(.accessibility) }
        if systemEvents.isGranted { done.insert(.automation) }
        if calibrationConfirmed { done.insert(.calibration) }
        if hooksHealthy { done.insert(.hooks) }
        if opensAtLogin { done.insert(.openAtLogin) }
        self.done = done
    }

    public func isDone(_ step: Step) -> Bool { done.contains(step) }

    /// Everything required is done. Recommended steps are excluded on purpose — an
    /// install that works is finished, whatever the user decided about login items.
    public var isReady: Bool {
        Step.allCases.filter(\.isRequired).allSatisfy(done.contains)
    }

    /// For "3 of 4". Counts required steps only, so the number cannot stall at 4/5
    /// because someone declined to launch the app at login.
    public var requiredDone: Int {
        Step.allCases.filter { $0.isRequired && done.contains($0) }.count
    }

    public var requiredTotal: Int {
        Step.allCases.count(where: \.isRequired)
    }

    /// The next thing worth doing, or nil when the required work is finished. Ordered
    /// by the declaration order of `Step`, which is the order that makes sense to work
    /// through rather than the order they were written in.
    public var next: Step? {
        Step.allCases.first { $0.isRequired && !done.contains($0) }
    }
}
