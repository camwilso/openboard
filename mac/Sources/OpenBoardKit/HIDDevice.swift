import Foundation
import IOKit
import IOKit.hid

/**
 The pad, over IOKit.

 Replaces the Node version's dependency on a `node-hid` prebuild scavenged out of
 ChatGPT.app or Work Louder Input — which worked, but meant the tool silently stopped
 functioning if either app was moved or updated. `IOHIDManager` is the system API and
 has no such dependency.

 ## Finding the vendor collection

 Only the vendor-defined collection (usage page `0xFF00`) speaks the `v.oai.*` RPC.
 Finding it is not what it looks like:

 The pad presents as a **single** `IOHIDDevice` carrying four top-level collections —
 `0x01:6` (keyboard), `0x0C:1`, `0x0C:2` (consumer) and `0xFF00:1` (vendor). Its
 *primary* usage page is `0x01`, so filtering on `kIOHIDPrimaryUsagePageKey` — the
 obvious property, and the one this first used — finds nothing at all.

 The vendor collection has to be located in `kIOHIDDeviceUsagePairsKey` instead, and
 reports are then routed to it by report id (`0x06`) on the one device handle.

 This is also why the counts differ from the Node version's diagnostics: node-hid
 enumerates per-collection and reports four matches with one vendor interface, while
 IOKit reports one device with four collections. Same hardware, different model.

 ## Opening non-exclusively

 `kIOHIDOptionsTypeNone`, deliberately: the ChatGPT app holds this interface open and
 repaints the LEDs on its own schedule. Seizing it would break that app; coexisting
 and re-asserting is the arrangement that works, and is why `HIDWriteLock` exists.

 ## Permissions

 Opening the interface requires **Input Monitoring**, granted per host application,
 and only after that app is restarted. A denial surfaces as `kIOReturnNotPermitted`
 (0xE00002E2), which is mapped to `.accessDenied` so the UI can say what to do rather
 than showing a hex code.
 */
public final class HIDDevice: @unchecked Sendable {
    /// Reassembled RPC lines from the device.
    public typealias LineHandler = @Sendable (Data) -> Void

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let queue = DispatchQueue(label: "com.openboard.hid", qos: .userInitiated)
    private var inputBuffer = Data()
    private var lineHandler: LineHandler?
    /**
     The input report buffer, heap-allocated and owned for the device's lifetime.

     IOKit keeps this pointer and writes into it on every report, so it must outlive
     the registration call. A Swift array's `withUnsafeMutableBufferPointer` yields a
     pointer valid only inside its closure — passing that to
     `IOHIDDeviceRegisterInputReportCallback` hands IOKit a dangling pointer the
     moment the closure returns. It does not crash; reports simply stop arriving,
     which showed up as writes succeeding while the device's acknowledgements never
     came back.
     */
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(
        capacity: CodexProtocol.reportSize
    )

    /// Calls waiting for their acknowledgement, keyed by request id. Touched from the
    /// IOKit callback thread as well as the caller's, hence the lock.
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private let pendingLock = NSLock()

    public init() {}

    /// How long to wait for a reply before giving up on one message. Upstream waits
    /// far longer; a status light is best-effort and must not stall a repaint.
    public static let acknowledgementTimeoutMs = 600

    // MARK: - discovery

    /// What the device layer can tell the UI, without opening anything.
    public struct Survey: Sendable, Equatable {
        public let matched: Int
        public let vendorInterfaces: Int
        /// How the pad is attached, as IOKit reports it: `USB`, `Bluetooth`,
        /// `Bluetooth Low Energy`. Nil when nothing matched.
        ///
        /// Worth knowing because the two transports fail and report differently. On the
        /// cable the pad drops its Bluetooth link entirely — `system_profiler` lists it
        /// under *Not Connected* and CoreBluetooth stops returning it — so a battery
        /// readout and a Bluetooth diagnosis both go stale while the board itself is
        /// working perfectly over USB.
        public let transport: String?
        /**
         Which pad this is.

         `kIOHIDSerialNumberKey` — a twelve-character hex string, unique per unit.
         Unique per device and stable across reconnects, which nothing else here is:
         the product name is "Codex Micro" for everyone, and the CoreBluetooth
         identifier is a per-host UUID that changes if you pair it elsewhere.

         It is what a custom name is filed under, so a household with two pads can tell
         them apart and a rename survives a reboot.
         */
        public let serial: String?
        /// What the device calls itself. Carries the pairing suffix macOS adds —
        /// "Codex Micro #1" — so it is a label, not an identity.
        public let product: String?

        public init(
            matched: Int,
            vendorInterfaces: Int,
            transport: String? = nil,
            serial: String? = nil,
            product: String? = nil
        ) {
            self.matched = matched
            self.vendorInterfaces = vendorInterfaces
            self.transport = transport
            self.serial = serial
            self.product = product
        }

        public var found: Bool { vendorInterfaces == 1 }
        /// On the cable. Charging, and off Bluetooth for as long as it is.
        public var isWired: Bool { transport?.uppercased().contains("USB") == true }
    }

    /// Count matching interfaces. Cheap, and needs no permission — so it can
    /// distinguish "not plugged in" from "plugged in but not allowed", which are
    /// completely different messages to show a user.
    public static func survey() -> Survey {
        guard let manager = makeManager() else { return Survey(matched: 0, vendorInterfaces: 0) }
        IOHIDManagerSetDeviceMatching(manager, matchingDictionary() as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        defer {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return Survey(matched: 0, vendorInterfaces: 0)
        }
        let vendor = devices.filter(hasVendorCollection)
        func string(_ key: String) -> String? {
            vendor.first.flatMap { IOHIDDeviceGetProperty($0, key as CFString) as? String }
        }
        return Survey(
            matched: devices.count,
            vendorInterfaces: vendor.count,
            transport: string(kIOHIDTransportKey),
            serial: string(kIOHIDSerialNumberKey),
            product: string(kIOHIDProductKey)
        )
    }

    private static func makeManager() -> IOHIDManager? {
        IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private static func matchingDictionary() -> [String: Any] {
        [
            kIOHIDVendorIDKey: CodexProtocol.vendorID,
            kIOHIDProductIDKey: CodexProtocol.productID,
        ]
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    /// Does this device expose the vendor collection anywhere in its usage pairs?
    ///
    /// Not `kIOHIDPrimaryUsagePageKey`: the pad's primary collection is a keyboard,
    /// and the vendor collection is the fourth of four. Checking only the primary
    /// finds nothing.
    private static func hasVendorCollection(_ device: IOHIDDevice) -> Bool {
        guard let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
            as? [[String: Any]] else {
            return intProperty(device, kIOHIDPrimaryUsagePageKey) == CodexProtocol.usagePage
        }
        return pairs.contains { pair in
            (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue == CodexProtocol.usagePage
        }
    }

    /// How the pad is attached. Bluetooth LE disappears and reappears on its own,
    /// which the reconnect handling has to expect.
    public static func transport(of device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
    }

    // MARK: - lifecycle

    /// Open the vendor interface. Throws rather than degrading, because every caller
    /// needs to know *why* — the remedies for "not plugged in", "not permitted" and
    /// "wrong interface" share nothing.
    public func open() throws {
        guard device == nil else { return }

        guard let manager = Self.makeManager() else { throw CodexError.noVendorInterface }
        IOHIDManagerSetDeviceMatching(manager, Self.matchingDictionary() as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue
        )

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              !devices.isEmpty
        else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw CodexError.noVendorInterface
        }

        // Only the vendor-defined interface speaks the RPC. Writing to any of the
        // others succeeds and does nothing.
        guard let target = devices.first(where: Self.hasVendorCollection) else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw CodexError.noVendorInterface
        }

        // Non-exclusive: the ChatGPT app holds this open too.
        let result = IOHIDDeviceOpen(target, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            // 0xE00002E2 — the Input Monitoring denial, and by far the most common
            // failure. Anything else is genuinely unexpected.
            throw result == kIOReturnNotPermitted ? CodexError.accessDenied : CodexError.noVendorInterface
        }

        self.manager = manager
        self.device = target

        IOHIDDeviceScheduleWithRunLoop(
            target, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue
        )
        startReading(target)
    }

    public func close() {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(
                device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        manager = nil
        inputBuffer.removeAll()
    }

    public var isOpen: Bool { device != nil }

    /// Raw input reports seen since open, regardless of whether they parsed.
    /// Distinguishes "nothing is arriving" from "arriving and being rejected", which
    /// are completely different bugs.
    public private(set) var reportsSeen = 0
    public private(set) var lastRawReport: Data?

    // MARK: - reading

    /// Receive reassembled RPC lines: our own acknowledgements and, more usefully,
    /// the unsolicited key events the pad broadcasts.
    public func onLine(_ handler: @escaping LineHandler) {
        lineHandler = handler
    }

    private func startReading(_ device: IOHIDDevice) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        reportBuffer.initialize(repeating: 0, count: CodexProtocol.reportSize)
        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            CodexProtocol.reportSize,
            { context, _, _, _, reportID, report, length in
                guard let context, length > 0 else { return }
                let device = Unmanaged<HIDDevice>.fromOpaque(context).takeUnretainedValue()
                let body = Data(UnsafeBufferPointer(start: report, count: length))
                device.ingest(
                    CodexProtocol.normaliseReport(body, reportID: UInt8(truncatingIfNeeded: reportID))
                )
            },
            context
        )
    }

    deinit {
        reportBuffer.deallocate()
    }

    /**
     Reassemble chunked JSON.

     Messages arrive split across reports and are newline-delimited once joined. The
     buffer is bounded: a partial message that never completes — a chunk lost to a
     disconnect mid-write — would otherwise grow forever.
     */
    private func ingest(_ report: Data) {
        reportsSeen += 1
        lastRawReport = report
        guard let chunk = CodexProtocol.payload(ofReport: report) else { return }
        inputBuffer.append(chunk)

        if inputBuffer.count > 64 * 1024 {
            inputBuffer.removeAll()
            return
        }

        while let newline = inputBuffer.firstIndex(of: 0x0A) {
            let line = inputBuffer.subdata(in: inputBuffer.startIndex..<newline)
            inputBuffer.removeSubrange(inputBuffer.startIndex...newline)
            let trimmed = line.filter { $0 != 0x0D }
            guard !trimmed.isEmpty else { continue }
            resolvePending(Data(trimmed))
            lineHandler?(Data(trimmed))
        }

        // Some firmware builds send a complete object with no trailing newline. If
        // what we have parses on its own, take it and reset.
        if !inputBuffer.isEmpty,
           (try? JSONSerialization.jsonObject(with: inputBuffer)) != nil {
            let line = inputBuffer
            inputBuffer.removeAll()
            resolvePending(line)
            lineHandler?(line)
        }
    }

    /// A reply carries `result` and echoes the request's `id`. Key events carry `m`
    /// instead, and must not be mistaken for one.
    private func resolvePending(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["result"] != nil,
              let id = object["id"] as? Int
        else { return }

        pendingLock.lock()
        let continuation = pending.removeValue(forKey: id)
        pendingLock.unlock()
        continuation?.resume()
    }

    // MARK: - writing

    /// Frame a thread-status call. Uses the hand-built JSON so field order matches
    /// upstream exactly — see CodexProtocol.requestJSON for why that matters.
    public func prepare(threads: [CodexProtocol.ThreadState]) -> [Data] {
        let params = "[" + threads.map(\.json).joined(separator: ",") + "]"
        return CodexProtocol.frame(
            CodexProtocol.requestJSON(
                method: .threadStatus, params: params, id: Int.random(in: 0..<1000)
            )
        )
    }

    /// Frame a lighting-config call.
    public func prepare(lighting: CodexProtocol.LightingConfig) -> [Data] {
        CodexProtocol.frame(
            CodexProtocol.requestJSON(
                method: .rgbConfig, params: lighting.json, id: Int.random(in: 0..<1000)
            )
        )
    }

    /// Fire-and-forget: the device acknowledges, but a status light must never make
    /// anything wait on the acknowledgement.
    public func send(threads: [CodexProtocol.ThreadState]) async throws {
        try await write(batch: [prepare(threads: threads)])
    }

    public func send(lighting: CodexProtocol.LightingConfig) async throws {
        try await write(batch: [prepare(lighting: lighting)])
    }

    /**
     Write several prepared calls under one lock acquisition.

     A board repaint is one rgbcfg plus six thstatus calls. Taking the cross-process
     lock seven separate times per repaint meant seven chances to collide with another
     writer — and, while a bug in the lock itself made that fatal, it is wasteful
     regardless. A repaint is one logical operation and should hold the lock once.
     */
    public func write(batch: [[Data]]) async throws {
        guard let device else { throw CodexError.notConnected }
        // Short timeout, then give up. Upstream waits 20s; a wedged RPC must not stall
        // a repaint that is only ever cosmetic.
        try await HIDWriteLock.shared.withLock(timeout: 3) {
            for reports in batch {
                try await sendAndAwaitAck(reports, to: device)
            }
        }
    }

    /**
     Write one message and wait for the device to acknowledge it.

     Not fire-and-forget, which is what this did first and why nothing lit.
     `IOHIDDeviceSetReport` returns as soon as the report is queued, not when the
     firmware has acted on it — so a full repaint went out as fourteen reports with no
     gap, the device acknowledged every one with `ok:1`, and the pad did not change.

     Upstream waits for each reply before sending the next, which is what paces a
     repaint to roughly 200ms. Guessing a delay instead is not the same thing: the
     acknowledgement is the only signal that the device has actually consumed the
     message. Recovered from rather than thrown on, because a missed reply should cost
     one light, not the whole repaint.
     */
    /**
     Send a bare method and return whatever raw line comes back.

     A diagnostic, not part of the app's normal traffic: the vendor channel is
     undocumented, so the only way to learn whether a capability exists is to ask and
     read the answer verbatim rather than through a decoder that assumes a shape.

     Returns nil if nothing arrives within the window — which for an unknown method is
     itself the answer.
     */
    /// The last raw reply captured by `askAsync`, for a caller that is spinning a run
    /// loop rather than awaiting.
    public private(set) var lastReply: String?

    /**
     Send a bare method and capture whatever raw line comes back.

     A diagnostic, not part of the app's normal traffic: the vendor channel is
     undocumented, so the only way to learn whether a capability exists is to ask and
     read the answer verbatim rather than through a decoder that assumes a shape.

     **The caller must keep a run loop spinning.** Input reports arrive through
     `IOHIDDeviceScheduleWithRunLoop`, so a caller that blocks its thread waiting will
     never receive one — and will conclude the device is silent when it is not.
     */
    public func askAsync(method: String) {
        guard let device = self.device else { return }
        lastReply = nil
        lineHandler = { [weak self] data in
            guard let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip the notifications that share this stream.
            guard !trimmed.contains("v.oai.hid"), !trimmed.contains("v.oai.rad") else { return }
            if self?.lastReply == nil { self?.lastReply = trimmed }
        }

        let payload = CodexProtocol.requestJSON(methodName: method, params: "{}", id: 4242)
        for report in CodexProtocol.frame(payload) {
            try? Self.write(report, to: device)
        }
    }

    private func sendAndAwaitAck(_ reports: [Data], to device: IOHIDDevice) async throws {
        // The id is in the framed payload; read it back rather than threading it
        // through every call site.
        let id = Self.requestID(in: reports)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let id {
                pendingLock.lock()
                pending[id] = continuation
                pendingLock.unlock()
            }

            do {
                for report in reports {
                    try Self.write(report, to: device)
                }
            } catch {
                if let id {
                    pendingLock.lock()
                    let stored = pending.removeValue(forKey: id)
                    pendingLock.unlock()
                    stored?.resume(throwing: error)
                } else {
                    continuation.resume(throwing: error)
                }
                return
            }

            guard let id else {
                continuation.resume()
                return
            }

            // Give up rather than wedge a repaint on a reply that never comes.
            // Scheduled on a queue rather than in a Task: NSLock cannot be taken from
            // an async context, and this only needs a timer.
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .milliseconds(Self.acknowledgementTimeoutMs)
            ) { [weak self] in
                guard let self else { return }
                self.pendingLock.lock()
                let stranded = self.pending.removeValue(forKey: id)
                self.pendingLock.unlock()
                stranded?.resume()
            }
        }
    }

    /// Pull the `id` back out of a framed request.
    private static func requestID(in reports: [Data]) -> Int? {
        var payload = Data()
        for report in reports { payload.append(CodexProtocol.payload(ofReport: report) ?? Data()) }
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return nil
        }
        return object["id"] as? Int
    }

    private static func write(_ report: Data, to device: IOHIDDevice) throws {
        /*
         Send the *whole* report, id byte included.

         The obvious reading of `IOHIDDeviceSetReport` is that the id goes in the
         argument and the body goes in the buffer without it. That is what this did,
         and every write succeeded while the pad never changed.

         hidapi — which node-hid uses, and which drives this device correctly — only
         strips the leading byte when the report id is `0x00`. For a numbered report
         like this one (`0x06`) it passes the full buffer *including* the id and sets
         the id argument as well. The firmware evidently expects those 64 bytes.

         It is also symmetric with the read path, where reports arrive with the id
         still in the body — something already discovered here the hard way.
         */
        let reportID = CFIndex(report[0])
        let result = report.withUnsafeBytes { buffer -> IOReturn in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                reportID,
                buffer.bindMemory(to: UInt8.self).baseAddress!,
                report.count
            )
        }
        guard result == kIOReturnSuccess else {
            throw result == kIOReturnNotPermitted ? CodexError.accessDenied : CodexError.notConnected
        }
    }
}
