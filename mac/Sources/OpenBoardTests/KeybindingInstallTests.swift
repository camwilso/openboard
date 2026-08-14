import Foundation
import OpenBoardKit

/**
 The ⌃Y binding, audited and written the way hooks are.

 `keybindings.json` is the user's file: the tests that matter are the ones about
 leaving it alone — every unrelated binding preserved, a conflicting ⌃Y reported
 rather than overwritten, a fresh document given the schema fields it should have.
 */
func runKeybindingInstallTests() {
    test("no file reads as missing, and install can create one") {
        let audit = KeybindingInstall.audit(document: nil)
        expectEqual(audit.status, .missing)
        expectEqual(audit.fileExists, false)
        expect(!audit.isHealthy)
    }

    test("the wired chord reads as healthy") {
        let doc: [String: Any] = ["bindings": [
            ["context": "Chat", "bindings": ["ctrl+y": "voice:pushToTalk"]]
        ]]
        expectEqual(KeybindingInstall.audit(document: doc).status, .ok)
    }

    test("a chord bound elsewhere is a conflict, named") {
        let doc: [String: Any] = ["bindings": [
            ["context": "Chat", "bindings": ["ctrl+y": "chat:stash"]]
        ]]
        expectEqual(KeybindingInstall.audit(document: doc).status, .conflict("chat:stash"))
    }

    test("with duplicate Chat blocks, the last binding wins") {
        // Claude Code appends user bindings after defaults, so a later block
        // overrides an earlier one — the audit must judge what actually applies.
        let doc: [String: Any] = ["bindings": [
            ["context": "Chat", "bindings": ["ctrl+y": "chat:stash"]],
            ["context": "Chat", "bindings": ["ctrl+y": "voice:pushToTalk"]],
        ]]
        expectEqual(KeybindingInstall.audit(document: doc).status, .ok)
    }

    test("bindings in other contexts say nothing about the chord") {
        let doc: [String: Any] = ["bindings": [
            ["context": "Global", "bindings": ["ctrl+y": "voice:pushToTalk"]]
        ]]
        expectEqual(KeybindingInstall.audit(document: doc).status, .missing)
    }

    test("wiring an empty document creates the skeleton the format asks for") {
        let wired = KeybindingInstall.wiring(into: [:])
        expect(wired["$schema"] is String)
        expect(wired["$docs"] is String)
        expectEqual(KeybindingInstall.audit(document: wired).status, .ok)
    }

    test("wiring preserves every binding that is not ours") {
        let doc: [String: Any] = [
            "$schema": "kept",
            "bindings": [
                ["context": "Global", "bindings": ["ctrl+t": "app:toggleTodos"]],
                ["context": "Chat", "bindings": ["space": "voice:pushToTalk", "ctrl+s": "chat:stash"]],
            ],
        ]
        let wired = KeybindingInstall.wiring(into: doc)
        expectEqual(wired["$schema"] as? String, "kept")
        expectEqual(KeybindingInstall.audit(document: wired).status, .ok)

        let blocks = wired["bindings"] as? [[String: Any]] ?? []
        expectEqual(blocks.count, 2)
        let global = blocks.first { $0["context"] as? String == "Global" }?["bindings"] as? [String: Any]
        expectEqual(global?["ctrl+t"] as? String, "app:toggleTodos")
        let chat = blocks.first { $0["context"] as? String == "Chat" }?["bindings"] as? [String: Any]
        expectEqual(chat?["space"] as? String, "voice:pushToTalk")
        expectEqual(chat?["ctrl+s"] as? String, "chat:stash")
    }

    test("wiring a document with no Chat context appends one") {
        let doc: [String: Any] = ["bindings": [
            ["context": "Global", "bindings": ["ctrl+t": "app:toggleTodos"]]
        ]]
        let wired = KeybindingInstall.wiring(into: doc)
        expectEqual(KeybindingInstall.audit(document: wired).status, .ok)
        expectEqual((wired["bindings"] as? [[String: Any]])?.count, 2)
    }

    test("install writes a real file and round-trips through the audit") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keybinding-install-\(UUID().uuidString)")
        let target = dir.appendingPathComponent("keybindings.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        try KeybindingInstall.install(url: target)
        expectEqual(KeybindingInstall.audit(document: KeybindingInstall.load(url: target)).status, .ok)
    }

    test("install refuses to overwrite a conflicting binding") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keybinding-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("keybindings.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let doc: [String: Any] = ["bindings": [
            ["context": "Chat", "bindings": ["ctrl+y": "chat:stash"]]
        ]]
        try JSONSerialization.data(withJSONObject: doc).write(to: target)

        do {
            try KeybindingInstall.install(url: target)
            expect(false, "install should have thrown on a conflict")
        } catch {
            // The user's binding survives, byte for byte as far as the audit sees.
            expectEqual(
                KeybindingInstall.audit(document: KeybindingInstall.load(url: target)).status,
                .conflict("chat:stash")
            )
        }
    }
}
