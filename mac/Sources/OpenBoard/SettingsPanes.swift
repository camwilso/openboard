import OpenBoardKit
import SwiftUI

/**
 Device — connection, permissions, calibration, and what is deliberately inert.

 The permissions section is the important one. Several families, granted separately and
 independently — Input Monitoring and Bluetooth are both "talking to the pad" and having
 one says nothing about the other. Each produces a differently-shaped silent failure,
 and the app cannot fix any of them, so the least it can do is say precisely which is
 missing and open the right pane.
 */
struct DevicePane: View {
    @EnvironmentObject private var board: BoardModel
    @EnvironmentObject private var updater: Updater
    @Environment(\.boardCommands) private var commands

    @State private var permissions = PermissionProbe.inspect()
    @State private var hooks = HookInstall.Audit(statuses: [:], settingsExists: false)
    @State private var calibrating = false
    @State private var hookNote: String?
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?
    @State private var allGranted = false
    @State private var requestingAutomation = false
    @State private var automationNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(board.device.isUsable ? Color(RGB(0x09B821)) : Color(RGB(0xD41145)))
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(board.device.headline(board.deviceName)).font(.system(size: 13, weight: .semibold))
                        Text(board.device.message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))

                // Kept: someone grants a permission, comes back, sees no change, and
                // concludes the app is broken.
                PaneHeader("Permissions", "Each takes effect after OpenBoard restarts.")
                VStack(spacing: 0) {
                    permissionRow(
                        "Input Monitoring", "reading the pad — all lighting and every key",
                        status: permissions.inputMonitoring, pane: "Privacy_ListenEvent"
                    )
                    permissionRow(
                        "Accessibility", "typing snippets, sending ⏎ and ⎋, scrolling",
                        status: permissions.accessibility, pane: "Privacy_Accessibility"
                    )
                    // Separate from Input Monitoring, even though both are "talking to
                    // the pad": the battery is read as a Bluetooth central, and macOS
                    // gates that on its own.
                    permissionRow(
                        "Bluetooth", "reading the pad's battery level",
                        status: permissions.bluetooth, pane: "Privacy_Bluetooth"
                    )
                    ForEach(PermissionProbe.automationTargets, id: \.bundleID) { target in
                        permissionRow(
                            "Automation → \(target.name)", why(automating: target.name),
                            status: permissions.automation[target.name] ?? .unknown,
                            pane: "Privacy_Automation",
                            subject: target.name,
                            optional: target.optional
                        )
                    }
                }
                HStack(spacing: 8) {
                    /*
                     The button worked and looked like it did not.

                     Re-probing is instant and usually finds exactly what was already on
                     screen, so pressing it changed nothing visible — and a button that
                     appears to do nothing is indistinguishable from one that is broken.
                     It is pressed precisely when someone has just granted something in
                     System Settings and wants to be told, so now it answers out loud.

                     Only on success. A failure already has an answer on screen: the row
                     that is not green, and the list beside this button.
                     */
                    Button("Check now") {
                        permissions = PermissionProbe.inspect()
                        allGranted = permissions.missing.isEmpty
                    }
                    .controlSize(.small)
                    .disabled(requestingAutomation)

                    /*
                     Automation is the only permission the app can raise a prompt for
                     itself, and until now it was the only one it did not.

                     The other three send you to System Settings because that is where
                     they are granted. Automation is not: it has no "request access"
                     API, macOS asks when something tries to drive the target, and
                     System Events — the one the key actions need — is a launch-on-demand
                     helper that is asleep most of the time. So its row sat at "not
                     running" beside an Open button leading to a pane where OpenBoard was
                     not yet listed, because it had never asked for anything.

                     QuickTime is not in this. It prompts itself the first time fun mode
                     opens the video, which is the better moment — the user has just
                     asked for the thing the dialog is about.

                     Shown only while there is something to ask for. Once the required
                     targets have answered the button is not a control, it is a leftover.
                     */
                    if !automationSettled {
                        Button(requestingAutomation ? "Asking" : "Grant permissions") {
                            requestAutomation()
                        }
                        .controlSize(.small)
                        .disabled(requestingAutomation)
                        .help("Asks macOS for permission to drive System Events, which "
                            + "the key actions need. QuickTime is not included — fun "
                            + "mode asks for that itself the first time you play it.")
                    }

                    if !permissions.missing.isEmpty {
                        Text("Missing: \(permissions.missing.joined(separator: ", "))")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(RGB(0xFF6A00)))
                    }
                }

                if let automationNote {
                    Text(automationNote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                /*
                 Key order and Hooks are gone from this pane.

                 Both were one-time setup wearing the clothes of a setting. The key order
                 is the layout every pad reports and is now assumed rather than gated on;
                 the hooks are wired once and then never thought about again. A settings
                 window is for things you change, and a permanent readout of two answered
                 questions is furniture.

                 Neither check went away — see `refresh()`. The audit still runs at
                 launch and writes its verdict to the log, which is where a *broken*
                 install has always been diagnosed from.

                 Repair did not go away either. `hooksProblem` below still offers it,
                 and has to: a new install has all eight hooks missing, which is the
                 one state where the app runs, the pad connects, and nothing ever
                 lights. What is gone is the permanent readout on a healthy machine.
                */
                // Hooks have no section either, but a *broken* install still has to be
                // fixable: without them the app runs, the pad connects, and nothing ever
                // lights. So this appears only when the audit finds a problem, and is
                // absent entirely on a healthy machine — an error, not a readout.
                if !hooks.isHealthy {
                    hooksProblem
                }

                PaneHeader("Starting up", "Setting OpenBoard up, and keeping it running.")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: loginItemBinding) {
                        Text("Open OpenBoard at login").font(.system(size: 12.5))
                    }
                    .toggleStyle(.switch)
                    .disabled(!LoginItem.isInstalledProperly)

                    if !LoginItem.isInstalledProperly {
                        // Registration is tied to the bundle path, so a copy running
                        // from a build directory registers a path that will vanish.
                        Text("Move OpenBoard to /Applications first — a login item "
                            + "registered from anywhere else breaks when that folder changes.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(RGB(0xFF6A00)))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if loginStatus == .awaitingApproval {
                        Text("Waiting for approval in System Settings → General → Login Items.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(RGB(0xFF6A00)))
                    } else if case let .unavailable(reason) = loginStatus {
                        Text(reason)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color(RGB(0xFF6A00)))
                    }
                    if let loginError {
                        Text(loginError).font(.system(size: 11.5))
                            .foregroundStyle(Color(RGB(0xD41145)))
                    }

                    // Grouped here as the other thing you do once when setting up, and
                    // then never again. It is not a setting — nothing about it changes
                    // in daily use — but it is the only way to fix a pad whose keys are
                    // in an order this app did not expect, and deleting the button
                    // would leave the capture sheet as code nothing calls, which is how
                    // four separate bugs got into this app.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Key order").font(.system(size: 12.5))
                        Text(calibrationStatus)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button(board.isCalibrationConfirmed ? "Recalibrate" : "Check key order") {
                                calibrating = true
                            }
                            .controlSize(.small)
                            .disabled(!board.device.isUsable)

                            if !board.device.isUsable {
                                Text("Connect the pad first.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                // Before Files, not after. Files is reference and this is actionable,
                // and the actionable thing should not sit below the list of paths
                // nobody scrolls past.
                PaneHeader("Version", "Which build this is, and how it gets a newer one.")
                updateSection

                PaneHeader("Files", "Where your settings and log are kept.")
                configFileSection
            }
            .padding(22)
        }
        // Re-probed on appearance because these are granted *outside* the app: someone
        // flips a switch in System Settings and comes straight back here, and a stale
        // red would send them round the loop again.
        .onAppear { refresh() }
        .sheet(isPresented: $calibrating) { CalibrationSheet() }
        // Everything, not just what lighting and keys need: someone checking after a
        // trip to System Settings wants to know the whole list is clear. A target that
        // is merely not running does not count against it — see PermissionProbe.Status.
        .alert("All permissions granted", isPresented: $allGranted) {
            Button("OK", role: .cancel) {}
        }
    }

    /**
     What the board currently believes about which key is which.

     The button had no context: "Recalibrate" on its own answers neither "is anything
     wrong?" nor "what would I be changing?", so the honest reading was that pressing it
     might break something that currently works.

     Three states, and the middle one is why this is not a boolean. A calibration that
     was checked and came out identity behaves exactly like the assumption — but one is
     an answer and the other is a guess that has held so far, and collapsing them would
     throw away the only thing the check produces.
     */
    private var calibrationStatus: String {
        let calibration = board.calibration
        if calibration.isAssumed {
            return "Not checked. Running on the order every pad so far reports — "
                + "slot 1 top-left, then reading order."
        }

        let when = calibration.recordedAt.map {
            " on " + $0.formatted(date: .abbreviated, time: .omitted)
        } ?? ""

        guard calibration.isCustom else {
            return "Checked\(when) — the standard order, slot 1 top-left."
        }
        let moved = calibration.movedSlots
            .map { "slot \($0.slot) → key \($0.key)" }
            .joined(separator: ", ")
        return "Custom order recorded\(when): \(moved)."
    }

    /**
     Nothing left to ask about.

     Optional targets do not count. QuickTime Player prompts itself the first time fun
     mode runs, so it is never something this button could obtain — leaving it in the
     sum meant the button stayed on screen forever, offering to do a thing it would then
     skip.

     A denial counts as settled: macOS will not re-prompt once someone has said no, and
     only System Settings can undo it. `unavailable` does not — that is a target asleep
     rather than an answer, and `refresh()` wakes it before this is read.
     */
    private var automationSettled: Bool {
        PermissionProbe.automationTargets
            .filter { !$0.optional }
            .allSatisfy { target in
                let status = permissions.automation[target.name] ?? .unknown
                return status == .granted || status == .denied
            }
    }

    /**
     Ask macOS for the automation grants, one target at a time.

     The summary afterwards matters more than it looks. Each target produces a *system*
     dialog, and someone who clicks through two of them has no idea which they answered
     which way — least of all when one of them briefly opened QuickTime Player. So the
     result is stated rather than left to be inferred from two dots changing colour.

     A denial is reported without alarm. Automation is optional: without System Events
     the snippet keys stop working, without QuickTime fun mode does, and neither is the
     board. Painting a refusal red would imply something is broken that is not.
     */
    private func requestAutomation() {
        requestingAutomation = true
        automationNote = nil
        // Captured before, so the summary can report what this click *did* rather than
        // what happens to be true afterwards. Listing everything currently granted read
        // as "I just granted these three" when all three were already on — taking
        // credit for work it did not do, and leaving the real answer ("nothing needed
        // asking") unsaid.
        let before = permissions.automation

        Task {
            let results = await AutomationRequest.requestAll(current: before)
            permissions = PermissionProbe.inspect()
            requestingAutomation = false

            let changed = results.filter { before[$0.name]?.isGranted != true }
            let granted = changed.filter { $0.status.isGranted }.map(\.name)
            let refused = changed.filter { $0.status == .denied }.map(\.name)
            let unanswered = changed.filter { $0.status != .granted && $0.status != .denied }

            var parts: [String] = []
            if !granted.isEmpty { parts.append("Granted: \(granted.joined(separator: ", ")).") }
            if !refused.isEmpty {
                parts.append("Refused: \(refused.joined(separator: ", ")) — "
                    + "turn these on in System Settings → Privacy & Security → Automation.")
            }
            if !unanswered.isEmpty {
                // Dismissing the dialog without choosing, or a target that would not
                // start. Neither is a decision, so the button stays available.
                parts.append("No answer yet for \(unanswered.map(\.name).joined(separator: ", ")).")
            }
            automationNote = parts.isEmpty
                ? "Nothing to grant — everything OpenBoard needs is already allowed."
                : parts.joined(separator: " ")
        }
    }

    /**
     Where the settings live, read from the store rather than written down.

     A hardcoded path is a caption that can be wrong: `OPENBOARD_HOME` moves the whole
     state directory, and a label claiming otherwise sends someone to edit a file the
     app is not reading.

     Two rows, because state and logs are deliberately in different places: logs live
     where Console.app looks, and can be thrown away without losing a setting.
     */
    private var configFileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fileRow("Settings", url: PreferencesStore.url())
            fileRow("Log", url: Log.url)
            // Kept: it names capabilities that exist nowhere else in the UI.
            Text("Safe to hand-edit. Holds a few settings this window does not show.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /**
     Which build this is, and how it gets a newer one.

     Its own section rather than a line under Files, which is where it started. Files is
     reference — here is where things live, nothing to do. This is the opposite: a
     status that changes and a button that acts on it, and burying an action under a
     list of paths is how it stays unfound.

     There is no About window, so this is also the only answer to "what version are you
     on?" short of reading Info.plist in a terminal — a poor first question to ask
     someone reporting a bug. Selectable, because the point is to paste it into an issue.

     The controls are hidden rather than disabled in a build that cannot update. A
     disabled control is a promise that something would happen if only you were allowed;
     a locally-built copy will never have an update feed, so there is nothing to promise
     — the status line says why instead.
     */
    private var updateSection: some View {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Version")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 54, alignment: .leading)
                Text("\(short) (\(build))")
                    .font(.system(size: 11.5).monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(updateStatusText)
                .font(.system(size: 11.5))
                .foregroundStyle(
                    updater.status.isFailure
                        ? AnyShapeStyle(Color(RGB(0xD41145)))
                        : AnyShapeStyle(.secondary)
                )
                .fixedSize(horizontal: false, vertical: true)

            if commands.canUpdate {
                HStack(spacing: 10) {
                    // A switch, matching Starting up. Both are "should the app do this
                    // on its own", and two different controls for one question read as
                    // two different kinds of setting.
                    Toggle(isOn: Binding(
                        get: { commands.automaticUpdates() },
                        set: { commands.setAutomaticUpdates($0) }
                    )) {
                        Text("Check for updates automatically").font(.system(size: 12.5))
                    }
                    .toggleStyle(.switch)

                    Spacer(minLength: 0)

                    Button(updater.status.updateVersion == nil ? "Check now" : "Install") {
                        if updater.status.updateVersion == nil {
                            commands.checkForUpdates()
                        } else {
                            commands.showAvailableUpdate()
                        }
                    }
                    .controlSize(.small)
                    .disabled(updater.status == .checking)
                }
            }
        }
    }

    /**
     One line under the version, saying what the updater knows.

     "Never checked" and "no update found" are told apart on purpose. A status line that
     only knows a boolean renders both as silence, and the difference is the entire
     question when someone is wondering why they have not been offered a release they
     know shipped.
     */
    private var updateStatusText: String {
        switch updater.status {
        case .disabled:
            return "This build cannot update itself — it was compiled locally."
        case .notChecked:
            // Sparkle remembers the last check across launches, so "not checked yet"
            // alone would be misleading the morning after one — the app has checked,
            // just not since it started.
            guard let last = updater.lastCheck else { return "Not checked yet." }
            return "Last checked \(Self.relative(last))."
        case .checking:
            return "Checking"
        case .available(let version):
            return "Version \(version) is available."
        case .upToDate:
            guard let last = updater.lastCheck else { return "Up to date." }
            return "Up to date — last checked \(Self.relative(last))."
        case .failed(let message):
            return "Could not check: \(message)"
        }
    }

    /// Shared so the two branches above cannot drift into phrasing the same instant
    /// two different ways.
    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// One path, shortened to `~` and openable. Disabled rather than hidden when the
    /// file does not exist yet: the path is still the answer to "where would it be?".
    private func fileRow(_ label: String, url: URL) -> some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        return HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 54, alignment: .leading)
            Text(shown)
                .font(.system(size: 11.5).monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .controlSize(.small)
            .disabled(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginStatus.isOn },
            set: { wanted in
                switch LoginItem.set(wanted) {
                case let .success(status):
                    loginStatus = status
                    loginError = nil
                case let .failure(error):
                    loginError = error.localizedDescription
                    loginStatus = LoginItem.status
                }
            }
        )
    }

    private func refresh() {
        permissions = PermissionProbe.inspect()
        // System Events is asleep most of the time, and a permission it has held for
        // months then reads as "not running". Wake it and ask again, so the row shows
        // the grant rather than the helper's nap schedule.
        if permissions.automation["System Events"] == .unavailable {
            Task {
                await AutomationRequest.wakeProbeableTargets()
                permissions = PermissionProbe.inspect()
            }
        }
        // Read live rather than remembered: the registration is tied to the bundle
        // path and signature, so it can go stale exactly like a hook path can.
        loginStatus = LoginItem.status
        hooks = HookInstall.audit(
            settings: HookInstall.loadSettings(),
            expectedCommand: HookInstall.hookCommandPath()
        )
    }

    /**
     Only ever shown when something is wrong.

     Writing to `~/.claude/settings.json` changes behaviour for every Claude Code
     session on the machine, so it never happens on launch — only on this press, and the
     current file is backed up beside itself first.
     */
    @ViewBuilder
    private var hooksProblem: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(Color(RGB(0xFF6A00))).frame(width: 9, height: 9)
                Text(hooks.settingsExists
                    ? "\(hooks.problems.count) of \(HookInstall.events.count) hooks need attention."
                    : "No ~/.claude/settings.json found.")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                Button("Repair hooks") {
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

            ForEach(hooks.problems, id: \.self) { event in
                HStack(spacing: 6) {
                    Text(event).font(.system(size: 11.5).monospaced())
                    Text(describe(hooks.statuses[event]))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if let hookNote {
                Text(hookNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }

    private func describe(_ status: HookInstall.EventStatus?) -> String {
        switch status {
        case .missing, nil: "not wired"
        case .stalePath(let path): "points at a binary that is gone — \(path)"
        case .otherPath(let path): "points at another install — \(path)"
        case .ok: "ok"
        }
    }

    /// What each automation target is actually for. All three said "jumping to a chat",
    /// which is true of one of them: System Events types every snippet and sends every
    /// ⏎, and QuickTime only ever plays the countdown.
    private func why(automating target: String) -> String {
        switch target {
        case "System Events": "typing snippets, ⏎ and ⎋, arrow keys"
        case "Terminal": "jumping to a chat"
        // Names the feature, because that is the whole answer to "do I need this?".
        case "QuickTime Player": "fun mode only — macOS asks the first time you play it"
        default: "driving \(target)"
        }
    }

    private func permissionRow(
        _ name: String, _ why: String,
        status: PermissionProbe.Status, pane: String,
        subject: String? = nil,
        optional: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color(for: status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12.5, weight: .medium))
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // An optional target that has not answered is not missing anything —
            // macOS asks the first time the feature runs. "not running" invited people
            // to go and fix a permission that was never a problem.
            Text(optional && !status.isGranted && status != .denied
                 ? "when needed"
                 : label(for: status))
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.secondary)
                .help(hint(for: status, name: subject ?? name) ?? "")
            Button("Open") {
                if let url = PermissionProbe.settingsURL(forPane: pane) {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func color(for status: PermissionProbe.Status) -> Color {
        switch status {
        case .granted: Color(RGB(0x09B821))
        case .denied: Color(RGB(0xD41145))
        // Not the same as denied: nobody has been asked yet. Sending someone to a
        // settings pane where the app is not even listed is worse than saying so.
        case .unknown: Color(RGB(0xFF6A00))
        // Nothing is wrong and there is nothing to do, so it must not look like an
        // alert. This was orange, which read as "you are missing a permission" for a
        // grant the user had already given.
        case .unavailable: Color.secondary.opacity(0.5)
        }
    }

    private func label(for status: PermissionProbe.Status) -> String {
        switch status {
        case .granted: "granted"
        case .denied: "denied"
        case .unknown: "not asked"
        // Deliberately describes the *target*, not the permission: the permission is
        // very likely granted and simply cannot be read while the app is asleep.
        case .unavailable: "not running"
        }
    }

    /// Only where it is not obvious. A row that explains itself does not need a tooltip.
    private func hint(for status: PermissionProbe.Status, name: String) -> String? {
        guard status == .unavailable else { return nil }
        return "\(name) is not running, so macOS cannot be asked whether OpenBoard may "
            + "drive it. It starts on demand — use a key that needs it and this resolves "
            + "itself."
    }

}

struct ShowCard: View {
    let show: Show
    let running: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if show.auto {
                        Circle().fill(tint).frame(width: 8, height: 8)
                    }
                    Text(show.label).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if running {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(show.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: "%.1fs", show.duration.seconds))
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            // Interactive, because it is a button: the material has to react to a press
            // rather than sit there as a texture.
            .glassControl(cornerRadius: 10)
        }
        .buttonStyle(.plain)
    }

    /// Auto-fire shows borrow the color of the state they announce.
    private var tint: Color {
        switch show.name {
        case "completion": Color(RGB(0x09B821))
        case "question": Color(RGB(0xFF6A00))
        case "error": Color(RGB(0xD41145))
        default: .secondary
        }
    }
}

/**
 A section heading and one line under it.

 Every section carries one. The line is still held to a standard: it says something the
 title does not, in one sentence, and never restates it in longer words. "Permissions —
 each takes effect after OpenBoard restarts" earns its place; "Permissions — the
 permissions OpenBoard needs" would not.

 The subtitle stays optional in the type rather than required, so a section that
 genuinely has nothing to add is not forced to invent something.
 */
struct PaneHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, _ subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
