import Foundation

/**
 A keyboard chord a pad key replays.

 Recorded in Settings from a real keystroke and stored beside the snippets, keyed by the
 control it belongs to: `ACT08`, `ENC` (the dial's click), `ENC.long` (its hold) and
 `JOY.up` … `JOY.right`. The action itself is just `KeyAction.shortcut`; this is the
 payload, the same split `.snippet` and `snippets` already have.

 `key` is the name shown for the main key ("Space", "Y", "F5") and is captured at record
 time by the app, which is the only place that can ask the keyboard what a key code is
 called. Kept on disk so the label does not depend on a table that may not know the key.

 Pure Foundation, so the file format and the label can be tested without AppKit.
 */
public struct Shortcut: Equatable, Sendable {
    /// In the order macOS prints them: fn first because it is a word, then ⌃ ⌥ ⇧ ⌘.
    public enum Modifier: String, CaseIterable, Sendable {
        case function, control, option, shift, command

        var symbol: String {
            switch self {
            case .function: "fn "
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
    }

    /// Tap sends the chord once. Hold keeps it down until the pad key comes back up —
    /// only honoured on the action caps, the one control with a release edge.
    public enum Mode: String, Sendable {
        case tap, hold
    }

    /// macOS virtual key code.
    public var keyCode: Int
    public var modifiers: Set<Modifier>
    public var key: String
    public var mode: Mode

    public init(keyCode: Int, modifiers: Set<Modifier> = [], key: String, mode: Mode = .tap) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
        self.mode = mode
    }

    /// What push-to-talk holds: space, no modifiers.
    public static let space = Shortcut(keyCode: 49, key: "Space", mode: .hold)

    /// "⌃⌥Space" — for the button and the log. A chord that is a modifier alone (a
    /// lone right ⌥) has no key name and shows just its symbol.
    public var label: String {
        let symbols = Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined()
        guard key.isEmpty else { return symbols + key }
        return symbols.isEmpty ? "key \(keyCode)" : symbols.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - the file

    /// Nil without a key code — there is nothing to send. Anything else degrades: an
    /// unknown modifier name is skipped, an unknown mode is a tap.
    public init?(json: [String: Any]) {
        guard let keyCode = json["keyCode"] as? Int else { return nil }
        self.keyCode = keyCode
        let names = json["modifiers"] as? [String] ?? []
        modifiers = Set(names.compactMap(Modifier.init(rawValue:)))
        key = json["key"] as? String ?? ""
        mode = (json["mode"] as? String).flatMap(Mode.init(rawValue:)) ?? .tap
    }

    /// Modifiers written in `allCases` order, so a save never reorders the file.
    public var json: [String: Any] {
        [
            "keyCode": keyCode,
            "modifiers": Modifier.allCases.filter(modifiers.contains).map(\.rawValue),
            "key": key,
            "mode": mode.rawValue,
        ]
    }
}
