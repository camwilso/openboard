import Foundation
import OpenBoardKit

/**
 Fun mode's decisions, checked without a pad, a video or a clock.

 Several of the numbers here are measurements rather than taste, and changing them
 reintroduces a specific bug that was found by watching the thing fail. Those are the
 cases worth having.
 */
func runCountdownTests() {
    test("hsl lands on the colors the palette assumes") {
        expectEqual(Countdown.hsl(0, 1, 0.5).hex, "#FF0000")
        expectEqual(Countdown.hsl(120, 1, 0.5).hex, "#00FF00")
        expectEqual(Countdown.hsl(240, 1, 0.5).hex, "#0000FF")
        // Wrapping, because hue drift and the blaze flip both push past 360.
        expectEqual(Countdown.hsl(360, 1, 0.5).hex, "#FF0000")
        expectEqual(Countdown.hsl(-120, 1, 0.5).hex, "#0000FF")
        expectEqual(Countdown.hsl(480, 1, 0.5).hex, "#00FF00")
        // Saturation 0 is grey at any hue, and lightness runs to both ends.
        expectEqual(Countdown.hsl(200, 0, 0.5).hex, "#808080")
        expectEqual(Countdown.hsl(200, 1, 0).hex, "#000000")
        expectEqual(Countdown.hsl(200, 1, 1).hex, "#FFFFFF")
    }

    test("style follows how loud a section is") {
        // Lighting a quiet intro like a chorus is what made an earlier version feel
        // mechanical: it kept time but never noticed the music getting bigger.
        expectEqual(Countdown.style(forEnergy: 0.0), .ember)
        expectEqual(Countdown.style(forEnergy: 0.24), .ember)
        expectEqual(Countdown.style(forEnergy: 0.25), .pulse)
        expectEqual(Countdown.style(forEnergy: 0.44), .pulse)
        expectEqual(Countdown.style(forEnergy: 0.45), .sweep)
        expectEqual(Countdown.style(forEnergy: 0.64), .sweep)
        expectEqual(Countdown.style(forEnergy: 0.65), .blaze)
        expectEqual(Countdown.style(forEnergy: 1.0), .blaze)
    }

    test("sectionIndex picks the last section at or before the time") {
        let sections = [
            Countdown.Section(t: 0, energy: 0.2),
            Countdown.Section(t: 10, energy: 0.5),
            Countdown.Section(t: 20, energy: 0.8),
        ]
        expectEqual(Countdown.sectionIndex(sections, at: 0), 0)
        expectEqual(Countdown.sectionIndex(sections, at: 9.9), 0)
        expectEqual(Countdown.sectionIndex(sections, at: 10), 1, "a boundary belongs to the new section")
        expectEqual(Countdown.sectionIndex(sections, at: 999), 2)
    }

    test("the intro bar renders in three distinct brightness buckets") {
        // The whole point of the defaults. Three levels — the leading key, the trail
        // behind it, the empty keys ahead — must land in *different* step() buckets or
        // the bar renders flat. The first attempt put all three in one.
        let frame = Countdown.introFrame(progress: 0.5, downbeat: true)
        let buckets = Set(frame.map { Countdown.step($0) })
        expect(buckets.count >= 3, "the bar collapsed to \(buckets.count) visible level(s)")
    }

    test("the intro bar fills left to right and never overruns") {
        expectEqual(Countdown.introFrame(progress: 0, downbeat: true)[0], 0.6)
        expectEqual(Countdown.introFrame(progress: 0, downbeat: true)[5], 0)

        // Halfway: three trailing, one leading, two empty.
        let middle = Countdown.introFrame(progress: 0.5, downbeat: true)
        expectEqual(Array(middle[0..<3]), [0.2, 0.2, 0.2])
        expectEqual(middle[3], 0.6)
        expectEqual(Array(middle[4..<6]), [0, 0])

        // At and past the end the leading key stays on the last slot rather than
        // running off the array.
        for progress in [1.0, 1.5, 99.0] {
            let frame = Countdown.introFrame(progress: progress, downbeat: true)
            expectEqual(frame.count, 6)
            expectEqual(frame[5], 0.6, "the lead left the pad at progress \(progress)")
        }
        // Garbage in does not crash or produce NaN.
        let broken = Countdown.introFrame(progress: .nan, downbeat: false)
        expect(broken.allSatisfy { $0.isFinite })
    }

    test("off-beat frames are dimmer than the downbeat") {
        // The leading key breathes on the beat; that is the only motion before the flash.
        let on = Countdown.introFrame(progress: 0.5, downbeat: true)
        let off = Countdown.introFrame(progress: 0.5, downbeat: false)
        expect(off[3] < on[3])
    }

    test("the local scaler exposes dynamics the absolute level hides") {
        // The mix is relentlessly loud, so keys driven by the absolute level would
        // simply stay on. Judged against the last few seconds, the same signal shows
        // the dynamics you actually hear: 0.90 is loud in absolute terms and merely
        // mid-range against a window spanning 0.80–1.00.
        var scaler = Countdown.LocalScaler()
        var last = 0.0
        for value in [0.80, 0.95, 0.85, 1.0, 0.82, 0.90] { last = scaler.scale(value) }
        expectEqual(Countdown.step(last), 0.6, "0.90 in a 0.80–1.00 window scaled to \(last)")
    }

    test("the flat-window fallback triggers on a span, not on a level") {
        // The threshold is 0.08 and it is load-bearing in both directions. A window
        // that is merely *loud* still scales; one that is genuinely flat falls back,
        // because normalising it would drive the keys dark exactly when the music is
        // at its loudest.
        var narrow = Countdown.LocalScaler()
        var narrowLast = 0.0
        // Span 0.06 — under the threshold, so the absolute level survives.
        for value in [0.94, 0.96, 0.95, 1.0, 0.94, 0.98] { narrowLast = narrow.scale(value) }
        expectEqual(narrowLast, 0.98, "a near-flat loud window was normalised anyway")

        var wide = Countdown.LocalScaler()
        var wideLast = 0.0
        // Span 0.10 — over the threshold, so it scales despite also being loud.
        for value in [0.90, 0.92, 0.95, 1.0, 0.91, 0.95] { wideLast = wide.scale(value) }
        expect(wideLast < 0.95, "a window with real dynamics was not scaled")
    }

    test("a flat window falls back to the absolute level") {
        // Without this, bass pegged at 1.00 for sixteen beats scales to 0 and the keys
        // go dark exactly when the music is loudest — the opposite of the signal.
        var scaler = Countdown.LocalScaler()
        var last = 0.0
        for _ in 0..<20 { last = scaler.scale(1.0) }
        expectEqual(last, 1.0, "pegged-loud went dark")

        var quiet = Countdown.LocalScaler()
        var quietLast = 0.0
        for _ in 0..<20 { quietLast = quiet.scale(0.02) }
        expectEqual(quietLast, 0.02, "pegged-quiet lit up")
    }

    test("the scaler only remembers its window") {
        var scaler = Countdown.LocalScaler(window: 4)
        for value in [0.0, 1.0, 0.0, 1.0] { _ = scaler.scale(value) }
        // A loud burst long past should not still be setting the ceiling.
        for _ in 0..<4 { _ = scaler.scale(0.5) }
        expectEqual(Countdown.step(scaler.scale(0.5)), 0.6, "an old peak still dominates")
    }

    test("the intro flash is forced to the front and shields itself") {
        // Detection put the first flash at 1.05s, which is merely where audio begins.
        // The moment that reads as the song starting is the pickup into the fanfare.
        let analysis = Countdown.Analysis(
            bpm: 119, durationSec: 295.5,
            beats: [],
            sections: [Countdown.Section(t: 0, energy: 0.2)],
            surges: [
                Countdown.Surge(t: 1.05, jump: 0.16),
                Countdown.Surge(t: 14.0, jump: 0.4),
                Countdown.Surge(t: 20.0, jump: 0.5),
            ]
        )
        let surges = Countdown.surgeList(analysis, introSec: 13.2)
        expectEqual(surges.first?.t, 13.2)
        expect(surges.first?.isIntro == true)
        // 1.05 is before it and 14.0 is inside the 1.5s shadow — both dropped, so
        // nothing upstages the reveal.
        expectEqual(surges.map(\.t), [13.2, 20.0])
    }

    test("flash brightness follows the size of the lift") {
        // So a small surge does not read as the finale.
        let small = Countdown.Surge(t: 30, jump: 0.05)
        let large = Countdown.Surge(t: 40, jump: 0.5)
        expect(Countdown.surgePunch(small) < Countdown.surgePunch(large))
        expect(Countdown.surgePunch(large) <= 1)

        var intro = Countdown.Surge(t: 13.2, jump: 0.3)
        intro.isIntro = true
        expectEqual(Countdown.surgePunch(intro), 1, "the reveal is always full")
    }

    test("an accent reads as a hit, not as a mistake") {
        // Same hue, hotter and desaturated toward white. A hue-shifted flash reads as
        // an error; a brighter version of the current color reads as emphasis.
        let analysis = Countdown.Analysis(
            bpm: 119, durationSec: 300, beats: [],
            sections: [Countdown.Section(t: 0, energy: 0.7)], surges: []
        )
        let accent = Countdown.Beat(t: 30, i: 0.5, b: 0.5, v: 0.5, h: 0.5, a: 1)
        let plain = Countdown.Beat(t: 30, i: 0.5, b: 0.5, v: 0.5, h: 0.5, a: 0)

        let hit = Countdown.ringFrame(beat: accent, analysis: analysis, beatIndex: 1, flip: false)
        let normal = Countdown.ringFrame(beat: plain, analysis: analysis, beatIndex: 1, flip: false)
        expectEqual(hit.brightness, 1)
        expect(hit.brightness > normal.brightness)
        expectEqual(hit.effect, .solid, "an accent must not also change the motion")
    }

    test("spatial effects are reserved for the ring") {
        // snake and gradient need more than one LED. On a single key they render dark,
        // which is why the per-key list is explicit rather than allCases.
        expect(LEDEffect.snake.isSpatial)
        expect(LEDEffect.gradient.isSpatial)
        expect(!LEDEffect.perKey.contains(.snake))
        expect(!LEDEffect.perKey.contains(.gradient))
        expect(LEDEffect.perKey.contains(.breath))
        // The ring genuinely uses them, so they must survive in the enum.
        expectEqual(LEDEffect.snake.deviceCode, 2)
        expectEqual(LEDEffect.gradient.deviceCode, 5)
    }

    test("a downbeat in a loud section gets the spatial effect") {
        let analysis = Countdown.Analysis(
            bpm: 119, durationSec: 300, beats: [],
            sections: [Countdown.Section(t: 0, energy: 0.8)], surges: []
        )
        let beat = Countdown.Beat(t: 30, i: 0.6, b: 0.6, v: 0.5, h: 0.5, a: 0)
        let down = Countdown.ringFrame(beat: beat, analysis: analysis, beatIndex: 4, flip: false)
        let up = Countdown.ringFrame(beat: beat, analysis: analysis, beatIndex: 5, flip: false)
        expectEqual(down.effect, .snake)
        expectEqual(up.effect, .solid)
        expect(down.speed > 0 && up.speed == 0)
    }

    test("blaze alternates hue beat to beat") {
        let analysis = Countdown.Analysis(
            bpm: 119, durationSec: 300, beats: [],
            sections: [Countdown.Section(t: 0, energy: 0.9)], surges: []
        )
        let beat = Countdown.Beat(t: 30, i: 0.6, b: 0.6, v: 0.5, h: 0.5, a: 0)
        let a = Countdown.ringFrame(beat: beat, analysis: analysis, beatIndex: 5, flip: false)
        let b = Countdown.ringFrame(beat: beat, analysis: analysis, beatIndex: 5, flip: true)
        expect(a.color != b.color, "the flip did not change anything")
    }

    test("ring brightness stays within what the device accepts") {
        // punch feeds an expression that could exceed 1 on a loud beat, and an
        // out-of-range brightness is rejected by ThreadState rather than clamped.
        let energies = [0.1, 0.3, 0.5, 0.9]
        for energy in energies {
            let analysis = Countdown.Analysis(
                bpm: 119, durationSec: 300, beats: [],
                sections: [Countdown.Section(t: 0, energy: energy)], surges: []
            )
            for index in 0..<8 {
                let beat = Countdown.Beat(t: 30, i: 1, b: 1, v: 1, h: 1, a: 0)
                let frame = Countdown.ringFrame(
                    beat: beat, analysis: analysis, beatIndex: index, flip: index % 2 == 0
                )
                expect(
                    frame.brightness >= 0 && frame.brightness <= 1,
                    "energy \(energy) beat \(index) gave brightness \(frame.brightness)"
                )
                expect(frame.speed >= 0 && frame.speed <= 1)
            }
        }
    }

    test("keys split by role, with silence thresholds") {
        // Voice up top, bass and high end below — matching the calibration order, so no
        // remapping is needed.
        let beat = Countdown.Beat(t: 30, i: 0.5, b: 0.5, v: 0.5, h: 0.5, a: 0)
        let frame = Countdown.keyFrame(beat: beat, hue: 200, vocal: 0.8, bass: 0.8, high: 0.8)
        expectEqual(frame.map(\.slot), [1, 2, 3, 4, 5, 6])
        // Each role has one color across its pair, and the pairs differ.
        expectEqual(frame[0].color, frame[1].color)
        expectEqual(frame[2].color, frame[3].color)
        expect(frame[0].color != frame[2].color)
        expect(frame[2].color != frame[4].color)
        // The pair alternates emphasis so a sustained note still shows movement.
        expect(frame[0].brightness > frame[1].brightness)

        // Below threshold a key goes fully dark rather than sitting at a floor.
        let quiet = Countdown.keyFrame(beat: beat, hue: 200, vocal: 0.05, bass: 0.05, high: 0.05)
        expect(quiet.allSatisfy { $0.brightness == 0 })
    }

    test("key brightness never exceeds what the device accepts") {
        let frame = Countdown.keyFrame(beat: Countdown.Beat(t: 0, i: 1, b: 1, v: 1, h: 1, a: 0),
                                       hue: 0, vocal: 1, bass: 1, high: 1)
        expect(frame.allSatisfy { $0.brightness >= 0 && $0.brightness <= 1 })
    }

    test("the write dedup only suppresses invisible changes") {
        // Six keys plus the ring at ~80ms a write needs ~560ms of a 504ms beat, so most
        // beats must skip most surfaces — but a change you could see must never be one
        // of the skipped ones.
        expectEqual(Countdown.step(0.50), Countdown.step(0.52))
        expect(Countdown.step(0.5) != Countdown.step(0.7))
        expectEqual(Countdown.step(0.0), 0.0)
        expectEqual(Countdown.step(1.0), 1.0)
    }

    test("the daylight lift raises everything without flattening the top") {
        // The whole point: a multiplier would put every one of these at 1.0 and the
        // loud end — where the intensity lives — would stop being dynamic at all.
        let gain = 1.5
        let authored = [0.1, 0.3, 0.55, 0.7, 0.9, 1.0]
        let lifted = authored.map { Countdown.lift($0, gain: gain) }

        for (before, after) in zip(authored, lifted) where before > 0 && before < 1 {
            expect(after > before, "\(before) did not rise (got \(after))")
        }
        // Order and separation survive, which is what keeps the show readable.
        expect(zip(lifted, lifted.dropFirst()).allSatisfy { $0 < $1 }, "levels collapsed")
        // The extremes are fixed points: silence stays dark, maximum stays maximum.
        expectEqual(Countdown.lift(0, gain: gain), 0)
        expectEqual(Countdown.lift(1, gain: gain), 1)
        // Nothing may leave the range the device accepts.
        expect(lifted.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    test("gain 1 is the show exactly as authored") {
        // A default that quietly altered the choreography would make every earlier
        // timing and brightness note in this file wrong.
        for value in [0.0, 0.18, 0.3, 0.62, 1.0] {
            expectEqual(Countdown.lift(value, gain: 1), value)
        }
    }

    test("a lift below 1 dims, and a nonsense gain is inert") {
        expect(Countdown.lift(0.5, gain: 0.5) < 0.5)
        // Zero or negative would be a divide-by-zero or a flipped curve; both are
        // reachable from a hand-edited config.json.
        expectEqual(Countdown.lift(0.5, gain: 0), 0.5)
        expectEqual(Countdown.lift(0.5, gain: -2), 0.5)
    }

    test("the intro bar's three levels stay distinct once lifted") {
        /*
         The bar is the one place the levels are *supposed* to be close, and the
         quantiser has five buckets — so the lift must not merge the lead into the trail.

         Tested at the documented 0.6/0.2 pair rather than at whatever is configured.
         The shipped default is `introBrightness: 0.3`, and at 0.3 the lead and the trail
         land in the same bucket both before *and* after any lift: 0.3 and 0.2 quantise
         to 0.4 together, and lifting is monotonic so it cannot separate them. That is a
         defect in the default, not in the lift, and it is the exact failure
         `Countdown.introFrame`'s own comment warns about.
         */
        let frame = Countdown.introFrame(
            progress: 0.5, downbeat: true, brightness: 0.6, trail: 0.2
        )
        let filled = 3  // progress 0.5 over six slots
        let lead = Countdown.lift(frame[filled], gain: 1.5)
        let trail = Countdown.lift(frame[0], gain: 1.5)
        expect(
            Countdown.step(lead) > Countdown.step(trail),
            "lead \(lead) and trail \(trail) landed in the same bucket"
        )
        expectEqual(
            Countdown.lift(frame[filled + 1], gain: 1.5), 0,
            "keys ahead of the bar must stay dark"
        )
    }

    test("the shipped intro bar reads correctly on every beat and every gain") {
        /*
         This replaces a test that recorded a defect, now fixed.

         The default shipped as 0.3 — the value `lib/countdown.cjs` passed — while
         `Countdown.introFrame`'s own default was 0.6 and its comment explained why. At
         0.3 the bar worked on downbeats and rendered *backwards* on the other three
         beats: the lead is scaled to 0.3 x 0.6 = 0.18 against a 0.2 trail, so the
         leading edge was dimmer than its own tail on three frames in four. The lift
         could not rescue it either, being monotonic.

         So the invariant, at the value actually shipped: the lead outranks the trail on
         every beat, at every gain.
         */
        let brightness = Preferences.default.countdown.introBrightness
        let trail = Preferences.default.countdown.introTrail
        expectEqual(brightness, 0.6, "the default changed; re-check the arithmetic below")

        for downbeat in [true, false] {
            let frame = Countdown.introFrame(
                progress: 0.5, downbeat: downbeat, brightness: brightness, trail: trail
            )
            // The defect that mattered: the lead must never be *dimmer* than its own
            // trail. Lift is monotonic, so establishing the order once establishes it
            // at every gain.
            expect(frame[3] > frame[0], "the lead is dimmer than its trail (downbeat: \(downbeat))")

            for gain in [0.5, 1.0, 1.5, 2.0] {
                expect(
                    Countdown.step(Countdown.lift(frame[3], gain: gain))
                        > Countdown.step(Countdown.lift(frame[0], gain: gain)),
                    "downbeat \(downbeat) at gain \(gain) flattened the bar"
                )
                // Keys ahead of the bar stay dark at any lift: zero is preserved exactly.
                expectEqual(Countdown.lift(frame[4], gain: gain), 0)
            }
        }
    }

    test("at the very top of the lift range the offbeat bar flattens") {
        /*
         A known limit, recorded rather than hidden.

         `lift` is a gamma curve and `step` has five buckets, so a hard enough lift
         pushes neighbouring values into the same one. At gain 2.5 the offbeat lead
         (0.36 → 0.667) and the trail (0.2 → 0.525) both quantise to 0.6.

         It is not the old defect — the lead is still brighter, just not by a whole
         bucket — and it only bites at the extreme end of the slider, on the three
         offbeats, during the 13s intro. Worth knowing before someone "fixes" the
         quantiser and wonders what changed.
         */
        let frame = Countdown.introFrame(
            progress: 0.5, downbeat: false, brightness: 0.6, trail: 0.2
        )
        expect(Countdown.lift(frame[3], gain: 2.5) > Countdown.lift(frame[0], gain: 2.5),
               "the order still holds")
        expectEqual(
            Countdown.step(Countdown.lift(frame[3], gain: 2.5)),
            Countdown.step(Countdown.lift(frame[0], gain: 2.5)),
            "if this separates, the quantiser or the curve changed"
        )
    }

    test("the real analysis file parses") {
        // The one case that catches a schema drift between the analyser and this port.
        guard let analysis = Countdown.loadAnalysis() else {
            skip("analysis.json not installed")
            return
        }
        expect(analysis.beats.count > 100, "only \(analysis.beats.count) beats")
        expect(analysis.sections.count > 1)
        expect(analysis.bpm > 60 && analysis.bpm < 200)
        expect(analysis.durationSec > 60)
        // Beats must be in order, or the skip-ahead loop spins.
        expect(zip(analysis.beats, analysis.beats.dropFirst()).allSatisfy { $0.t <= $1.t })
        // Every beat must produce a frame the device will accept.
        for (index, beat) in analysis.beats.enumerated() {
            let frame = Countdown.ringFrame(
                beat: beat, analysis: analysis, beatIndex: index, flip: index % 2 == 0
            )
            guard frame.brightness >= 0, frame.brightness <= 1,
                  frame.speed >= 0, frame.speed <= 1 else {
                expect(false, "beat \(index) at \(beat.t)s gave an out-of-range frame")
                return
            }
        }
    }

    // MARK: - choosing a video

    test("an empty library has nothing to play, and says so") {
        expectEqual(
            Countdown.chooseMedia(configured: nil, library: []),
            .none("the media folder is empty")
        )
        // An unset preference is the empty string, not nil — the same case.
        expectEqual(
            Countdown.chooseMedia(configured: "", library: []),
            .none("the media folder is empty")
        )
        expectEqual(
            Countdown.chooseMedia(configured: "   ", library: []),
            .none("the media folder is empty")
        )
    }

    test("one video needs no choosing") {
        expectEqual(
            Countdown.chooseMedia(configured: "", library: ["the-final-countdown"]),
            .library("the-final-countdown")
        )
    }

    test("a second video never turns fun mode off") {
        // The failure this guards against is silent: refusing to pick would leave the
        // Play button dim with nothing on screen to say why.
        let choice = Countdown.chooseMedia(
            configured: "", library: ["the-final-countdown", "africa", "sandstorm"]
        )
        expectEqual(choice, .library("africa"), "first by name, deterministically")
    }

    test("listing order does not decide which video plays") {
        let a = Countdown.chooseMedia(configured: "", library: ["zeta", "alpha"])
        let b = Countdown.chooseMedia(configured: "", library: ["alpha", "zeta"])
        expectEqual(a, b)
    }

    test("a bare name picks from the library, a path is taken literally") {
        expectEqual(
            Countdown.chooseMedia(configured: "sandstorm", library: ["africa"]),
            .library("sandstorm"),
            "a configured name wins even when the library has not got it yet"
        )
        expectEqual(
            Countdown.chooseMedia(configured: "~/Videos/mine", library: ["africa"]),
            .path("~/Videos/mine")
        )
        expectEqual(
            Countdown.chooseMedia(configured: "/Volumes/Big/mine", library: []),
            .path("/Volumes/Big/mine")
        )
    }

    test("a folder name reads as a song title on the button") {
        expectEqual(Countdown.songTitle("the-final-countdown"), "The Final Countdown")
        expectEqual(Countdown.songTitle("africa"), "Africa")
        expectEqual(Countdown.songTitle("sandstorm_darude"), "Sandstorm Darude")
        // Already-capitalised words are left alone rather than re-cased.
        expectEqual(Countdown.songTitle("Toto-Africa"), "Toto Africa")
        expectEqual(Countdown.songTitle("ABBA-SOS"), "ABBA SOS")
        // Nothing sensible to do with these, and nothing that should crash either.
        expectEqual(Countdown.songTitle(""), "")
        expectEqual(Countdown.songTitle("---"), "---")
        expectEqual(Countdown.songTitle("99-luftballons"), "99 Luftballons")
    }

    test("a configured value is trimmed before it is judged") {
        // Hand-edited JSON is how this preference gets set; a stray space must not
        // turn a library name into a path or an empty string into a selection.
        expectEqual(
            Countdown.chooseMedia(configured: "  africa  ", library: []),
            .library("africa")
        )
    }
}
