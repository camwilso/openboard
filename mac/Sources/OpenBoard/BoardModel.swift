import Combine
import Foundation
import OpenBoardKit
import SwiftUI

/**
 What the UI reads.

 One observable object shared by the status item, the popover and the settings
 window, so the three can never disagree about the state of the board. Everything
 here is display state derived from the registry — the registry itself is owned by
 the session store and rebuilt from hooks.

 Deliberately holds no device handle: the UI must keep rendering, and keep saying
 *why*, when the pad is unreachable.
 */
@MainActor
final class BoardModel: ObservableObject {
    @Published private(set) var slots: [SlotView] = SlotView.emptyBoard
    @Published private(set) var device: DeviceStatus = .unknown
    /// Attached by cable. Charging, and off Bluetooth for as long as it is — which is
    /// why the battery percentage stops updating and must not be shown as if it had.
    @Published private(set) var isWired = false
    /// The attached pad's hardware serial, or nil when nothing is attached. The key a
    /// custom name is filed under — see `Preferences.deviceNames`.
    @Published private(set) var deviceSerial: String?

    /**
     What to call the pad on screen.

     The name you gave this one, or the plain product name. Never the pairing suffix
     macOS appends — "Codex Micro #3" describes this Mac's pairing history, not the
     object, and reads as a version number.
     */
    var deviceName: String {
        if let deviceSerial, let named = preferences.deviceNames[deviceSerial],
           !named.trimmingCharacters(in: .whitespaces).isEmpty {
            return named
        }
        return "Codex Micro"
    }
    @Published var appearances: [SessionState: Appearance] = [:]
    @Published var actions: [String: KeyAction] = [:]
    @Published var caps: [String: String] = [:]
    /// Per-key snippet text. `snippet` is the fallback for a key with none set.
    @Published var snippets: [String: String] = [:]
    @Published var snippet: String = "/start-ticket"
    /// Never nil: an un-recorded pad runs on the assumed layout rather than staying
    /// dark. See `Calibration` for the evidence behind that default.
    @Published var calibration: Calibration = Calibration.loadDefault()

    /// Which hooks may repaint. Absent means enabled — muting is opt-in.
    @Published var events: [String: Bool] = [:]
    /// Notification subtype → state. `idle_prompt` is deliberately absent.
    @Published var notifications: [String: SessionState] = [:]
    /// The show currently owning the ring, if any.
    @Published var runningShow: String?
    /// Fun mode, which owns the whole pad rather than just the ring.
    @Published var funModeRunning = false

    /// Sessions blocked on a human, in slot order. Drives the popover's orange row
    /// and the status item's color — one source, so they cannot drift apart.
    var blocked: [SlotView] { slots.filter { $0.state?.isAttention == true } }

    /// Whether a person has actually confirmed the key order, as opposed to the board
    /// running on the layout every pad so far has reported.
    var isCalibrationConfirmed: Bool { !calibration.isAssumed }

    /// The whole configuration, so callers that need a value the model does not
    /// surface (decay timings, ambient mode, countdown) can reach it in one place.
    @Published private(set) var preferences: Preferences = .default

    init() {
        apply(PreferencesStore.shared.load())
    }

    /// Adopt a settings document. The single path by which stored preferences reach
    /// the UI, so there is one place to look when a setting does not take effect.
    func apply(_ settings: Preferences) {
        preferences = settings
        appearances = Dictionary(
            uniqueKeysWithValues: SessionState.allCases.map { ($0, settings.appearance(for: $0)) }
        )
        actions = settings.keyActions
        caps = settings.caps
        snippets = settings.snippets
        events = settings.events
        notifications = settings.notificationStates
    }

    /// Fold the current UI state back into a settings document.
    var settings: Preferences {
        var next = preferences
        for (state, appearance) in appearances { next.setAppearance(appearance, for: state) }
        // Every action key, including ones explicitly cleared — an unassigned key has
        // to persist as unassigned rather than falling back to its default.
        // Every action key, including ones explicitly cleared — an unassigned key must
        // persist *as* unassigned or it reverts to its default on the next launch.
        var keys: [String: KeyAction?] = [:]
        for cell in BoardLayout.cells where cell.isAction { keys[cell.id] = actions[cell.id] }
        keys["ENC"] = actions["ENC"]
        next.actionKeys = keys
        next.caps = caps
        next.snippets = snippets
        next.events = events
        var mapped: [String: SessionState?] = [:]
        for kind in ["permission_prompt", "agent_needs_input", "elicitation_dialog", "idle_prompt"] {
            mapped[kind] = notifications[kind]
        }
        next.notifications = mapped
        return next
    }

    func persist() { PreferencesStore.shared.save(settings) }

    /// Edit a field the UI does not mirror into its own `@Published` state.
    ///
    /// `settings` rebuilds the document from the mirrored properties, so a direct write
    /// to `preferences` would be overwritten by the next fold-back. Everything not
    /// mirrored — encoder, ambient, countdown, timings — goes through here.
    func updatePreferences(_ change: (inout Preferences) -> Void) {
        var next = settings
        change(&next)
        apply(next)
    }

    func resetToDefaults() {
        apply(PreferencesStore.shared.reset())
    }

    /// Replace the visible board. Called from the session store as hooks arrive.
    func apply(slots: [SlotView]) { self.slots = slots }

    func apply(device: DeviceStatus) { self.device = device }

    func apply(isWired: Bool) { self.isWired = isWired }

    func apply(deviceSerial: String?) { self.deviceSerial = deviceSerial }
}

/// One of the six keys, as the UI needs it.
struct SlotView: Identifiable, Equatable {
    let slot: Int
    var state: SessionState?
    var title: String?
    var project: String?
    var surface: String?
    var age: String?
    var sessionID: String?
    var pendingTool: String?
    /// Terminal, VS Code, or a CLI with no tty.
    var origin: SessionOrigin?
    /// Whether `title` is the session's own name or a fallback to its folder.
    var isNamed: Bool = false
    /// The real working directory. `project` is its *display* form with the home
    /// directory shortened to `~`, which is not a path anything can open.
    var cwd: String?

    var id: Int { slot }

    var key: String { BoardLayout.key(forSlot: slot) ?? "AG\(slot - 1)" }
    /// Holds a session record — including one that has ended and not yet been pruned.
    var isOccupied: Bool { sessionID != nil }

    /// Actually running. What "N live" in the header means, and not the same thing:
    /// an ended session still holds its record until its process is reaped.
    var isLive: Bool { isOccupied && state != .ended }

    /// The color this key is emitting. An empty slot is not a color — it is the
    /// absence of one, and must look different from a slot deliberately turned off.
    /// What this key is emitting, including the focus pulse — so the dot in the menu
    /// bar and the swatch in the popover agree with the pad rather than describing a
    /// state the hardware is not showing.
    var appearance: Appearance? {
        // Resolved by the controller from the *configured* colors. Computing it here
        // from the shipped defaults was its own quiet lie: a customised idle showed the
        // user's white on the pad and the stock blue in the popover.
        if let emitting { return emitting }
        guard let state else { return nil }
        return Viewing.appearance(state, isFocused: isFocused)
    }

    /// What the pad was told to emit for this slot, colors and all.
    var emitting: Appearance?

    /// Whether this is the session in front of you. Set by the controller, which is the
    /// only thing that knows what the focus watcher last reported.
    var isFocused: Bool = false

    var swatch: Color {
        guard let appearance, appearance.effect != .off else { return Color.secondary.opacity(0.28) }
        return Color(appearance.color)
    }

    /// Brightness reads as opacity in the menu bar: the dot is small enough that a
    /// dim color and a bright one are otherwise indistinguishable.
    var menuBarOpacity: Double {
        guard let appearance, appearance.effect != .off else { return 0.30 }
        return 0.45 + 0.55 * appearance.brightness
    }

    /// The second line, beside the origin badge. See `SessionDetail`.
    var detail: String {
        SessionDetail.line(
            terminal: surface, project: project, age: age, isNamed: isNamed
        )
    }

    /// Kept for the settings window, which shows one line rather than two.
    var meta: String {
        [origin?.rawValue, project, age].compactMap { $0 }.joined(separator: " · ")
    }

    static let emptyBoard: [SlotView] = (1...BoardLayout.slotCount).map { SlotView(slot: $0) }
}

/**
 Why the pad is or is not usable.

 Modelled as a closed set rather than a boolean because the remedies differ
 completely, and the popover's job when things are broken is to say which one applies.
 */
enum DeviceStatus: Equatable {
    case unknown
    case ready
    /// Paired but not connected — press a key to wake it.
    case bluetoothDisconnected
    /// Bluetooth itself is off, so nothing can connect.
    case bluetoothOff
    /// Visible and permitted, but another process holds it.
    case inUseElsewhere
    /// Found, but macOS refused access. Per-app, and needs a restart after granting.
    case permissionDenied(missing: [String])
    /// No vendor interface at all.
    case notFound
    /// Present and permitted, but no calibration record — nothing may paint.
    case notCalibrated

    var isUsable: Bool { self == .ready }

    /// - Parameter name: what the user calls this pad. Threaded in rather than read
    ///   here, because a status enum has no business knowing about preferences.
    func headline(_ name: String = "Codex Micro") -> String {
        switch self {
        case .unknown: "Looking for the pad…"
        case .ready: "Connected to \(name)"
        case .bluetoothDisconnected: "Not connected over Bluetooth"
        case .bluetoothOff: "Bluetooth is off"
        case .inUseElsewhere: "Something else is holding the pad"
        case .permissionDenied: "macOS denied access"
        case .notFound: "No \(name) found"
        case .notCalibrated: "Not calibrated"
        }
    }

    var message: String {
        switch self {
        case .unknown:
            "Checking the HID interface."
        case .ready:
            "Six keys, live."
        case .bluetoothDisconnected:
            "The Codex Micro is paired but not connected. Press any key on the pad to wake it — "
                + "until then every color here is the last thing OpenBoard asked for, not what the pad is showing."
        case let .permissionDenied(missing):
            "OpenBoard needs \(missing.joined(separator: " and ")). "
                + "These are granted per app, and only take effect after the app is restarted."
        case .notFound:
            "Connect the pad over USB or Bluetooth. If it is plugged in, check that it is on Layer 1."
        case .notCalibrated:
            "Slot order is never assumed, so nothing will light until you record which physical key is which."
        case .bluetoothOff:
            "Bluetooth is switched off, so the pad cannot connect at all."
        case .inUseElsewhere:
            "The pad is here and OpenBoard is allowed to read it, but something else has it open. "
                + "An older copy of OpenBoard still running is the usual cause."
        }
    }
}
