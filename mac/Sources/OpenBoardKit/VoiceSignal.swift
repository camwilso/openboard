import Foundation

/**
 Whether dictation is running, believed *and corroborated*.

 The belief half is unchanged from the board's beginning: a voice key was pressed, so
 recording probably started. Claude Code reports nothing back — no hook, no state
 file, and the transcript records a dictated prompt as `typed` — so the press is still
 the only way to know recording was *asked for*.

 What changed is the end. The microphone's own running state (CoreAudio's
 "is running somewhere", the truth behind the orange menu-bar dot — see `MicActivity`)
 says whether *anything* is actually recording. That gives the belief two things it
 never had:

 - **Confirmation.** A tap with text already in the chat input types a space and never
   starts dictation. The mic stays off, the grace window expires, and the light goes
   out instead of lying for three minutes.
 - **An ending.** Recording stopped by a second tap, Escape, submit, or anything else
   stops the mic — and the light follows within a beat, instead of waiting for a
   timeout to guess.

 The mic is system-wide, not per-app, so the conjunction is deliberate: the light
 needs both the belief (we asked) and the mic (something is recording). A video call
 alone never lights it. A video call *during* dictation keeps the mic running after
 dictation ends — then the old bounds still apply, so the light is never worse than
 the belief-only version was.

 Pure and clock-injected so every transition is testable; `BoardController` owns the
 wiring and the repaints.
 */
public struct VoiceSignal: Sendable, Equatable {
    /// When the belief began — a voice key was pressed. `nil` is off.
    public private(set) var since: Date?
    /// The mic has been seen running during this belief. Confirmation is sticky:
    /// it decides how the belief may *end* (mic stop ends it; grace no longer can).
    public private(set) var micConfirmed = false

    /// How long a fresh belief may show without the mic starting. Long enough for
    /// dictation's spin-up, short enough that a tap that never started anything is a
    /// blink rather than a lie.
    public var grace: TimeInterval
    /// The old absolute backstop, kept for the degraded case where another app holds
    /// the mic open past dictation's end and a stop can never be observed.
    public var limit: TimeInterval

    public init(grace: TimeInterval = 3, limit: TimeInterval = 180) {
        self.grace = grace
        self.limit = limit
    }

    public func isActive(now: Date = Date()) -> Bool {
        guard let since else { return false }
        guard now.timeIntervalSince(since) < limit else { return false }
        if micConfirmed { return true }
        // Waiting for the mic to spin up — or for the grace window to admit it never
        // will.
        return now.timeIntervalSince(since) < grace
    }

    public mutating func begin(now: Date = Date()) {
        since = now
        micConfirmed = false
    }

    public mutating func end() {
        since = nil
        micConfirmed = false
    }

    /// Feed a mic transition. Returns a log-worthy reason when the transition ends
    /// the belief, nil when nothing user-visible changed.
    public mutating func micChanged(running: Bool, now: Date = Date()) -> String? {
        guard since != nil else { return nil }
        if running {
            // Confirmation is only accepted while the belief still shows. A mic that
            // starts after the grace window judged the tap dead is someone else's
            // recording — a call beginning minutes later must not resurrect it.
            if isActive(now: now) { micConfirmed = true }
            return nil
        }
        // Only a *confirmed* belief ends on mic-stop: an unconfirmed one may see a
        // stop from some other app releasing the mic before dictation ever started,
        // and the grace window is already the judge of that case.
        guard micConfirmed else { return nil }
        end()
        return "mic stopped"
    }
}
