import Foundation
import OpenBoardKit

/**
 Hold a key down — space for dictation, or any recorded chord — with the safety the
 raw key events do not have.

 ## Why this is its own type

 `keyDown` without a matching `keyUp` is **OS-level state that outlives this process**.
 Miss the release — a dropped HID report, a crash, a quit mid-hold, the pad going out
 of Bluetooth range — and space is logically held down across the entire machine. Every
 keystroke afterwards carries it, and nothing on screen explains why. The user's next
 move is to reboot.

 So the hold is never trusted to end on its own:

 - a **timer** releases it after `maxHoldSeconds` whether or not the release arrives
 - **quitting** releases it, so a crash-adjacent path still cleans up
 - a second `down` while already held is **not** a second hold

 The Node version documented this danger and then shipped tap-only, which is the safe
 default and also the reason `voiceTalk` silently behaved like `voiceTap` — a binding
 the picker offered and did not honour.
 */
@MainActor
final class PushToTalk {
    private let log: (String) -> Void
    private var releaseTask: Task<Void, Never>?
    /// What is down, and which pad key put it there. Only that key's release ends it;
    /// otherwise any other key's release would end the dictation.
    private var holding: Shortcut?
    private(set) var heldBy: String?
    var isHeld: Bool { holding != nil }
    private var heldSince: Date?

    /// The backstop. Long enough not to cut off real dictation, short enough that a
    /// missed release is an annoyance rather than a mystery.
    var maxHoldSeconds: Int = 60

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// Begin a hold. Idempotent: a repeat `down` extends nothing and starts nothing.
    func begin(_ shortcut: Shortcut = .space, key: String) {
        guard !isHeld else {
            log("hold: already held, ignoring a second press")
            return
        }
        let result = Actions.hold(shortcut, down: true)
        guard result.ok else {
            log("hold: could not press \(shortcut.label) — \(result.detail)")
            return
        }
        holding = shortcut
        heldBy = key
        heldSince = Date()
        log("hold: \(shortcut.label) down")

        releaseTask?.cancel()
        releaseTask = Task { [weak self, maxHoldSeconds] in
            try? await Task.sleep(for: .seconds(maxHoldSeconds))
            guard !Task.isCancelled else { return }
            guard let self, self.isHeld else { return }
            // The release never came. Say so loudly: a hold that ends by timeout means
            // an event was lost, and the user needs to know their key is unreliable
            // rather than discovering it through corrupted typing later.
            self.log("hold: NO RELEASE after \(maxHoldSeconds)s — releasing anyway")
            self.end(reason: "timeout")
        }
    }

    /// End a hold. Safe to call when nothing is held.
    func end(reason: String = "released") {
        releaseTask?.cancel()
        releaseTask = nil
        guard let shortcut = holding else { return }
        holding = nil
        heldBy = nil

        let result = Actions.hold(shortcut, down: false)
        let duration = heldSince.map { Date().timeIntervalSince($0) } ?? 0
        heldSince = nil
        log(result.ok
            ? String(format: "hold: %@ up after %.1fs (%@)", shortcut.label, duration, reason)
            : "hold: COULD NOT RELEASE \(shortcut.label) — \(result.detail)")
    }

    /// Called on quit. The whole point of the type.
    func releaseIfHeld() {
        guard isHeld else { return }
        end(reason: "app quitting")
    }
}
