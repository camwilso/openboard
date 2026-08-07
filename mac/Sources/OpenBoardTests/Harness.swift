import Foundation

/**
 A test runner in ninety lines, because neither test framework is usable here.

 Xcode is not installed. XCTest ships only with Xcode, and while the Command Line
 Tools do carry a `Testing.framework`, it is incomplete — `lib_TestingInterop.dylib`
 is absent, so anything built against swift-testing fails to load at run time.

 The options were: require Xcode to run the tests, or write the ~90 lines that make
 assertions runnable. Tests that cannot run on the machine that builds the code are
 not tests, so this is the harness. It reports in the same shape as the Node suite —
 pass/fail counts and a non-zero exit — so both can be driven the same way.

 Swap this for swift-testing the day Xcode is installed; the assertions read almost
 identically and the test bodies would not change.
 */
enum Harness {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0
    nonisolated(unsafe) static var currentTest = ""
    nonisolated(unsafe) static var currentFailed = false
    nonisolated(unsafe) static var failures: [String] = []

    static func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        currentFailed = false
        do {
            try body()
        } catch {
            currentFailed = true
            failures.append("\(name): threw \(error)")
        }
        if currentFailed {
            failed += 1
            FileHandle.standardOutput.write(Data("✖ \(name)\n".utf8))
        } else {
            passed += 1
            FileHandle.standardOutput.write(Data("✔ \(name)\n".utf8))
        }
    }

    static func expect(
        _ condition: Bool,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard !condition else { return }
        currentFailed = true
        let detail = message().isEmpty ? "expectation failed" : message()
        let location = "\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line)"
        failures.append("  \(currentTest) — \(detail) (\(location))")
    }

    static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard actual != expected else { return }
        let note = message().isEmpty ? "" : " — \(message())"
        expect(false, "expected \(expected), got \(actual)\(note)", file: file, line: line)
    }

    static func require<T>(
        _ value: T?,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) throws -> T {
        guard let value else {
            expect(false, message().isEmpty ? "required a value, got nil" : message(), file: file, line: line)
            throw HarnessError.requirementFailed
        }
        return value
    }

    static func summarise() -> Int32 {
        var out = "\n"
        if !failures.isEmpty {
            out += "failures:\n" + failures.joined(separator: "\n") + "\n\n"
        }
        out += "tests \(passed + failed)  pass \(passed)  fail \(failed)\n"
        FileHandle.standardOutput.write(Data(out.utf8))
        return failed == 0 ? 0 : 1
    }
}

enum HarnessError: Error { case requirementFailed }

// Free functions, not `let` aliases: assigning a function to a constant discards
// its default arguments, which would make every call site spell out #file and #line.

func test(_ name: String, _ body: () throws -> Void) {
    Harness.test(name, body)
}

func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Harness.expect(condition, message(), file: file, line: line)
}

/// Note a case that could not run, rather than passing silently.
///
/// Used only where the missing thing is genuinely optional — a 90MB video that is not
/// part of the app. A skip must never stand in for a check that could have run.
func skip(_ reason: String) {
    FileHandle.standardOutput.write(Data("  — skipped: \(reason)\n".utf8))
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Harness.expectEqual(actual, expected, message(), file: file, line: line)
}
