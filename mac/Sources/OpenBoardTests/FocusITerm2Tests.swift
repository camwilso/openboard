import Foundation
import OpenBoardKit

/**
 iTerm2 press-to-jump, checked the same way `runSuiteWiringTests` and
 `runSettingsPersistenceTests` check things this harness cannot otherwise reach.

 `Focus.swift` and `Actions.swift` live in the `OpenBoard` executable target, which
 `OpenBoardTests` does not — and, per the epic's minimal-diff fence, must not — depend
 on: nothing in this suite can `import OpenBoard` and call `Focus.raise` or
 `Actions.respond` directly, and the AppleScript they emit cannot be run here without
 moving a real iTerm2/Terminal window while someone is using the machine. So this reads
 the source text instead, the same trade `runSettingsPersistenceTests` already makes:
 not a substitute for exercising the real path (that is rig validation's job — see
 toj.6), but a real check that the behavioral contract promised by the design — the
 routing, the return contract, the escaping, the app-naming — is actually in the file,
 not just in the commit message.
 */
func runFocusITerm2Tests() {
    let openBoard = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // OpenBoardTests
        .deletingLastPathComponent()      // Sources
        .appendingPathComponent("OpenBoard")

    func read(_ name: String) -> String {
        (try? String(contentsOf: openBoard.appendingPathComponent("\(name).swift"), encoding: .utf8)) ?? ""
    }

    let focus = read("Focus")
    let actions = read("Actions")

    test("the scan actually reads Focus.swift and Actions.swift") {
        // A scan that silently matches nothing reports every test below as passing for
        // the wrong reason — the same failure mode `runSettingsPersistenceTests` guards
        // against with its own "the scan would actually notice" test.
        expect(!focus.isEmpty, "Focus.swift did not read — the scan is checking nothing")
        expect(!actions.isEmpty, "Actions.swift did not read — the scan is checking nothing")
    }

    test("focusITerm2 exists and targets iTerm2") {
        expect(focus.contains("func focusITerm2(tty: String)"))
        expect(focus.contains("tell application \"iTerm2\""))
    }

    test("focusITerm2 walks windows, then tabs, then sessions") {
        // One level deeper than Terminal's windows-then-tabs walk: iTerm2 exposes tty
        // per *session*, and a session lives inside a tab, which lives inside a window
        // — the coverage contract (epic principle 4) requires the tab-among-several
        // case to work, not just the separate-windows case, so all three repeat levels
        // must be present, in this order.
        guard let start = focus.range(of: "func focusITerm2(tty: String)") else {
            expect(false, "focusITerm2 not found")
            return
        }
        let body = String(focus[start.lowerBound...])
        let windowsIndex = body.range(of: "repeat with w in windows")
        let tabsIndex = body.range(of: "repeat with t in tabs of w")
        let sessionsIndex = body.range(of: "repeat with s in sessions of t")
        guard let w = windowsIndex, let t = tabsIndex, let s = sessionsIndex else {
            expect(false, "expected windows -> tabs -> sessions repeat levels, found \(windowsIndex != nil), \(tabsIndex != nil), \(sessionsIndex != nil)")
            return
        }
        expect(w.lowerBound < t.lowerBound && t.lowerBound < s.lowerBound, "the walk must nest windows -> tabs -> sessions, in that order")
    }

    test("focusITerm2 selects the matched tab and session before raising the window") {
        expect(focus.contains("select t"))
        expect(focus.contains("tell t to select s"))
        expect(focus.contains("select w"))
    }

    test("focusITerm2 shares focusTerminal's \"focused\" / \"not-found\" return contract") {
        expect(focus.contains("output == \"focused\" ? .raised(method: \"iterm-tty\") : .notFound"))
        expect(focus.contains("output == \"focused\" ? .raised(method: \"terminal-tty\") : .notFound"))
    }

    test("focusITerm2 escapes only the double quote, like focusTerminal") {
        // tty paths from `ps`/`/dev/ttysNNN` never contain backslashes (design doc §3.1)
        // — over-escaping would be a real divergence from focusTerminal, not a stricter
        // version of it, so both functions must use the identical one-line escape.
        let occurrences = focus.components(separatedBy: "replacingOccurrences(of: \"\\\"\", with: \"\\\\\\\"\")").count - 1
        expectEqual(occurrences, 2, "expected the same escape in both focusTerminal and focusITerm2")
    }

    test("raise falls through to focusITerm2 only on .notFound") {
        guard let raiseStart = focus.range(of: "static func raise(_ slot: SlotView)") else {
            expect(false, "Focus.raise not found")
            return
        }
        let body = String(focus[raiseStart.lowerBound...])
        guard let switchRange = body.range(of: "switch focusTerminal(tty: path) {") else {
            expect(false, "raise no longer routes through a switch on focusTerminal's outcome")
            return
        }
        let afterSwitch = String(body[switchRange.upperBound...].prefix(800))
        expect(
            afterSwitch.contains("case .notFound:") && afterSwitch.contains("return focusITerm2(tty: path)"),
            ".notFound must fall through to focusITerm2"
        )
        expect(
            afterSwitch.contains("case let outcome:") && afterSwitch.contains("return outcome"),
            ".raised and .failed must return as-is, not retry against iTerm2"
        )
    }

    test("run names the app that refused Automation, not just Terminal") {
        // The -1743 message used to hardcode "Terminal". Now that `run` drives a
        // second app, the message must say which one actually refused.
        expect(focus.contains("forApp app: String = \"Terminal\""), "run should default to Terminal so focusTerminal's call site needs no change")
        expect(focus.contains("not authorised to control \\(app) — grant Automation"))
        expect(!focus.contains("not authorised to control Terminal — grant Automation"), "the message must no longer hardcode Terminal")
    }

    test("focusTerminal and focusITerm2 both refuse to launch an app that is not running") {
        expect(focus.contains("isRunning(bundleID: \"com.apple.Terminal\")"))
        expect(focus.contains("isRunning(bundleID: \"com.googlecode.iterm2\")"))
    }

    test("hasLanded confirms an iTerm2-hosted session, not just Terminal") {
        expect(actions.contains("tell application \"iTerm2\""), "hasLanded needs an iTerm2 branch or respond() misreports .focusFailed for iTerm2 sessions")
        expect(actions.contains("current session of current window"))
    }

    test("hasLanded guards both Terminal and iTerm2 checks on the app already running") {
        // Without this, polling hasLanded during confirmFrontmost's retry loop can
        // launch Terminal for an iTerm2-only user, or vice versa — up to ~19 times
        // before the 1.5s timeout, per confirmFrontmost's 0.08s poll interval.
        expect(actions.contains("Focus.isRunning(bundleID: \"com.apple.Terminal\")"))
        expect(actions.contains("Focus.isRunning(bundleID: \"com.googlecode.iterm2\")"))
    }
}
