import Foundation
import OpenBoardKit

/**
 Selection follows the system, not a brand palette.

 Every highlight, hover and selection surface takes the user's chosen colour. The
 hardware colours are the exception and must *not* follow it: an LED is told to emit a
 specific value, and restyling it to match a window would make the swatch and the key
 disagree — the one thing this app's colour model must never do.
 */
func runSelectionColorTests() {
    test("no brand accent is hardcoded into a selection surface") {
        // #D97757 is the design's accent. It shipped in five places — the keycap
        // picker, the selected key's ring, and two popover rows — and none of them
        // followed the user's setting.
        let sources = ["SettingsWindow", "PopoverView", "SettingsPanes", "ColorsPane"]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // OpenBoardTests
            .deletingLastPathComponent()      // Sources
            .appendingPathComponent("OpenBoard")
        for name in sources {
            let url = root.appendingPathComponent("\(name).swift")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            expect(!text.contains("0xD97757"), "\(name) still hardcodes the brand accent")
        }
    }

    // The values themselves are asserted once, in `runPortFidelityTests` — "LED colors
    // are the hardware values, not a palette". Restating the four hex strings here was
    // a second place to update for one decision, which is how a suite grows a test that
    // fails for a reason nobody remembers.
}

/**
 A control that changes nothing.

 `BoardModel` is the display copy. Writing to it redraws the settings window and does
 nothing else — it does not save, and it does not push the change into the dispatcher
 that reads a binding when a key is actually pressed. `commands.bindingsChanged()` is
 what does both.

 The whole Board pane was missing it: keycap, action, snippet, joystick direction,
 encoder click, hold time and scroll size all appeared to take, then vanished on
 restart, and never took effect on the pad in between. The notification-state picker
 and the fun-mode gain slider had the same gap.

 This is the same shape as every other bug in this project's history — correct code
 that nothing called — and no test of the settings *logic* can catch it, because the
 logic is right and the wiring is absent. So this reads the source.
 */
func runSettingsPersistenceTests() {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // OpenBoardTests
        .deletingLastPathComponent()      // Sources
        .appendingPathComponent("OpenBoard")

    /// A write to the shared model, by file and line.
    func setters(in name: String) -> [(line: Int, text: String, notifies: Bool)] {
        let url = root.appendingPathComponent("\(name).swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
        var found: [(Int, String, Bool)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Comments describe the rule; they are not writes.
            guard !trimmed.hasPrefix("//") else { continue }
            let isWrite = trimmed.contains("board.updatePreferences")
                || (trimmed.contains("board.caps[") || trimmed.contains("board.actions[")
                    || trimmed.contains("board.snippets[") || trimmed.contains("board.events[")
                    || trimmed.contains("board.notifications[")
                    || trimmed.contains("board.appearances["))
                    // `] =` alone also matches `] ==`, which is a comparison.
                    && (trimmed.contains("] = ") || trimmed.contains("removeValue"))
            guard isWrite else { continue }
            // The announcement follows the write, inside the same setter.
            let window = lines[index..<min(index + 10, lines.count)].joined(separator: "\n")
            found.append((index + 1, trimmed, window.contains("bindingsChanged()")))
        }
        return found
    }

    test("every settings control saves and applies what it changes") {
        var silent: [String] = []
        for pane in ["SettingsWindow", "SettingsPanes", "ColorsPane", "PopoverView", "MainWindow"] {
            for setter in setters(in: pane) where !setter.notifies {
                silent.append("\(pane).swift:\(setter.line) \(setter.text)")
            }
        }
        expect(
            silent.isEmpty,
            "these edits are never saved or applied:\n  " + silent.joined(separator: "\n  ")
        )
    }

    test("the check would actually notice a silent setter") {
        // A guard that cannot fail is not a guard. The Board pane is the pane that was
        // broken, so it has to be one the scan genuinely reads.
        let scanned = setters(in: "SettingsWindow")
        expect(!scanned.isEmpty, "the scan found no setters at all — it is matching nothing")
    }
}

/**
 The suite that checks the suite.

 Every test file is wired up by hand in `main.swift`, one line each. A file added
 without that line compiles, looks complete, and never runs — which is this project's
 signature failure exactly: correct code that nothing calls. It has already happened to
 shipping code four times (`prune`, the focus watcher, the transcript backfill, the
 Board pane's save), and there is no reason the tests are immune.

 A missing suite is worse than a missing feature, because it reports success.
 */
func runSuiteWiringTests() {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    test("every suite defined is a suite that runs") {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else {
            skip("test directory not readable")
            return
        }
        guard let main = try? String(
            contentsOf: directory.appendingPathComponent("main.swift"), encoding: .utf8
        ) else {
            skip("main.swift not readable")
            return
        }

        var defined: [String] = []
        for file in names where file.hasSuffix(".swift") && file != "main.swift" {
            guard let source = try? String(
                contentsOf: directory.appendingPathComponent(file), encoding: .utf8
            ) else { continue }
            for line in source.components(separatedBy: "\n") where line.hasPrefix("func run") {
                // "func runFooTests() {" and the async form.
                let name = line.dropFirst("func ".count).prefix { $0 != "(" }
                defined.append(String(name))
            }
        }

        expect(defined.count > 30, "found only \(defined.count) suites — the scan is broken")
        let unwired = defined.filter { !main.contains("\($0)()") }
        expect(
            unwired.isEmpty,
            "defined but never run: \(unwired.sorted().joined(separator: ", "))"
        )
    }
}
