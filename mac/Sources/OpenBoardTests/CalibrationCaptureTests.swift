import Foundation
import OpenBoardKit

/**
 Capturing a calibration.

 This is the one gap that blocks a fresh install outright, and the one where being
 *confidently wrong* is worse than failing: a bad mapping lights the wrong key every
 time, which teaches you to distrust the board rather than to fix it.
 */
func runCalibrationCaptureTests() {
    test("the six legend colors stay maximally distinguishable, in slot order") {
        // Ported from lib/paint.cjs. The order *is* the slot order — reshuffling it
        // silently changes what every future capture means.
        expectEqual(CalibrationCapture.legend.map(\.name),
                    ["RED", "GREEN", "BLUE", "YELLOW", "CYAN", "MAGENTA"])
        expectEqual(CalibrationCapture.legend.map(\.slot), [1, 2, 3, 4, 5, 6])
        expectEqual(CalibrationCapture.legend[0].color.hex, "#FF0000")
        expectEqual(CalibrationCapture.legend[5].color.hex, "#FF00FF")
        // Each channel is fully on or fully off, so no two are confusable under the
        // brightness the pad actually paints at.
        for entry in CalibrationCapture.legend {
            for shift in [16, 8, 0] {
                let channel = (entry.color.value >> UInt32(shift)) & 0xFF
                expect(channel == 0 || channel == 0xFF, "\(entry.name) has a mid channel")
            }
        }
    }

    test("an identity observation gives an identity mapping") {
        let record = try Harness.require(try? CalibrationCapture.record(observed: [1, 2, 3, 4, 5, 6]))
        for slot in 1...6 { expectEqual(record.physicalSlot(for: slot), slot) }
        expectEqual(record.rows, [[1, 2], [3, 4, 5, 6]])
    }

    test("a scrambled observation is inverted, not copied") {
        // The Node command records `rows` and then saves mapping: identity regardless,
        // so a non-identity pad gets a record contradicting its own observation. Here
        // the mapping is derived: seeing slot 4's color at reading position 1 means
        // slot 4 lives at physical key 1.
        let observed = [4, 1, 6, 2, 5, 3]
        let record = try Harness.require(try? CalibrationCapture.record(observed: observed))
        expectEqual(record.physicalSlot(for: 4), 1)
        expectEqual(record.physicalSlot(for: 1), 2)
        expectEqual(record.physicalSlot(for: 6), 3)
        expectEqual(record.physicalSlot(for: 2), 4)
        expectEqual(record.physicalSlot(for: 5), 5)
        expectEqual(record.physicalSlot(for: 3), 6)

        // Every physical key is used exactly once — an inversion that dropped or
        // doubled one would leave a key permanently dark or double-lit.
        expectEqual(Set(record.mapping.values), Set(1...6))
    }

    test("the observation is reshaped to the pad's rows") {
        let record = try Harness.require(try? CalibrationCapture.record(observed: [4, 1, 6, 2, 5, 3]))
        expectEqual(record.rows, [[4, 1], [6, 2, 5, 3]], "two on top, four below")
    }

    test("an incomplete or contradictory observation is refused") {
        // Refusing costs one retry. Accepting writes a mapping that misroutes silently
        // and forever, so every one of these is a hard error rather than a repair.
        expect((try? CalibrationCapture.record(observed: [1, 2, 3])) == nil, "too few")
        expect((try? CalibrationCapture.record(observed: [1, 2, 3, 4, 5, 6, 1])) == nil, "too many")
        expect((try? CalibrationCapture.record(observed: [1, 1, 3, 4, 5, 6])) == nil, "duplicate")
        expect((try? CalibrationCapture.record(observed: [0, 2, 3, 4, 5, 6])) == nil, "zero")
        expect((try? CalibrationCapture.record(observed: [7, 2, 3, 4, 5, 6])) == nil, "out of range")
    }

    test("a captured record round-trips through the file the Node version reads") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-cal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let record = try Harness.require(try? CalibrationCapture.record(observed: [2, 1, 3, 4, 6, 5]))
        try record.save(to: url)

        let reloaded = try Harness.require((try? Calibration.load(from: url)) ?? nil)
        for slot in 1...6 {
            expectEqual(reloaded.physicalSlot(for: slot), record.physicalSlot(for: slot))
        }
        expectEqual(reloaded.rows, [[2, 1], [3, 4, 6, 5]])
        expect(reloaded.recordedAt != nil, "the timestamp did not survive")

        // The on-disk shape is the one lib/calibration.cjs writes, so a pad calibrated
        // here still works if anyone runs the Node tooling against it.
        let json = try Harness.require(
            (try? JSONSerialization.jsonObject(with: try Data(contentsOf: url))) as? [String: Any]
        )
        expectEqual(json["version"] as? Int, 1)
        expectEqual(json["confirmedBy"] as? String, "operator")
        expect(json["legend"] != nil, "the legend is what makes the record auditable later")
        expectEqual((json["mapping"] as? [String: Int])?["2"], 1)
    }

    test("the record is not world-readable") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ob-cal-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try (try Harness.require(try? CalibrationCapture.record(observed: [1, 2, 3, 4, 5, 6])))
            .save(to: url)

        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.posixPermissions] as? NSNumber }?.intValue ?? 0
        expectEqual(mode & 0o077, 0)
    }

    test("the CLI's row spec still parses") {
        expectEqual(try? CalibrationCapture.parseRows("1,2/3,4,5,6"), [1, 2, 3, 4, 5, 6])
        expectEqual(try? CalibrationCapture.parseRows(" 2, 1 / 3,4,5,6 "), [2, 1, 3, 4, 5, 6])
        expect((try? CalibrationCapture.parseRows("1,2/3,4")) == nil)
    }
}
