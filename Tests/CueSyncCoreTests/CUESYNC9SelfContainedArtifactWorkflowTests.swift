import Foundation
import XCTest

// =============================================================================
// CUESYNC-9 §0.2 (round 3) compliance — the self-contained-artifact fix.
//
// The click-probe gate captured only the harness's launcher cmd.exe console;
// CueSync's own /SUBSYSTEM:WINDOWS exe never showed a window because its Swift
// runtime DLLs were resolved from the toolchain root on the CI runner's PATH and
// were NOT bundled into the uploaded artifact, so a clean PC (the GTE) could not
// load the exe at all (specs/CUESYNC-9-findings.md §0.2). The round-3 fix bundles
// them in the `windows-build` job, after the DLL-closure check and before upload.
//
// Same rationale/style as CUESYNC9WindowsInputDispatchWorkflowTests: `swift test`
// is deterministic and network-free, so it cannot spin up a real Windows box — it
// pins that the workflow declares the bundling step the fix requires, in the order
// it requires, driven off the dependency walker rather than a hardcoded DLL list.
// The YAML-scoping helper below is intentionally file-local (mirrors the repo
// convention of self-contained per-file workflow parsers).
// =============================================================================

final class CUESYNC9SelfContainedArtifactWorkflowTests: XCTestCase {

    // The bare step names; `firstLineIndex` needs the `name:\s*` prefix, `stepBlock`
    // prepends it itself (so it is passed the bare name — see the sibling
    // CUESYNC9WindowsInputDispatchWorkflowTests for the same convention).
    private let bundleStepName = "Bundle Swift runtime DLLs"
    private let bundleStepPattern = #"name:\s*Bundle Swift runtime DLLs"#
    private let closureStepPattern = #"name:\s*Verify DLL closure"#
    private let uploadStepPattern = #"name:\s*Upload build artifact"#

    /// spec CUESYNC-9 §0.2: the fix is a bundling step in the `windows-build` job.
    func testWindowsBuildDeclaresASwiftRuntimeDLLBundlingStep() throws {
        let job = try SelfContainedJob.require("windows-build")
        XCTAssertNotNil(job.firstLineIndex(matching: bundleStepPattern),
            "windows-build must declare a 'Bundle Swift runtime DLLs' step so the uploaded artifact is " +
            "self-contained and launches on a clean PC (specs/CUESYNC-9-findings.md §0.2)")
    }

    /// spec CUESYNC-9 §0.2: it must run AFTER the closure check + its negative control
    /// (which stay green, gating the pre-bundle artifact) and BEFORE the upload.
    func testBundlingStepRunsAfterTheClosureCheckAndBeforeTheUpload() throws {
        let job = try SelfContainedJob.require("windows-build")
        guard let closureLine = job.firstLineIndex(matching: closureStepPattern) else {
            XCTFail("windows-build must still declare the 'Verify DLL closure' step"); return
        }
        guard let bundleLine = job.firstLineIndex(matching: bundleStepPattern) else {
            XCTFail("windows-build must declare the 'Bundle Swift runtime DLLs' step"); return
        }
        guard let uploadLine = job.firstLineIndex(matching: uploadStepPattern) else {
            XCTFail("windows-build must still declare the 'Upload build artifact' step"); return
        }
        XCTAssertGreaterThan(bundleLine, closureLine,
            "the bundling step must run AFTER the DLL-closure check + negative control, so that check " +
            "keeps gating the pre-bundle artifact unchanged (spec CUESYNC-9 §0.2)")
        XCTAssertLessThan(bundleLine, uploadLine,
            "the bundling step must run BEFORE the artifact upload, so the uploaded artifact actually " +
            "contains the Swift runtime DLLs (spec CUESYNC-9 §0.2)")
    }

    /// spec CUESYNC-9 §0.2: driven off the dependency walker's own resolved closure —
    /// not a hardcoded DLL list — so it bundles exactly CueSync.exe's transitive Swift
    /// deps, and it derives the toolchain root at runtime rather than hardcoding a path.
    func testBundlingStepIsDrivenOffTheResolvedClosureNotAHardcodedList() throws {
        let job = try SelfContainedJob.require("windows-build")
        let block = try job.stepBlock(named: bundleStepName)
        XCTAssertTrue(block.contains("wldd"),
            "the bundling step must re-use the same dependency walker (wldd) the closure check trusts, " +
            "so it copies exactly CueSync.exe's resolved Swift dependencies")
        XCTAssertTrue(block.contains("Copy-Item"),
            "the bundling step must actually copy the resolved Swift runtime DLLs into the artifact")
        XCTAssertTrue(block.contains("swift.exe") || block.lowercased().contains("swifttoolchainroot"),
            "the bundling step must derive the Swift toolchain root at runtime (from swift.exe), not " +
            "hardcode a version/edition-specific path")
        // Must not silently ship a broken artifact: if nothing was bundled, fail.
        XCTAssertTrue(block.contains("exit 1"),
            "the bundling step must fail the job if it finds no Swift runtime DLL to bundle (a clean PC " +
            "would otherwise still be unable to load the exe)")
    }

    /// spec CUESYNC-9 §0.2: the artifact must be machine-verified self-contained on the
    /// box (re-walk CueSync.exe, assert nothing resolves from the toolchain root) — the
    /// one half of this fix a non-Windows environment cannot check.
    func testBundlingStepReVerifiesTheArtifactIsSelfContained() throws {
        let job = try SelfContainedJob.require("windows-build")
        let block = try job.stepBlock(named: bundleStepName)
        let wlddRuns = block.components(separatedBy: "wldd").count - 1
        XCTAssertGreaterThanOrEqual(wlddRuns, 2,
            "the bundling step must walk CueSync.exe at least twice — once to find the Swift deps to " +
            "copy, once to re-verify nothing still resolves from the toolchain root (found \(wlddRuns))")
    }

    /// spec CUESYNC-9 §0.2: it is a PACKAGING fix — it must not touch swift-cross-ui bytes.
    /// The pin and the two dependency patches are out of scope for this step.
    func testBundlingStepIsPackagingOnlyAndTouchesNoDependencySource() throws {
        let job = try SelfContainedJob.require("windows-build")
        let block = try job.stepBlock(named: bundleStepName)
        XCTAssertFalse(block.contains("git apply"),
            "the bundling step is a packaging fix and must not apply any swift-cross-ui patch")
        XCTAssertFalse(block.contains(".build\\checkouts") || block.contains(".build/checkouts"),
            "the bundling step must not edit the resolved dependency checkout — it only copies runtime " +
            "DLLs into the artifact directory")
    }

    /// spec CUESYNC-9 §0.2: the findings doc records the corrected diagnosis — the probe
    /// clicked the launcher console, and the unbundled Swift runtime DLLs are the cause.
    func testFindingsRecordsTheRoundThreeReDiagnosis() throws {
        let text = try String(contentsOf: SelfContainedRepoPaths.findings, encoding: .utf8)
        XCTAssertTrue(text.contains("§0.2"),
            "specs/CUESYNC-9-findings.md must contain the round-3 §0.2 re-diagnosis")
        XCTAssertTrue(text.lowercased().contains("cmd.exe"),
            "the §0.2 re-diagnosis must record that the probe captured the launcher's cmd.exe console, " +
            "not CueSync's window")
        XCTAssertTrue(text.contains("swiftCore.dll") || text.contains("Swift runtime DLL"),
            "the §0.2 re-diagnosis must name the unbundled Swift runtime DLLs as the root cause")
    }
}

// MARK: - Helpers (deliberately file-local — see the file header rationale)

private enum SelfContainedRepoPaths {
    /// Tests/CueSyncCoreTests/<this file> -> Tests/CueSyncCoreTests -> Tests -> repo root
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let workflow = root.appendingPathComponent(".github/workflows/swift-windows.yml")
    static let findings = root.appendingPathComponent("specs/CUESYNC-9-findings.md")
}

/// A single top-level GitHub Actions job's YAML text (file-local, mirrors the
/// JobBlock helpers in the sibling CUESYNC workflow-test files).
private struct SelfContainedJob {
    let lines: [String]

    func firstLineIndex(matching pattern: String) -> Int? {
        lines.firstIndex { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    func stepBlock(named namePattern: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let nameIndex = firstLineIndex(matching: #"name:\s*"# + namePattern) else {
            XCTFail("no step matching '\(namePattern)' found in job", file: file, line: line)
            return ""
        }
        var end = lines.count
        for i in (nameIndex + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- name:") || trimmed.hasPrefix("- uses:") {
                end = i
                break
            }
        }
        return lines[nameIndex..<end].joined(separator: "\n")
    }

    static func require(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> SelfContainedJob {
        let raw = try String(contentsOf: SelfContainedRepoPaths.workflow, encoding: .utf8)
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let allLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = allLines.firstIndex(of: "  \(name):") else {
            XCTFail("could not locate the top-level `\(name):` job in .github/workflows/swift-windows.yml",
                    file: file, line: line)
            return SelfContainedJob(lines: [])
        }
        var end = allLines.count
        for i in (start + 1)..<allLines.count {
            if allLines[i].range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil {
                end = i
                break
            }
        }
        return SelfContainedJob(lines: Array(allLines[start..<end]))
    }
}
