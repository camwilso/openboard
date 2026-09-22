import Foundation

/**
 The surface the app drives a pad through, at the framed-report level.

 Deliberately `[Data]` rather than a semantic `paint(keys:ring:)`: everything above
 this line — the hand-built JSON field order, the 64-byte chunking, the one-lock-per-
 repaint batching — is exactly where this project's worst bugs lived, and a substitute
 transport that bypassed it would test a different program. A `VirtualPad` conforming
 here consumes the same bytes the hardware does.

 `HIDDevice.survey()` is not part of the contract: it is static, answers "is a pad on
 the bus" without opening anything, and `BoardController` takes it as a separate
 injected closure for the same reason.
 */
public protocol PadTransport: AnyObject, Sendable {
    func open() throws
    func close()
    func onLine(_ handler: @escaping HIDDevice.LineHandler)
    func prepare(threads: [CodexProtocol.ThreadState]) -> [Data]
    func prepare(lighting: CodexProtocol.LightingConfig) -> [Data]
    func write(batch: [[Data]]) async throws
    func send(threads: [CodexProtocol.ThreadState]) async throws
    func send(lighting: CodexProtocol.LightingConfig) async throws
}

extension HIDDevice: PadTransport {}
