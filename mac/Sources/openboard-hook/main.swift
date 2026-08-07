import Foundation

/*
 The hook helper. Reads a Claude Code hook payload on stdin, forwards it to the app's
 socket, exits.

 This is the entire contract with `hooks/install.cjs`: the installed command becomes
 `<path>/openboard-hook --event SessionStart`, so only the target path changes.

 Three rules, all of which the Node version learned the hard way:

 1. **Always exit 0.** A hook runs inline with the session. A non-zero exit or a
    stderr splat is something the user sees, and a status light must never be able to
    interrupt someone's work. Every failure here is silent by design.

 2. **Never block.** The socket write has a short timeout and nothing waits for a
    reply. If the app is not running, the pad is asleep, or another writer holds the
    device, this still returns immediately. The Node version ran the whole registry
    update and a device repaint inside the hook, which is why a wedged RPC could stall
    a prompt.

 3. **Forward the environment.** Eligibility is decided from CLAUDE_CODE_ENTRYPOINT
    and the subagent/SDK markers, and hooks inherit the session's environment while
    the app does not. Sent explicitly, or every session looks identical to the rules.
 */

// Exiting 0 no matter what, from the very top.
func finish() -> Never { exit(0) }

let arguments = CommandLine.arguments
let eventName = arguments.firstIndex(of: "--event")
    .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }

// Read stdin with a bound: a hook payload is small, and a hung writer must not hang
// the session.
var payload = Data()
while let line = readLine(strippingNewline: false) {
    payload.append(contentsOf: Array(line.utf8))
    if payload.count > 1_000_000 { break }
}

var object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
if let eventName, object["hook_event_name"] == nil {
    object["hook_event_name"] = eventName
}

// Only the variables the eligibility rules actually read. Forwarding the whole
// environment would put tokens and keys into a socket for no reason.
let wanted = [
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_AGENT_ID",
    "CLAUDE_AGENT_TYPE",
    "CLAUDE_AGENT_SDK_CLIENT_APP",
    "CLAUDE_PID",
    "OPENBOARD_ENTRYPOINTS",
]
let environment = ProcessInfo.processInfo.environment
object["env"] = wanted.reduce(into: [String: String]()) { result, key in
    if let value = environment[key] { result[key] = value }
}
object["entrypoint"] = environment["CLAUDE_CODE_ENTRYPOINT"]

/*
 Which agent this hook belongs to.

 Taken from the command line rather than guessed from the payload, because the command
 is the one thing we write: Claude Code's settings.json, Hermes' config.yaml and Pi's
 extension each invoke this binary and each can name themselves. Absent means Claude
 Code, so every settings.json already out there keeps working untouched.

 It matters because eligibility is fail-closed on `CLAUDE_CODE_ENTRYPOINT`, which the
 others do not set and never will — without this, every Hermes event would be refused
 as an unknown surface.
*/
if let index = CommandLine.arguments.firstIndex(of: "--harness"),
   CommandLine.arguments.count > index + 1 {
    object["harness"] = CommandLine.arguments[index + 1]
}

guard let body = try? JSONSerialization.data(withJSONObject: object) else { finish() }

/*
 Where the app is listening.

 This duplicates `AppPaths` rather than importing OpenBoardKit, and that is deliberate:
 this binary runs on *every* hook of every session, and linking a module that pulls in
 IOKit and CoreBluetooth would put dyld work on the critical path of a prompt.

 The cost of duplication is drift, so it is handled two ways. Both candidates are tried
 in order, newest first — a socket that no one is listening on refuses the connection
 immediately, so a wrong first guess costs microseconds. And a test asserts these
 literals still match what `AppPaths` computes, because the failure mode otherwise is
 the worst kind: hooks silently landing nowhere and a board that just stops updating.
*/
let candidates: [String] = {
    if let override = environment["OPENBOARD_HOME"], !override.isEmpty {
        return [URL(fileURLWithPath: override).appendingPathComponent("hook.sock").path]
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
        home.appendingPathComponent("Library/Application Support/OpenBoard/hook.sock").path,
        // An app that has not migrated yet, or an older build still running.
        home.appendingPathComponent(".claude/openboard/hook.sock").path,
    ]
}()

for socketPath in candidates {
    let handle = socket(AF_UNIX, SOCK_STREAM, 0)
    guard handle >= 0 else { finish() }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        close(handle)
        continue
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

    // A send timeout, so a stuck app cannot hold a session's prompt open.
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, size) }
    }
    // Nothing listening here. Try the next candidate; an app that is simply not
    // running is a normal state, not an error worth reporting into a session.
    guard connected == 0 else {
        close(handle)
        continue
    }

    _ = body.withUnsafeBytes { buffer in
        write(handle, buffer.baseAddress, buffer.count)
    }
    // Half-close so the server sees EOF and stops reading without a length prefix.
    shutdown(handle, SHUT_WR)
    close(handle)
    break
}
finish()
