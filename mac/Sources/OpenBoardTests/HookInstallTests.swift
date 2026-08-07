import Foundation
import OpenBoardKit

/**
 Auditing the hook wiring.

 A missing or dead hook is the most silent failure in the whole system: the app runs,
 the pad connects, and nothing ever lights, because Claude Code does not report a hook
 that fails to execute.

 The write path gets the most scrutiny here — `settings.json` belongs to every session
 on the machine, not to this app.
 */
func runHookInstallTests() {
    let command = "/Applications/OpenBoard.app/Contents/MacOS/openboard-hook"

    func settings(with hooks: [String: Any]) -> [String: Any] { ["hooks": hooks] }

    func group(_ cmd: String, matcher: String? = nil) -> [String: Any] {
        var entry: [String: Any] = ["hooks": [["type": "command", "command": cmd]]]
        if let matcher { entry["matcher"] = matcher }
        return entry
    }

    func healthyHooks(_ cmd: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in HookInstall.events {
            hooks[event.name] = [group("\(cmd) --event \(event.name)", matcher: event.matcher)]
        }
        return hooks
    }

    test("a fully wired settings file is healthy") {
        let audit = HookInstall.audit(
            settings: settings(with: healthyHooks(command)),
            expectedCommand: command,
            fileExists: { _ in true }
        )
        expect(audit.isHealthy)
        expect(audit.problems.isEmpty)
    }

    test("a missing event is named, not just counted") {
        var hooks = healthyHooks(command)
        hooks.removeValue(forKey: "Stop")
        let audit = HookInstall.audit(
            settings: settings(with: hooks), expectedCommand: command, fileExists: { _ in true }
        )
        expect(!audit.isHealthy)
        expectEqual(audit.problems, ["Stop"])
        expectEqual(audit.statuses["Stop"], .missing)
        expectEqual(audit.statuses["SessionStart"], .ok)
    }

    test("a hook pointing at a bundle that no longer exists is stale, not ok") {
        // The real failure: the app is moved or reinstalled, every hook still *looks*
        // configured, and none of them can run. Comparing command text alone reports a
        // clean bill of health here.
        let old = "/Users/someone/old/OpenBoard.app/Contents/MacOS/openboard-hook"
        let audit = HookInstall.audit(
            settings: settings(with: healthyHooks(old)),
            expectedCommand: command,
            fileExists: { _ in false }
        )
        expect(!audit.isHealthy)
        expectEqual(audit.statuses["Stop"], .stalePath(old))
        expectEqual(audit.problems.count, HookInstall.events.count)
    }

    test("a different but live binary is reported apart from a dead one") {
        // Two installs on one machine is a real situation, and it is not the same
        // problem as a dead path — telling someone to reinstall would be wrong.
        let other = "/Users/someone/build/OpenBoard.app/Contents/MacOS/openboard-hook"
        let audit = HookInstall.audit(
            settings: settings(with: healthyHooks(other)),
            expectedCommand: command,
            fileExists: { _ in true }
        )
        expectEqual(audit.statuses["Stop"], .otherPath(other))
    }

    test("a flag change does not read as a missing hook") {
        var hooks = healthyHooks(command)
        hooks["Stop"] = [group("\(command) --event Stop --verbose")]
        let audit = HookInstall.audit(
            settings: settings(with: hooks), expectedCommand: command, fileExists: { _ in true }
        )
        expectEqual(audit.statuses["Stop"], .ok)
    }

    test("a path containing spaces is not truncated") {
        // /Applications is fine, but a build in ~/My Projects is not, and the naive
        // split-on-space would blame the user's directory name for a broken install.
        let spaced = "/Users/someone/My Projects/OpenBoard.app/Contents/MacOS/openboard-hook"
        expectEqual(HookInstall.executablePath(from: "\(spaced) --event Stop"), spaced)
        expectEqual(HookInstall.executablePath(from: spaced), spaced)
    }

    test("no settings file at all is every event missing, not a crash") {
        let audit = HookInstall.audit(settings: nil, expectedCommand: command)
        expect(!audit.settingsExists)
        expectEqual(audit.problems.count, HookInstall.events.count)
    }

    test("Notification carries its matcher") {
        // Without it every subtype fires a hook, including ones that map to no state,
        // so the board does work for events it will then discard.
        let matcher = HookInstall.events.first { $0.name == "Notification" }?.matcher
        expectEqual(matcher, "permission_prompt|agent_needs_input|idle_prompt")

        let written = HookInstall.wiring(into: [:], command: command)
        let hooks = try Harness.require(written["hooks"] as? [String: Any])
        let groups = try Harness.require(hooks["Notification"] as? [[String: Any]])
        expectEqual(groups.first?["matcher"] as? String, matcher)
        expect(hooks["Stop"] != nil)
        expect((try Harness.require(hooks["Stop"] as? [[String: Any]])).first?["matcher"] == nil)
    }

    test("installing preserves every unrelated setting") {
        // This file is not ours. Someone's model, permissions and env must survive a
        // hook install untouched.
        let existing: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash(git diff:*)"]],
            "env": ["FOO": "bar"],
        ]
        let written = HookInstall.wiring(into: existing, command: command)
        expectEqual(written["model"] as? String, "opus")
        expectEqual((written["env"] as? [String: String])?["FOO"], "bar")
        expect(written["permissions"] != nil)
    }

    test("installing preserves another tool's hook on the same event") {
        // Sharing an event is normal. Replacing the array would silently break
        // somebody else's tooling, and they would have no idea why.
        let theirs = group("/usr/local/bin/somebody-else --on Stop")
        let written = HookInstall.wiring(
            into: ["hooks": ["Stop": [theirs]]], command: command
        )
        let groups = try Harness.require(
            (written["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        )
        expectEqual(groups.count, 2, "the other tool's hook was dropped")
        let commands = groups.flatMap { group -> [String] in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
        expect(commands.contains { $0.contains("somebody-else") })
        expect(commands.contains { $0.contains("openboard-hook") })
    }

    test("reinstalling does not stack duplicate hooks") {
        // Otherwise every launch of the pane adds another copy and each event fires
        // n times, which the registry would see as n sessions.
        var doc = HookInstall.wiring(into: [:], command: command)
        for _ in 0..<3 { doc = HookInstall.wiring(into: doc, command: command) }
        let groups = try Harness.require(
            (doc["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        )
        expectEqual(groups.count, 1)
    }

    test("hooks are async with a timeout, so they never hold up a session") {
        let written = HookInstall.wiring(into: [:], command: command)
        let groups = try Harness.require(
            (written["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        )
        let hook = try Harness.require((groups.first?["hooks"] as? [[String: Any]])?.first)
        expectEqual(hook["async"] as? Bool, true)
        expectEqual(hook["timeout"] as? Int, 5)
        expectEqual(hook["type"] as? String, "command")
    }

    test("an unparseable settings file is refused rather than overwritten") {
        // Truncated or hand-broken JSON is still someone's configuration. Replacing it
        // with a fresh document would destroy every setting they have.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = "{ \"model\": \"opus\", this is broken"
        try Data(original.utf8).write(to: url)

        expect((try? HookInstall.install(command: command, url: url)) == nil, "it wrote anyway")
        expectEqual(try? String(contentsOf: url, encoding: .utf8), original, "the file was altered")
    }

    test("a real install backs up first, then verifies clean") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data("{\"model\":\"opus\"}".utf8).write(to: url)

        try HookInstall.install(command: command, url: url)

        let backups = (try FileManager.default.contentsOfDirectory(atPath: dir.path))
            .filter { $0.hasPrefix("settings.backup-") }
        expectEqual(backups.count, 1, "no backup was taken")

        let audit = HookInstall.audit(
            settings: HookInstall.loadSettings(url: url),
            expectedCommand: command,
            fileExists: { _ in true }
        )
        expect(audit.isHealthy, "the file it just wrote does not pass its own audit")
        expectEqual(HookInstall.loadSettings(url: url)?["model"] as? String, "opus")
    }
}

/**
 Knowledge that would otherwise live only in the retired Node repo.
 */
func runHookOmissionTests() {
    test("PermissionDenied stays unwired, and the reason is written down") {
        // It is in Claude Code's hook schema and looks obviously relevant, but was
        // traced across many real rejections without firing once. Wiring it costs a
        // hook that never arrives and a maintainer the time to find that out again.
        expect(HookInstall.deliberatelyUnwired.contains("PermissionDenied"))
        expect(
            !HookInstall.events.contains { $0.name == "PermissionDenied" },
            "it got wired up after all — check whether it actually fires now"
        )
    }

    test("every wired event is one the board acts on") {
        // A hook that maps to no state is work done on every occurrence and then
        // discarded — and each one runs a process per session per event.
        for event in HookInstall.events where event.name != "Notification" {
            expect(
                EventMapper.state(for: event.name) != nil
                    || EventMapper.clearsAttention.contains(event.name),
                "\(event.name) is wired but means nothing to the board"
            )
        }
    }
}

