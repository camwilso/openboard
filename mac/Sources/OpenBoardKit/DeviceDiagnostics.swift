import Foundation

/**
 Why the pad is not there.

 "No Codex Micro found" is true in several very different situations, and the remedy
 differs completely: press a key, turn Bluetooth on, pair it, or grant a permission.
 A single message that covers all of them tells the user nothing they can act on.

 This matters more for this device than most. It attaches over Bluetooth LE, where
 **disconnecting is normal rather than exceptional** — the pad idles out, and to macOS
 it simply stops existing as a HID device. Reporting that as "not found" reads as
 broken hardware when the answer is to touch a key.
 */
public enum DeviceDiagnostics {
    public enum Presence: Equatable, Sendable {
        /// Visible as a HID device — the only state in which anything can be written.
        case connected
        /// Paired, and not currently connected. Press a key on the pad.
        case pairedButAsleep
        /// Bluetooth itself is off.
        case bluetoothOff
        /// Never paired on this Mac.
        case notPaired
        /// The pairing state could not be read. Distinct from `notPaired`, which is a
        /// claim; this is an admission.
        case unknown
    }

    /// The pad's Bluetooth name, as it appears in the paired-device list.
    public static let deviceNames = ["Codex Micro", "CodexMicro"]

    /**
     Ask the system about pairing, when the device is not on the HID bus.

     Only called when something is already wrong, because `system_profiler` takes on
     the order of a second — far too slow for the 2s presence poll, and pointless while
     the pad is working.
     */
    public static func presence(
        report: @autoclosure () -> String? = systemProfilerReport()
    ) -> Presence {
        guard let text = report() else { return .unknown }
        return interpret(text)
    }

    /**
     Read the pairing state out of a `system_profiler SPBluetoothDataType` dump.

     Split out and given the text directly so the parsing is testable — the output
     format has changed across macOS releases, and a silent parse failure here would
     downgrade every diagnostic to "unknown" without anyone noticing.
     */
    public static func interpret(_ report: String) -> Presence {
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Bluetooth off is unambiguous and outranks everything else: nothing can be
        // connected, so reporting "not paired" would send someone to the wrong place.
        if let state = value(of: "State", in: lines), state.lowercased().contains("off") {
            return .bluetoothOff
        }

        // Connectedness is a *section header*, not a property of the device — devices
        // are listed under `Connected:` or `Not Connected:` and carry no key of their
        // own. Checked against this Mac's real output, where the pad appears under
        // `Connected:` with only Address / Vendor ID / Product ID / Minor Type /
        // Services beneath it. Looking for a per-device `Connected` key finds nothing
        // and reports a working pad as asleep.
        var section: Presence?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Connected:" { section = .connected; continue }
            if trimmed == "Not Connected:" { section = .pairedButAsleep; continue }

            // The name carries a suffix when more than one has been paired —
            // "Codex Micro #3" on this machine.
            if deviceNames.contains(where: { trimmed.hasPrefix($0) }), trimmed.hasSuffix(":") {
                // Listed with no section header above it still means paired.
                return section ?? .pairedButAsleep
            }
        }
        return .notPaired
    }

    private static func value(of key: String, in lines: [String]) -> String? {
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0] == key { return parts[1] }
        }
        return nil
    }

    public static func systemProfilerReport() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
