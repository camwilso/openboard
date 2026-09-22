import Foundation
import OpenBoardKit

/**
 The pad with no hardware behind it: that the bytes a repaint writes decode back to
 what was meant, that every message is acknowledged the way the firmware does it, and
 that a virtual key press is indistinguishable from a real one to the parser.

 The decoder is also the first test the *encoder* has ever had beyond byte-diffing:
 until now nothing in the suite could say what a prepared batch meant.
 */
func runVirtualPadTests() async {
    let pad = VirtualPad()

    test("a prepared thread status decodes back to what was meant") {
        let state = try CodexProtocol.ThreadState(
            physicalSlot: 3, color: RGB(0xFF8800), brightness: 0.75,
            effect: .breath, speed: 0.45
        )
        let message = PadFrames.decode(pad.prepare(threads: [state]))
        guard case let .threads(threads, id) = message else {
            return expect(false, "decoded \(String(describing: message))")
        }
        expect(id != nil)
        expectEqual(threads.count, 1)
        // 1-based again on the way out: the decoder undoes the wire's zero-based id.
        expectEqual(threads.first?.slot, 3)
        expectEqual(threads.first?.color, 0xFF8800)
        expectEqual(threads.first?.effect, CodexProtocol.Effect.breath.rawValue)
        expectEqual(threads.first?.brightness, 0.75)
    }

    test("a prepared lighting config decodes both sides") {
        let lighting = CodexProtocol.LightingConfig(
            keys: .off,
            ambient: .init(color: RGB(0x008080), brightness: 0.9, effect: .rainbow, speed: 0.2)
        )
        let message = PadFrames.decode(pad.prepare(lighting: lighting))
        guard case let .lighting(keys, ambient, _) = message else {
            return expect(false, "decoded \(String(describing: message))")
        }
        expectEqual(keys.effect, CodexProtocol.Effect.off.rawValue)
        expectEqual(ambient.color, 0x008080)
        expectEqual(ambient.effect, CodexProtocol.Effect.rainbow.rawValue)
        // The mode flag upstream always sends; its absence once cost every light.
        expectEqual(ambient.mode, 0)
    }

    test("a message longer than one report reassembles before decoding") {
        // Six slots is a payload well past 61 bytes, so this is the chunked path.
        let states = try (1...6).map { slot in
            try CodexProtocol.ThreadState(
                physicalSlot: slot, color: RGB(0x112233), brightness: 1,
                effect: .solid, speed: 0
            )
        }
        let reports = pad.prepare(threads: states)
        expect(reports.count > 1)
        guard case let .threads(threads, _)? = PadFrames.decode(reports) else {
            return expect(false, "chunked message did not decode")
        }
        expectEqual(threads.map(\.slot), [1, 2, 3, 4, 5, 6])
    }

    test("garbage does not decode") {
        expect(PadFrames.decode([Data([0x06, 0x02, 0x03, 0x7B, 0x22, 0x6D])]) == nil)
        expect(PadFrames.decode([]) == nil)
        expect(PadFrames.decode([Data()]) == nil)
    }

    // The async half, in the lock tests' pattern: the write path is async because the
    // real one is, and the acks it emits are the signal the transport waits on.

    let closed = VirtualPad()
    var closedThrew = false
    do { try await closed.write(batch: [[]]) } catch { closedThrew = true }
    test("writing to a closed pad throws, like the hardware") {
        expect(closedThrew)
    }

    // Locked boxes, not captured vars: the handlers are `@Sendable`, and the
    // compiler is right that a bare var across them is a race.
    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var faces: [VirtualPad.Face] = []
        func add(line: String) { lock.lock(); lines.append(line); lock.unlock() }
        func add(face: VirtualPad.Face) { lock.lock(); faces.append(face); lock.unlock() }
        var allLines: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        var lastFace: VirtualPad.Face? { lock.lock(); defer { lock.unlock() }; return faces.last }
    }
    let collected = Collected()
    pad.onLine { data in collected.add(line: String(decoding: data, as: UTF8.self)) }
    pad.onFace { face in collected.add(face: face) }
    try? pad.open()

    let state = try? CodexProtocol.ThreadState(
        physicalSlot: 2, color: RGB(0x00FF00), brightness: 0.5, effect: .solid, speed: 0
    )
    try? await pad.write(batch: [
        pad.prepare(lighting: .init(keys: .off, ambient: .off)),
        pad.prepare(threads: [state].compactMap { $0 }),
    ])

    test("every written message is acknowledged with its own id") {
        let lines = collected.allLines
        expectEqual(lines.count, 2)
        for line in lines {
            expect(line.hasPrefix("{\"result\":{\"ok\":1},\"id\":"), "unexpected ack: \(line)")
        }
    }

    test("the face shows the write, keyed by 1-based physical slot") {
        guard let face = collected.lastFace else {
            return expect(false, "no face published")
        }
        expectEqual(face.threads[2]?.color, 0x00FF00)
        expect(face.threads[1] == nil)
    }

    test("a virtual key press parses as a real one") {
        let events = Collected()
        pad.onLine { data in
            if KeyEvent.parse(data) != nil {
                events.add(line: String(decoding: data, as: UTF8.self))
            }
        }
        pad.press("AG00")
        pad.release("AG00")
        pad.turnEncoder(clockwise: true)
        let seen = events.allLines.compactMap { KeyEvent.parse(Data($0.utf8)) }
        expectEqual(seen, [
            KeyEvent(key: "AG00", action: .down),
            KeyEvent(key: "AG00", action: .up),
            KeyEvent(key: "ENC_CW", action: .tick),
        ])
    }

    test("the survey names a pad that is unmistakably not hardware") {
        let survey = VirtualPad.survey()
        expect(survey.found)
        expect(!survey.isWired)
        expectEqual(survey.product, "Virtual Pad")
        // Not a name the Bluetooth or HID matchers would claim as a board they drive.
        expect(!CodexProtocol.isKnownProductName(survey.product ?? ""))
    }
}
