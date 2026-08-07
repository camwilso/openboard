import OpenBoardKit
import SwiftUI

/**
 One harness — how it reaches the board, and what its events mean.

 Everything Claude-specific was scattered before this: the hook wiring lived under
 Device beside Bluetooth and Input Monitoring, which are facts about a *keyboard*; the
 notification mappings were their own tab called Events, named after the mechanism
 rather than the thing; and how a session is detected on Terminal versus VS Code was
 written down only in the README and the source.

 They are one subject — *how a coding agent reaches this board* — and they are now one
 pane, ordered the way setup actually goes: is it wired, what do its events mean, and
 where does it work.

 ## Three harnesses, not equally

 Claude Code is wired end to end and OpenBoard writes its file. Hermes and Pi share the
 same helper, socket and payload fields, but their configuration is theirs — so the pane
 hands over the exact text to paste rather than writing YAML into somebody's file or
 dropping a TypeScript module into their extension directory.

 Its limitations are shown in orange, and they are not a disclaimer:
 Hermes has no completion event, so its keys never turn green, and Pi has no documented
 approval event, so its keys never turn orange — which is the state this board exists
 for. A tab that showed three logos and hid that would be the failure this project keeps
 auditing out.
 */
struct HarnessPane: View {
    @EnvironmentObject private var board: BoardModel
    @Environment(\.boardCommands) private var commands

    /// Which harness to show. A value, not a binding: the sidebar's selection decides
    /// it and this pane never changes it, so a binding would be write access nothing
    /// uses.
    let harnessID: String

    @State private var hooks = HookInstall.Audit(statuses: [:], settingsExists: false)
    @State private var hookNote: String?
    @State private var agents: [(agent: HarnessDetector.Agent, installed: Bool)] = []

    private var installedIDs: Set<String> {
        Set(agents.filter(\.installed).compactMap { $0.agent.harnessID })
    }

    /// Installed *and* reporting. Either alone is not a connection: an agent that is
    /// not here cannot send anything, and one whose hooks are unwired never will.
    private var isConnected: Bool {
        installedIDs.contains(harness.id) && (harness.setup == .automatic ? hooks.isHealthy : true)
    }

    private var harness: Harness {
        Harness.all.first { $0.id == harnessID } ?? Harness.claudeCode
    }

    private static let notificationKinds = [
        "permission_prompt", "agent_needs_input", "elicitation_dialog", "idle_prompt",
    ]

    /// Has ever reported an event. The sections below describe what a harness *does*,
    /// and one that has never sent an event has done nothing to describe.
    private var everSeen: Bool {
        board.preferences.harnessesSeen.contains(harness.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !everSeen {
                    emptyState
                } else {
                // The card below names it, and the sidebar row is highlighted. A
                // third statement of which harness this is would be two too many.
                harnessCard

                if !installedIDs.contains(harness.id) {
                    Text("Not found on this Mac.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                if !harness.limitations.isEmpty {
                    // Orange, and above the setup rather than under it. A color that
                    // will never appear on your board is not a footnote.
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(harness.limitations, id: \.self) { limitation in
                            Text(limitation)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color(RGB(0xFF6A00)))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // One section, because they were one thing described twice: a hook is
                // the event, and "is it wired" and "what does it mean" are two columns
                // of the same answer rather than two headings.
                PaneHeader("Events", "What a session reports, and whether it reaches the board.")
                eventsSection

                if harness.id == Harness.claudeCode.id {
                    // Claude Code's voice-mode setting and any action-key binding must
                    // agree, or the pad tap silently records nothing (hold mode) or
                    // sticks Space down forever (tap mode with voice-talk).
                    PaneHeader("Voice", "Whether the pad's voice key matches Claude's mode.")
                    voiceSection

                    // Notification subtypes are Claude Code's alone. Showing this table
                    // under Hermes would be four pickers editing settings its events
                    // never consult.
                    PaneHeader("Notifications", "Which notification subtype means which state.")
                    notificationSection
                }

                PaneHeader("Where it works", "How a session is found, and what its key does.")
                surfaceTable
                }
            }
            .padding(22)
        }
        .onAppear {
            refresh()
            agents = HarnessDetector.survey()
        }
    }

    /**
     A harness that has never reported.

     Everything in the connected view describes behaviour: what its events mean, where
     it works, which key does what. None of that has happened yet, and showing it would
     be four sections of confident description for something that has never run here —
     the failure this project keeps auditing out, one screen at a time.

     So the empty state is what is true and useful: what it is, that it has not
     reported, and exactly how to wire it. The limitations come first, because they are
     the reason someone might decide not to bother.
     */
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(.tertiary, lineWidth: 1)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(harness.name).font(.system(size: 13, weight: .semibold))
                    Text(installedIDs.contains(harness.id)
                        ? "Found on this Mac, and it has never reported to the board."
                        : "Not found on this Mac.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))

            if !harness.limitations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(harness.limitations, id: \.self) { limitation in
                        Text(limitation)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(RGB(0xFF6A00)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            PaneHeader("Set it up", "Then send it something — the rest fills in from there.")
            switch harness.setup {
            case .automatic:
                VStack(spacing: 0) { wiringRow }
                    .padding(.horizontal, 12)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
                if let hookNote {
                    Text(hookNote).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case let .manual(path, snippet):
                manualSetup(path: path, snippet: snippet)
            }
        }
    }

    // MARK: - the harness

    private var harnessCard: some View {
        HStack(spacing: 10) {
            // Green means connected, and connected means found here *and* wired. It
            // used to mean "OpenBoard supports this", which is a claim about the app
            // rather than about your machine and was true whether or not the agent
            // existed.
            Circle()
                .fill(isConnected ? Color(RGB(0x09B821)) : Color.secondary.opacity(0.45))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(harness.name).font(.system(size: 13, weight: .semibold))
                Text(isConnected ? "Connected" : "Not connected")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let path = harness.settingsPath {
                Text(path)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    // MARK: - hooks


    /**
     For a harness whose configuration OpenBoard will not edit.

     Hermes keeps YAML, where a machine edit risks comments and ordering, and Pi has no
     out-of-process hooks at all — there is no file that runs commands to install into.
     So the exact text is handed over, with the real binary path already substituted,
     and a button that puts it on the clipboard.
     */
    private func manualSetup(path: String, snippet: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(path)
                    .font(.system(size: 11.5).monospaced())
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(resolved(snippet), forType: .string)
                    hookNote = "Copied."
                }
                .controlSize(.small)
            }
            ScrollView(.horizontal) {
                Text(resolved(snippet))
                    .font(.system(size: 11).monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hookNote {
                Text(hookNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }

    /// The snippet says OPENBOARD; the file has to say where this build actually is.
    /// A copied command pointing at a binary that is not there is the stale-path
    /// failure the hook audit exists to catch, shipped by hand.
    private func resolved(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "OPENBOARD", with: HookInstall.hookCommandPath())
    }

    // MARK: - events

    /// The wiring and the meaning, in one card: whether the events arrive, then what
    /// each one does when it does.
    @ViewBuilder
    private var eventsSection: some View {
        VStack(spacing: 0) {
            if case .automatic = harness.setup {
                wiringRow
                Divider().opacity(0.3)
            }
            eventRows
        }
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))

        if case let .manual(path, snippet) = harness.setup {
            // No audit for these: their configuration is not ours to read, so the only
            // honest thing to show is what it should contain.
            manualSetup(path: path, snippet: snippet)
        }

        if let hookNote {
            Text(hookNote).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /**
     Whether the events are actually arriving.

     `~/.claude/settings.json` affects every Claude Code session on the machine, so the
     audit is read-only and runs freely while the repair happens only on a press, and
     backs the file up first.
     */
    private var wiringRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(hooks.isHealthy ? Color(RGB(0x09B821)) : Color(RGB(0xFF6A00)))
                .frame(width: 8, height: 8)
            Text(hooks.isHealthy
                ? "All \(harness.events.count) wired to this build."
                : hooks.settingsExists
                    ? "\(hooks.problems.count) of \(harness.events.count) need attention."
                    : "No settings file found.")
                .font(.system(size: 12))
            Spacer(minLength: 0)
            Button("Re-check", action: refresh).controlSize(.small)
            if !hooks.isHealthy {
                Button("Repair") {
                    do {
                        try HookInstall.install(command: HookInstall.hookCommandPath())
                        hookNote = "Wired. A backup of the previous file is beside it."
                    } catch {
                        hookNote = error.localizedDescription
                    }
                    refresh()
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 9)
    }

    // MARK: - the mapping

    /// Read-only on purpose. These are what the events *are*; the only genuinely
    /// ambiguous one is a notification, and that is the editable table below.
    private var eventRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(harness.events.enumerated()), id: \.element.name) { index, event in
                if index > 0 { Divider().opacity(0.3) }
                HStack(spacing: 10) {
                    Text(event.name)
                        .font(.system(size: 11.5).monospaced())
                        .frame(width: 150, alignment: .leading)
                    if let state = EventMapper.state(
                        for: event.name,
                        matcher: event.matcher.map { _ in "permission_prompt" },
                        notifications: board.notifications
                    ) {
                        StateChip(state: state)
                    } else {
                        Text("depends on the subtype")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if let matcher = event.matcher {
                        Text(matcher)
                            .font(.system(size: 10.5).monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.vertical, 7)
            }
        }
    }

    private var notificationSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.notificationKinds.enumerated()), id: \.element) { index, kind in
                if index > 0 { Divider().opacity(0.3) }
                HStack {
                    Text(kind).font(.system(size: 11.5).monospaced())
                    Spacer(minLength: 12)
                    Picker("", selection: notificationBinding(kind)) {
                        Text("unmapped").tag(SessionState?.none)
                        ForEach(
                            [SessionState.awaiting, .stalled, .working, .error, .idle, .done],
                            id: \.self
                        ) { state in
                            Text(state.label).tag(SessionState?.some(state))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
        .overlay(alignment: .bottom) { EmptyView() }
    }

    // MARK: - voice

    /**
     Claude Code's voice mode and the pad's voice bindings must line up. `hold` records
     while Space is held; `tap` records between two Space taps. A `voice-tap` binding
     sends one tap — perfect for `tap`, silent under `hold` since Space never stayed
     down. `voice-talk` presses Space on key-down and releases on key-up — right for
     `hold`, and under `tap` it starts a recording that never ends.

     Read `~/.claude/settings.json → voice.mode` and compare against every ACT key
     bound to a `voice-*` action. Report matches in green, mismatches in orange with
     the specific rebind the user needs to do.
     */
    private var voiceSection: some View {
        let bindings = voiceBindings()
        let claudeMode = ClaudeVoice.readMode()
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Claude's mode")
                    .font(.system(size: 11.5))
                    .frame(width: 150, alignment: .leading)
                Text(claudeMode ?? "not set")
                    .font(.system(size: 11.5).monospaced())
                    .foregroundStyle(claudeMode == nil ? .tertiary : .primary)
                Spacer(minLength: 0)
                Text("~/.claude/settings.json")
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            Divider().opacity(0.3)
            if bindings.isEmpty {
                HStack(spacing: 10) {
                    Text("Pad bindings")
                        .font(.system(size: 11.5))
                        .frame(width: 150, alignment: .leading)
                    Text("no key bound to a voice action")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array(bindings.enumerated()), id: \.element.key) { index, binding in
                    if index > 0 { Divider().opacity(0.3) }
                    voiceRow(key: binding.key, action: binding.action, claudeMode: claudeMode)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    private func voiceRow(key: String, action: KeyAction, claudeMode: String?) -> some View {
        let verdict = VoiceMatch.evaluate(action: action, claudeMode: claudeMode)
        return HStack(spacing: 10) {
            Circle()
                .fill(verdict.isMatch ? Color(RGB(0x09B821)) : Color(RGB(0xFF6A00)))
                .frame(width: 8, height: 8)
            Text(key)
                .font(.system(size: 11.5).monospaced())
                .frame(width: 60, alignment: .leading)
            Text(action.rawValue)
                .font(.system(size: 11.5).monospaced())
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verdict.detail)
                .font(.system(size: 11))
                .foregroundStyle(verdict.isMatch ? .secondary : Color(RGB(0xFF6A00)))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 8)
    }

    /// Every action-key binding whose action is one of the voice variants, sorted for
    /// stable display.
    private func voiceBindings() -> [(key: String, action: KeyAction)] {
        board.preferences.actionKeys
            .compactMap { key, action -> (String, KeyAction)? in
                guard let action, [.voiceTap, .voiceTalk, .voiceToggle].contains(action) else {
                    return nil
                }
                return (key, action)
            }
            .sorted { $0.0 < $1.0 }
    }

    // MARK: - surfaces

    private var surfaceTable: some View {
        VStack(spacing: 0) {
            ForEach(Array(harness.surfaces.enumerated()), id: \.element.id) { index, surface in
                if index > 0 { Divider().opacity(0.3) }
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(surface.unsupported == nil
                            ? Color(RGB(0x09B821))
                            : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(surface.name).font(.system(size: 12.5, weight: .medium))
                        if let reason = surface.unsupported {
                            Text(reason)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(surface.detection)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Key press → \(surface.jump)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }


    // MARK: - plumbing

    private func refresh() {
        hooks = HookInstall.audit(
            settings: HookInstall.loadSettings(),
            expectedCommand: HookInstall.hookCommandPath()
        )
    }

    private func describe(_ status: HookInstall.EventStatus?) -> String {
        switch status {
        case .missing, nil: "not wired"
        case .stalePath(let path): "points at a binary that is gone — \(path)"
        case .otherPath(let path): "points at another install — \(path)"
        case .ok: "ok"
        }
    }

    private func notificationBinding(_ kind: String) -> Binding<SessionState?> {
        Binding(
            get: { board.notifications[kind] },
            set: {
                board.notifications[kind] = $0
                commands.bindingsChanged()
            }
        )
    }
}

/// A state, as its own color. The chip is the appearance the pad will actually emit,
/// so the table cannot describe a state in a color the board is not using.
struct StateChip: View {
    @EnvironmentObject private var board: BoardModel
    let state: SessionState

    var body: some View {
        let appearance = board.appearances[state] ?? state.defaultAppearance
        HStack(spacing: 5) {
            Circle()
                .fill(Color(appearance.color))
                .opacity(appearance.effect == .off ? 0.3 : 1)
                .frame(width: 7, height: 7)
            Text(state.label).font(.system(size: 11.5))
        }
    }
}
