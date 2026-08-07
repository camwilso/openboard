import Foundation

/**
 The Codex Micro's private `v.oai.*` HID RPC.

 Undocumented, reverse-engineered, and liable to break on any ChatGPT / Work Louder
 Input / firmware update. Ported from `lib/hid.cjs`, which was in turn vendored from
 pejmanjohn/codex-micro-light (MIT) — see THIRD-PARTY-NOTICES.md.

 Kept free of IOKit so the framing can be tested without a pad plugged in. The
 transport lives in `HIDDevice.swift`.

 ## Wire format

 A JSON request is chunked across 64-byte output reports:

 ```
 byte 0   report id      0x06
 byte 1   channel        0x02
 byte 2   chunk length   ≤ 61
 bytes 3+ payload
 ```

 Responses arrive the same way and are reassembled by accumulating chunks until the
 buffer parses as JSON. The device acknowledges each write and echoes the method
 back, which is how we know the channel is being read correctly.
 */
public enum CodexProtocol {
    public static let vendorID = 0x303A   // Espressif
    public static let productID = 0x8360
    public static let usagePage = 0xFF00  // vendor-defined
    public static let reportID: UInt8 = 0x06
    public static let rpcChannel: UInt8 = 0x02
    public static let reportSize = 64
    public static let maxChunkSize = 61

    /// Firmware effect codes. `snake` and `gradient` are spatial: they only mean
    /// anything on the multi-LED ring and render a single key dark, which is why the
    /// per-key picker does not offer them.
    public enum Effect: UInt8 {
        case off = 0
        case solid = 1
        case snake = 2
        case rainbow = 3
        case breath = 4
        case gradient = 5
        case shallowBreath = 6

        public var isSpatial: Bool { self == .snake || self == .gradient }
    }

    /// One Agent key's lighting, as `v.oai.thstatus` wants it. The short field names
    /// are the firmware's, not an abbreviation choice.
    public struct ThreadState: Encodable, Equatable, Sendable {
        /// Zero-based slot, 0…5. The firmware counts from zero; everything above
        /// this layer counts from one.
        public let id: Int
        public let c: UInt32   // color, packed RGB
        public let b: Double   // brightness 0…1
        public let e: UInt8    // effect code
        public let s: Double   // speed 0…1
        public let sk: Int     // sync keys
        public let sa: Int     // sync ambient

        /// - Parameter physicalSlot: 1-based, as calibration reports it.
        public init(
            physicalSlot: Int,
            color: RGB,
            brightness: Double,
            effect: Effect,
            speed: Double,
            syncKeys: Bool = false,
            syncAmbient: Bool = false
        ) throws {
            guard (1...6).contains(physicalSlot) else {
                throw CodexError.badSlot(physicalSlot)
            }
            self.id = physicalSlot - 1
            self.c = color.value
            self.b = min(max(brightness, 0), 1)
            self.e = effect.rawValue
            self.s = min(max(speed, 0), 1)
            self.sk = syncKeys ? 1 : 0
            self.sa = syncAmbient ? 1 : 0
        }

        /// Upstream's order: id, c, b, e, s, sk, sa.
        public var json: String {
            "{\"id\":\(id),\"c\":\(c),\"b\":\(CodexProtocol.number(b))," +
            "\"e\":\(e),\"s\":\(CodexProtocol.number(s)),\"sk\":\(sk),\"sa\":\(sa)}"
        }
    }

    /**
     One side of a complete lighting config — the key backlight or the ring.

     Five fields, not four. `m` is a mode flag the firmware expects and which upstream
     always sends as 0; omitting it produced a config the device acknowledged with
     `ok:1` and then appeared not to act on. An acknowledgement is not confirmation
     that a message was understood, only that it arrived.

     Field *order* is not matched, because it cannot be: Swift's JSONEncoder does not
     emit in declaration order and offers no way to ask it to. Key order is not
     significant to any JSON parser, and the device's own responses come back in a
     different order again — so this is a difference from upstream that is safe, unlike
     the missing field, which was not.
     */
    public struct LightingSide: Encodable, Equatable, Sendable {
        public let e: UInt8
        public let b: Double
        public let s: Double
        public let m: Int
        public let c: UInt32

        enum CodingKeys: String, CodingKey { case e, b, s, m, c }

        public init(color: RGB, brightness: Double, effect: Effect, speed: Double) {
            self.e = effect.rawValue
            self.b = min(max(brightness, 0), 1)
            self.s = min(max(speed, 0), 1)
            self.m = 0
            self.c = color.value
        }

        public static let off = LightingSide(
            color: RGB(0), brightness: 0, effect: .off, speed: 0
        )

        /// Upstream's order: e, b, s, m, c.
        public var json: String {
            "{\"e\":\(e),\"b\":\(CodexProtocol.number(b)),\"s\":\(CodexProtocol.number(s))," +
            "\"m\":\(m),\"c\":\(c)}"
        }
    }

    /**
     `v.oai.rgbcfg` takes a *complete* config — both sides, always.

     Sending `keys: off` is safe on Layer 1 and is exactly what upstream does:
     the Agent LEDs are driven by a separate RPC (`thstatus`) and survive it. That is
     what makes per-key status visible at all, because the layer otherwise floods the
     pad with a white backlight that buries it.

     On Layer 2 the same call kills everything, which is consistent with per-key
     status simply not rendering there.
     */
    public struct LightingConfig: Encodable, Equatable, Sendable {
        public let keys: LightingSide
        public let ambient: LightingSide

        public init(keys: LightingSide, ambient: LightingSide) {
            self.keys = keys
            self.ambient = ambient
        }

        /// Upstream's order: keys, then ambient.
        public var json: String { "{\"keys\":\(keys.json),\"ambient\":\(ambient.json)}" }
    }

    public enum Method: String {
        case threadStatus = "v.oai.thstatus"
        case rgbConfig = "v.oai.rgbcfg"
    }

    /// Chunk an encoded request into output reports.
    ///
    /// The report id is byte 0 of the buffer here, matching the Node version. IOKit's
    /// `IOHIDDeviceSetReport` takes the id separately, so the transport strips it —
    /// see `HIDDevice.write`.
    public static func frame(_ payload: Data) -> [Data] {
        var reports: [Data] = []
        var offset = 0
        repeat {
            let size = min(maxChunkSize, payload.count - offset)
            var report = Data(count: reportSize)
            report[0] = reportID
            report[1] = rpcChannel
            report[2] = UInt8(size)
            if size > 0 {
                report.replaceSubrange(3..<(3 + size), with: payload[offset..<(offset + size)])
            }
            reports.append(report)
            offset += size
        } while offset < payload.count
        return reports
    }

    /// Encode and frame an RPC call.
    ///
    /// `id` is echoed back in the response, which is how a reply is matched to its
    /// request on a channel carrying unsolicited key events at the same time.
    /**
     Build the request JSON by hand, in upstream's field order.

     Swift's JSONEncoder does not emit in declaration order and offers no way to ask
     it to. That was written off as harmless — key order is not significant to any
     JSON *parser* — right up until it was the only remaining difference between an
     implementation whose writes lit the pad and one whose identical-looking writes
     did not.

     This firmware is undocumented and reverse-engineered. There is no spec promising
     a conforming parser, the device acknowledges malformed input with `ok:1`, and the
     failure mode is silence. So the bytes are assembled to match the known-good
     implementation exactly rather than to be equivalent by the standard.
     */
    /// The same framing for a method this app does not otherwise know. Diagnostics
    /// only — see `HIDDevice.ask`.
    public static func requestJSON(methodName: String, params: String, id: Int) -> Data {
        Data("{\"method\":\"\(methodName)\",\"params\":\(params),\"id\":\(id)}".utf8)
    }

    public static func requestJSON(method: Method, params: String, id: Int) -> Data {
        Data("{\"method\":\"\(method.rawValue)\",\"params\":\(params),\"id\":\(id)}".utf8)
    }

    /// Format a number the way `JSON.stringify` does, since that is what produced the
    /// bytes known to work: integral values without a decimal point.
    public static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        // Trim the float noise Swift's default description can introduce.
        var text = String(format: "%.6g", value)
        if text.contains("."), !text.contains("e") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    public static func request<P: Encodable>(
        method: Method,
        params: P,
        id: Int
    ) throws -> [Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(RPCEnvelope(method: method.rawValue, params: params, id: id))
        return frame(data)
    }

    /**
     Normalise an input report to "report id included".

     Whether IOKit hands back the report id in the body is not something to assume.
     The documentation reads as though it is stripped and returned separately, so this
     code first prepended it — which shifted every byte by one and silently corrupted
     every message. On this device the id *is* present: a captured report began
     `06 02 2C 7B 22 6D` — id, channel, length 44, then `{"m"`.

     So both shapes are handled, keyed off the id/channel pair actually being there.
     */
    public static func normaliseReport(_ body: Data, reportID id: UInt8) -> Data {
        guard body.count >= 2 else { return body }
        let hasHeader = body[body.startIndex] == reportID
            && body[body.startIndex + 1] == rpcChannel
        if hasHeader { return body }
        var data = Data([id])
        data.append(body)
        return data
    }

    /// Strip the 3-byte header off an input report.
    public static func payload(ofReport report: Data) -> Data? {
        guard report.count >= 3 else { return nil }
        // Channel is byte 1 when the report id is present, byte 0 when IOKit has
        // already consumed it. The transport normalises to "id included".
        guard report[1] == rpcChannel else { return nil }
        let length = Int(report[2])
        guard length > 0, report.count >= 3 + length else { return nil }
        return report.subdata(in: 3..<(3 + length))
    }
}

/// The request wrapper. At file scope because a generic type cannot be nested inside
/// a generic function.
struct RPCEnvelope<T: Encodable>: Encodable {
    let method: String
    let params: T
    let id: Int
}

public enum CodexError: Error, LocalizedError {
    case badSlot(Int)
    case notConnected
    case timedOut(String)
    /// The device was found but macOS refused to open it — Input Monitoring.
    case accessDenied
    case noVendorInterface

    public var errorDescription: String? {
        switch self {
        case let .badSlot(slot): "slot \(slot) is outside 1…6"
        case .notConnected: "the Codex Micro is not connected"
        case let .timedOut(method): "timed out waiting for \(method)"
        case .accessDenied: "macOS denied access to the pad (Input Monitoring)"
        case .noVendorInterface: "no vendor HID interface found"
        }
    }
}

/**
 A key event broadcast by the device.

 The pad reports every press on the vendor channel as an unsolicited notification —
 which is why it can stay on Layer 1 with Codex's locked keycodes and still mean
 something to us:

 ```
 {"m":"v.oai.hid","p":{"k":"AG00","act":1}}   down
 {"m":"v.oai.hid","p":{"k":"AG00","act":0}}   up
 {"m":"v.oai.hid","p":{"k":"ENC_CW","act":2}} one encoder tick
 ```
 */
public struct KeyEvent: Equatable, Sendable {
    public enum Action: Int, Sendable {
        case up = 0
        case down = 1
        /// A discrete rotation tick. Has no matching release and must never be
        /// debounced — a fast turn emits many in quick succession and dropping them
        /// makes the encoder feel broken.
        case tick = 2
    }

    public let key: String
    public let action: Action

    private struct Envelope: Decodable {
        struct Payload: Decodable {
            let k: String
            let act: Int
        }
        let m: String
        let p: Payload
    }

    /// Parse one line of the RPC stream, or nil if it is not a key event.
    ///
    /// Our own writes are acknowledged on this same channel and carry `result`
    /// rather than `m`, so anything without `m: "v.oai.hid"` is skipped.
    public static func parse(_ data: Data) -> KeyEvent? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.m == "v.oai.hid",
              let action = Action(rawValue: envelope.p.act)
        else { return nil }
        return KeyEvent(key: envelope.p.k, action: action)
    }

    public init(key: String, action: Action) {
        self.key = key
        self.action = action
    }
}
