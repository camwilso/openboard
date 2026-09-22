import Foundation

/**
 Decode the bytes a repaint writes, back into what the firmware would show.

 The decoder is the other half of `CodexProtocol.frame` + `requestJSON`, and exists
 for the same reason `--dump` does in the probe: the wire format is the contract, and
 nothing else in the suite could check what `paint()` actually puts on it. It parses
 with `JSONSerialization` rather than mirroring the hand-built field order — the
 firmware's parser is forgiving, the point of the hand-built order is byte-for-byte
 fidelity on the *write* side, and a decoder that only accepted one field order would
 test the encoder's spelling rather than its meaning.
 */
public enum PadFrames {
    /// One half of an rgbcfg — the key backlight or the ambient ring — raw, as sent.
    public struct Side: Equatable, Sendable {
        public let effect: UInt8
        public let brightness: Double
        public let speed: Double
        public let mode: Int
        public let color: UInt32

        public init(effect: UInt8, brightness: Double, speed: Double, mode: Int, color: UInt32) {
            self.effect = effect
            self.brightness = brightness
            self.speed = speed
            self.mode = mode
            self.color = color
        }
    }

    /// One slot's status light, raw, as sent. `slot` is *physical* — calibration has
    /// already been applied by the sender, which is exactly what makes rendering it
    /// worthwhile: a wrong mapping shows up as the wrong key lighting, here as on the
    /// desk.
    public struct Thread: Equatable, Sendable {
        public let slot: Int
        public let color: UInt32
        public let brightness: Double
        public let effect: UInt8
        public let speed: Double

        public init(slot: Int, color: UInt32, brightness: Double, effect: UInt8, speed: Double) {
            self.slot = slot
            self.color = color
            self.brightness = brightness
            self.effect = effect
            self.speed = speed
        }
    }

    public enum Message: Equatable, Sendable {
        case lighting(keys: Side, ambient: Side, id: Int?)
        case threads([Thread], id: Int?)
    }

    /// Reassemble one framed message and decode it. Nil for anything that is not a
    /// well-formed rgbcfg or thstatus call — the two methods a pad is painted with.
    public static func decode(_ reports: [Data]) -> Message? {
        var payload = Data()
        for report in reports {
            guard let chunk = CodexProtocol.payload(ofReport: report) else { return nil }
            payload.append(chunk)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let method = object["method"] as? String
        else { return nil }
        let id = object["id"] as? Int

        switch method {
        case CodexProtocol.Method.rgbConfig.rawValue:
            guard let params = object["params"] as? [String: Any],
                  let keys = side(params["keys"]),
                  let ambient = side(params["ambient"])
            else { return nil }
            return .lighting(keys: keys, ambient: ambient, id: id)

        case CodexProtocol.Method.threadStatus.rawValue:
            guard let params = object["params"] as? [[String: Any]] else { return nil }
            let threads = params.compactMap(thread)
            guard threads.count == params.count else { return nil }
            return .threads(threads, id: id)

        default:
            return nil
        }
    }

    private static func side(_ value: Any?) -> Side? {
        guard let dict = value as? [String: Any],
              let e = dict["e"] as? Int,
              let b = number(dict["b"]),
              let s = number(dict["s"]),
              let m = dict["m"] as? Int,
              let c = dict["c"] as? Int,
              let effect = UInt8(exactly: e),
              let color = UInt32(exactly: c)
        else { return nil }
        return Side(effect: effect, brightness: b, speed: s, mode: m, color: color)
    }

    private static func thread(_ dict: [String: Any]) -> Thread? {
        guard let id = dict["id"] as? Int,
              let c = dict["c"] as? Int,
              let b = number(dict["b"]),
              let e = dict["e"] as? Int,
              let s = number(dict["s"]),
              let color = UInt32(exactly: c),
              let effect = UInt8(exactly: e)
        else { return nil }
        // The wire counts slots from zero; everything above the firmware counts from
        // one — see `ThreadState.init(physicalSlot:)`, which subtracts what this adds.
        return Thread(slot: id + 1, color: color, brightness: b, effect: effect, speed: s)
    }

    /// JSONSerialization hands back NSNumber; an integral value bridges to Int, not
    /// Double, so asking for Double alone drops every whole number.
    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

/**
 A pad with no hardware behind it.

 Speaks the vendor channel the way the firmware does — consumes the same framed
 reports, acknowledges each message by echoing its `id`, and emits key events as the
 same JSON lines — so everything above `PadTransport` runs unmodified against it:
 painting, calibration capture, key dispatch, setup. What the firmware would show is
 published through `onFace`, for a window to render.

 Two ways this is *not* the hardware, both deliberate:

 - **It never disappears.** The real pad idles off Bluetooth as a matter of course
   and the app's resident loop exists to cope; the virtual pad is for exercising
   everything else, and a simulated outage would be a feature pretending to be a bug.
 - **Acks are instant** unless `ackLatencyMs` is set. A ring write on hardware
   measures ~86ms, and fun mode's scheduling is built around that — set a latency
   before trusting anything time-shaped.
 */
public final class VirtualPad: PadTransport, @unchecked Sendable {
    /// Everything a renderer needs, decoded from the exact bytes written.
    public struct Face: Equatable, Sendable {
        public var keys = PadFrames.Side(effect: 0, brightness: 0, speed: 0, mode: 0, color: 0)
        public var ambient = PadFrames.Side(effect: 0, brightness: 0, speed: 0, mode: 0, color: 0)
        /// By physical slot. A slot never written stays unlit, like the hardware's.
        public var threads: [Int: PadFrames.Thread] = [:]
        public init() {}
    }

    private let lock = NSLock()
    private var handler: HIDDevice.LineHandler?
    private var opened = false
    private var face = Face()
    private var faceHandler: (@Sendable (Face) -> Void)?

    /// Per-message delay before the ack, mimicking the measured hardware round trip.
    public var ackLatencyMs: Int

    public init(ackLatencyMs: Int = 0) {
        self.ackLatencyMs = ackLatencyMs
    }

    /// The pad a survey would find, were this one on the bus.
    public static func survey() -> HIDDevice.Survey {
        HIDDevice.Survey(
            matched: 1,
            vendorInterfaces: 1,
            transport: "Virtual",
            serial: "VIRTUALPAD00",
            product: "Virtual Pad"
        )
    }

    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return opened
    }

    /// Where decoded writes land. Called after every message, off no particular
    /// thread — hop to the main actor before touching UI.
    public func onFace(_ handler: @escaping @Sendable (Face) -> Void) {
        lock.lock()
        faceHandler = handler
        let snapshot = face
        lock.unlock()
        handler(snapshot)
    }

    // MARK: - PadTransport

    public func open() throws {
        lock.lock(); defer { lock.unlock() }
        opened = true
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        opened = false
    }

    public func onLine(_ handler: @escaping HIDDevice.LineHandler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    public func prepare(threads: [CodexProtocol.ThreadState]) -> [Data] {
        let params = "[" + threads.map(\.json).joined(separator: ",") + "]"
        return CodexProtocol.frame(
            CodexProtocol.requestJSON(
                method: .threadStatus, params: params, id: Int.random(in: 0..<1000)
            )
        )
    }

    public func prepare(lighting: CodexProtocol.LightingConfig) -> [Data] {
        CodexProtocol.frame(
            CodexProtocol.requestJSON(
                method: .rgbConfig, params: lighting.json, id: Int.random(in: 0..<1000)
            )
        )
    }

    public func write(batch: [[Data]]) async throws {
        guard isOpen else { throw CodexError.notConnected }
        for reports in batch {
            // A message that does not decode is *dropped without an ack* — the write
            // path then eats its 600ms timeout per message, which is the hardware's
            // failure mode for garbage too (`ok:1` to malformed input is the other,
            // but silence is the one worth reproducing: it is the one that hurts).
            guard let message = PadFrames.decode(reports) else { continue }

            let ackID = apply(message)
            if ackLatencyMs > 0 {
                try? await Task.sleep(for: .milliseconds(ackLatencyMs))
            }
            if let id = ackID {
                emit("{\"result\":{\"ok\":1},\"id\":\(id)}")
            }
        }
    }

    /// Update the face under the lock, publish outside it, return the id to ack.
    /// Synchronous on purpose: `NSLock` refuses to be taken from async code.
    private func apply(_ message: PadFrames.Message) -> Int? {
        let ackID: Int?
        lock.lock()
        switch message {
        case let .lighting(keys, ambient, id):
            face.keys = keys
            face.ambient = ambient
            ackID = id
        case let .threads(threads, id):
            for thread in threads { face.threads[thread.slot] = thread }
            ackID = id
        }
        let publish = faceHandler
        let snapshot = face
        lock.unlock()

        publish?(snapshot)
        return ackID
    }

    public func send(threads: [CodexProtocol.ThreadState]) async throws {
        try await write(batch: [prepare(threads: threads)])
    }

    public func send(lighting: CodexProtocol.LightingConfig) async throws {
        try await write(batch: [prepare(lighting: lighting)])
    }

    // MARK: - input

    /// A key going down, by switch name — `AG00`, `ACT06`, `ENC_CLK`. The line is the
    /// firmware's exact shape, so it exercises the real parse → canonical → dispatch
    /// path, double-fire collapse included.
    public func press(_ key: String) {
        emit("{\"m\":\"v.oai.hid\",\"p\":{\"k\":\"\(key)\",\"act\":1}}")
    }

    public func release(_ key: String) {
        emit("{\"m\":\"v.oai.hid\",\"p\":{\"k\":\"\(key)\",\"act\":0}}")
    }

    /// One dial detent. The hardware reports a tick, not a position.
    public func turnEncoder(clockwise: Bool) {
        emit("{\"m\":\"v.oai.hid\",\"p\":{\"k\":\"\(clockwise ? "ENC_CW" : "ENC_CC")\",\"act\":2}}")
    }

    private func emit(_ line: String) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(Data(line.utf8))
    }
}
