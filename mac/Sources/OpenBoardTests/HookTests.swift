import Foundation
import OpenBoardKit

/**
 The hook path, end to end over a real socket.

 Not mocked: the whole point of this layer is the transport, and a fake one would test
 nothing that can actually break. Each test binds a socket in a temp directory, so
 they neither touch the live one nor collide with a running app.
 */
func runHookTests() {
    /// Connect and write, exactly as `openboard-hook` does.
    func send(_ object: [String: Any], to path: String) -> Bool {
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, size) }
        }
        guard connected == 0, let body = try? JSONSerialization.data(withJSONObject: object) else {
            return false
        }
        _ = body.withUnsafeBytes { write(handle, $0.baseAddress, $0.count) }
        shutdown(handle, SHUT_WR)
        return true
    }

    func withServer(_ body: (HookServer, String, @escaping () -> [HookServer.Event]) throws -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-hook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("hook.sock")
        let server = HookServer(url: url)
        let box = EventBox()

        let started = DispatchSemaphore(value: 0)
        Task {
            try? await server.start { event in await box.append(event) }
            started.signal()
        }
        _ = started.wait(timeout: .now() + 3)

        try? body(server, url.path, { box.snapshot() })

        Task { await server.stop() }
        // Let the stop land before the directory goes away.
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Waits for the server's async handler to run.
    func settle(_ read: () -> [HookServer.Event], expecting count: Int) -> [HookServer.Event] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let events = read()
            if events.count >= count { return events }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return read()
    }

    test("a hook payload arrives over the socket") {
        withServer { _, path, read in
            expect(send([
                "hook_event_name": "SessionStart",
                "session_id": "abc-123",
                "cwd": "/Users/someone/Developer/Projects",
                "env": ["CLAUDE_CODE_ENTRYPOINT": "cli"],
            ], to: path), "socket write should succeed")

            let events = settle(read, expecting: 1)
            expectEqual(events.count, 1)
            expectEqual(events.first?.name, "SessionStart")
            expectEqual(events.first?.sessionID, "abc-123")
            expectEqual(events.first?.environment["CLAUDE_CODE_ENTRYPOINT"], "cli")
        }
    }

    test("the eligibility rules apply to what arrives") {
        // The transport is only worth having if the rules still hold on the far side.
        withServer { _, path, read in
            _ = send([
                "hook_event_name": "SessionStart",
                "session_id": "human",
                "env": ["CLAUDE_CODE_ENTRYPOINT": "cli"],
            ], to: path)
            _ = send([
                "hook_event_name": "SessionStart",
                "session_id": "subagent",
                "agent_type": "Explore",
                "env": ["CLAUDE_CODE_ENTRYPOINT": "cli"],
            ], to: path)

            let events = settle(read, expecting: 2)
            expectEqual(events.count, 2)
            for event in events {
                let verdict = Eligibility.evaluate(
                    env: event.environment,
                    payload: event.eligibilityPayload
                )
                if event.sessionID == "human" {
                    expect(verdict.eligible, "a real CLI session must get a key")
                } else {
                    expect(!verdict.eligible, "a subagent must not")
                    expectEqual(verdict.reason, .subagent)
                }
            }
        }
    }

    test("a notification's subtype survives the trip") {
        // permission_prompt means "act now"; idle_prompt means "sitting idle" and is
        // unmapped by default. Losing the distinction makes the pad cry wolf.
        withServer { _, path, read in
            _ = send([
                "hook_event_name": "Notification",
                "session_id": "a",
                "matcher": "permission_prompt",
                "tool_name": "Bash",
                "env": ["CLAUDE_CODE_ENTRYPOINT": "cli"],
            ], to: path)

            let events = settle(read, expecting: 1)
            expectEqual(events.first?.matcher, "permission_prompt")
            expectEqual(events.first?.toolName, "Bash")
        }
    }

    test("malformed payloads are dropped, not crashed on") {
        withServer { _, path, read in
            let handle = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, size) }
            }
            let junk = Array("this is not json".utf8)
            _ = junk.withUnsafeBufferPointer { write(handle, $0.baseAddress, $0.count) }
            shutdown(handle, SHUT_WR)
            close(handle)

            Thread.sleep(forTimeInterval: 0.3)
            expectEqual(read().count, 0, "garbage must be ignored")

            // And the server must still be alive afterwards.
            expect(send([
                "hook_event_name": "Stop",
                "session_id": "still-here",
                "env": ["CLAUDE_CODE_ENTRYPOINT": "cli"],
            ], to: path))
            expectEqual(settle(read, expecting: 1).count, 1, "server survived the garbage")
        }
    }

    test("every event the Node version handles is carried") {
        // Each of these is individually mutable in settings, so all eight have to make
        // it across or a toggle silently does nothing.
        let events = [
            "SessionStart", "UserPromptSubmit", "Notification", "Stop",
            "SessionEnd", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
        ]
        withServer { _, path, read in
            for name in events {
                _ = send([
                    "hook_event_name": name,
                    "session_id": "s",
                    "env": ["CLAUDE_CODE_ENTRYPOINT": "cli"],
                ], to: path)
            }
            let received = settle(read, expecting: events.count)
            expectEqual(Set(received.map(\.name)), Set(events))
        }
    }

    test("backgroundSubagentIDs filters background_tasks to type == subagent") {
        // By design, the Stop-time reconcile is subagent-only scope — a
        // shell/monitor/workflow/teammate/cloud-session/MCP-task background entry
        // must not count toward delegatedCount.
        let event = HookServer.Event(raw: [
            "hook_event_name": "Stop",
            "session_id": "s",
            "background_tasks": [
                ["id": "agent-1", "type": "subagent"],
                ["id": "shell-1", "type": "shell"],
                ["id": "agent-2", "type": "subagent"],
                ["id": "monitor-1", "type": "monitor"],
            ],
        ])
        expectEqual(Set(event.backgroundSubagentIDs), Set(["agent-1", "agent-2"]))
    }

    test("backgroundSubagentIDs is empty when background_tasks is absent or empty") {
        let missing = HookServer.Event(raw: ["hook_event_name": "Stop", "session_id": "s"])
        expect(missing.backgroundSubagentIDs.isEmpty)

        let empty = HookServer.Event(raw: [
            "hook_event_name": "Stop", "session_id": "s", "background_tasks": [],
        ])
        expect(empty.backgroundSubagentIDs.isEmpty)
    }

    test("writing to a socket nobody is listening on fails quietly") {
        // The app not running is a normal state. The helper must return without a
        // sound: a hook runs inline with the session and cannot be allowed to
        // complain, hang, or exit non-zero.
        let dead = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-absent-\(UUID().uuidString).sock").path
        expect(!send(["hook_event_name": "Stop"], to: dead), "connect should fail")
    }

    test("the socket is not world-readable") {
        // It can drive shell-visible actions downstream, so it is 0600.
        withServer { _, path, _ in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            expectEqual(permissions & 0o077, 0, "no group or other access")
        }
    }
}

/// Collects handler callbacks from the server's actor context.
final class EventBox: @unchecked Sendable {
    private var events: [HookServer.Event] = []
    private let lock = NSLock()

    func append(_ event: HookServer.Event) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [HookServer.Event] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
