import Foundation

/**
 Which physical key a logical slot lights.

 Reads the *existing* record at `~/.claude/openboard/calibration.json` unchanged, so
 a pad calibrated under the Node version keeps working — recalibrating means sitting
 there pressing keys against colored lights, and nobody should have to redo it for a
 rewrite.

 ## Why a missing record is no longer a hard stop

 It used to be: nothing painted until a human had named all six colors, on the rule
 that slot order is never assumed. The rule is right and the gate was the wrong way to
 enforce it, for a reason that only became clear once the evidence was gathered.

 **Every mapping ever recorded is identity.** Not "usually" — the Node version's
 `calibrate --rows` saved `identityMapping()` *regardless of what the operator
 reported*, so no other mapping has ever been produced by either implementation, on
 any pad. The gate cost every new user a dark board and six dropdowns to write down an
 answer that was already known.

 So identity is the default, and the capture becomes what it should always have been:
 the fix for a pad that disagrees, rather than a toll on one that does not.

 The invariant survives where it matters. `physicalSlot(for:)` still returns nil for a
 slot a record does not cover, which still means *do not write* rather than "guess" —
 a partial or damaged record is not silently completed with identity.
 */
public struct Calibration: Sendable {
    /// Logical slot (1…6) → physical key index the firmware expects.
    public let mapping: [Int: Int]
    /// The row shape the operator confirmed, e.g. [[1,2],[3,4,5,6]]. Kept for display.
    public let rows: [[Int]]
    public let recordedAt: Date?

    public init(mapping: [Int: Int], rows: [[Int]] = [], recordedAt: Date? = nil) {
        self.mapping = mapping
        self.rows = rows
        self.recordedAt = recordedAt
    }

    /// The physical key for a logical slot, or nil if the record does not cover it.
    /// Nil means *do not write*, never "guess".
    public func physicalSlot(for slot: Int) -> Int? {
        mapping[slot]
    }

    /// Slot N is physical key N — the layout every pad seen so far reports, and what
    /// a board runs on until someone records otherwise.
    public static let identity = Calibration(
        mapping: Dictionary(uniqueKeysWithValues: (1...BoardLayout.slotCount).map { ($0, $0) }),
        rows: [[1, 2], [3, 4, 5, 6]]
    )

    /// Whether this is the assumed layout rather than one a person confirmed. Drives
    /// the Device pane's offer to check it — an unverified assumption should say so.
    public var isAssumed: Bool { recordedAt == nil && mapping == Calibration.identity.mapping }
}

extension Calibration {
    /// The JSON the Node version writes. Decoded leniently on everything except
    /// `mapping`, which is the one field that must be present and well-formed —
    /// matching `lib/calibration.cjs`, which returns null without it.
    private struct Record: Decodable {
        let mapping: [String: Int]
        let rows: [[Int]]?
        let recordedAt: String?
    }

    public static func load(from url: URL) throws -> Calibration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }

        var mapping: [Int: Int] = [:]
        for (key, value) in record.mapping {
            guard let slot = Int(key) else { continue }
            mapping[slot] = value
        }
        guard !mapping.isEmpty else { return nil }

        // The record is written by JavaScript's toISOString(), which always emits
        // fractional seconds — and ISO8601DateFormatter refuses those unless asked.
        // Parsed leniently: a timestamp we cannot read is a cosmetic loss, not a
        // reason to reject a calibration that is otherwise perfectly good.
        let recorded = record.recordedAt.flatMap { text -> Date? in
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        return Calibration(mapping: mapping, rows: record.rows ?? [], recordedAt: recorded)
    }

    /// Where state lives. One forwarder rather than a second definition — see
    /// `AppPaths` for what moved and why.
    public static func defaultStateDirectory(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        AppPaths.state(env: env)
    }

    /// The recorded mapping, or the assumed one.
    ///
    /// Never nil. A pad with no record lights on identity rather than staying dark —
    /// see the note on `Calibration` for why that is safe, and what is still refused.
    /// A record that exists but is *malformed* also lands here: it is the same
    /// situation as never having one, and a broken file should not be a dead board.
    public static func loadDefault(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Calibration {
        let url = defaultStateDirectory(env: env).appendingPathComponent("calibration.json")
        return ((try? load(from: url)) ?? nil) ?? .identity
    }
}
