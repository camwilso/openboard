import CoreBluetooth
import Foundation
import OpenBoardKit

/**
 The pad's battery.

 ## Where it actually lives

 Not in the HID descriptors, not in the IO registry, not in `system_profiler`, not in
 the vendor RPC, and not in `IOBluetoothDevice`'s battery properties — all of which
 were checked, and all of which say nothing. The full 28MB registry dump contains no
 battery value anywhere near this device.

 It is published where every BLE device publishes it: the standard **GATT Battery
 Service**, `0x180F`, characteristic `0x2A19`. macOS reads it there for the Bluetooth
 menu, and `retrieveConnectedPeripherals(withServices:)` gives the same access — public
 API, no entitlement, no pairing, and no private framework.

 The lesson is the one this project keeps relearning: five confident negatives, and the
 answer was in the sixth place, which happened to be the standard one.

 ## Why it is polled slowly

 Reading means connect, discover, read — a few hundred milliseconds and some radio
 traffic on a device whose job is to respond to keypresses. Battery moves by single
 digits over hours, so a slow poll costs nothing and a fast one would be pure
 interference. It also refreshes when the popover opens, which is the only moment the
 number is actually being looked at.
 */
@MainActor
final class BatteryMonitor: NSObject, ObservableObject {
    /// Percent, or nil when it has not been read yet or the pad is away.
    @Published private(set) var percent: Int?
    @Published private(set) var lastRead: Date?

    /// The device we care about. Matched by name because the peripheral identifier is
    /// a per-host UUID, not the Bluetooth address, so it cannot be compared with what
    /// the HID layer knows.
    private let nameFragment = "codex"

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var refreshTimer: Timer?

    // Computed rather than stored: CBUUID is not Sendable, so a static constant is a
    // shared-mutable-state error the moment a nonisolated delegate touches it. These
    // are two allocations on a path that runs at most a few times an hour.
    nonisolated static var service: CBUUID { CBUUID(string: "180F") }
    nonisolated static var characteristic: CBUUID { CBUUID(string: "2A19") }

    /// Long enough that it is never in the way. Battery does not move faster than this.
    private let interval: TimeInterval = 15 * 60

    func start() {
        // Created lazily and kept: constructing a CBCentralManager is what triggers the
        // one-time Bluetooth permission prompt, so it should not happen at launch
        // before the user has any idea what the app is.
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
    }

    private func record(percent value: Int) {
        percent = value
        lastRead = Date()
        Log.write("battery: \(value)%")
        // Hand the connection back. Holding it open would keep the radio busier than a
        // status readout deserves.
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    }

    /// Read now. Called when the popover opens — the moment the number is looked at.
    func refresh() {
        guard let central, central.state == .poweredOn else { return }

        // Devices already connected to the *system*. This does not pair, does not
        // steal the connection, and does not disturb the HID stream the board runs on.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.service])
        let candidates = connected.filter {
            ($0.name ?? "").lowercased().contains(nameFragment)
        }
        /*
         More than one pad can match.

         Pairing a Codex Micro twice leaves both registrations behind — this machine
         carries "Codex Micro #1" and "Codex Micro #3" — and a household with two pads
         is the ordinary version of the same thing. `first` then reports an arbitrary
         one's battery as though it were yours, which is the specific kind of
         confidently-wrong number this app exists not to show.

         Prefer one that is actually connected. If that still leaves a choice there is
         no way to tell them apart from here — the peripheral identifier is a per-host
         UUID, not the Bluetooth address the HID layer knows — so it reads the first and
         says so in the log rather than pretending the question did not come up.
         */
        let pad = candidates.first { $0.state == .connected } ?? candidates.first
        if candidates.count > 1 {
            Log.write(
                "battery: \(candidates.count) pads match — reading "
                    + "\(pad?.name ?? "?"), which may not be the one on your desk"
            )
        }
        guard let pad else {
            // Away, asleep, or not exposing the service. Not an error, and the last
            // reading is deliberately kept rather than blanked — a stale percentage is
            // more useful than none, and `lastRead` says how stale.
            return
        }

        peripheral = pad
        pad.delegate = self
        central.connect(pad)
    }
}

extension BatteryMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard manager.state == .poweredOn else { return }
        Task { @MainActor in self.refresh() }
    }

    nonisolated func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics([Self.characteristic], for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for characteristic in service.characteristics ?? [] {
            peripheral.readValue(for: characteristic)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // A single unsigned byte, 0…100, per the GATT spec.
        guard let value = characteristic.value?.first else { return }
        // Only the byte crosses the actor boundary. Sending the peripheral itself is a
        // data race — it belongs to CoreBluetooth's queue — so the disconnect uses the
        // reference the actor already holds.
        Task { @MainActor in self.record(percent: Int(value)) }
    }
}
