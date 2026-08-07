import Foundation

/**
 Recording which physical key is which slot.

 Nothing paints until this exists — the "never guess a slot" rule made mechanical. A
 wrong mapping silently misroutes every light, which is worse than no light at all
 because it teaches you to distrust the board.

 ## How the capture works

 Each of the six Agent keys is painted a maximally distinguishable color, chosen so a
 mapping can be read off by eye without counting. The operator reports what they
 actually see, in reading order — top row left to right, then the bottom row — and the
 mapping is derived from that.

 ## A difference from the Node version, on purpose

 `bin/openboard calibrate --rows` records the observed layout and then saves
 `mapping: identityMapping()` regardless. That is only correct when the observed order
 happens to *be* identity, which is true on the machine it was written for and is
 exactly the case where calibration was unnecessary. If the pad reported keys in any
 other order the record would claim a mapping that contradicts its own observation.

 Here the mapping is derived from what was seen. Identity input still yields an identity
 mapping, so existing records are unaffected, and the `rows` field is kept so the record
 stays readable by both implementations.
 */
public enum CalibrationCapture {
    /// Maximally distinguishable on an RGB LED, so a mapping can be read off by eye.
    /// Ported from `lib/paint.cjs` CALIBRATION_COLORS — the order *is* the slot order.
    public static let legend: [(slot: Int, name: String, color: RGB)] = [
        (1, "RED", RGB(0xFF0000)),
        (2, "GREEN", RGB(0x00FF00)),
        (3, "BLUE", RGB(0x0000FF)),
        (4, "YELLOW", RGB(0xFFFF00)),
        (5, "CYAN", RGB(0x00FFFF)),
        (6, "MAGENTA", RGB(0xFF00FF)),
    ]

    /// Two on top, four below — the Agent keys' physical shape.
    public static let defaultRows = [[1, 2], [3, 4, 5, 6]]

    public enum CaptureError: Error, LocalizedError, Equatable {
        case wrongCount(Int)
        case duplicate(Int)
        case outOfRange(Int)

        public var errorDescription: String? {
            switch self {
            case let .wrongCount(count):
                "each of the six keys must be named exactly once — got \(count)"
            case let .duplicate(slot):
                "slot \(slot) was chosen more than once"
            case let .outOfRange(slot):
                "slot \(slot) is outside 1…6"
            }
        }
    }

    /**
     Turn an observation into a calibration record.

     - Parameter observed: the logical slot seen at each physical position, in reading
       order. `[1, 2, 3, 4, 5, 6]` means the pad lit in slot order.
     */
    public static func record(
        observed: [Int],
        rows: [[Int]] = defaultRows,
        now: Date = Date()
    ) throws -> Calibration {
        guard observed.count == BoardLayout.slotCount else {
            throw CaptureError.wrongCount(observed.count)
        }
        var seen = Set<Int>()
        for slot in observed {
            guard (1...BoardLayout.slotCount).contains(slot) else {
                throw CaptureError.outOfRange(slot)
            }
            guard seen.insert(slot).inserted else { throw CaptureError.duplicate(slot) }
        }

        // Reading position i showed logical slot `observed[i]`, so that slot lives at
        // physical key i+1. This is the step the Node version skipped.
        var mapping: [Int: Int] = [:]
        for (index, slot) in observed.enumerated() {
            mapping[slot] = index + 1
        }

        // Reshape the observation to the row widths, so the record describes the pad.
        var shaped: [[Int]] = []
        var cursor = 0
        for row in rows {
            let width = min(row.count, observed.count - cursor)
            guard width > 0 else { break }
            shaped.append(Array(observed[cursor..<(cursor + width)]))
            cursor += width
        }

        return Calibration(mapping: mapping, rows: shaped, recordedAt: now)
    }

    /// Parse `"1,2/3,4,5,6"`, the CLI's layout spec. Kept so a record written by hand
    /// or by the old command still means the same thing.
    public static func parseRows(_ spec: String) throws -> [Int] {
        let flat = spec
            .split(separator: "/")
            .flatMap { $0.split(separator: ",") }
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard flat.count == BoardLayout.slotCount else { throw CaptureError.wrongCount(flat.count) }
        return flat
    }
}

extension Calibration {
    /// The JSON the Node version wrote, so a record stays readable by both.
    public var json: [String: Any] {
        var mappingJSON: [String: Int] = [:]
        for (slot, physical) in mapping { mappingJSON[String(slot)] = physical }

        return [
            "version": 1,
            "recordedAt": ISO8601DateFormatter().string(from: recordedAt ?? Date()),
            "confirmedBy": "operator",
            "legend": CalibrationCapture.legend.map {
                ["slot": $0.slot, "name": $0.name, "color": Int($0.color.value)]
            },
            "rows": rows.isEmpty ? CalibrationCapture.defaultRows : rows,
            "mapping": mappingJSON,
        ]
    }

    /// Write to the state directory, at mode 0600 like the Node version.
    public func save(to url: URL? = nil) throws {
        let target = url ?? Calibration.defaultStateDirectory()
            .appendingPathComponent("calibration.json")
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: target, options: [.atomic])
        // An atomic write replaces the inode, so the mode is reapplied after it.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: target.path
        )
    }
}
