import Foundation
import OpenBoardKit

/*
 A diagnostic, and the only way to exercise the IOKit layer against real hardware
 without launching the menu bar app.

 Equivalent to `openboard devices` in the Node version, and it exists for the same
 reason: when the pad does not light there are four completely different causes —
 not plugged in, wrong interface, no permission, no calibration — and they are
 indistinguishable from the outside.

 Run from a terminal that already holds Input Monitoring:
   swift run openboard-probe            survey and open
   swift run openboard-probe --paint    also light slot 1 orange for 2s
*/

let startedAt = Date().timeIntervalSince1970

/// The same six colors the calibration step uses — maximally distinguishable on an
/// RGB LED, so "did it work" needs no squinting.
let legendColors: [RGB] = [
    RGB(0xFF0000), RGB(0x00FF00), RGB(0x0000FF),
    RGB(0xFFFF00), RGB(0x00FFFF), RGB(0xFF00FF),
]
let legendNames: [(String, RGB)] = [
    ("RED", legendColors[0]), ("GREEN", legendColors[1]), ("BLUE", legendColors[2]),
    ("YELLOW", legendColors[3]), ("CYAN", legendColors[4]), ("MAGENTA", legendColors[5]),
]

/*
 Ask the device a question it may not know how to answer.

 Only ever used with **read-shaped** method names. The vendor channel is undocumented
 and this is somebody's firmware: a guessed name that turns out to mutate something
 cannot be undone, so nothing resembling set/write/reset/erase/flash/update is sent
 here, and nothing is sent with parameters that could be interpreted as new state.

 Exists because "the pad does not report X" has been wrong before — the joystick was
 declared inert for months while broadcasting on a method nobody had looked at.
 */
if let index = CommandLine.arguments.firstIndex(of: "--ask"),
   CommandLine.arguments.count > index + 1 {
    let method = CommandLine.arguments[index + 1]
    let forbidden = ["set", "write", "reset", "erase", "flash", "update", "fw", "boot", "cfg"]
    guard !forbidden.contains(where: { method.lowercased().contains($0) }) else {
        print("refused: \(method) is not read-shaped")
        exit(1)
    }
    let device = HIDDevice()
    do { try device.open() } catch {
        print("could not open the pad: \(error)")
        exit(1)
    }
    /*
     The run loop has to keep spinning while we wait.

     Input reports arrive through `IOHIDDeviceScheduleWithRunLoop`, so blocking the
     main thread on a semaphore guarantees the callback never fires — every method
     comes back "no reply", including ones the device certainly knows. Which is
     exactly what happened, and would have made this probe answer "the pad reports
     nothing" no matter what the pad actually does.
     */
    device.askAsync(method: method)
    let deadline = Date().addingTimeInterval(2.5)
    while Date() < deadline, device.lastReply == nil {
        CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }
    let reply = device.lastReply
    print("\(method) -> \(reply ?? "no reply")")
    device.close()
    exit(0)
}

/*
 Dump the HID device's live properties.

 `ioreg` does not necessarily show everything: a property can be served on demand by
 the driver rather than published in the registry tree, so "not in ioreg" is not the
 same as "not available". macOS itself shows this pad's battery in the Bluetooth menu,
 which is proof the number exists somewhere.
 */
if CommandLine.arguments.contains("--props") {
    let candidates = [
        "BatteryPercent", "BatteryLevel", "AppleHIDBatteryPercent",
        kIOHIDProductKey, kIOHIDTransportKey, kIOHIDVendorIDKey, kIOHIDProductIDKey,
        kIOHIDSerialNumberKey, kIOHIDVersionNumberKey,
        "DeviceAddress", "BD_ADDR", "PrimaryUsagePage", "PrimaryUsage",
    ]
    let matching = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(matching, nil)
    IOHIDManagerOpen(matching, IOOptionBits(kIOHIDOptionsTypeNone))
    let found = (IOHIDManagerCopyDevices(matching) as? Set<IOHIDDevice>) ?? []
    for hid in found {
        let name = IOHIDDeviceGetProperty(hid, kIOHIDProductKey as CFString) as? String ?? "?"
        guard name.lowercased().contains("codex") else { continue }
        print("device: \(name)")
        for key in candidates {
            if let value = IOHIDDeviceGetProperty(hid, key as CFString) {
                print("  \(key) = \(value)")
            }
        }
    }
    exit(0)
}

/*
 Dump every raw line the pad emits.

 Lives here rather than in the app: it is how an unmapped control is identified, which
 is a thing you do once per control and never again. It found the joystick, which had
 been declared inert for months because the only captures ever taken were filtered to
 the keypress method.

 Prints *before* parsing, so a control reporting under a method this codebase does not
 know is visible rather than discarded.
 */
if CommandLine.arguments.contains("--listen") {
    let seconds = CommandLine.arguments.firstIndex(of: "--listen")
        .flatMap { CommandLine.arguments.count > $0 + 1 ? Int(CommandLine.arguments[$0 + 1]) : nil }
        ?? 30
    let device = HIDDevice()
    do { try device.open() } catch {
        print("could not open the pad: \(error)")
        exit(1)
    }
    print("listening for \(seconds)s — work the control you want to identify")
    device.onLine { line in
        let text = String(data: line, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<binary>"
        // Replies to our own writes are noise here.
        guard !text.isEmpty, !text.contains("\"result\"") else { return }
        print(text)
    }
    // The run loop must keep spinning: input reports arrive through
    // IOHIDDeviceScheduleWithRunLoop, so blocking here would print nothing at all and
    // look exactly like a silent device.
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.1, true) }
    device.close()
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    // Print the exact bytes, for diffing against the Node implementation. This
    // protocol is undocumented, so "identical to the thing known to work" is the only
    // real correctness check available.
    // Same call the app makes for a `working` key, so the bytes are comparable.
    let state = try! CodexProtocol.ThreadState(
        physicalSlot: 1, color: RGB(0x0C47E9), brightness: 0.75, effect: .breath, speed: 0.45
    )
    // Join every chunk: a message longer than 61 bytes spans several reports, and
    // printing only the first shows a truncated string that looks like a bug.
    func joined(_ reports: [Data]) -> String {
        var out = Data()
        for report in reports { out.append(CodexProtocol.payload(ofReport: report) ?? Data()) }
        return String(data: out, encoding: .utf8) ?? "<not utf8>"
    }
    let th = CodexProtocol.frame(CodexProtocol.requestJSON(
        method: .threadStatus, params: "[" + state.json + "]", id: 123))
    print("SWIFT thstatus:", joined(th))
    print("  len :", joined(th).utf8.count)
    print("  hex :", th[0].prefix(24).map { String(format: "%02x", $0) }.joined(separator: " "))
    print("SWIFT rgbcfg:  ", joined(CodexProtocol.frame(CodexProtocol.requestJSON(
        method: .rgbConfig,
        params: CodexProtocol.LightingConfig(keys: .off, ambient: .off).json, id: 124))))
    exit(0)
}

if CommandLine.arguments.contains("--hook-listen") {
    // Stand up the hook socket alone, to exercise the real helper binary against it.
    let server = HookServer()
    let seen = DispatchSemaphore(value: 0)
    Task {
        try? await server.start { event in
            print("RECEIVED event=\(event.name) session=\(event.sessionID ?? "-") " +
                  "entrypoint=\(event.environment["CLAUDE_CODE_ENTRYPOINT"] ?? "-") " +
                  "tool=\(event.toolName ?? "-")")
            seen.signal()
        }
        print("listening")
    }
    while seen.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if Date().timeIntervalSince1970 > startedAt + 8 { print("timeout"); exit(1) }
    }
    exit(0)
}

if CommandLine.arguments.contains("--discover") {
    // What `reconnect` would seed the board with.
    for found in Discovery.runningSessions() {
        print("pid \(found.pid)  \(found.tty)  \(found.cwd ?? "-")")
    }
    exit(0)
}

let survey = HIDDevice.survey()
print("matching interfaces   \(survey.matched)")
print("vendor 0xFF00         \(survey.vendorInterfaces) (need exactly 1)")

guard survey.found else {
    print("\nBLOCKED: no vendor interface. Is the pad connected and on Layer 1?")
    exit(1)
}

let calibration = Calibration.loadDefault()
print("calibration           \(calibration.isAssumed ? "assumed (slot N = key N)" : "recorded")")

let device = HIDDevice()
device.onLine { line in
    if let event = KeyEvent.parse(line) {
        print("  key  \(event.key) \(event.action)")
    } else if let text = String(data: line, encoding: .utf8) {
        print("  rpc  \(text.prefix(120))")
    }
}

do {
    try device.open()
    print("open                  yes")
} catch {
    print("open                  NO — \(error.localizedDescription)")
    exit(1)
}

if CommandLine.arguments.contains("--paint") {
    guard let physical = calibration.physicalSlot(for: 1) else {
        print("\ncalibration has no entry for slot 1")
        exit(1)
    }

    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            // Silence the layer's own backlight first, or it floods the pad and
            // buries per-key status. rgbcfg needs a complete config, both sides.
            try await device.send(lighting: CodexProtocol.LightingConfig(keys: .off, ambient: .off))
            // Six distinct colors, so "did it work" needs no squinting. The same
            // legend the calibration step uses.
            let legend = legendNames
            for (slot, entry) in legend.enumerated() {
                guard let physical = calibration.physicalSlot(for: slot + 1) else { continue }
                let state = try CodexProtocol.ThreadState(
                    physicalSlot: physical,
                    color: entry.1,
                    brightness: 1,
                    effect: .solid,
                    speed: 0
                )
                try await device.send(threads: [state])
                print("  slot \(slot + 1) -> physical \(physical) -> \(entry.0)")
            }
            _ = physical
            print("\nall six painted — the pad should read RED GREEN BLUE / YELLOW CYAN MAGENTA")
        } catch {
            print("\npaint failed: \(error.localizedDescription)")
        }
        done.signal()
    }
    // The IOKit callbacks need the run loop, so pump it rather than blocking on it.
    while done.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    /*
     Hold the colors against everything else that writes to this pad.

     A single write is not observable here: the Claude Code hooks each shell out to
     `openboard state`, which repaints the whole board, so an active session overwrites
     anything the probe just did within milliseconds. Re-asserting in a loop is the
     only way to actually *see* the result while a session is running — the same
     reason the Node version holds during calibration.
     */
    let holdSeconds = CommandLine.arguments
        .firstIndex(of: "--hold")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Double(CommandLine.arguments[$0 + 1]) : nil }
        ?? 2.5

    if holdSeconds > 3 {
        print("holding for \(Int(holdSeconds))s against other writers — watch the pad")
    }
    let until = Date().addingTimeInterval(holdSeconds)
    var lastAssert = Date.distantPast
    while Date() < until {
        if Date().timeIntervalSince(lastAssert) > 0.35 {
            lastAssert = Date()
            let done2 = DispatchSemaphore(value: 0)
            Task {
                try? await device.send(lighting: CodexProtocol.LightingConfig(keys: .off, ambient: .off))
                for (slot, entry) in legendColors.enumerated() {
                    guard let physical = calibration.physicalSlot(for: slot + 1) else { continue }
                    if let state = try? CodexProtocol.ThreadState(
                        physicalSlot: physical, color: entry,
                        brightness: 1, effect: .solid, speed: 0
                    ) {
                        try? await device.send(threads: [state])
                    }
                }
                done2.signal()
            }
            while done2.wait(timeout: .now() + 0.02) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
} else {
    print("\nlistening for key presses for 8s — press something on the pad")
    let until = Date().addingTimeInterval(8)
    while Date() < until {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
}

print("\nraw input reports seen: \(device.reportsSeen)")
if let last = device.lastRawReport {
    print("last report bytes: \(last.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " "))")
}
device.close()
print("done")
