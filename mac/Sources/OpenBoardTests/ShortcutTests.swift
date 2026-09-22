import Foundation
import OpenBoardKit

/**
 The recorded chord: how it prints, how it is stored, and that the two actions built
 on it are wired into the picker.
 */
func runShortcutTests() {
    test("the label prints modifiers in the order macOS does") {
        let all = Shortcut(keyCode: 49, modifiers: [.command, .control, .option, .shift], key: "Space")
        expectEqual(all.label, "⌃⌥⇧⌘Space")
        expectEqual(Shortcut(keyCode: 96, modifiers: [.function], key: "F5").label, "fn F5")
        expectEqual(Shortcut(keyCode: 16, key: "Y").label, "Y")
    }

    test("a modifier on its own shows just its symbol") {
        // A lone right ⌥ has no key name; "key 61" would be a number nobody recognises.
        expectEqual(Shortcut(keyCode: 61, modifiers: [.option], key: "").label, "⌥")
        expectEqual(Shortcut(keyCode: 63, modifiers: [.function], key: "").label, "fn")
        expectEqual(Shortcut(keyCode: 200, key: "").label, "key 200")
    }

    test("a shortcut round-trips through JSON with a stable modifier order") {
        let chord = Shortcut(keyCode: 16, modifiers: [.command, .control], key: "Y", mode: .hold)
        expectEqual(Shortcut(json: chord.json), chord)
        // A Set has no order; the file must not be rewritten differently each save.
        expectEqual(chord.json["modifiers"] as? [String], ["control", "command"])
        expectEqual(chord.json["mode"] as? String, "hold")
    }

    test("a document without a key code is not a shortcut") {
        expect(Shortcut(json: ["modifiers": ["command"], "key": "Y"]) == nil)
    }

    test("unknown modifiers and modes degrade rather than fail") {
        let chord = Shortcut(json: ["keyCode": 49, "modifiers": ["command", "hyper"], "mode": "toggle"])
        expectEqual(chord?.modifiers, [.command])
        expectEqual(chord?.mode, .tap)
        expectEqual(chord?.key, "")
    }

    test("space is what push-to-talk holds") {
        expectEqual(Shortcut.space.keyCode, 49)
        expectEqual(Shortcut.space.mode, .hold)
        expect(Shortcut.space.modifiers.isEmpty)
    }

    test("the two new actions are wired into the pickers") {
        expectEqual(KeyAction(rawValue: "enter"), .enter)
        expectEqual(KeyAction(rawValue: "shortcut"), .shortcut)
        expectEqual(KeyAction.enter.hint, "⏎", "the keycap glyph approve already uses")
        expect(KeyAction.shortcut.needsShortcut)
        expect(!KeyAction.enter.needsShortcut)
        expect(!KeyAction.shortcut.needsSnippetText)
        expect(KeyAction.forJoystick.contains(.enter))
        expect(KeyAction.forJoystick.contains(.shortcut))
    }
}
