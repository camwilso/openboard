import OpenBoardKit
import SwiftUI

/**
 The settings window: a sidebar and five panes, all real. Hosted in a window the app owns rather than a SwiftUI `Settings`
 scene — see `MainWindowController` for why that distinction turned out to matter.

 The sidebar is color-chipped icons and a status group that answers "is this working"
 without navigating anywhere.

 It had a search field, copied from CodexBar, which has a long provider list to filter.
 This window has four panes, all visible at once — searching a list you can already see
 is a control that can only ever narrow it to something you were looking at.
 */
struct SettingsWindow: View {
    @EnvironmentObject private var board: BoardModel
    /**
     What the detail side is showing.

     A pane or a harness, because the sidebar now lists both and they are not the same
     kind of thing: a pane is a subject, a harness is one of several instances of one.
     Modelling it as a single enum keeps `List` selection working — two selection
     states in one list means clicking either leaves the other highlighted.
     */
    enum Selection: Hashable {
        case pane(Pane)
        case harness(String)
    }

    @State private var selection: Selection = .pane(.board)
    @State private var installed: Set<String> = []

    enum Pane: String, CaseIterable, Identifiable {
        case board = "Board"
        case colors = "Colors"
        case device = "Device"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .board: "square.grid.3x2"
            case .colors: "paintpalette"
            case .device: "cable.connector"
            }
        }

        /// One color per pane, as System Settings and CodexBar both do it.
        ///
        /// The color is the thing you actually navigate by once you know the window —
        /// it is recognisable in peripheral vision in a way a monochrome glyph is not.
        var tint: Color {
            switch self {
            case .board: Color(RGB(0x0C47E9))
            case .colors: Color(RGB(0xD41145))
            case .device: Color(RGB(0x09B821))
            }
        }

    }


    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section {
                        ForEach(Pane.allCases) { item in
                            SidebarRow(pane: item).tag(Selection.pane(item))
                        }
                    }

                    /*
                     The three harnesses, where CodexBar puts its providers.

                     Only the three OpenBoard can actually drive. The harness pane knows
                     about thirteen and can say which are on the machine, but a sidebar
                     is navigation: every row here has to go somewhere, and ten rows
                     that only report a fact would be a list you cannot click.

                     A row is lit when its agent is installed *and* reporting. Grey is
                     "not connected", which covers both "not here" and "here but not
                     wired" — the pane says which.
                    */
                    Section {
                        ForEach(Harness.all) { item in
                            HarnessRow(
                                harness: item,
                                connected: installed.contains(item.id),
                                everSeen: board.preferences.harnessesSeen.contains(item.id)
                            )
                            .tag(Selection.harness(item.id))
                        }
                    } header: {
                        Text("HARNESS")
                            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(.tertiary)
                    }

                    // Live state, not navigation — the board's own status. It answers
                    // "is this thing working" without changing pane.
                    Section {
                        StatusRow(
                            // Just "Connected" here. The pad's name is worth carrying
                            // in the menu bar, where it is the only thing identifying
                            // which board you are looking at; in a window whose title
                            // is already the app, it was a long line saying little.
                            title: board.device.isUsable ? "Connected" : "Pad unavailable",
                            detail: board.device.isUsable
                                ? "\(liveCount) session\(liveCount == 1 ? "" : "s")"
                                : board.device.headline(board.deviceName),
                            ok: board.device.isUsable
                        )
                    } header: {
                        Text("STATUS")
                            .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.sidebar)
                // The list draws its own backdrop, which over the window's material is
                // a second pane of frosted glass on top of the first — the seam down
                // the middle of the window. Cleared, so the one behind shows through.
                .scrollContentBackground(.hidden)
            }
            .onAppear(perform: refreshHarnesses)
            /*
             Fixed, and wide enough for the longest thing in it.

             `min == ideal == max` is what makes it fixed: with a range, the divider is
             draggable and the column takes whatever width the window was last left at,
             which is how "Claude Code" became "Clau…" in a 268pt sidebar. A settings
             window has four panes and nothing to gain from a resizable sidebar.

             250 is the longest row — "Connected to <pad name>" — plus its dot and
             insets, measured rather than guessed.
            */
            .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 250)
            // Belt and braces. `navigationSplitViewColumnWidth` states the column's
            // width; it does not stop the split view proposing less to the content
            // inside it, which is how "Claude Code" came back as "Claude…" in a column
            // that was supposed to be fixed at 250.
            .frame(minWidth: 250)
            // The floating glyph above the list was NavigationSplitView's own collapse
            // toggle. A settings window has exactly two panes and nothing to gain from
            // hiding one of them, so it was a control that could only make the window
            // worse — and it read as a broken icon rather than as a button.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                // Device is deliberately ungated. It is the pane that says which
                // permission is missing, so blocking it because a permission is missing
                // would be a locked door with the key behind it.
                switch selection {
                case .pane(.board):
                    BoardPane().requiresSetup("What each key does")
                case .pane(.colors):
                    ColorsPane().requiresSetup("How the keys look")
                case .pane(.device):
                    DevicePane()
                case let .harness(id):
                    HarnessPane(harnessID: id).requiresSetup("How this harness is shown")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Same reason as the sidebar: every pane is a ScrollView, and a ScrollView
            // paints an opaque background over the window's material by default.
            .scrollContentBackground(.hidden)
        }
        // Nothing to collapse and nothing to drag, so the divider is decoration
        // separating two halves of one surface.
        .navigationSplitViewStyle(.balanced)
        // Without this the sidebar selection is a fixed blue whatever the user chose:
        // SwiftUI resolves the accent from an asset catalog, and a SwiftPM build has
        // none. See SystemColors.
        .tint(SystemColors.selectedRow)
    }

    private var liveCount: Int { board.slots.filter(\.isLive).count }

    /// Installed *and* wired. The dot is the same claim the harness pane's card makes,
    /// computed once here so the two cannot disagree.
    private func refreshHarnesses() {
        let found = Set(
            HarnessDetector.survey().filter(\.installed).compactMap { $0.agent.harnessID }
        )
        let audit = HookInstall.audit(
            settings: HookInstall.loadSettings(),
            expectedCommand: HookInstall.hookCommandPath()
        )
        installed = Set(
            Harness.all
                .filter { found.contains($0.id) && ($0.setup == .automatic ? audit.isHealthy : true) }
                .map(\.id)
        )
    }
}

/// A sidebar row: color-chipped icon, then the name.
struct SidebarRow: View {
    let pane: SettingsWindow.Pane

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(pane.tint)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            Text(pane.rawValue).font(.system(size: 13))
        }
        .padding(.vertical, 1)
    }
}

/// Live state in the sidebar, with a dot rather than a chip — it is not somewhere you
/// can navigate to, and a chip would say otherwise.
struct StatusRow: View {
    let title: String
    let detail: String
    let ok: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(ok ? Color(RGB(0x09B821)) : Color(RGB(0xFF6A00)))
                .frame(width: 7, height: 7)
                .padding(.leading, 7)
                // Aligned to the first line rather than centred on a block whose height
                // now changes with the name.
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 0) {
                /*
                 Wraps, rather than truncating.

                 A pad can be called anything, and this is the one line in the window
                 that names it — "Connected to…" is the least useful half of the
                 sentence to keep. `fixedSize` vertically is what actually does it: a
                 sidebar row proposes a height for one line, and without it the text
                 takes that proposal and truncates instead of growing.
                */
                Text(title)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        // Not selectable: it is a readout, and letting it take selection would leave
        // the detail pane showing a pane that is no longer highlighted.
        .allowsHitTesting(false)
    }
}

/**
 The pad, drawn as the object on your desk.

 A case, a plate with screws, and keys that catch light — because the window's job is
 to let you point at a key here and know which one your hand will find. A flat grid of
 squares needs translating; this does not.

 ## Selection

 Nothing is selected until you click. The inspector then opens *beside* the pad rather
 than under it, so the key you are editing stays visible and in the same place while
 you change it — a panel below pushes the board around as it grows and shrinks, and
 you lose track of which cap you picked.

 It closes, too. An inspector that cannot be dismissed is a permanent column of
 controls for a decision you already made.
 */
struct BoardPane: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands
    /// Deliberately nil at first. Opening on a preselected key implies you asked about
    /// it, and hides the fact that the board is the thing to click.
    @State private var selected: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // No page title: the sidebar already says which pane this is, and a
                // heading that repeats the selected row is a line of chrome between you
                // and the first setting.
                PaneHeader("Name", "What this pad is called everywhere in OpenBoard.")
                nameRow

                PaneHeader("Map keys", "Click a key to see what it does and change its cap.")
                HStack(alignment: .top, spacing: 20) {
                    padCase
                    if let selected, let cell = BoardLayout.cell(id: selected) {
                        CapInspector(cell: cell) { self.selected = nil }
                            .frame(width: 300)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(22)
        }
    }

    /**
     Name this pad.

     Every Codex Micro reports the same product name, so "Connected to Codex Micro"
     tells someone with two of them nothing — and macOS's own answer is a pairing
     counter, "#1" and "#3", which describes this Mac's history rather than the object
     on the desk.

     Filed under the hardware serial, so the name follows the pad rather than the port
     it is plugged into, and survives re-pairing.

     Disabled with no pad attached: there is nothing to name, and a field that accepts
     a name and files it under nothing is worse than one that will not take it.
     */
    private var nameRow: some View {
        HStack(spacing: 10) {
            TextField("Codex Micro", text: nameBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .disabled(board.deviceSerial == nil)
            // The serial is still what the name is filed under; it is just not
            // something anyone needs to read. Kept only for the case the field cannot
            // be used at all, where the reason matters.
            if board.deviceSerial == nil {
                Text("No pad attached")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { board.deviceSerial.flatMap { board.preferences.deviceNames[$0] } ?? "" },
            set: { name in
                guard let serial = board.deviceSerial else { return }
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                board.updatePreferences {
                    // Cleared rather than stored empty, so the placeholder comes back
                    // and the file does not accumulate blank entries.
                    if trimmed.isEmpty {
                        $0.deviceNames.removeValue(forKey: serial)
                    } else {
                        $0.deviceNames[serial] = trimmed
                    }
                }
                commands.bindingsChanged()
            }
        )
    }

    /**
     The pad itself.

     Built outward from the grid — `padding` then `background` then `padding` then
     `background` — so each layer is exactly the size of what it wraps. The previous
     version used a `ZStack` whose screws were positioned with
     `frame(maxHeight: .infinity)`, which made the whole stack greedy: the pad stretched
     to whatever height the inspector beside it happened to be, and grew as you
     selected keys. Screws are `overlay` now, which does not participate in layout.

     Shadows are deliberately sparse. Three of them stacked — plate, case, and one per
     key — plus a `plusLighter` rim turned a flat object into a cloud. The plate carries
     none at all: on the real pad it is a recess, and a recess does not cast.
     */
    private var padCase: some View {
        Grid(horizontalSpacing: 7, verticalSpacing: 7) {
            ForEach(Array(BoardLayout.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.id) { cell in
                        BoardCapView(
                            cell: cell,
                            slot: cell.slot.flatMap { slot in
                                board.slots.first { $0.slot == slot }
                            },
                            capID: board.caps[cell.id],
                            action: board.actions[cell.id],
                            isSelected: selected == cell.id
                        )
                        .gridCellColumns(cell.span)
                        .onTapGesture { selected = cell.id }
                    }
                }
            }
        }
        // No width here. The caps are explicitly sized, so the grid is exactly
        // 4 x 51 + 3 x 7 = 225 and the plate wraps whatever that comes to.
        .padding(22)
        .background(plate)
        .overlay(alignment: .topLeading) { screw }
        .overlay(alignment: .topTrailing) { screw }
        .overlay(alignment: .bottomLeading) { screw }
        .overlay(alignment: .bottomTrailing) { screw }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(
                    stops: [
                        .init(color: Color(RGB(0xFCFCFB)), location: 0),
                        .init(color: Color(RGB(0xEDECE8)), location: 0.52),
                        .init(color: Color(RGB(0xDBD9D3)), location: 1),
                    ],
                    startPoint: UnitPoint(x: 0.09, y: 0), endPoint: UnitPoint(x: -0.09, y: 1)
                ))
                // Inside the background, on the shape.
                //
                // `.shadow()` applied to the *container* shadows the whole composited
                // subtree — so every key cast this 22pt blur as well, and it pooled
                // between the case edge and the plate as a dark halo. Attached to the
                // shape, only the outer silhouette casts, which is what an object
                // sitting on a desk actually does.
                .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
        )
    }

    /// The recessed plate. Inset shading only — a recess does not cast a shadow.
    private var plate: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(RGB(0xF7F6F3)), Color(RGB(0xEFEEEA))],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay {
                // A hairline, not an outline. The plate is a recess in the case, so
                // the only thing marking its edge is where the light stops.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.black.opacity(0.05), lineWidth: 0.5)
            }
    }

    private var screw: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color(RGB(0x4A4A4E)), Color(RGB(0x141416))],
                center: UnitPoint(x: 0.38, y: 0.32), startRadius: 0, endRadius: 7
            ))
            .frame(width: 11, height: 11)
            .padding(11)
    }
}

/// Which corner a case screw sits in.
enum Screw: CaseIterable, Hashable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    static var corners: [Screw] { allCases }

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}

/**
 What the selected cap is and what it does.

 Agent keys are not rebindable — they always jump to their slot — so they get an icon
 picker only. Action keys and the encoder click get both. The dial, stick and touch
 sensor get neither: they are drawn because the pad has them, not because they can be
 bound.
 */
struct CapInspector: View {
    @EnvironmentObject private var board: BoardModel
    /**
     Every edit here has to be announced.

     `BoardModel` is the *display* copy. Writing to it repaints the window and nothing
     else: it does not save, and it does not push the change into the dispatcher that
     actually reads a binding when a key is pressed. `bindingsChanged` is what does
     both — which is why the whole pane silently forgot every keycap, binding, snippet
     and joystick direction the moment the app restarted, and why a rebound key kept
     doing its old job until it did.

     There is no save button by design, so a setter that does not call this is not a
     missing confirmation step — it is a control that does nothing.
     */
    @Environment(\.boardCommands) private var commands
    let cell: BoardCell
    /// Dismiss. An inspector that cannot be closed is a permanent column of controls
    /// for a decision already made.
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Text(title).font(.system(size: 12, weight: .semibold).monospaced())
                Text(kind)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: .capsule)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            switch cell.kind {
            case .element(.encoder):
                // Kept: it scrolls whatever is under the pointer, not the focused
                // window, which is not what a dial on a keyboard implies.
                Text("Scrolls the window under the pointer.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("TURNING CLOCKWISE")
                        .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                        .foregroundStyle(.tertiary)
                    Picker("", selection: encoderDirectionBinding) {
                        Text("Scrolls up").tag(true)
                        Text("Scrolls down").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    // There is no correct default: macOS ships "natural" scrolling on
                    // and plenty of people turn it off, so the direction a dial should
                    // feel like depends on a setting this app cannot read.
                    // Kept: otherwise the missing second direction reads as an
                    // omission, and someone goes looking for it.
                    Text("Counter-clockwise is always the opposite.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("LINES PER CLICK")
                            .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(board.preferences.scrollLines)")
                            .font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                    }
                    Slider(
                        value: scrollLinesBinding, in: 1...10, step: 1
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("PRESSING DOES")
                        .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                        .foregroundStyle(.tertiary)
                    Picker("", selection: encoderActionBinding(\.click)) {
                        Text("nothing").tag(KeyAction?.none)
                        ForEach(KeyAction.allCases, id: \.self) { action in
                            Text(action.long).tag(KeyAction?.some(action))
                        }
                    }
                    .labelsHidden()
                }
                if board.preferences.encoder.click?.needsShortcut == true {
                    shortcutSection(key: "ENC", allowHold: false)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("HOLDING DOES")
                            .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("after \(board.preferences.encoder.longPressMs)ms")
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Picker("", selection: encoderActionBinding(\.longPress)) {
                        Text("nothing").tag(KeyAction?.none)
                        ForEach(KeyAction.allCases, id: \.self) { action in
                            Text(action.long).tag(KeyAction?.some(action))
                        }
                    }
                    .labelsHidden()
                    Slider(value: holdMsBinding, in: 150...1200, step: 50)
                    // The hold fires while the dial is still down, not on release:
                    // classifying on release gives no feedback that you have held it
                    // long enough, so people let go early and get the wrong action.
                }
                if board.preferences.encoder.longPress?.needsShortcut == true {
                    shortcutSection(key: "ENC.long", allowHold: false)
                }

            case .element(.joystick):
                ForEach(Joystick.Direction.allCases, id: \.self) { direction in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(direction.rawValue.uppercased())
                            .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                            .foregroundStyle(.tertiary)
                        Picker("", selection: stickBinding(direction)) {
                            Text("unassigned").tag(KeyAction?.none)
                            ForEach(KeyAction.forJoystick, id: \.self) { action in
                                Text(action.long).tag(KeyAction?.some(action))
                            }
                        }
                        .labelsHidden()
                    }
                    if board.preferences.joystick.action(for: direction)?.needsShortcut == true {
                        shortcutSection(key: "JOY.\(direction.rawValue)", allowHold: false)
                    }
                }

                // Kept: a stick you can hold looks like it should repeat.
                Text("One push is one action, however long you hold it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

            case .element(.touch):
                inert("No event has ever been observed from this sensor.")

            case .agent:
                // Kept: this pane is where every other key is rebound.
                Text("Agent keys always jump to their slot and cannot be rebound.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                capPicker(allowNone: true)

            case .action:
                actionPicker(title: "PRESSING THIS KEY", key: cell.id)
                if board.actions[cell.id]?.needsSnippetText == true {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TEXT IT TYPES")
                            .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                            .foregroundStyle(.tertiary)
                        TextField("", text: snippetBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5).monospaced())
                        Text("Typed at the cursor. Not submitted.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if board.actions[cell.id]?.needsShortcut == true {
                    shortcutSection(key: cell.id, allowHold: true)
                }
                capPicker(allowNone: false)
                if cell.span > 1 {
                    // Kept: the title reads "ACT10 + ACT11", which looks like two keys
                    // to bind separately.
                    Text("One keycap, two switches — bound as \(cell.members[0]).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
    }

    private func inert(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The chord a `.shortcut` binding sends and, on the action caps only, whether the
    /// pad key taps or holds it. Shaped like the snippet block. The dial's hold and the
    /// stick have no release edge, so they are never offered hold.
    @ViewBuilder
    private func shortcutSection(key: String, allowHold: Bool) -> some View {
        let recorded = board.preferences.shortcuts[key]
        VStack(alignment: .leading, spacing: 6) {
            Text("SHORTCUT IT SENDS")
                .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.tertiary)
            ShortcutRecorder(shortcut: recorded) { chord in
                var next = chord
                next.mode = recorded?.mode ?? .tap
                board.updatePreferences { $0.shortcuts[key] = next }
                commands.bindingsChanged()
            }
            Text("Press the keys on your keyboard. Esc cancels.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if allowHold, recorded != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("WHEN PRESSED")
                    .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                    .foregroundStyle(.tertiary)
                Picker("", selection: shortcutModeBinding(key)) {
                    Text("Taps it").tag(Shortcut.Mode.tap)
                    Text("Holds it while pressed").tag(Shortcut.Mode.hold)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("Hold keeps the chord down until you let go, like hold to dictate.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutModeBinding(_ key: String) -> Binding<Shortcut.Mode> {
        Binding(
            get: { board.preferences.shortcuts[key]?.mode ?? .tap },
            set: { mode in
                board.updatePreferences { $0.shortcuts[key]?.mode = mode }
                commands.bindingsChanged()
            }
        )
    }

    private func actionPicker(title: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.tertiary)
            Picker("", selection: actionBinding(key)) {
                Text("unassigned").tag(KeyAction?.none)
                ForEach(KeyAction.allCases, id: \.self) { action in
                    Text(action.long).tag(KeyAction?.some(action))
                }
            }
            .labelsHidden()
        }
    }

    /// The real Codex Micro caps, so the window matches the hardware.
    private func capPicker(allowNone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("KEYCAP")
                .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.tertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 6)], spacing: 6) {
                if allowNone {
                    // Session keys default to none: the LED is the signal there, and a
                    // glyph competes with it.
                    capButton(id: nil)
                }
                ForEach(KeycapCatalog.caps, id: \.id) { cap in
                    capButton(id: cap.id)
                }
            }
        }
    }

    private func capButton(id: String?) -> some View {
        let chosen = board.caps[cell.id] == id
        return Button {
            if let id { board.caps[cell.id] = id } else { board.caps.removeValue(forKey: cell.id) }
            commands.bindingsChanged()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(chosen
                        ? AnyShapeStyle(SystemColors.selectedRow.opacity(0.28))
                        : AnyShapeStyle(.quaternary.opacity(0.4)))
                if let id, let icon = KeycapCatalog.icon(forCap: id) {
                    KeycapIconView(icon: icon).frame(width: 18, height: 18)
                } else if id == nil {
                    Image(systemName: "nosign").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 34)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(SystemColors.selectedRow, lineWidth: chosen ? 1.5 : 0)
            )
        }
        .buttonStyle(.plain)
        .help(id ?? "no icon")
    }

    private var title: String {
        switch cell.kind {
        case let .agent(slot): "\(cell.id) · slot \(slot)"
        case .element(.encoder): "ENCODER"
        case .element(.joystick): "JOYSTICK"
        case .element(.touch): "TOUCH SENSOR"
        case .action: cell.span > 1 ? cell.members.joined(separator: " + ") : cell.id
        }
    }

    private var kind: String {
        switch cell.kind {
        case .agent: "agent key · always jumps to its slot"
        case .element(.encoder): "dial · turn and click"
        case .element: "inert"
        case .action: cell.span > 1 ? "action key · one wide cap" : "action key · yours to set"
        }
    }

    private func actionBinding(_ key: String) -> Binding<KeyAction?> {
        Binding(
            get: { board.actions[key] },
            set: {
                board.actions[key] = $0
                commands.bindingsChanged()
            }
        )
    }

    private var snippetBinding: Binding<String> {
        Binding(
            get: { board.snippets[cell.id] ?? "" },
            set: {
                board.snippets[cell.id] = $0
                commands.bindingsChanged()
            }
        )
    }

    private var encoderDirectionBinding: Binding<Bool> {
        Binding(
            get: { board.preferences.encoder.clockwiseScrollsUp },
            set: { up in
                board.updatePreferences { $0.encoder.clockwiseScrollsUp = up }
                commands.bindingsChanged()
            }
        )
    }

    private func stickBinding(_ direction: Joystick.Direction) -> Binding<KeyAction?> {
        Binding(
            get: { board.preferences.joystick.action(for: direction) },
            set: { action in
                board.updatePreferences { prefs in
                    switch direction {
                    case .up: prefs.joystick.up = action
                    case .down: prefs.joystick.down = action
                    case .left: prefs.joystick.left = action
                    case .right: prefs.joystick.right = action
                    }
                }
                commands.bindingsChanged()
            }
        )
    }

    private func encoderActionBinding(
        _ path: WritableKeyPath<Preferences.Encoder, KeyAction?>
    ) -> Binding<KeyAction?> {
        Binding(
            get: { board.preferences.encoder[keyPath: path] },
            set: { action in
                board.updatePreferences { $0.encoder[keyPath: path] = action }
                commands.bindingsChanged()
            }
        )
    }

    private var holdMsBinding: Binding<Double> {
        Binding(
            get: { Double(board.preferences.encoder.longPressMs) },
            set: { ms in
                board.updatePreferences { $0.encoder.longPressMs = Int(ms.rounded()) }
                commands.bindingsChanged()
            }
        )
    }

    private var scrollLinesBinding: Binding<Double> {
        Binding(
            get: { Double(board.preferences.scrollLines) },
            set: { lines in
                board.updatePreferences { $0.scrollLines = Int(lines.rounded()) }
                commands.bindingsChanged()
            }
        )
    }
}

/**
 One key, drawn to the design's measurements.

 Every number here comes from `OpenBoard-Board-New.html` rather than being judged by
 eye: 51pt keys, 11pt corners, 7pt gaps, and the specific gradients that make a plastic
 cap read as plastic and a rubber stick read as rubber. Approximating them produced
 something recognisably similar and obviously not the same thing.

 The three round controls are round because they are round on the pad — the dial and
 the stick are not keycaps and never take an icon.
 */
struct BoardCapView: View {
    let cell: BoardCell
    let slot: SlotView?
    let capID: String?
    let action: KeyAction?
    let isSelected: Bool
    /**
     Drop the moulded-plastic finish.

     The settings window is a picture *of the pad*, so there the gradients and the
     contact shadow are the point — it should read as the object on your desk. The menu
     bar popover is a menu: it sits over whatever you were doing, at a glance, and
     fifteen little lit plastic objects in it is noise pretending to be realism.

     Same geometry either way. Only the material changes, so the two surfaces can never
     disagree about which key is where — which is the whole reason there is one view
     here rather than two.
     */
    var isFlat: Bool = false

    /**
     Key geometry, from the hardware rather than from the grid.

     Every cap on the pad is **square** — 1U — and the MIC is a 2U: twice the width,
     the same height. Letting the column width fall out of the grid instead made them
     44.25 wide by 51 tall, which is subtly wrong in a way that reads as "off" long
     before you can say why.

     2U is two keys plus the gap between them, not two keys, or the wide cap ends up
     narrower than the pair it replaces.
     */
    private static let unit: CGFloat = 51
    private static let gap: CGFloat = 7

    private var side: CGFloat { isTouch ? 30 : Self.unit }
    private var width: CGFloat {
        if isRound { return side }
        return cell.span > 1
            ? Self.unit * CGFloat(cell.span) + Self.gap * CGFloat(cell.span - 1)
            : Self.unit
    }
    private var isRound: Bool { isDial || isStick || isTouch }

    private var isDial: Bool { if case .element(.encoder) = cell.kind { true } else { false } }
    private var isStick: Bool { if case .element(.joystick) = cell.kind { true } else { false } }
    private var isTouch: Bool { if case .element(.touch) = cell.kind { true } else { false } }
    private var isAgent: Bool { if case .agent = cell.kind { true } else { false } }

    var body: some View {
        ZStack {
            shell
            if let lit { glow(lit) }
            VStack(spacing: 3) {
                if !isRound, let icon = KeycapCatalog.icon(forCap: capID ?? "") {
                    KeycapIconView(icon: icon)
                        .frame(width: 18, height: 18)
                        // Ink on a white cap; the label color on a flat one, which has
                        // to invert with the system appearance rather than stay black.
                        //
                        // A concrete `Color`, never `AnyShapeStyle`. The icon is drawn
                        // in a `Canvas` with `.style(.foreground)`, and an erased style
                        // does not resolve there — the shapes render as nothing and the
                        // caps come out empty.
                        .foregroundStyle(isFlat ? Color.primary : Color(RGB(0x1A1A1A)))
                }
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.45)
                        .foregroundStyle(isStick || isTouch
                            ? Color.white.opacity(0.78)
                            : Color(RGB(0x121214)).opacity(0.82))
                        .shadow(color: .white.opacity(lit == nil ? 0 : 0.75), radius: 2)
                }
            }
            if isSelected { selectionRing }
        }
        .frame(width: width, height: side)
        .glassCap(isFlat: isFlat, shape: shape)
        .contentShape(shape)
    }

    private var shape: AnyShape {
        isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// `AnyShape` erases `InsettableShape`, so a stroked border has to branch on the
    /// concrete type rather than going through the erased one.
    @ViewBuilder
    private func border(_ color: Color, width: CGFloat) -> some View {
        if isRound {
            Circle().strokeBorder(color, lineWidth: width)
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(color, lineWidth: width)
        }
    }

    /// The cap itself. Four materials: rubber for the stick and touch strip, and three
    /// slightly different plastics for the dial, the session caps and the action caps.
    private var shell: some View {
        shape
            .fill(fill)
            // A contact shadow: short, tight, close underneath. Keys sit *on* the
            // plate, they do not hover above it, and a soft blur around each one is
            // what turned fifteen objects into a cloud. Flat keys cast nothing.
            .shadow(
                color: .black.opacity(isFlat ? 0 : (isStick || isTouch ? 0.28 : 0.13)),
                radius: isFlat ? 0 : 1.5,
                y: isFlat ? 0 : 1
            )
    }

    private var fill: AnyShapeStyle {
        if isFlat {
            // Clear only where the glass actually lands. `glassCap` is a no-op below
            // macOS 26, so clearing unconditionally would have left the popover's caps
            // invisible on every system this package still deploys to — the fill *is*
            // the cap there.
            if #available(macOS 26.0, *) {
                return AnyShapeStyle(Color.clear)
            }
            return AnyShapeStyle(Color.primary.opacity(isRound ? 0.16 : 0.08))
        }
        if isStick || isTouch {
            return AnyShapeStyle(RadialGradient(
                colors: [Color(RGB(0x3C3C40)), Color(RGB(0x151518)), Color(RGB(0x08080A))],
                center: UnitPoint(x: 0.42, y: 0.30), startRadius: 1, endRadius: side * 0.85
            ))
        }
        if isDial {
            return AnyShapeStyle(LinearGradient(
                stops: [
                    .init(color: Color(RGB(0xFDFDFC)), location: 0),
                    .init(color: Color(RGB(0xEDECE9)), location: 0.46),
                    .init(color: Color(RGB(0xCFCEC9)), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        }
        if isAgent {
            // Translucent, so an LED underneath shows through the cap.
            return AnyShapeStyle(LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.90), location: 0),
                    .init(color: Color(RGB(0xF8F8F6)).opacity(0.78), location: 0.60),
                    .init(color: Color(RGB(0xECECE8)).opacity(0.72), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ))
        }
        return AnyShapeStyle(LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: Color(RGB(0xF6F5F2)), location: 0.58),
                .init(color: Color(RGB(0xE3E1DC)), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        ))
    }

    /// The LED under a session cap, if it is lit.
    private var lit: Appearance? {
        guard isAgent, let appearance = slot?.appearance, appearance.effect != .off else {
            return nil
        }
        return appearance
    }

    private func glow(_ appearance: Appearance) -> some View {
        shape
            .fill(LinearGradient(
                stops: [
                    .init(color: pastel(appearance.color, 0.42), location: 0),
                    .init(color: pastel(appearance.color, 0.58), location: 0.58),
                    .init(color: pastel(appearance.color, 0.74), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ))
            .opacity(0.6 + 0.4 * appearance.brightness)
            .overlay { border(pastel(appearance.color, 0.30), width: 1.5) }
            .shadow(color: Color(appearance.color).opacity(0.4), radius: 6)
    }

    /**
     Toward white by `amount`, matching the design's own `pastel()`.

     A cap is white plastic over a coloured LED, so what you see is never the raw
     colour — it is that colour washed out by the diffuser. Painting the raw value made
     every key look like a sticker.
     */
    private func pastel(_ color: RGB, _ amount: Double) -> Color {
        Color(
            .sRGB,
            red: color.red + (1 - color.red) * amount,
            green: color.green + (1 - color.green) * amount,
            blue: color.blue + (1 - color.blue) * amount
        )
    }

    private var selectionRing: some View {
        border(SystemColors.selectedRow, width: 2.5)
    }

    private var label: String {
        switch cell.kind {
        case let .agent(slot): "S\(slot)"
        case .element(.encoder): "DIAL"
        case .element(.joystick): "STICK"
        case .element(.touch): ""
        case .action: ""
        }
    }
}



/**
 One harness in the sidebar: its mark, its name, and whether it is reporting.

 A plain row now rather than a `Button`. It used to draw its own selection because it
 navigated somewhere the `List` did not know about; now the list owns the selection for
 both kinds of row, so hand-drawn highlighting would be a second one fighting the first.
 */
struct HarnessRow: View {
    let harness: Harness
    let connected: Bool
    /// Has ever reported an event here. Distinct from `connected`, which is about now:
    /// a harness set up months ago and quiet today is not an empty state.
    let everSeen: Bool

    var body: some View {
        HStack(spacing: 9) {
            // A picture first, then a shape, then nothing at all. Hermes' mark is a
            // portrait with no monochrome form worth drawing, so it ships as the
            // favicon it already is — see ProviderRasters.
            if let png = ProviderRasters.data(iconID), let image = NSImage(data: png) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 15, height: 15)
                    .opacity(everSeen ? (connected ? 1 : 0.55) : 0.4)
            } else if let icon = ProviderIcons.icon(iconID) {
                KeycapIconView(icon: icon)
                    .frame(width: 15, height: 15)
                    // A concrete `Color`, never an inherited or erased style. The mark
                    // is drawn in a `Canvas` with `.style(.foreground)`, which resolves
                    // nothing in a sidebar row — the paths render as empty and the row
                    // shows a name with a hole where its logo should be.
                    .foregroundStyle(Color.primary)
                    .opacity(everSeen ? (connected ? 1 : 0.55) : 0.35)
            } else {
                Circle()
                    .strokeBorder(.tertiary, lineWidth: 1)
                    .frame(width: 13, height: 13)
                    .opacity(everSeen ? 1 : 0.5)
            }
            // The name outranks the dot. Without a priority the Spacer and the trailing
            // circle take their space first and the label is what truncates.
            Text(harness.name)
                .font(.system(size: 13))
                .foregroundStyle(everSeen ? .primary : .secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if everSeen {
                Circle()
                    .fill(connected ? Color(RGB(0x09B821)) : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
            // Nothing at all when it has never reported. The dimmed mark and label
            // already say it, and a word in the trailing slot competes with the dots
            // above it for a meaning it does not have.
        }
        .padding(.vertical, 1)
    }

    /// The catalogue is keyed by vendor, the harness by id — they agree everywhere
    /// except Claude Code, whose mark is filed under the product rather than the CLI.
    private var iconID: String {
        harness.id == "claude-code" ? "claude" : harness.id
    }
}

