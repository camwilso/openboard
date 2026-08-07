import Foundation

/**
 Fun mode: drive the pad in time with a video.

 Everything here is pure — the color decisions, the intro bar geometry, the dynamics
 scaling — so the parts that are hard to get right can be checked without a pad, a video
 or a clock. The transport (QuickTime, the beat loop, the writes) lives in the app.

 ## The constants are measurements, not taste

 Several numbers below were arrived at by watching the thing fail, and changing them
 reintroduces a specific bug. They are called out individually.
 */
public enum Countdown {
    // MARK: - the analysis

    /// Produced by `tools/analyse-audio.cjs` — energy envelope → onset flux →
    /// autocorrelation. A guessed BPM drifts audibly within about a minute.
    public struct Analysis: Decodable, Sendable {
        public let bpm: Int
        public let durationSec: Double
        public let beats: [Beat]
        public let sections: [Section]
        public let surges: [Surge]

        public var beatPeriod: Double { 60.0 / Double(max(bpm, 1)) }

        public init(
            bpm: Int, durationSec: Double, beats: [Beat],
            sections: [Section], surges: [Surge]
        ) {
            self.bpm = bpm
            self.durationSec = durationSec
            self.beats = beats
            self.sections = sections
            self.surges = surges
        }
    }

    public struct Beat: Decodable, Sendable {
        /// Seconds into the media.
        public let t: Double
        /// Overall intensity.
        public let i: Double
        /// Bass, vocal, high-end. Each drives a different pair of keys.
        public let b: Double
        public let v: Double
        public let h: Double
        /// 1 on an accent.
        public let a: Int

        public var isAccent: Bool { a != 0 }

        public init(t: Double, i: Double, b: Double, v: Double, h: Double, a: Int) {
            self.t = t; self.i = i; self.b = b; self.v = v; self.h = h; self.a = a
        }
    }

    public struct Section: Decodable, Sendable {
        public let t: Double
        public let energy: Double

        public init(t: Double, energy: Double) {
            self.t = t
            self.energy = energy
        }
    }

    public struct Surge: Decodable, Sendable {
        public let t: Double
        public let jump: Double
        /// The explicit first flash, which is not detected — see `surgeList`.
        public var isIntro: Bool = false

        enum CodingKeys: String, CodingKey { case t, jump }

        public init(t: Double, jump: Double, isIntro: Bool = false) {
            self.t = t
            self.jump = jump
            self.isIntro = isIntro
        }
    }

    // MARK: - palette

    /// One hue per section, so a section change reads as a change of scene.
    public static let sectionHues: [Double] = [225, 300, 190, 35, 270, 0, 165, 45]

    /**
     A section's look, chosen by how loud it is.

     Lighting a quiet intro like a chorus is what made an earlier version feel
     mechanical: the lights kept time but never noticed the music getting bigger.
     */
    public enum Style: String, Sendable {
        case ember, pulse, sweep, blaze
    }

    public static func style(forEnergy energy: Double) -> Style {
        if energy < 0.25 { return .ember }
        if energy < 0.45 { return .pulse }
        if energy < 0.65 { return .sweep }
        return .blaze
    }

    /// Which section a time falls in.
    public static func sectionIndex(_ sections: [Section], at time: Double) -> Int {
        var index = 0
        for (position, section) in sections.enumerated() where time >= section.t {
            index = position
        }
        return index
    }

    /// HSL → RGB, because the palette is written in hues and the device wants bytes.
    public static func hsl(_ degrees: Double, _ saturation: Double, _ lightness: Double) -> RGB {
        let hue = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let second = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))

        let (r, g, b): (Double, Double, Double) = switch Int(hue) {
        case 0: (chroma, second, 0)
        case 1: (second, chroma, 0)
        case 2: (0, chroma, second)
        case 3: (0, second, chroma)
        case 4: (second, 0, chroma)
        default: (chroma, 0, second)
        }

        let offset = lightness - chroma / 2
        let byte = { (value: Double) -> UInt32 in
            UInt32(max(0, min(255, ((value + offset) * 255).rounded())))
        }
        return RGB(byte(r) << 16 | byte(g) << 8 | byte(b))
    }

    // MARK: - key roles

    /// Top two follow the voice, bottom four the instruments. Calibration order puts
    /// slots 1–2 on the top row and 3–6 below, so this needs no remapping.
    public static let vocalSlots = [1, 2]
    public static let bassSlots = [3, 4]
    public static let highSlots = [5, 6]
    public static let allSlots = [1, 2, 3, 4, 5, 6]

    /**
     Scale a value against the recent past rather than the whole song.

     The mix is relentlessly loud: absolute bass sits at 0.94–1.00 for three minutes, so
     keys driven by it would simply stay on. Judged against the last few seconds, the
     same signal shows the dynamics you actually hear.
     */
    public struct LocalScaler: Sendable {
        private var recent: [Double] = []
        private let window: Int
        private let flatSpan: Double

        public init(window: Int = 16, flatSpan: Double = 0.08) {
            self.window = window
            self.flatSpan = flatSpan
        }

        public mutating func scale(_ value: Double) -> Double {
            recent.append(value)
            if recent.count > window { recent.removeFirst() }
            let high = recent.max() ?? value
            let low = recent.min() ?? value
            let span = high - low
            // A flat window means there is no local dynamic to expose, so fall back to
            // the absolute level. Without this, bass pegged at 1.00 for sixteen beats
            // scales to 0 and the keys go dark exactly when the music is loudest — the
            // opposite of what the signal says.
            guard span >= flatSpan else { return min(1, max(0, value)) }
            return min(1, max(0, (value - low) / span))
        }
    }

    /// Quantise, so a key is only rewritten when it would visibly differ.
    public static func step(_ value: Double, levels: Double = 5) -> Double {
        (value * levels).rounded() / levels
    }

    /**
     Lift every brightness for a lit room, without flattening the show.

     Applied at the two write paths, so it reaches the intro bar, the surges, the ring
     and the keys identically — one number for the whole show rather than a scattering
     of per-section tweaks that would drift apart.

     **Not a multiply.** `b * gain` clamped at 1 raises the quiet end and then crushes
     everything above `1/gain` into a flat maximum — and the loud end is exactly where
     the intensity lives. At gain 1.5 every beat above 0.67 becomes indistinguishable,
     which reads as *less* dynamic in a bright room, not more visible.

     A gamma curve raises the whole range instead: 0 stays off, 1 stays maximum, and
     everything between rises while keeping its order and its spacing. Silence
     thresholds still read as dark, because zero is preserved exactly.

     - Parameter gain: 1 is the show as authored. Above 1 lifts; below 1 dims.
     */
    public static func lift(_ value: Double, gain: Double) -> Double {
        let clamped = min(1, max(0, value))
        // Zero is a decision — keyFrame's silence thresholds force it — so it must not
        // be lifted into a dim glow. pow(0, x) is already 0; this also guards gain <= 0.
        guard clamped > 0, gain > 0, gain != 1 else { return clamped }
        return min(1, max(0, pow(clamped, 1 / gain)))
    }

    /**
     The pre-flash intro: six keys filling left to right as a countdown bar.

     Three levels, and they must land in *different* `step()` buckets or the bar renders
     flat — the leading key, the trail behind it, and the empty keys ahead. That is why
     the defaults are 0.6 and 0.2 rather than something more obviously dim: the quantiser
     has five levels and the first attempt put all three in one of them.
     */
    public static func introFrame(
        progress: Double,
        downbeat: Bool,
        brightness: Double = 0.6,
        trail: Double = 0.2,
        slots: Int = 6
    ) -> [Double] {
        let clamped = min(1, max(0, progress.isFinite ? progress : 0))
        let filled = min(slots - 1, Int(clamped * Double(slots)))
        let punch = downbeat ? 1.0 : 0.6
        return (0..<slots).map { index in
            if index < filled { return trail }
            if index == filled { return brightness * punch }
            return 0
        }
    }

    // MARK: - the frame decisions

    /// What the ring should show on a given beat.
    ///
    /// `flip` alternates on `blaze` beats and is the caller's to carry between frames.
    public static func ringFrame(
        beat: Beat,
        analysis: Analysis,
        beatIndex: Int,
        flip: Bool
    ) -> Appearance {
        let index = sectionIndex(analysis.sections, at: beat.t)
        let section = analysis.sections.indices.contains(index)
            ? analysis.sections[index]
            : Section(t: 0, energy: 0.5)
        let look = style(forEnergy: section.energy)
        // Hue drifts within a section so a long chorus does not sit on one color.
        let drift = ((beat.t - section.t) * 6).truncatingRemainder(dividingBy: 40)
        let hue = sectionHues[index % sectionHues.count] + drift
        let downbeat = beatIndex % 4 == 0
        // Bass drives brightness, not overall loudness: the pulse you feel is the kick,
        // while total energy tracks vocals and cymbals instead.
        let punch = max(beat.b, beat.i * 0.7)

        if beat.isAccent {
            // Same hue, much hotter and desaturated toward white. A hue-shifted flash
            // reads as a mistake; a brighter version of the current color reads as a hit.
            return Appearance(color: hsl(hue, 0.35, 0.72), effect: .solid, brightness: 1, speed: 0)
        }

        switch look {
        case .ember:
            return Appearance(
                color: hsl(hue, 0.9, 0.3), effect: .breath,
                brightness: 0.1 + punch * 0.2, speed: 0.12
            )
        case .pulse:
            return Appearance(
                color: hsl(hue, 0.95, 0.45),
                effect: downbeat ? .gradient : .solid,
                brightness: 0.2 + punch * 0.5,
                speed: downbeat ? 0.3 : 0
            )
        case .sweep:
            return downbeat
                ? Appearance(color: hsl(hue, 1, 0.5), effect: .snake, brightness: 0.9, speed: 0.45)
                : Appearance(
                    color: hsl(hue + 20, 1, 0.45), effect: .solid,
                    brightness: 0.3 + punch * 0.5, speed: 0
                )
        case .blaze:
            // Alternate complementary hues beat to beat for a hard, driving feel.
            return Appearance(
                color: hsl(hue + (flip ? 165 : 0), 1, 0.5),
                effect: downbeat ? .snake : .solid,
                brightness: 0.55 + punch * 0.45,
                speed: downbeat ? 0.7 : 0
            )
        }
    }

    /// Brightness per key slot for a beat, after local scaling. Index 0 is slot 1.
    ///
    /// Returned rather than written, so the role split and the silence thresholds can be
    /// checked without a pad.
    public static func keyFrame(
        beat: Beat,
        hue: Double,
        vocal: Double,
        bass: Double,
        high: Double
    ) -> [(slot: Int, color: RGB, brightness: Double)] {
        var frame: [(Int, RGB, Double)] = []

        // Voice keeps a warm, near-white hue so it reads as a different *kind* of thing
        // from the instruments rather than just another color in the same scheme.
        let vocalColor = hsl(hue + 18, 0.35, 0.62)
        for (position, slot) in vocalSlots.enumerated() {
            // The pair alternates emphasis so a sustained note still shows movement.
            let bias = position == 0 ? 1.0 : 0.75
            frame.append((slot, vocalColor, vocal < 0.12 ? 0 : vocal * bias))
        }

        let bassColor = hsl(hue, 1, 0.45)
        for (position, slot) in bassSlots.enumerated() {
            let bias = position == 0 ? 1.0 : 0.7
            frame.append((slot, bassColor, bass < 0.1 ? 0 : bass * bias))
        }

        let highColor = hsl(hue + 150, 0.9, 0.55)
        for (position, slot) in highSlots.enumerated() {
            let bias = position == 0 ? 0.8 : 1.0
            frame.append((slot, highColor, high < 0.1 ? 0 : high * bias))
        }

        return frame.map { (slot: $0.0, color: $0.1, brightness: $0.2) }
    }

    /// The hue a beat is painted in — shared by the ring and the keys so they agree.
    public static func hue(for beat: Beat, analysis: Analysis) -> Double {
        let index = sectionIndex(analysis.sections, at: beat.t)
        let section = analysis.sections.indices.contains(index)
            ? analysis.sections[index]
            : Section(t: 0, energy: 0.5)
        let drift = ((beat.t - section.t) * 6).truncatingRemainder(dividingBy: 40)
        return sectionHues[index % sectionHues.count] + drift
    }

    /**
     The surge list, with the intro flash forced to the front.

     The first flash is explicit rather than detected. Automatic detection put it at
     1.05s, which is merely where audio begins; the moment that actually reads as the
     song starting is the pickup into the fanfare. Detected surges within 1.5s after it
     are dropped so nothing upstages the reveal.
     */
    public static func surgeList(_ analysis: Analysis, introSec: Double) -> [Surge] {
        var intro = Surge(t: introSec, jump: 0.3)
        intro.isIntro = true
        return [intro] + analysis.surges.filter { $0.t > introSec + 1.5 }
    }

    /// How bright a surge flashes. Following the size of the lift stops a small one
    /// reading as the finale.
    public static func surgePunch(_ surge: Surge) -> Double {
        surge.isIntro ? 1 : min(1, 0.7 + surge.jump * 1.2)
    }

    public static func surgeColor(
        _ surge: Surge, analysis: Analysis, introColor: RGB
    ) -> RGB {
        guard !surge.isIntro else { return introColor }
        let index = sectionIndex(analysis.sections, at: surge.t)
        return hsl(sectionHues[index % sectionHues.count], 0.25, 0.75)
    }
}

extension Countdown {
    /// What `countdown.mediaDir` means. A bare name picks a folder out of the media
    /// library; anything that looks like a path is taken literally, so a video can
    /// still live anywhere on disk.
    public enum MediaChoice: Equatable {
        /// A folder in the media library, by name.
        case library(String)
        /// A path, as written. Tildes are expanded by the caller.
        case path(String)
        /// Nothing to play, and why — phrased for the log.
        case none(String)
    }

    /// The whole rule, with no filesystem in it.
    ///
    /// Two videos in the library and no choice made is deliberately *not* a refusal.
    /// Dropping in a second video should never turn fun mode off — the Play button
    /// would simply go dim, and nothing on screen would explain why. Picking the first
    /// by name is arbitrary, but it is stated in the log along with how to change it,
    /// which is the difference between arbitrary and mysterious.
    public static func chooseMedia(configured: String?, library: [String]) -> MediaChoice {
        let trimmed = (configured ?? "").trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let looksLikePath = trimmed.contains("/") || trimmed.hasPrefix("~")
            return looksLikePath ? .path(trimmed) : .library(trimmed)
        }
        let folders = library.sorted()
        guard let first = folders.first else {
            return .none("the media folder is empty")
        }
        return .library(first)
    }

    /// A folder name as a song title, for the Play button. `the-final-countdown`
    /// becomes `The Final Countdown`; a name that is already prose is left alone, so
    /// nothing turns `Toto - Africa` into `Toto - africa`.
    public static func songTitle(_ folder: String) -> String {
        let words = folder
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return folder }
        return words
            .map { $0.first!.isLowercase ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
            .joined(separator: " ")
    }

    /// Where the video and its analysis live. Never inside the bundle: a video is
    /// ~90MB and would triple the size of the app for a party trick.
    public static func mediaDirectory(
        configured: String? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = env["OPENBOARD_MEDIA"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let root = AppPaths.media(env: env)
        switch chooseMedia(configured: configured, library: AppPaths.mediaLibrary(env: env)) {
        case let .path(path):
            let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: expanded.path) { return expanded }
        case let .library(name):
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        case .none:
            break
        }
        // Last: beside the app bundle, then the working directory it was launched from.
        // Both are relative to where the app actually is, which keeps a source-tree run
        // working without anyone having to populate the library first.
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("the-final-countdown"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("the-final-countdown"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func loadAnalysis(directory: URL? = nil, configured: String? = nil) -> Analysis? {
        guard let directory = directory ?? mediaDirectory(configured: configured) else { return nil }
        let url = directory.appendingPathComponent("analysis.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Analysis.self, from: data)
    }

    /// The video beside the analysis. Matched by extension rather than by name so
    /// renaming the file does not break it.
    public static func findVideo(directory: URL? = nil, configured: String? = nil) -> URL? {
        guard let directory = directory ?? mediaDirectory(configured: configured) else { return nil }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.first { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
    }
}
