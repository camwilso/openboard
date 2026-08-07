import Foundation
import OpenBoardKit

/**
 Fun mode's transport: play the video full-screen and drive the pad in time with it.

 ## Closed loop, not a timer

 Sync is measured against QuickTime's own playhead rather than run open-loop from a
 start timestamp. Over four minutes an open-loop timer drifts badly — and worse, it
 cannot tell that the video was paused, scrubbed or quit, so the lights would carry on
 dancing to nothing.

 ## This deliberately takes over the board

 Live agent status is overridden for the duration. It is a party trick, it was asked
 for, and the board is repainted when it ends.
 */
@MainActor
final class CountdownPlayer {
    private let device: HIDDevice
    private let log: (String) -> Void
    /// Called when the show ends, so the caller can repaint the real board.
    private let finished: () -> Void

    private var task: Task<Void, Never>?
    private(set) var isRunning = false
    /// Read once for the whole song. Reloading it per write cost six file reads a beat
    /// against a 504ms budget the write scheduling is already built to fit inside.
    private var calibration: Calibration?
    /// Held for the run, for the same reason as the calibration: both write paths need
    /// it on every beat, and neither is handed the preferences.
    private var gain: Double = 1

    init(
        device: HIDDevice,
        log: @escaping (String) -> Void,
        finished: @escaping () -> Void
    ) {
        self.device = device
        self.log = log
        self.finished = finished
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        log("fun mode: cancelled")
    }

    func start(preferences: Preferences) {
        guard !isRunning else { return }
        let configured = preferences.countdown.mediaDir
        let library = AppPaths.mediaLibrary()
        guard let media = Countdown.mediaDirectory(configured: configured) else {
            log("""
                fun mode: nothing to play. Put a folder holding a video and its \
                analysis.json in \(AppPaths.media().path)
                """)
            return
        }
        // Say which one, and say it every time: the choice is only obvious while there
        // is exactly one folder, and that stops being true the moment a second lands.
        if configured.isEmpty, library.count > 1 {
            log("""
                fun mode: playing \(media.lastPathComponent) — \(library.count) in the \
                library (\(library.joined(separator: ", "))). Set countdown.mediaDir to \
                pick another.
                """)
        }
        guard let analysis = Countdown.loadAnalysis(directory: media) else {
            log("fun mode: no analysis.json in \(media.path) — nothing to sync to")
            return
        }
        guard let video = Countdown.findVideo(directory: media) else {
            log("fun mode: no video in \(media.path)")
            return
        }
        log("fun mode: media from \(media.path)")

        let loaded = Calibration.loadDefault()
        calibration = loaded

        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(video: video, analysis: analysis, preferences: preferences)
            self.isRunning = false
            self.finished()
        }
    }

    // MARK: - the show

    private func run(video: URL, analysis: Countdown.Analysis, preferences: Preferences) async {
        let config = preferences.countdown
        gain = config.gain
        // Fire each cue early. A ring write measures ~86ms and a key write ~79ms on this
        // device, and audio output adds its own delay, so issuing a write when the beat
        // lands puts the light visibly behind the music.
        let lead = Double(config.leadMs) / 1000

        log(
            "fun mode: \(video.lastPathComponent) — \(analysis.bpm)bpm, "
                + "\(analysis.beats.count) beats, lead \(config.leadMs)ms, "
                // Logged because the lift is invisible in the code path and the symptom
                // of a wrong one — "the show looks flat" — reads as a choreography bug.
                + String(format: "lift %.2f×", gain)
        )

        // Blank the pad before the video appears, so the opening is genuinely dark.
        await blank()

        guard await QuickTime.open(video) else {
            log("fun mode: QuickTime would not open the video")
            await finish(cancelled: true)
            return
        }
        // Do not anchor until the playhead is actually moving: `play` returns before it
        // does, and anchoring to a stopped clock puts every cue in the wrong place.
        guard await QuickTime.waitForPlayback() != nil else {
            log("fun mode: playback never started")
            await finish(cancelled: true)
            return
        }
        guard var anchor = await QuickTime.anchorClock() else {
            log("fun mode: no playhead")
            await finish(cancelled: true)
            return
        }
        log(String(
            format: "fun mode: anchored at %.3fs (read rtt %dms)",
            anchor.media, Int(anchor.rtt * 1000)
        ))

        func mediaNow() -> Double {
            anchor.media + Date().timeIntervalSince(anchor.wall)
        }

        let introSec = config.introFlashSec
        let surges = Countdown.surgeList(analysis, introSec: introSec)
        var surgeIndex = 0
        // The ring is dark until the intro flash — no beat writes at all before then.
        var ringArmed = false
        var holdRingUntil = Date.distantPast

        // Say so, because a deliberately dark pad and a broken one look identical.
        // Thirteen seconds is a long time to watch nothing happen, and the natural
        // reading is "it isn't working" — which is exactly what happened: two runs
        // cancelled at 3 and 10 beats, both well before the pad was going to light.
        log(String(
            format: "fun mode: counting up on the keys until the intro flash at %.1fs "
                + "(~%d beats); the ring stays dark until then",
            introSec, Int(introSec / analysis.beatPeriod)
        ))

        var beatIndex = 0
        var flip = false
        var lastSync = Date()
        var reanchoring = false
        var closed = false
        var cancelled = false

        var vocalScaler = Countdown.LocalScaler()
        var bassScaler = Countdown.LocalScaler()
        var highScaler = Countdown.LocalScaler()
        // Only write a surface when its quantised value changes. With six keys plus the
        // ring at ~80ms a write, painting everything every beat needs ~560ms of a 504ms
        // beat and the lights fall permanently behind. Most beats change one or two.
        var lastWritten: [Int: String] = [:]

        while beatIndex < analysis.beats.count {
            // Checked every iteration rather than on the 3s sync tick, so a cancel feels
            // immediate rather than taking up to three seconds.
            if Task.isCancelled { cancelled = true; break }

            // Re-anchor WITHOUT blocking the loop. Awaiting a ~100ms read here stalled a
            // fifth of a 504ms beat every three seconds, which is visible as hitching.
            if !reanchoring, Date().timeIntervalSince(lastSync) > 3 {
                reanchoring = true
                lastSync = Date()
                Task { @MainActor in
                    if let next = await QuickTime.anchorClock(samples: 2) {
                        anchor = next
                    } else {
                        closed = true
                    }
                    reanchoring = false
                }
            }
            if closed {
                log("fun mode: video closed, stopping")
                break
            }

            // Skip beats the media clock has already passed, e.g. after a scrub forward.
            while beatIndex < analysis.beats.count,
                  analysis.beats[beatIndex].t < mediaNow() - 0.12 {
                beatIndex += 1
            }
            guard beatIndex < analysis.beats.count else { break }

            // Surges are not on beats, so they get their own check first.
            if surgeIndex < surges.count {
                let surge = surges[surgeIndex]
                let untilSurge = (surge.t - lead - mediaNow()) * 1000
                if untilSurge <= 200 {
                    // Two writes at ~86ms each, so the blackout begins ~200ms out.
                    // Going dark first is what makes a lift land — a bright-to-brighter
                    // change barely registers.
                    await writeRing(.off)
                    if surge.isIntro {
                        // The intro leaves a lit bar across the keys. Take it down with
                        // the ring so the flash comes out of black.
                        for slot in Countdown.allSlots {
                            await writeKey(
                                slot: slot, color: config.introColorKeys, brightness: 0,
                                lastWritten: &lastWritten
                            )
                        }
                    }
                    let remaining = (surge.t - lead - mediaNow())
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }
                    await writeRing(Appearance(
                        color: Countdown.surgeColor(
                            surge, analysis: analysis, introColor: config.introFlashColor
                        ),
                        effect: .solid,
                        brightness: Countdown.surgePunch(surge),
                        speed: 0
                    ))
                    log(surge.isIntro
                        ? String(format: "intro flash at %.2fs — ring live from here", surge.t)
                        : String(format: "surge %.2fs (+%.2f) — flash", surge.t, surge.jump))
                    surgeIndex += 1
                    ringArmed = true
                    // Beat writes are suppressed briefly after a flash so they cannot
                    // stomp on it.
                    holdRingUntil = Date().addingTimeInterval(0.26)
                    continue
                }
            }

            let beat = analysis.beats[beatIndex]
            let wait = (beat.t - lead - mediaNow()) * 1000
            if wait > 4 {
                // Sleep in short hops so a surge or a cancel is never slept through.
                var next = wait
                if surgeIndex < surges.count {
                    next = min(wait, (surges[surgeIndex].t - lead - mediaNow()) * 1000 - 200)
                }
                try? await Task.sleep(for: .milliseconds(Int(max(5, min(next, 120)))))
                continue
            }

            let hue = Countdown.hue(for: beat, analysis: analysis)

            // Dark before the first surge, and briefly protected after a flash.
            if ringArmed, Date() >= holdRingUntil {
                let frame = Countdown.ringFrame(
                    beat: beat, analysis: analysis, beatIndex: beatIndex, flip: flip
                )
                if frame.effect == .snake || frame.effect == .gradient { flip.toggle() }
                await writeRing(frame)
            }

            if !ringArmed {
                // Before the flash: the keys count, the ring stays dark. Six keys fill
                // left to right, the leading one breathing on the beat. Dim and cold on
                // purpose — this builds toward the flash and then loses to it.
                let frame = Countdown.introFrame(
                    progress: mediaNow() / introSec,
                    downbeat: beatIndex % 4 == 0,
                    brightness: config.introBrightness,
                    trail: config.introTrail
                )
                for (index, slot) in Countdown.allSlots.enumerated() {
                    await writeKey(
                        slot: slot, color: config.introColorKeys, brightness: frame[index],
                        lastWritten: &lastWritten
                    )
                }
                beatIndex += 1
                continue
            }

            let keys = Countdown.keyFrame(
                beat: beat,
                hue: hue,
                vocal: vocalScaler.scale(beat.v),
                bass: bassScaler.scale(beat.b),
                high: highScaler.scale(beat.h)
            )
            for key in keys {
                await writeKey(
                    slot: key.slot, color: key.color, brightness: key.brightness,
                    lastWritten: &lastWritten
                )
            }

            beatIndex += 1
        }

        log("fun mode: finished after \(beatIndex) beat(s)\(cancelled ? ", cancelled" : "")")
        await finish(cancelled: cancelled)
    }

    // MARK: - writes

    private func blank() async {
        await writeRing(.off)
        try? await device.write(batch: [device.prepare(
            lighting: CodexProtocol.LightingConfig(keys: .off, ambient: .off)
        )])
    }

    private func finish(cancelled: Bool) async {
        // Leaving a full-screen video up after cancelling is not cancelling.
        await QuickTime.close()
        if cancelled { await blank() }
    }

    private func writeRing(_ appearance: Appearance) async {
        let ambient = CodexProtocol.LightingSide(
            color: appearance.color,
            brightness: Countdown.lift(appearance.brightness, gain: gain),
            effect: CodexProtocol.Effect(rawValue: appearance.effect.deviceCode) ?? .solid,
            speed: appearance.speed
        )
        // rgbcfg carries a complete config, both sides. The key side stays off: the
        // per-key colors come from thstatus and the backlight would bury them.
        try? await device.write(batch: [device.prepare(
            lighting: CodexProtocol.LightingConfig(keys: .off, ambient: ambient)
        )])
    }

    private func writeKey(
        slot: Int, color: RGB, brightness: Double,
        lastWritten: inout [Int: String]
    ) async {
        // Lifted before the dedup signature, not after: two levels that the gain pulls
        // apart into different visible buckets must not be collapsed by a signature
        // computed on the authored values.
        let clamped = Countdown.lift(brightness, gain: gain)
        let signature = "\(color.value):\(Countdown.step(clamped))"
        guard lastWritten[slot] != signature else { return }
        lastWritten[slot] = signature

        // Fun mode addresses physical keys through the calibration like everything else,
        // so the roles land where the operator actually sees them.
        guard let physical = calibration?.physicalSlot(for: slot),
              let thread = try? CodexProtocol.ThreadState(
                  physicalSlot: physical, color: color,
                  brightness: clamped, effect: .solid, speed: 0
              )
        else { return }
        try? await device.write(batch: [device.prepare(threads: [thread])])
    }
}

/**
 Driving QuickTime by Apple event.

 Needs Automation → QuickTime Player, which is why fun mode reports a permission
 problem rather than simply doing nothing when it is missing.
 */
enum QuickTime {
    struct Anchor {
        let media: Double
        let rtt: TimeInterval
        let wall: Date
    }

    @discardableResult
    static func run(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil); return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(
                    returning: String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    /// `present` is QuickTime's own full-screen mode.
    static func open(_ file: URL) async -> Bool {
        let escaped = file.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = await run("""
        tell application "QuickTime Player"
          activate
          set doc to open POSIX file "\(escaped)"
          present doc
          play doc
          return "ok"
        end tell
        """)
        return result == "ok"
    }

    static func playhead() async -> Double? {
        let result = await run(
            "tell application \"QuickTime Player\" to if (count of documents) > 0 "
                + "then return current time of document 1 as string"
        )
        guard let result, let value = Double(result) else { return nil }
        return value
    }

    /// `play` returns before the playhead moves — measured: an 88ms play call, then a
    /// read still showing 0.
    static func waitForPlayback(timeout: TimeInterval = 5) async -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = await playhead()
        while Date() < deadline {
            guard let now = await playhead() else { return nil }
            if let previous, now > previous { return now }
            previous = now
            try? await Task.sleep(for: .milliseconds(60))
        }
        return nil
    }

    /**
     Sample the playhead and estimate *when* that value was true.

     A read costs ~100ms round-trip, so timestamping it on return biases the clock.
     Taking several samples and keeping the fastest reduces jitter, and crediting the
     sample to the midpoint of its own round-trip removes most of the remaining
     systematic error. What is left is a constant, which is what `leadMs` absorbs.
     */
    static func anchorClock(samples: Int = 4) async -> Anchor? {
        var best: Anchor?
        for _ in 0..<samples {
            let before = Date()
            guard let media = await playhead() else { return nil }
            let rtt = Date().timeIntervalSince(before)
            if best == nil || rtt < best!.rtt {
                best = Anchor(
                    media: media, rtt: rtt,
                    wall: before.addingTimeInterval(rtt / 2)
                )
            }
        }
        return best
    }

    static func close() async {
        await run("""
        tell application "QuickTime Player"
          if (count of documents) > 0 then
            stop document 1
            close document 1 saving no
          end if
        end tell
        """)
    }
}
