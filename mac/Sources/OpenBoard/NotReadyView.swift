import OpenBoardKit
import SwiftUI

/**
 Stands in for a pane that cannot mean anything yet.

 ## Why replace rather than disable

 Board, Colors and the harness panes all configure how the six keys look and what they
 do. On an install that has not been set up, every one of those settings saves happily
 to disk and changes nothing anybody can see — the pad is not open, so nothing paints.
 The window looked completely functional and was not, which is the worst combination:
 someone picks colours for twenty minutes, sees no result, and concludes the app is
 broken rather than unfinished.

 Greying the controls out would be the smaller change and the wrong one. A disabled
 control says "you may not do this", when the truth is "this will work, and you will not
 be able to tell". The pane is replaced by what to do instead.

 ## Why the Device pane is exempt

 It is the diagnostic surface. Blocking the one place that says which permission is
 missing, on the grounds that a permission is missing, is a locked door with the key
 behind it.
 */
struct NotReadyView: View {
    let progress: SetupProgress
    /// What this particular pane would have been for, so the sentence names the thing
    /// the user came here to do rather than talking about "settings" in the abstract.
    let purpose: String
    var openSetup: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)

            Text("Finish setting up first")
                .font(.system(size: 15, weight: .semibold))

            Text("\(purpose) is saved, but nothing will show on the pad until OpenBoard "
                 + "has what it needs. \(remaining)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            Button("Open setup") { openSetup() }
                .controlSize(.large)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Names what is missing rather than saying "some settings". The count is the
    /// difference between a task and an unknown amount of work.
    private var remaining: String {
        let missing = SetupProgress.Step.allCases
            .filter { $0.isRequired && !progress.isDone($0) }
        guard !missing.isEmpty else { return "" }
        return "Still needed: \(missing.map(label).joined(separator: ", "))."
    }

    private func label(_ step: SetupProgress.Step) -> String {
        switch step {
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        case .automation: "Automation"
        case .calibration: "Key order"
        case .hooks: "Claude Code hooks"
        case .openAtLogin: "Open at login"
        }
    }
}

/**
 Wraps a pane so it shows `NotReadyView` until the required setup is done.

 A modifier rather than an `if` inside each pane, because the check has to be identical
 across all of them — three copies of "is this ready" is three chances for one of them
 to disagree, and the one that disagrees is the one that lets you edit a board that
 cannot paint.
 */
struct RequiresSetup: ViewModifier {
    let purpose: String
    @Environment(\.boardCommands) private var commands
    @EnvironmentObject private var setup: SetupState

    func body(content: Content) -> some View {
        Group {
            if !setup.hasSettled {
                // Nothing is claimed while the answer is unknown. Showing the
                // finish-setup screen here and replacing it a moment later reads as the
                // app changing its mind about whether you are set up.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if setup.isReady {
                content
            } else {
                NotReadyView(progress: setup.progress, purpose: purpose) {
                    commands.openSetup()
                }
            }
        }
        // Re-read on appearance rather than held: permissions change outside this app,
        // and a pane that decided it was blocked at launch would stay blocked for the
        // rest of the session after the user fixed it.
        .onAppear { setup.refresh() }
    }
}

extension View {
    /// Show this pane only once OpenBoard can act on what it configures.
    func requiresSetup(_ purpose: String) -> some View {
        modifier(RequiresSetup(purpose: purpose))
    }
}
