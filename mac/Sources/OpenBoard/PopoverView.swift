import OpenBoardKit
import SwiftUI

/**
 The menu bar popover.

 Section order is the design's, and it is an order of urgency: what the pad is doing,
 then anything blocked on you, then the six sessions, then the action keys, then the
 commands. 376pt wide and internally scrollable so a long chat title never widens it.

 When the pad is unusable the session list is replaced entirely rather than shown
 greyed out. Everything below the header would be describing hardware that is not
 listening, and a board you cannot trust is worse than no board.
 */
struct PopoverView: View {
    @EnvironmentObject private var board: BoardModel
    @EnvironmentObject private var battery: BatteryMonitor
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var setup: SetupState
    @Environment(\.boardCommands) private var commands

    private let width: CGFloat = 376

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)

            // Setup first, then the hardware. An install missing hooks has a working
            // pad and six keys that will never change — showing that board is showing
            // something that looks live and is not, which is worse than showing
            // nothing. The device states below are for a set-up install whose pad has
            // gone away.
            if !setup.isReady {
                SetupNeededView(
                    progress: setup.progress,
                    sessions: board.slots.filter(\.isLive).count,
                    startSetup: {
                        commands.dismissMenu()
                        commands.openSetup()
                    }
                )
            } else if board.device.isUsable {
                // Deliberately *not* a ScrollView. Inside a MenuBarExtra window it is
                // proposed no height and collapses to nothing — which is exactly how the
                // session list came to be invisible while the commands below it rendered
                // fine. The content is a fixed six rows plus the action keys, so it has a
                // known height and never needs to scroll.
                VStack(spacing: 0) {
                    if !board.blocked.isEmpty { blockedRow }
                    sessions
                    Divider().opacity(0.6)
                    actionKeys
                }
            } else {
                DisconnectedView(
                    status: board.device,
                    name: board.deviceName,
                    retry: { commands.sync() },
                    startSetup: {
                        commands.dismissMenu()
                        commands.openSetup()
                    }
                )
            }

            Divider().opacity(0.6)
            updateRow
            commandRows
        }
        .frame(width: width)
        // Cheap, and this is the only moment anyone is looking. A popover that opened
        // with a stale answer would keep offering setup after it was finished.
        .onAppear { setup.refresh() }
    }

    // MARK: update

    /**
     There is a new version — shown only when there is.

     Placed down here with the commands rather than up top with the blocked row, and
     that is a judgement about urgency rather than layout. A blocked session is costing
     you time right now; a new version is not. Putting them in the same place would
     teach you to skim past the one that matters.

     It also deliberately does not borrow the pad's colours. Orange, green, blue and red
     mean specific *session* states on the hardware and in this window, and an app update
     is not a session state — a green update row would read as "a chat finished" to
     anyone who has learned the board. So it takes the neutral control treatment and
     earns attention by being absent the rest of the time.
     */
    @ViewBuilder
    private var updateRow: some View {
        if let version = updater.status.updateVersion {
            Button { commands.showAvailableUpdate() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Version \(version) is available")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                    Text("Install")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassControl()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.top, 9)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(board.device.isUsable ? Color(RGB(0x09B821)) : Color(RGB(0xD41145)))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(board.device.headline(board.deviceName))
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if board.device.isUsable {
                BatteryBadge(percent: battery.percent, isCharging: board.isWired)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
        // Read when the popover opens, which is the only moment anyone is looking at
        // it. The background poll is deliberately slow.
        .onAppear { battery.refresh() }
    }

    private var subtitle: String {
        // `isOccupied` means "holds a session record", which stays true after the
        // session ends — so this counted five with three of them closed. It is the
        // running ones.
        let live = board.slots.filter(\.isLive).count
        let blocked = board.blocked.count
        // "sessions", not "live". Both surfaces say it, and "live" was doing the work
        // of a qualifier nobody asked for — a session that is not running is not on
        // the board at all.
        var parts = ["\(live) session\(live == 1 ? "" : "s")"]
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.joined(separator: " · ")
    }

    // MARK: blocked

    private var blockedRow: some View {
        Button {
            if let first = board.blocked.first { commands.jump(first.slot) }
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(RGB(0xFF6A00)))
                    .frame(width: 9, height: 9)
                    .shadow(color: Color(RGB(0xFF6A00)), radius: 5)
                Text(blockedText)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
                Text("⏎").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassAccent(Color(RGB(0xFF6A00)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    /// With two or more blocked, the pad's approve key refuses to guess between
    /// them — so the row says which, rather than implying a single target.
    private var blockedText: String {
        let blocked = board.blocked
        if blocked.count == 1 {
            let slot = blocked[0]
            let tool = slot.pendingTool.map { " on \($0)" } ?? ""
            return "Slot \(slot.slot) is waiting\(tool)"
        }
        let slots = blocked.map { String($0.slot) }.joined(separator: " and ")
        return "Slots \(slots) are waiting — press one of those keys"
    }

    // MARK: sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Agent keys")
            ForEach(board.slots) { slot in
                SessionRow(
                    slot: slot,
                    capID: board.caps[slot.key],
                    jump: { commands.jump(slot.slot) },
                    release: { commands.release(slot.slot) }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: action keys

    /**
     The action keys, laid out as they physically are.

     Previously a three-column grid in reading order, which put ACT09 underneath ACT06
     and stood the double-width MIC cap up as an ordinary square. Neither matches the
     object under your hand: on the pad, ACT06–ACT09 are one row of four, and the
     bottom row is the touch strip, a 2U cap, and one more key.

     So this renders `BoardLayout.rows`' last two rows through the same `BoardCapView`
     the settings window draws the pad with — same 51pt caps, same 2U geometry, same
     materials. Reaching for a key in the menu should be the same spatial act as
     reaching for it on the desk, and two different pictures of one keyboard is a
     memory tax for no benefit.

     `Grid`, not `LazyVGrid`: only `Grid` honours `gridCellColumns`, and without it the
     wide cap silently collapses and the row comes out a column short.

     ## The touch strip is a hole, not a key

     It is drawn on the pad in the settings window because it is physically there, and
     the window is a picture of the object. Here it was a black disc labelled "inert" —
     a control offering nothing, in a menu whose every other item does something.

     It is left out, but **its column is not**. An empty cell of the same width keeps
     the 2U cap in the position your hand knows; deleting the cell outright slides the
     whole bottom row one key to the left and the picture stops being true.
     */
    private var actionKeys: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Action keys")
            // One container for the whole block: side by side, independently sampled
            // glass leaves a hard seam between caps, and grouped they blend at the
            // edges the way a single sheet of material does.
            GlassGroup(spacing: 7) {
                Grid(horizontalSpacing: 7, verticalSpacing: 12) {
                    ForEach(Array(BoardLayout.rows.suffix(2).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(row, id: \.id) { cell in
                                keyCell(cell).gridCellColumns(cell.span)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// A caption may use its key's width plus a little of the gutter either side, but
    /// never enough to touch the next one — 3pt of clear space is what keeps two
    /// wrapped names from reading as one paragraph.
    private func captionWidth(for cell: BoardCell) -> CGFloat {
        let unit: CGFloat = 51, gap: CGFloat = 7
        let key = unit * CGFloat(cell.span) + gap * CGFloat(cell.span - 1)
        return key + gap - 3
    }

    @ViewBuilder
    private func keyCell(_ cell: BoardCell) -> some View {
        if case .element(.touch) = cell.kind {
            Color.clear.frame(width: 51, height: 51)
        } else {
            VStack(spacing: 6) {
                BoardCapView(
                    cell: cell,
                    slot: nil,
                    capID: board.caps[cell.id],
                    action: board.actions[cell.id],
                    isSelected: false,
                    isFlat: true
                )
                /*
                 The name earns its place; the ACT id does not. It is what you type into
                 the settings window, not what you need while deciding which key to
                 press.

                 Held to the key's own width so it wraps instead of running under its
                 neighbours — "new Terminal tab" is nearly three keys wide as one line,
                 which is what made the first row look crooked. Two lines are reserved
                 whether or not the second is used, so every key in a row sits on the
                 same baseline, and the scale factor lets a stubborn name shrink a
                 little rather than truncate into "new Terminal…".
                 */
                Text(board.actions[cell.id]?.short ?? "unassigned")
                    .font(.system(size: 10.5))
                    .foregroundStyle(board.actions[cell.id] == nil ? .tertiary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.82)
                    .frame(width: captionWidth(for: cell))
            }
        }
    }

    // MARK: commands

    private var commandRows: some View {
        VStack(spacing: 1) {
            MenuRow("Find running sessions") { commands.reconnect() }
            // Close first, then open. The panel's dismissal is a click on the status
            // item, and doing it *after* activating our own window would land the click
            // while focus is already moving — which is how this reads as ignored.
            MenuRow("Settings") {
                commands.dismissMenu()
                commands.openSettings()
            }
            MenuRow("Quit OpenBoard", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 9)
    }
}

// MARK: - pieces

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
    }
}

/**
 One key's row.

 Two lines: what you asked this session for, and where it is running. The name matters
 because six rows of the same repo name is not a board — it tells you which *project*
 is busy, never which *chat*.

 The remove control replaces the state badge on hover rather than appearing beside it.
 Adding a control on hover shifts everything left of it, so the row you are pointing at
 moves out from under the cursor at the moment you decide to click.
 */
struct SessionRow: View {
    let slot: SlotView
    let capID: String?
    var jump: () -> Void = {}
    var release: () -> Void = {}
    @State private var hovering = false

    private var showsRelease: Bool { slot.isOccupied && hovering }

    var body: some View {
        // The release control is a *sibling* of the row button, not a child. Nested
        // buttons on macOS can deliver the click to both, which here would free the key
        // and jump to the session at the same time.
        ZStack(alignment: .trailing) {
            Button(action: jump) { rowContent }
                .buttonStyle(HoverRowStyle())
                // Not `.disabled`: a disabled button stops reporting hover, and the
                // release control's visibility depends on it.
                .allowsHitTesting(slot.isOccupied)

            if showsRelease {
                Button(action: release) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Stop tracking this session and free its key. The session keeps running.")
            }
        }
        .onHover { hovering = $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(slot.swatch)
                .frame(width: 9, height: 9)
                .shadow(color: slot.swatch.opacity(slot.isOccupied ? 0.9 : 0), radius: 4)

            if let capID, let icon = KeycapCatalog.icon(forCap: capID) {
                KeycapIconView(icon: icon)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(.secondary)
            }

            Text("\(slot.slot)")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 9, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title ?? (slot.isOccupied ? "Untitled chat" : "Free"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(slot.isOccupied ? .primary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if slot.isOccupied {
                    HStack(spacing: 5) {
                        if let origin = slot.origin { OriginBadge(origin: origin) }
                        if !slot.detail.isEmpty {
                            Text(slot.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            Spacer(minLength: 6)

            // Hidden rather than removed while the release control is showing, so the
            // row does not reflow under the pointer at the moment of clicking.
            if let state = slot.state {
                StateBadge(state: state).opacity(showsRelease ? 0 : 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(.rect)
    }
}

/// Where a session is running, as a scannable pill rather than a word in a sentence.
///
/// It is the one attribute you cannot infer from the name, and it predicts what
/// pressing the key will do: a Terminal session is raised exactly, by tty, while
/// anything else is approximate.
struct OriginBadge: View {
    let origin: SessionOrigin

    var body: some View {
        Text(origin.rawValue)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 4))
    }
}

struct StateBadge: View {
    let state: SessionState

    var body: some View {
        Text(state.label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tint.opacity(0.18), in: .capsule)
    }

    /// The badge borrows the hardware color so screen and pad agree, but `idle`
    /// stays neutral — most keys sit there most of the time, and a colored badge on
    /// all six would drown the one that matters.
    private var tint: Color {
        switch state {
        case .idle, .ended: .secondary
        default: Color(state.defaultAppearance.color)
        }
    }
}

/**
 The pad's battery, where the Sync button used to be.

 Sync went because it had little to do: the resident loop repaints every ten seconds
 anyway, so the button mostly re-did work that was already happening. A number you
 cannot get anywhere else is worth more than a button that duplicates a timer.

 Drawn as a real battery outline rather than bare text so it reads at a glance, and
 coloured only when it is low — a green battery at 80% is decoration, an orange one at
 15% is information.
 */
struct BatteryBadge: View {
    let percent: Int?
    /**
     On the cable.

     The percentage comes from the GATT battery service, which is only reachable over
     Bluetooth — and plugging the pad in drops that link entirely. So while charging
     there is no reading to be had, and the last one is minutes or hours old.

     Showing that stale number beside a charging pad is the kind of quiet lie this app
     exists not to tell: it would sit at 35% while the thing filled up. The bolt says
     what is actually known — attached to power, percentage unavailable — and the badge
     stops pretending to a live reading.
     */
    var isCharging: Bool = false

    private var tint: Color {
        if isCharging { return Color(RGB(0x09B821)) }
        guard let percent else { return .secondary }
        if percent <= 10 { return Color(RGB(0xD41145)) }
        if percent <= 25 { return Color(RGB(0xFF6A00)) }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 5) {
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(isCharging ? "USB" : (percent.map { "\($0)%" } ?? "—"))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(tint)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(tint.opacity(0.55), lineWidth: 1)
                    .frame(width: 22, height: 11)
                if let percent, !isCharging {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(tint)
                        // Never wider than the shell, and never invisible at 1% —
                        // a bar that vanishes reads as "no reading" rather than "low".
                        .frame(width: max(2, 20 * Double(min(100, percent)) / 100), height: 8)
                        .padding(.leading, 1)
                }
            }
            .overlay(alignment: .trailing) {
                // The nub.
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint.opacity(0.55))
                    .frame(width: 2, height: 4)
                    .offset(x: 3)
            }
        }
        .help(isCharging
            ? "Plugged in over USB. The battery level is published over Bluetooth, "
                + "which the pad drops while it is on the cable."
            : percent == nil
                ? "Battery not read yet — the pad may be asleep."
                : "Codex Micro battery")
    }
}

struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void

    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut).font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(HoverRowStyle(tint: SystemColors.hover))
    }
}

/// The pad is unreachable, so this replaces the board rather than dimming it.
struct DisconnectedView: View {
    let status: DeviceStatus
    var name: String = "Codex Micro"
    var retry: () -> Void = {}
    var startSetup: () -> Void = {}

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle().fill(Color(RGB(0xD41145)).opacity(0.24))
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(Color(RGB(0xFF9DB2)))
            }
            .frame(width: 38, height: 38)

            Text(status.headline(name))
                .font(.system(size: 13.5, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // The part that varies, and the only part that says what to do about it —
            // so it must never be the part that gets cut.
            //
            // `maxWidth` alone truncated it. Inside a fixed-width popover SwiftUI
            // proposes one line's height and Text obeys, so "check that it is on
            // Layer 1" — the actual fix, and the least guessable thing this app knows
            // — became an ellipsis. fixedSize makes it claim the height it needs and
            // wrap instead.
            Text(status.message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 296)
                .fixedSize(horizontal: false, vertical: true)

            // A permission is not fixed by asking again. Retrying puts the same
            // question to macOS and gets the same answer, so for that case the button
            // has to lead somewhere the answer can change.
            Button(status.needsSetup ? "Start setup" : "Try again") {
                if status.needsSetup { startSetup() } else { retry() }
            }
            .glassButton(prominent: true)
            .padding(.top, 3)
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }
}

// MARK: - button styles

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.1), in: .rect(cornerRadius: 6))
    }
}

// PrimaryButtonStyle drew its own filled capsule in the accent color. `.glassProminent`
// is the system's version of the same idea and picks up the material, the press state
// and the accent without reimplementing any of it.

struct HoverRowStyle: ButtonStyle {
    /// Follows the system highlight rather than a fixed grey. See `SystemColors`.
    var tint: Color = SystemColors.hover
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering ? tint : .clear, in: .rect(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}

/**
 The board is not shown yet, and why.

 Distinct from `DisconnectedView`, which is about the hardware. This one is about the
 install: the pad may be sitting there connected and perfectly happy, and the six keys
 would still never change, because nothing is reporting. A board that looks live and is
 not is worse than no board — it is the difference between "my pad is broken" and "I
 have not finished".

 It names the remaining steps rather than saying "setup incomplete". The count is what
 turns an unknown obligation into a short errand.
 */
struct SetupNeededView: View {
    let progress: SetupProgress
    /// How many sessions are already running. Said out loud because the alternative
    /// reads as "nothing is working" — the app has found them, it simply cannot show a
    /// board worth trusting yet, and those are very different problems.
    var sessions: Int = 0
    var startSetup: () -> Void = {}

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle().fill(Color(RGB(0x0C47E9)).opacity(0.18))
                Image(systemName: "checklist")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(RGB(0x6C93FF)))
            }
            .frame(width: 38, height: 38)

            Text("\(progress.requiredDone) of \(progress.requiredTotal) set up")
                .font(.system(size: 13.5, weight: .semibold))

            if sessions > 0 {
                Text("\(sessions) session\(sessions == 1 ? "" : "s") found — "
                     + "the keys stay dark until this is finished.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 296)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(remaining)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 296)
                .fixedSize(horizontal: false, vertical: true)

            Button("Continue setup") { startSetup() }
                .glassButton(prominent: true)
                .padding(.top, 3)
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }

    private var remaining: String {
        let missing = SetupProgress.Step.allCases
            .filter { $0.isRequired && !progress.isDone($0) }
        guard !missing.isEmpty else { return "Almost there." }
        return "Still needed: " + missing.map(label).joined(separator: ", ") + "."
    }

    private func label(_ step: SetupProgress.Step) -> String {
        switch step {
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        case .automation: "Automation"
        case .calibration: "key order"
        case .hooks: "Claude Code hooks"
        case .openAtLogin: "Open at login"
        }
    }
}
