import SwiftUI
import OpenBoardKit

/**
 Confirming the key order — one question, with the full map behind it.

 The board no longer waits for this. Identity is the default because it is the only
 mapping either implementation has ever produced, so the common path is a pad that is
 already right and an owner who need only glance at it.

 That makes the first question a yes/no. Six dropdowns is the correct interface for
 *recording* an unknown order and a poor one for *confirming* a known one, and it was
 charged to every new user regardless. Now it appears only for the pad that disagrees.

 ## Why naming colors, rather than pressing keys

 Pressing the key that lit is the more obvious flow and it needs Input Monitoring to
 already work. Calibration is part of *setup*, so it has to function on a machine where
 that permission has not been granted yet — otherwise the two gaps deadlock, each
 waiting on the other. Reading colors off the pad only needs the app to write, which
 is the half that is working by the time anyone gets here.

 It also degrades honestly: if the pad is dark, you cannot fill this in, which is the
 correct outcome. A key-press flow on a dark pad still records something.
 */
struct CalibrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.boardCommands) private var commands

    /// The slot whose color is showing at each physical position, in reading order.
    /// `nil` means not yet named — deliberately not pre-filled with a guess, since a
    /// plausible default is exactly what someone would click past.
    @State private var observed: [Int?] = Array(repeating: nil, count: BoardLayout.slotCount)
    @State private var failed = false
    /// Whether the answer to "is this the order?" was no. Until it is, the six pickers
    /// are not on screen at all.
    @State private var mapping = false

    private var complete: [Int]? {
        let named = observed.compactMap { $0 }
        guard named.count == BoardLayout.slotCount, Set(named).count == named.count else { return nil }
        return named
    }

    /// Two on top, four below.
    private let rowShape = CalibrationCapture.defaultRows

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(mapping ? "Which color is on which key?" : "Check the key order")
                    .font(.system(size: 16, weight: .semibold))
                // The colors are drawn below rather than named here: naming six hues in
                // prose and asking someone to hold them in their head while they look
                // away at the pad is what made this feel like a chore.
                Text(mapping
                    ? "Pick the color you can see on each key — top row first, left to right."
                    : "Your pad should look like this.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !mapping {
                // The expected order, drawn. Naming the colors in prose and asking
                // someone to hold six of them in their head while looking away at the
                // pad is the part that makes this feel like a chore.
                HStack(spacing: 7) {
                    ForEach(CalibrationCapture.legend, id: \.slot) { entry in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(entry.color))
                                .frame(height: 30)
                            Text("\(entry.slot)")
                                .font(.system(size: 10, weight: .semibold).monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if mapping {
            VStack(spacing: 10) {
                ForEach(Array(rowShape.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 10) {
                        ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, _ in
                            let position = rowShape[..<rowIndex].reduce(0) { $0 + $1.count } + columnIndex
                            keyPicker(position: position)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
            }

            if failed {
                Text("Each color must be chosen exactly once.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(RGB(0xD41145)))
            } else {
                EmptyView()
            }

            HStack {
                Button("Repaint") { commands.beginCalibration() }
                    .help("Codex repaints these LEDs on its own schedule — use this if they drift.")
                Spacer()
                Button("Cancel") {
                    commands.endCalibration()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if mapping {
                    Button("Save") {
                        guard let complete else { failed = true; return }
                        if commands.saveCalibration(complete) {
                            dismiss()
                        } else {
                            failed = true
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(complete == nil)
                } else {
                    // Named for what each does, not for the answer it gives. "Yes, that
                    // is the order" and "No, they are different" both truncated in a
                    // 460pt sheet — and a truncated button is worse than a terse one,
                    // because it hides the half that distinguishes it from its neighbour.
                    Button("Remap") { mapping = true }
                    // Recorded, not merely accepted: confirming is a statement about
                    // this pad, and it should stop being described as an assumption.
                    Button("Confirm") {
                        _ = commands.saveCalibration(Array(1...BoardLayout.slotCount))
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { commands.beginCalibration() }
        // The legend must not outlive the sheet: closing it any other way — Escape, the
        // window button — still has to hand the board back.
        .onDisappear { commands.endCalibration() }
    }

    private func keyPicker(position: Int) -> some View {
        let chosen = observed[position]
        let color = chosen.flatMap { slot in
            CalibrationCapture.legend.first { $0.slot == slot }?.color
        }
        // A color named twice is the likely mistake, so it is shown rather than only
        // reported at save time.
        let duplicated = chosen != nil && observed.filter { $0 == chosen }.count > 1

        return Menu {
            ForEach(CalibrationCapture.legend, id: \.slot) { entry in
                Button(entry.name) { observed[position] = entry.slot; failed = false }
            }
            Divider()
            Button("Not lit") { observed[position] = nil; failed = false }
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(color.map { Color($0) } ?? Color.secondary.opacity(0.18))
                    .frame(height: 34)
                    .overlay {
                        if color == nil {
                            Text("?").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(
                                duplicated ? Color(RGB(0xD41145)) : .clear, lineWidth: 2
                            )
                    }
                Text(chosen.flatMap { slot in
                    CalibrationCapture.legend.first { $0.slot == slot }?.name
                } ?? "pick")
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }
}
