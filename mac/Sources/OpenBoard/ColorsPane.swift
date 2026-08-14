import OpenBoardKit
import SwiftUI

/**
 Colors — everything the pad emits, on one pane.

 This was two tabs, Keys & Colors and Fun, and the split did not survive the question
 "which one holds the ring?". The ring is a color the board shows; so are the laps that
 fire on it, the toy shows, and the countdown. They were filed under Fun because they
 are animated, which is a fact about *how* they light rather than about what they are.

 These are **hardware** colors: the swatch and the LED are the same number. So the
 editor offers the real ones as presets and any hex besides, but no system color picker,
 whose output would be a screen color that happens to be nearby.

 ## Less scrolling, same controls

 Each state used to be a block about 110pt tall — swatch, ten presets, a hex field, an
 effect picker, two sliders — and seven of those meant most of a screen of scrolling
 before reaching anything else. Now a state is one row, and the color controls sit in a
 popover behind its swatch. Nothing was dropped: presets, hex, speed and the hardware
 preview are all still there, one click further in, which is the right distance for
 values that are set once and then left.

 Ordered by how often a thing is touched rather than by how it is implemented: colors,
 how long they stay, the ring, then fun mode.
 */
struct ColorsPane: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands

    private let showColumns = [GridItem(.adaptive(minimum: 210), spacing: 10)]

    // MARK: - how long a color stays

    private var holdsDone: Bool { board.preferences.doneDecaySeconds <= 0 }

    /// Zero means never, which is what the registry's decay already understands — so
    /// the toggle writes the same field rather than adding a second source of truth.
    private var holdDoneBinding: Binding<Bool> {
        Binding(
            get: { holdsDone },
            set: { hold in
                board.updatePreferences { $0.doneDecaySeconds = hold ? 0 : 90 }
                commands.bindingsChanged()
            }
        )
    }

    private var doneSecondsBinding: Binding<Double> {
        Binding(
            get: { Double(max(10, board.preferences.doneDecaySeconds)) },
            set: { value in
                board.updatePreferences { $0.doneDecaySeconds = Int(value.rounded()) }
                commands.bindingsChanged()
            }
        )
    }

    private var holdAttentionBinding: Binding<Bool> {
        Binding(
            get: { board.preferences.holdAttention },
            set: { hold in
                board.updatePreferences { $0.holdAttention = hold }
                commands.bindingsChanged()
            }
        )
    }

    // MARK: - the ring

    private var currentAmbientMode: Ambient.Mode {
        Ambient.Mode(rawValue: board.preferences.ambient.mode) ?? .events
    }

    private var ambientModeBinding: Binding<Ambient.Mode> {
        Binding(
            get: { currentAmbientMode },
            set: { mode in
                board.updatePreferences { $0.ambient.mode = mode.rawValue }
                commands.bindingsChanged()
            }
        )
    }

    private var fixedColorBinding: Binding<Color> {
        Binding(
            get: { Color(board.preferences.ambient.fixed.color) },
            set: { picked in
                guard let rgb = RGB(picked) else { return }
                board.updatePreferences { $0.ambient.fixed.color = rgb }
                commands.bindingsChanged()
            }
        )
    }

    private var fixedBrightnessBinding: Binding<Double> {
        Binding(
            get: { board.preferences.ambient.fixed.brightness },
            set: { value in
                board.updatePreferences { $0.ambient.fixed.brightness = value }
                commands.bindingsChanged()
            }
        )
    }

    /// What the selected mode actually does. Restored because the four words on the
    /// segments are a name each, not a description — "Show the board" and "Laps only"
    /// are indistinguishable until you know that one holds a color and the other is
    /// dark between events.
    private var ambientExplanation: String {
        switch currentAmbientMode {
        case .events: "Dark, except for a lap when something changes."
        case .aggregate: "Holds the color of the most urgent session. Laps still fire."
        case .fixed: "Holds one color whatever the board is doing. Laps still fire."
        case .off: "Never lights, laps included."
        }
    }

    private func lapBinding(
        _ path: WritableKeyPath<Preferences.Ambient, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { board.preferences.ambient[keyPath: path] },
            set: { value in
                board.updatePreferences { $0.ambient[keyPath: path] = value }
                commands.bindingsChanged()
            }
        )
    }

    // MARK: - fun mode

    /// Both halves are required: the analysis without the video has nothing to sync to,
    /// and the video without the analysis has nothing to sync *with*.
    private var mediaPresent: Bool {
        guard let media = Countdown.mediaDirectory(
            configured: board.preferences.countdown.mediaDir
        ) else { return false }
        return Countdown.loadAnalysis(directory: media) != nil
            && Countdown.findVideo(directory: media) != nil
    }

    /// The song the Play button would start. Falls back to a bare verb rather than a
    /// guess: with no media there is no song to name, and the button is disabled anyway.
    private var selectedSong: String {
        guard let media = Countdown.mediaDirectory(
            configured: board.preferences.countdown.mediaDir
        ) else { return "" }
        return Countdown.songTitle(media.lastPathComponent)
    }

    /// Only a *refusal* is worth warning about. QuickTime reports nothing useful while
    /// it is not running, which is the normal state before fun mode starts — treating
    /// that as missing would be a permanent false alarm on a working machine.
    private var permissionMissing: Bool {
        PermissionProbe.automation(bundleID: "com.apple.QuickTimePlayerX") == .denied
    }

    // MARK: - body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // "Colors" was doing two jobs — page title and the heading for the
                // rows below it. The title goes; the heading it was quietly providing
                // has to stay, or the states arrive unannounced.
                PaneHeader("States", "What each one looks like on a session key.")
                statesSection

                HStack {
                    Button("Reset to defaults") { commands.resetColors() }
                        .controlSize(.small)
                    Spacer(minLength: 0)
                    Text("Saved to \(PreferencesStore.url().lastPathComponent)")
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.tertiary)
                }

                PaneHeader("How long a color stays", "When the board clears a color on its own.")
                holdSection

                PaneHeader("The ring", "The outer light, which summarises the whole board.")
                ringSection

                // Kept: "Fun mode" says nothing, and this one takes over the entire
                // board — including status — for four minutes.
                PaneHeader("Fun mode", "Takes over the whole pad, status included, for the song.")
                funSection
            }
            .padding(22)
        }
    }

    // MARK: - sections

    private var statesSection: some View {
        VStack(spacing: 0) {
            // Column headers, aligned to StateRow's fixed widths. The swatch is the
            // least discoverable control on the pane — it opens color, hex and speed —
            // so the leading header says so instead of naming the column.
            HStack(spacing: 12) {
                GroupLabel("STATE — CLICK THE SWATCH FOR COLOR, HEX & SPEED")
                Spacer(minLength: 8)
                GroupLabel("EFFECT").frame(width: 130, alignment: .leading)
                GroupLabel("BRIGHTNESS").frame(width: 90, alignment: .leading)
                // Same footprint as the row's play button, so the columns line up.
                Image(systemName: "play.fill").font(.system(size: 9)).hidden()
            }
            .padding(.top, 9)
            .padding(.bottom, 3)

            ForEach(Array(SessionState.displayOrder.enumerated()), id: \.element) { index, state in
                Divider().opacity(index > 0 ? 0.3 : 0.15)
                StateRow(state: state)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    private var holdSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            holdToggle(
                state: .done,
                title: "Keep finished sessions lit until you go back",
                detail: "Clears when you send that session something.",
                isOn: holdDoneBinding
            )

            if !holdsDone {
                HStack(spacing: 8) {
                    Text("Clears after")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Slider(value: doneSecondsBinding, in: 10...600, step: 10)
                        .frame(width: 200)
                    Text("\(board.preferences.doneDecaySeconds)s")
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                }
                .padding(.leading, 38)
            }

            Divider().opacity(0.35)

            holdToggle(
                state: .awaiting,
                title: "Keep sessions lit while they wait for you",
                detail: board.preferences.holdAttention
                    ? "Clears the moment the prompt is answered."
                    // Kept: an orange that vanishes on its own otherwise looks like the
                    // board losing track rather than a deliberate bound.
                    : "Clears when answered, or after 15 minutes if it never is.",
                isOn: holdAttentionBinding
            )
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    private var ringSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: ambientModeBinding) {
                Text("Laps only").tag(Ambient.Mode.events)
                Text("Show the board").tag(Ambient.Mode.aggregate)
                Text("One color").tag(Ambient.Mode.fixed)
                Text("Never light").tag(Ambient.Mode.off)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            if currentAmbientMode == .fixed {
                HStack(spacing: 10) {
                    ColorPicker("", selection: fixedColorBinding, supportsOpacity: false)
                        .labelsHidden()
                    Text(board.preferences.ambient.fixed.color.hex)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                    Slider(value: fixedBrightnessBinding, in: 0...1).frame(width: 150)
                    Text("\(Int(board.preferences.ambient.fixed.brightness * 100))%")
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Text(ambientExplanation)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Above the laps, because it is not one: a lap fires and ends, this holds
            // for as long as the machine is listening.
            VStack(spacing: 0) {
                lapToggle("Spin while dictating", isOn: lapBinding(\.voiceRainbow))
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))

            GroupLabel("LAPS")
            VStack(spacing: 0) {
                lapToggle("A chat finishes", isOn: lapBinding(\.completionLap))
                Divider().opacity(0.3)
                lapToggle("One needs you", isOn: lapBinding(\.questionLap))
                Divider().opacity(0.3)
                lapToggle("One fails", isOn: lapBinding(\.errorPulse))
            }
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
            .disabled(currentAmbientMode == .off)
            .opacity(currentAmbientMode == .off ? 0.45 : 1)

            GroupLabel("PLAY ONE NOW")
            LazyVGrid(columns: showColumns, spacing: 10) {
                ForEach(Shows.all, id: \.name) { show in
                    ShowCard(show: show, running: board.runningShow == show.name) {
                        commands.playShow(show.name)
                    }
                }
            }
        }
    }

    /**
     One lap switch: label hard left, switch hard right.

     A `Toggle` carrying its own label is only as wide as it needs to be, and the
     enclosing `VStack` centres it — which put the text and the switch together in the
     middle of the row with empty space on both sides, reading as neither a list nor a
     form. An explicit `HStack` with a `Spacer` is the only version that cannot drift.
     */
    /**
     A hold switch, with the color it is talking about.

     The labels used to name the colors — "keep finished sessions **green**" — which is
     wrong the moment anyone edits the palette directly above. The swatch is read from
     the same configured appearance the pad emits, so the sentence stays true whatever
     `done` and `awaiting` have been set to.
     */
    private func holdToggle(
        state: SessionState,
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        let appearance = board.appearances[state] ?? state.defaultAppearance
        return HStack(spacing: 10) {
            Circle()
                .fill(Color(appearance.color))
                .frame(width: 10, height: 10)
                .overlay { Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private func lapToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12.5))
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 7)
    }

    private var funSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(board.funModeRunning ? "Stop"
                        : selectedSong.isEmpty ? "Play" : "Play \(selectedSong)") {
                    commands.playCountdown()
                }
                .disabled(!board.device.isUsable || !mediaPresent)
                if board.funModeRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            if !mediaPresent {
                Text("No video installed — put one in \(AppPaths.media().path).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(RGB(0xFF6A00)))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Said here as well as in the log, because a deliberately dark pad and a
                // broken one look identical — two early runs were cancelled at 3 and 10
                // beats, well before it was going to light.
                Text(
                    "The ring stays dark for the first "
                        + "\(String(format: "%.1f", board.preferences.countdown.introFlashSec))s."
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }

            if permissionMissing {
                Text("Needs Automation → QuickTime Player, on the Device pane.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(RGB(0xFF6A00)))
            }
        }
    }
}

/**
 One state, as a single row.

 Swatch, name, effect, brightness — the four worth seeing for all seven states at once.
 Everything else lives behind the swatch: presets, hex and speed are set once and then
 left, while comparing states against each other is what this pane is for.
 */
private struct StateRow: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands

    let state: SessionState
    @State private var editing = false

    private var appearance: Appearance {
        board.appearances[state] ?? state.defaultAppearance
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { editing = true } label: {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(appearance.color))
                    // Brightness reads as opacity, so a row at 20% does not claim the
                    // same presence as one at 100%.
                    .opacity(appearance.effect == .off ? 0.15 : 0.35 + 0.65 * appearance.brightness)
                    .frame(width: 26, height: 26)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .help("Color, hex and speed")
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                // Re-injected by hand: popover content hosts in its own window, and
                // macOS does not reliably carry custom environment values across
                // that boundary. Without this the editor resolves the *default*
                // BoardCommands — every closure a silent no-op — so a color picked
                // here painted the swatch, saved nothing, and reverted on relaunch.
                ColorEditor(state: state).padding(14)
                    .environmentObject(board)
                    .environment(\.boardCommands, commands)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(state.label).font(.system(size: 12.5, weight: .medium))
                // Kept: `stalled` and `viewing` are this product's words, not anything
                // anyone arrives already knowing.
                Text(state.means)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if appearance.color.isNearWhite, appearance.effect != .off {
                    Text("Near-white — the pad rests white, so this reads as unlit.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color(RGB(0xFF6A00)))
                }
            }

            Spacer(minLength: 8)

            Picker("", selection: effectBinding) {
                // The spatial effects are not offered: snake and gradient only mean
                // anything on the multi-LED ring and render a single key dark.
                ForEach([LEDEffect.solid, .breath, .shallowBreath, .rainbow, .off], id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Slider(value: brightnessBinding, in: 0...1).frame(width: 90)

            Button { commands.previewState(state) } label: {
                Image(systemName: "play.fill").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Show this state on the pad")
        }
        .padding(.vertical, 7)
    }

    private var effectBinding: Binding<LEDEffect> {
        Binding(get: { appearance.effect }, set: { effect in update { $0.effect = effect } })
    }

    private var brightnessBinding: Binding<Double> {
        Binding(get: { appearance.brightness }, set: { value in update { $0.brightness = value } })
    }

    private func update(_ change: (inout Appearance) -> Void) {
        var next = appearance
        change(&next)
        board.appearances[state] = next
        commands.bindingsChanged()
    }
}

/// The color itself: presets, hex, and speed when the effect moves.
private struct ColorEditor: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands

    let state: SessionState
    @State private var hexDraft = ""
    @FocusState private var hexFocused: Bool

    /// The hardware legend, plus a few useful neighbours.
    ///
    /// Presets rather than a color wheel because these are the values the product's
    /// vocabulary is built on — and because picking "roughly orange" off a wheel is how
    /// `awaiting` stops being unmistakable.
    private static let presets: [(name: String, rgb: RGB)] = [
        ("Slate", RGB(0x2E4A6B)),
        ("Blue", RGB(0x0C47E9)),
        ("Orange", RGB(0xFF6A00)),
        ("Green", RGB(0x09B821)),
        ("Crimson", RGB(0xD41145)),
        ("Violet", RGB(0x7B2FF7)),
        ("Cyan", RGB(0x00C8D7)),
        ("Amber", RGB(0xFFB300)),
        ("Magenta", RGB(0xE81CA8)),
        ("Off-black", RGB(0x000000)),
    ]

    private var appearance: Appearance {
        board.appearances[state] ?? state.defaultAppearance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.label).font(.system(size: 12.5, weight: .semibold))

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 5),
                spacing: 8
            ) {
                ForEach(Self.presets, id: \.name) { preset in
                    Button { update { $0.color = preset.rgb } } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(preset.rgb))
                            .frame(width: 24, height: 24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        appearance.color == preset.rgb
                                            ? Color.primary : .black.opacity(0.25),
                                        lineWidth: appearance.color == preset.rgb ? 2 : 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }

            TextField("hex", text: $hexDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5).monospaced())
                .frame(width: 96)
                .focused($hexFocused)
                .onSubmit(commitHex)
                // Committed on blur too, so a typed value is not silently lost by
                // clicking away.
                .onChange(of: hexFocused) { _, focused in if !focused { commitHex() } }

            if appearance.effect.isAnimated {
                HStack(spacing: 8) {
                    Text("Speed").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Slider(value: speedBinding, in: 0...1).frame(width: 110)
                    Text("\(Int(appearance.speed * 100))%")
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .frame(width: 214)
        .onAppear { hexDraft = appearance.color.hex }
        .onChange(of: appearance.color) { _, new in
            if !hexFocused { hexDraft = new.hex }
        }
    }

    private func commitHex() {
        guard let parsed = RGB(hex: hexDraft) else {
            hexDraft = appearance.color.hex
            return
        }
        update { $0.color = parsed }
        hexDraft = parsed.hex
    }

    private var speedBinding: Binding<Double> {
        Binding(get: { appearance.speed }, set: { value in update { $0.speed = value } })
    }

    private func update(_ change: (inout Appearance) -> Void) {
        var next = appearance
        change(&next)
        board.appearances[state] = next
        commands.bindingsChanged()
    }
}

/// A small-caps label for a group inside a section.
///
/// One step below `PaneHeader`: a section says what part of the product this is, a
/// group label says what the next few rows have in common. Used where the difference
/// matters — three switches and six buttons under one heading read as nine unrelated
/// controls without it.
struct GroupLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold)).kerning(0.8)
            .foregroundStyle(.tertiary)
    }
}
