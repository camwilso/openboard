import Foundation

/**
 Whether dictation is running, believed *and corroborated*.

 The belief half is unchanged from the board's beginning: a voice key was pressed, so
 recording probably started. Claude Code reports nothing back — no hook, no state
 file, and the transcript records a dictated prompt as `typed` — so the press is still
 the only way to know recording was *asked for*.

 What changed is the end. The microphone's own running state (CoreAudio's
 "is running somewhere", the truth behind the orange menu-bar dot — see `MicActivity`)
 says whether *anything* is actually recording. The light requires both — and the mic
 is the half that actually paints:

 - **A beginning.** The light stays dark until the mic starts. A tap with text
   already in the chat input types a space and never starts dictation — the mic
   stays off, and the ring never responded to a recording that never happened. The
   cost is the mic's spin-up: the rainbow arrives a beat after a real tap, not on it.
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
    /// The mic has been seen running during this belief. This is what lights the
    /// ring, and it is sticky: it also decides how the belief may end (mic stop
    /// ends it; grace expiry no longer can).
    public private(set) var micConfirmed = false

    /// How long a fresh belief waits for the mic to start. Long enough for
    /// dictation's spin-up, after which the tap is judged to have typed a space.
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
        // Dark until the mic actually starts. An unconfirmed belief is a request,
        // not a recording.
        return micConfirmed
    }

    /// Whether an unconfirmed belief is still inside its window for the mic to
    /// start. Once this is false the belief is dead weight, kept only until the
    /// owner sweeps it.
    public func isAwaitingMic(now: Date = Date()) -> Bool {
        guard let since, !micConfirmed else { return false }
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

    /// Feed a mic transition. Returns a log-worthy reason when the transition
    /// changes what the ring should show, nil when nothing user-visible changed.
    public mutating func micChanged(running: Bool, now: Date = Date()) -> String? {
        guard since != nil else { return nil }
        if running {
            // Confirmation is only accepted while the belief is still waiting for
            // it. A mic that starts after the grace window judged the tap dead is
            // someone else's recording — a call beginning minutes later must not
            // resurrect it.
            guard isAwaitingMic(now: now) else { return nil }
            micConfirmed = true
            return "mic started"
        }
        // Only a *confirmed* belief ends on mic-stop: an unconfirmed one may see a
        // stop from some other app releasing the mic before dictation ever started,
        // and the grace window is already the judge of that case.
        guard micConfirmed else { return nil }
        end()
        return "mic stopped"
    }
}
