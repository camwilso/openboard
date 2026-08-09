import AppKit
import OpenBoardKit
import SwiftUI

/**
 Guided setup — the four things that have to be true before anything lights.

 A checklist rather than a wizard, and that is forced by the platform: granting Input
 Monitoring only takes effect after OpenBoard restarts, so a linear flow would be killed
 by its own first step. This recomputes from the world every time it appears, which
 means quitting halfway and coming back lands where you left off.

 The pad itself is not in the list. Pairing and Layer 1 are things done on the hardware,
 neither is detectable from here, and an unticked box for something that is probably
 fine is worse than a sentence. They are stated at the bottom instead.
 */
struct SetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.boardCommands) private var commands
    @EnvironmentObject private var setup: SetupState
    @EnvironmentObject private var board: BoardModel

    @State private var permissions = PermissionProbe.inspect()
    @State private var loginStatus = LoginItem.status
    @State private var note: String?
    @State private var working = false
    @State private var calibrating = false
    /// A refusal macOS has on record. Distinct from "not asked": once someone has said
    /// no to an Apple Events prompt, the system never asks again — every further
    /// request returns denied instantly. Asking a second time is guaranteed to fail, so
    /// the button has to stop offering and point at the only thing that can undo it.
    @State private var automationRefused = false

    private var progress: SetupProgress { setup.progress }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                ForEach(SetupProgress.Step.allCases, id: \.self) { step in
                    row(step)
                    if step != SetupProgress.Step.allCases.last {
                        Divider().opacity(0.35)
                    }
                }
            }
            .padding(.horizontal, 20)

            Divider()
            footer
        }
        .frame(width: 520)
        // Re-read on every appearance: these are granted outside the app, and a stale
        // list is what sends someone back to System Settings to fix something they
        // already fixed.
        .onAppear(perform: refresh)
        .sheet(isPresented: $calibrating, onDismiss: refresh) { CalibrationSheet() }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(progress.isReady ? "OpenBoard is ready" : "Set up OpenBoard")
                .font(.system(size: 16, weight: .semibold))
            Text(progress.isReady
                 ? "Everything it needs is granted. Open a new Claude Code session and the keys will light."
                 : "\(progress.requiredDone) of \(progress.requiredTotal) done. "
                   + "Each takes a few seconds, and you can stop and come back.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    // MARK: rows

    private func row(_ step: SetupProgress.Step) -> some View {
        let done = progress.isDone(step)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(done ? Color(RGB(0x09B821)) : Color.secondary.opacity(0.5))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(step)).font(.system(size: 13, weight: .medium))
                    if !step.isRequired {
                        Text("optional")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(detail(step))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Said on the row rather than in a dialog afterwards, because it is the
                // reason a grant looks like it did nothing.
                if step.needsRestart && !done {
                    Text("Takes effect after OpenBoard restarts.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(RGB(0xFF6A00)))
                }
            }

            Spacer(minLength: 8)
            action(step, done: done)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func action(_ step: SetupProgress.Step, done: Bool) -> some View {
        switch step {
        case .inputMonitoring:
            Button("Open") { openPane("Privacy_ListenEvent") }.controlSize(.small)
        case .accessibility:
            Button("Open") { openPane("Privacy_Accessibility") }.controlSize(.small)
        case .automation:
            // Normally the only step the app can grant without sending anyone anywhere.
            // A recorded refusal takes that away: macOS will not re-prompt, so the
            // button changes to the one action that can still work.
            if automationRefused && !done {
                Button("Open") { openPane("Privacy_Automation") }.controlSize(.small)
            } else {
                Button(working ? "Asking" : "Grant") { grantAutomation() }
                    .controlSize(.small)
                    .disabled(working || done)
            }
        case .calibration:
            // Needs the pad open, because the check paints six colours on it. Disabled
            // rather than hidden: it is a real step, and hiding it would make the count
            // shrink and grow as the pad connects.
            Button(done ? "Re-check" : "Check") { calibrating = true }
                .controlSize(.small)
                .disabled(!board.device.isUsable)
        case .hooks:
            Button(done ? "Re-wire" : "Wire up") { wireHooks() }
                .controlSize(.small)
                .disabled(working)
        case .openAtLogin:
            Toggle("", isOn: Binding(
                get: { loginStatus.isOn },
                set: { setLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(!LoginItem.isInstalledProperly)
        }
    }

    private func title(_ step: SetupProgress.Step) -> String {
        switch step {
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        case .automation: "Automation"
        case .calibration: "Key order"
        case .hooks: "Claude Code hooks"
        case .openAtLogin: "Open at login"
        }
    }

    private func detail(_ step: SetupProgress.Step) -> String {
        switch step {
        case .inputMonitoring:
            "Reading the pad. Without it nothing lights and no key press is seen."
        case .accessibility:
            "Typing snippets, sending ⏎ and ⎋, and scrolling with the dial."
        case .automation:
            "Driving System Events, which the key actions use. OpenBoard asks macOS "
                + "directly — no trip to System Settings."
        case .calibration:
            board.device.isUsable
                ? "Confirms which physical key is slot 1. The board assumes the order "
                    + "every pad reports, so this takes ten seconds — but colours and "
                    + "bindings are set per slot, and an unchecked order puts them on "
                    + "the wrong keys."
                : "Connect the pad first — the check paints six colours on it."
        case .hooks:
            "Adds OpenBoard to ~/.claude/settings.json so sessions report what they "
                + "are doing. Every unrelated setting is preserved and the file is "
                + "backed up first."
        case .openAtLogin:
            "A board you have to remember to launch is not an ambient board."
        }
    }

    // MARK: footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Two things this cannot check, and both are on the hardware. Stated rather
            // than shown as boxes that would sit unticked forever.
            VStack(alignment: .leading, spacing: 3) {
                Text("On the pad itself")
                    .font(.system(size: 11.5, weight: .medium))
                Text("Pair the Codex Micro with this Mac over Bluetooth or USB, and keep "
                     + "it on Layer 1 — per-key status renders only there.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Check again", action: refresh)
                    .controlSize(.small)
                Spacer(minLength: 0)
                if !progress.isReady {
                    // Offered here because two of the four need it, and hunting for the
                    // menu bar item to quit and reopen is a poor reward for granting a
                    // permission correctly.
                    Button("Restart OpenBoard", action: restart)
                        .controlSize(.small)
                }
                Button(progress.isReady ? "Done" : "Close") { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: actions

    private func refresh() {
        setup.refresh()
        permissions = PermissionProbe.inspect()
        loginStatus = LoginItem.status
    }

    private func openPane(_ pane: String) {
        guard let url = PermissionProbe.settingsURL(forPane: pane) else { return }
        NSWorkspace.shared.open(url)
    }

    private func grantAutomation() {
        working = true
        note = nil
        Task {
            let results = await AutomationRequest.requestAll(current: permissions.automation)
            working = false
            refresh()

            let systemEvents = results.first { $0.name == "System Events" }?.status
            switch systemEvents {
            case .granted, .none:
                note = nil
            case .denied:
                // The specific case that had no message of its own. Saying "was not
                // granted" invited another click, and another click cannot work.
                automationRefused = true
                note = "macOS has a refusal on record for System Events, so it will not "
                    + "ask again. Turn OpenBoard on under Automation in System Settings, "
                    + "then come back and press Check again."
            case .unavailable:
                note = "System Events would not start, so macOS had nothing to ask "
                    + "about. Try again in a moment."
            case .unknown:
                note = "No answer was given. Press Grant again and choose OK in the "
                    + "dialog macOS shows."
            }
        }
    }

    private func wireHooks() {
        do {
            try HookInstall.install(command: HookInstall.hookCommandPath())
            note = "Hooks wired. Open a new Claude Code session to see it — they load "
                + "when a session starts, so ones already running will not light."
        } catch {
            note = error.localizedDescription
        }
        refresh()
    }

    private func setLogin(_ on: Bool) {
        switch LoginItem.set(on) {
        case let .success(status):
            loginStatus = status
            note = nil
        case let .failure(error):
            note = error.localizedDescription
            loginStatus = LoginItem.status
        }
    }

    /// Relaunch, because Input Monitoring and Accessibility are read at launch.
    ///
    /// A detached `open` after this process exits, rather than asking macOS to restart
    /// us: an app that terminates itself and expects something to notice is an app that
    /// does not come back.
    private func restart() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}
