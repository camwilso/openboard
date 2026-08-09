import Foundation
import OpenBoardKit

/**
 Why the pad is not there.

 "Not found" is true in several very different situations with completely different
 remedies — press a key, turn Bluetooth on, pair it, grant a permission. One message
 covering all of them tells the user nothing they can act on.

 The fixture below is this Mac's **actual** `system_profiler` output. The first version
 of the parser looked for a per-device `Connected` key, which does not exist in that
 format: connectedness is a section header. It would have reported a working pad as
 asleep, and no unit test written from the docs would have caught it.
 */
func runDiagnosticsTests() {
    /// Real output, trimmed to the relevant shape.
    let realReport = """
    Bluetooth:

          Bluetooth Controller:
              Address: A0:B1:C2:D3:E4:F5
              State: On
              Chipset: BCM_4388
              Discoverable: Off

          Connected:

              Codex Micro #3:
                  Address: 0A:1B:2C:3D:4E:5F
                  Vendor ID: 0x303A
                  Product ID: 0x8360
                  Minor Type: Keyboard
                  Services: 0x400000 < BLE >

              Wireless Mouse:
                  Address: F1:E2:D3:C4:B5:A6
                  Minor Type: Mouse

          Not Connected:

              Magic Keyboard:
                  Address: 11:22:33:44:55:66
    """

    test("a connected pad reads as connected") {
        // The case the first parser got wrong: there is no `Connected: Yes` key under
        // the device, only the section it is listed in.
        expectEqual(DeviceDiagnostics.interpret(realReport), .connected)
    }

    test("a paired pad in the Not Connected section reads as asleep") {
        // The common case. Over BLE, disconnecting is normal rather than exceptional:
        // the pad idles out and simply stops existing as a HID device. Reporting that
        // as "not found" reads as broken hardware when the fix is to touch a key.
        // Rebuilt line by line rather than by string replacement: a multiline literal
        // strips the closing delimiter's indentation, so matching on leading spaces
        // silently replaces nothing and the test passes against unchanged input.
        let asleep = realReport
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) == "Connected:"
                ? String($0).replacingOccurrences(of: "Connected:", with: "Not Connected:")
                : String($0) }
            .joined(separator: "\n")
        expect(asleep.contains("Not Connected:"), "the fixture was not actually modified")
        expectEqual(DeviceDiagnostics.interpret(asleep), .pairedButAsleep)
    }

    test("the name suffix does not break the match") {
        // Pairing more than once yields "Codex Micro #3" — matching on equality finds
        // nothing and every diagnostic silently becomes "not paired".
        expect(realReport.contains("Codex Micro #3"))
        expectEqual(DeviceDiagnostics.interpret(realReport), .connected)

        let plain = realReport.replacingOccurrences(of: "Codex Micro #3", with: "Codex Micro")
        expectEqual(DeviceDiagnostics.interpret(plain), .connected)
    }

    test("bluetooth being off outranks everything") {
        // Nothing can be connected, so "not paired" would send someone to the wrong
        // place entirely.
        let off = realReport.replacingOccurrences(of: "State: On", with: "State: Off")
        expectEqual(DeviceDiagnostics.interpret(off), .bluetoothOff)
    }

    test("a pad that was never paired says so") {
        let without = realReport
            .replacingOccurrences(of: "Codex Micro #3", with: "Somebody Else's Keyboard")
        expectEqual(DeviceDiagnostics.interpret(without), .notPaired)
    }

    test("an empty or unrecognisable report is not a claim") {
        // `unknown` exists so a format change downgrades to an admission rather than
        // to a confident lie. Empty text carries no State and no device.
        expectEqual(DeviceDiagnostics.interpret(""), .notPaired)
        expectEqual(DeviceDiagnostics.presence(report: nil), .unknown)
    }

    test("this machine's live Bluetooth report still parses") {
        // Guards against the format changing under a macOS update: a silent parse
        // failure would quietly turn every diagnostic into "not paired".
        guard let live = DeviceDiagnostics.systemProfilerReport(), !live.isEmpty else {
            skip("system_profiler produced nothing")
            return
        }
        // Skipped on the *text*, never on the verdict. Interpreting a report that has
        // no pad in it and interpreting one whose format changed both come back
        // .notPaired, so skipping on the verdict would silence exactly the regression
        // this exists to catch. Asking whether the device is named anywhere in the
        // report is a question the parser is not involved in answering.
        guard DeviceDiagnostics.deviceNames.contains(where: { live.contains($0) }) else {
            skip("no Codex Micro in this machine's Bluetooth report — nothing to parse")
            return
        }
        let presence = DeviceDiagnostics.interpret(live)
        expect(
            presence == .connected || presence == .pairedButAsleep,
            "the pad is paired on this machine but read as \(presence)"
        )
    }
}

// LoginItem is deliberately not unit-tested. It lives in the app target, which the
// test executable does not link — and `SMAppService.mainApp` refers to whichever
// bundle is *running*, so in a test binary it would describe the test binary. A test
// asserting `isInstalledProperly` here would only restate its own implementation.
// It is checked by using it: the Device pane reads the status live rather than
// remembering it, so a stale registration shows up the moment the pane is opened.

/**
 The pad on a cable.

 Plugging it in is not a small change: the pad drops its Bluetooth link entirely, so
 `system_profiler` moves it to *Not Connected*, CoreBluetooth stops returning it, and
 the battery percentage — which only exists over GATT — freezes at whatever it last
 read. Meanwhile the board works perfectly over USB.

 Every one of those is a case where the honest answer differs from the last known one.
 */
func runTransportTests() {
    test("a wired pad is recognised as wired") {
        // IOKit's spelling, verbatim: this is compared against, not parsed.
        expect(HIDDevice.Survey(matched: 1, vendorInterfaces: 1, transport: "USB").isWired)
        expect(!HIDDevice.Survey(matched: 1, vendorInterfaces: 1, transport: "Bluetooth").isWired)
        expect(
            !HIDDevice.Survey(
                matched: 1, vendorInterfaces: 1, transport: "Bluetooth Low Energy"
            ).isWired
        )
    }

    test("an unknown transport is not claimed to be wired") {
        // Nil is "we did not ask" or "nothing matched" — neither is a plugged-in pad,
        // and guessing yes would put a charging bolt on a pad that is on battery.
        expect(!HIDDevice.Survey(matched: 0, vendorInterfaces: 0).isWired)
        expect(!HIDDevice.Survey(matched: 1, vendorInterfaces: 1, transport: "SPI").isWired)
    }

    test("this machine's pad reports a transport it can act on") {
        // Guards the property key: `kIOHIDTransportKey` returning nothing would make
        // every pad look wireless and silently disable the charging state.
        let survey = HIDDevice.survey()
        guard survey.found else {
            skip("no pad attached")
            return
        }
        expect(
            survey.transport != nil,
            "the pad is attached but reports no transport — the IOKit key changed"
        )
    }
}
