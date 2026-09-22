import AppKit
import SwiftUI
import OpenBoardKit

/**
 The on-screen face of a `VirtualPad`, when the app is launched with
 `OPENBOARD_VIRTUAL_PAD=1`.

 ## What it renders

 The decoded bytes, not the app's intent. `BoardPane` draws the pad from
 `board.slots` — what the app *means* to show — which makes it exactly the wrong
 source here: the point of the virtual pad is to see what the writes would actually
 do, calibration permutation applied, unwritten slots dark. So the view is fed from
 `VirtualPad.Face`, and a paint bug shows up here the way it would on the desk.

 ## Why a non-activating panel

 Pressing a virtual key does what the real key does — jumps a Terminal tab, types a
 snippet, taps ⏎ into whatever is focused. A window that took focus on click would
 point half of those actions at itself. `.nonactivatingPanel` leaves focus where it
 is, which is also why this does not reuse `MainWindowController`'s raise-to-regular
 pattern.
 */
@MainActor
final class VirtualPadWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private let pad: VirtualPad
    private let state = VirtualPadState()

    init(pad: VirtualPad) {
        self.pad = pad
        super.init()
        pad.onFace { [weak state] face in
            Task { @MainActor in state?.face = face }
        }
    }

    func show() {
        if let window {
            window.orderFront(nil)
            return
        }

        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.title = "Virtual Pad"
        created.isFloatingPanel = true
        created.level = .floating
        created.isReleasedWhenClosed = false
        created.delegate = self

        let hosting = NSHostingView(
            rootView: VirtualPadView(state: state, pad: pad)
        )
        hosting.autoresizingMask = [.width, .height]
        created.contentView = hosting
        created.setFrameAutosaveName("VirtualPad")
        if created.frame.origin == .zero { created.center() }

        window = created
        created.orderFront(nil)
        Log.write("virtual pad: window opened")
    }
}

@MainActor
final class VirtualPadState: ObservableObject {
    @Published var face = VirtualPad.Face()
}

/**
 The face itself: the four rows at the real geometry, ringed by the ambient light.

 Materials are the flat rendition — this is an instrument, not a portrait; the
 settings window already owns the moulded-plastic picture. Effects are approximated
 just far enough to be recognisable: breath and shallow-breath modulate brightness,
 rainbow cycles hue, and the spatial pair (snake, gradient) render as solid, which
 is roughly what a single key shows of them anyway.
 */
struct VirtualPadView: View {
    @ObservedObject var state: VirtualPadState
    let pad: VirtualPad

    private static let unit: CGFloat = 44
    private static let gap: CGFloat = 6

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                grid(phase: phase)
                    .padding(16)
                    .background(ring(phase: phase))
            }

            HStack(spacing: 6) {
                dialButton("⟲") { pad.turnEncoder(clockwise: false) }
                dialButton("⟳") { pad.turnEncoder(clockwise: true) }
                Spacer()
                Text("Simulated — the same bytes as hardware")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func grid(phase: Double) -> some View {
        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
            ForEach(Array(BoardLayout.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.id) { cell in
                        cap(cell, phase: phase)
                            .gridCellColumns(cell.span)
                    }
                }
            }
        }
    }

    private func cap(_ cell: BoardCell, phase: Double) -> some View {
        let width = cell.span > 1
            ? Self.unit * CGFloat(cell.span) + Self.gap * CGFloat(cell.span - 1)
            : Self.unit
        let isRound: Bool = {
            if case .element = cell.kind { return true }
            return false
        }()

        return ZStack {
            let shape = RoundedRectangle(cornerRadius: isRound ? Self.unit / 2 : 9)
            shape.fill(Color(white: 0.16))
            if let lit = litColor(for: cell, phase: phase) {
                shape.fill(lit)
                shape.stroke(lit.opacity(0.9), lineWidth: 2).blur(radius: 4)
            }
            Text(label(for: cell))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: width, height: Self.unit)
        .contentShape(Rectangle())
        // Down on press, up on release — a hold on a virtual key is a real hold.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in press(cell, isDown: true) }
                .onEnded { _ in press(cell, isDown: false) }
        )
    }

    /// The dial and the stick report their own switch names, not their cell ids.
    private func press(_ cell: BoardCell, isDown: Bool) {
        // `onChanged` fires on every drag sample, not once; only the edges count.
        guard pressed.contains(cell.id) != isDown else { return }
        let key: String
        switch cell.kind {
        case .element(.encoder): key = "ENC_CLK"
        case .element(.joystick), .element(.touch): return
        default: key = cell.id
        }
        if isDown {
            pressed.insert(cell.id)
            pad.press(key)
        } else {
            pressed.remove(cell.id)
            pad.release(key)
        }
    }

    @State private var pressed: Set<String> = []

    private func label(for cell: BoardCell) -> String {
        if case .agent = cell.kind { return "S\(cell.slot ?? 0)" }
        if case .element(.encoder) = cell.kind { return "DIAL" }
        if case .element(.joystick) = cell.kind { return "STICK" }
        if case .element(.touch) = cell.kind { return "" }
        return cell.id
    }

    /// An agent key shows its slot's status light; everything else shows the `keys`
    /// side of the last rgbcfg, which the app keeps off on purpose.
    private func litColor(for cell: BoardCell, phase: Double) -> Color? {
        if case .agent = cell.kind, let slot = cell.slot,
           let thread = state.face.threads[slot] {
            return color(
                packed: thread.color,
                brightness: thread.brightness,
                effect: thread.effect,
                speed: thread.speed,
                phase: phase
            )
        }
        let keys = state.face.keys
        guard keys.effect != CodexProtocol.Effect.off.rawValue, keys.brightness > 0 else {
            return nil
        }
        return color(
            packed: keys.color, brightness: keys.brightness,
            effect: keys.effect, speed: keys.speed, phase: phase
        )
    }

    private func ring(phase: Double) -> some View {
        let ambient = state.face.ambient
        let lit = ambient.effect != CodexProtocol.Effect.off.rawValue && ambient.brightness > 0
            ? color(
                packed: ambient.color, brightness: ambient.brightness,
                effect: ambient.effect, speed: ambient.speed, phase: phase
            )
            : nil
        return RoundedRectangle(cornerRadius: 22)
            .strokeBorder((lit ?? .clear).opacity(lit == nil ? 0 : 1), lineWidth: 4)
            .blur(radius: 1.5)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.09)))
    }

    private func color(
        packed: UInt32, brightness: Double, effect: UInt8, speed: Double, phase: Double
    ) -> Color? {
        guard let kind = CodexProtocol.Effect(rawValue: effect), kind != .off else { return nil }
        var red = Double((packed >> 16) & 0xFF) / 255
        var green = Double((packed >> 8) & 0xFF) / 255
        var blue = Double(packed & 0xFF) / 255

        var level = brightness
        switch kind {
        case .breath, .shallowBreath:
            // A slow sine between floor and full. The floor is higher for shallow —
            // that is the difference the firmware shows too.
            let floor = kind == .breath ? 0.25 : 0.55
            let cycle = (sin(phase * (0.6 + speed * 2.4) * 2 * .pi) + 1) / 2
            level *= floor + (1 - floor) * cycle
        case .rainbow:
            let hue = (phase * (0.05 + speed * 0.4)).truncatingRemainder(dividingBy: 1)
            let cycled = NSColor(hue: hue, saturation: 0.85, brightness: 1, alpha: 1)
            red = cycled.redComponent
            green = cycled.greenComponent
            blue = cycled.blueComponent
        case .solid, .snake, .gradient, .off:
            break
        }
        return Color(.sRGB, red: red, green: green, blue: blue).opacity(max(level, 0.06))
    }

    private func dialButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol).font(.system(size: 13))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
