import Foundation
import Dispatch

// ParseError now lives in Models/ParseError.swift (Foundation-only, compiled into
// this standalone build via SRC in run-tests.sh) rather than App/AppState.swift, so
// it no longer needs a shim redeclaration here.

// MARK: - Micro test framework

struct TestFailure: Error { let message: String }

var failures: [String] = []

func expect(_ condition: Bool, _ message: String,
            file: String = #file, line: Int = #line) {
    if !condition {
        failures.append("\(URL(fileURLWithPath: file).lastPathComponent):\(line): \(message)")
    }
}

func expectEq<T: Equatable>(_ a: T, _ b: T, _ message: String,
                            file: String = #file, line: Int = #line) {
    if a != b {
        failures.append("\(URL(fileURLWithPath: file).lastPathComponent):\(line): \(message) — got \(a), expected \(b)")
    }
}

func expectThrows(_ message: String, file: String = #file, line: Int = #line,
                  _ body: () throws -> Void) {
    do {
        try body()
        failures.append("\(URL(fileURLWithPath: file).lastPathComponent):\(line): \(message) — expected an error but none was thrown")
    } catch {}
}

func expectNoThrow(_ message: String, file: String = #file, line: Int = #line,
                   _ body: () throws -> Void) {
    do { try body() } catch {
        failures.append("\(URL(fileURLWithPath: file).lastPathComponent):\(line): \(message) — unexpected error: \(error)")
    }
}

/// A cue start/y value that escaped a parser must be finite and non-negative.
func expectSaneCues(_ cues: [CuePoint], _ context: String,
                    file: String = #file, line: Int = #line) {
    for cue in cues {
        expect(cue.start.isFinite, "\(context): cue '\(cue.name)' start is not finite (\(cue.start))", file: file, line: line)
        expect(cue.start >= 0, "\(context): cue '\(cue.name)' start is negative (\(cue.start))", file: file, line: line)
        expect(cue.yValue.isFinite, "\(context): cue '\(cue.name)' yValue is not finite", file: file, line: line)
        expect((1...23).contains(cue.curve), "\(context): cue '\(cue.name)' curve out of range (\(cue.curve))", file: file, line: line)
    }
}

// Deterministic PRNG for fuzz inputs (no Date/random in scripts or flaky tests).
struct XorShift64 {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in byte() }
    }
}

let samplesDir = URL(fileURLWithPath: "/Users/amritrosell/Documents/claude/native-builds/cue-sync-build/samples")
let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("cuesync-tests", isDirectory: true)

func loadSample(_ name: String) throws -> String {
    try String(contentsOf: samplesDir.appendingPathComponent(name), encoding: .utf8)
}

// MARK: - Runner

// Each test runs in its own process (see run-tests.sh) so a trap/crash in one
// test is reported as CRASH without taking down the suite.
let arguments = CommandLine.arguments

try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

if arguments.count >= 2 && arguments[1] == "list" {
    for t in allTests { print(t.name) }
    exit(0)
}

guard arguments.count >= 2 else {
    fputs("usage: cuesync-tests <list | all | test-name>\n", stderr)
    exit(2)
}

// Watchdog: an infinite loop in parsing code must fail the test, not hang CI.
DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
    fputs("TIMEOUT: test exceeded 20s (possible infinite loop)\n", stderr)
    exit(124)
}

let selected: [(name: String, fn: () throws -> Void)]
if arguments[1] == "all" {
    selected = allTests
} else {
    selected = allTests.filter { $0.name == arguments[1] }
    if selected.isEmpty {
        fputs("unknown test: \(arguments[1])\n", stderr)
        exit(2)
    }
}

var anyFailed = false
for test in selected {
    failures = []
    do {
        try test.fn()
    } catch {
        failures.append("threw: \(error)")
    }
    if failures.isEmpty {
        print("PASS \(test.name)")
    } else {
        anyFailed = true
        print("FAIL \(test.name)")
        for f in failures { print("  - \(f)") }
    }
}
exit(anyFailed ? 1 : 0)
