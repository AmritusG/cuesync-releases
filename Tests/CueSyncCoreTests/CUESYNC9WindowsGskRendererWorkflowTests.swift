import Foundation
import XCTest

// =============================================================================
// CUESYNC-9 §0.3 / step-4-contingency compliance — the GtkBackend Windows
// GSK-renderer patch (round 4): its presence, placement, idempotency, read-only
// scoping, pin, and no-regression on the CUESYNC-8 interactivity patch, across all
// three GtkBackend-compiling CI legs (macos, windows-build, windows-test), and the
// checked-in `.patch` file itself.
//
// UPDATED for round 9 (specs/CUESYNC-9-findings.md §0.8): the CUESYNC-9
// input-dispatch patch this file used to no-regression-check against (it applied
// between the interactivity patch and this one) was REVERTED — a disproven,
// non-load-bearing fix per spec step 5, once round 8 proved the real root cause
// was an unrelated window-minimum relayout loop. The GSK-renderer patch itself
// (round 4, this file's subject) is untouched by that revert — it now applies
// immediately after the interactivity patch instead of after the (now-gone)
// input-dispatch patch. Tests that asserted the input-dispatch patch's presence
// are inverted into regression locks asserting its ABSENCE.
//
// Same rationale as CUESYNC9WindowsInputDispatchWorkflowTests: `swift test` is
// deterministic and network-free, so it cannot spin up a real Windows build box +
// click-probe gate to prove a window actually appears — what it CAN verify is that
// the workflow declares the patch step the spec's step-4 contingency requires, in
// the order it requires, without vacuous-green shapes. The YAML-scoping helpers are
// intentionally file-local (mirrors the repo convention of each compliance file
// keeping its own parser — see CUESYNC9WindowsInputDispatchWorkflowTests' header).
// =============================================================================

private let auditedRevision = "a6d206370812e3b9edba259d167e848892c5013d"
private let gskPatchRelativePath = "patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch"
private let windowsInputPatchRelativePath = "patches/swift-cross-ui-0.8.0-windows-input.patch"
private let interactivityPatchRelativePath = "patches/swift-cross-ui-0.8.0-gtk-interactivity.patch"
private let gskStepNamePattern = #"name:\s*Patch swift-cross-ui Windows GSK renderer"#

final class CUESYNC9GskRendererPatchStepPlacementTests: XCTestCase {

    /// The GSK-renderer patch step must exist on all three legs that compile GtkBackend.
    func testGskPatchStepExistsOnAllThreeGtkBackendCompilingLegs() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocksGSK.require(jobName)
            XCTAssertNotNil(
                job.firstLineIndex(matching: gskStepNamePattern),
                "\(jobName) must declare a 'Patch swift-cross-ui Windows GSK renderer' step (CUESYNC-9 §0.3)")
        }
    }

    /// UPDATED for round 9 (specs/CUESYNC-9-findings.md §0.8): the input-dispatch
    /// patch that used to sit between interactivity and GSK-renderer was reverted,
    /// so the apply order is now interactivity -> gsk directly. The GSK-renderer
    /// step must run AFTER the CUESYNC-8 interactivity patch step on every leg.
    /// Was: "runs after the input-dispatch patch."
    func testGskPatchStepRunsAfterTheInteractivityPatchOnEveryLeg() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocksGSK.require(jobName)
            guard let interactivityLine = job.firstLineIndex(matching: #"name:\s*Patch swift-cross-ui GTK interactivity"#) else {
                XCTFail("\(jobName) has no CUESYNC-8 interactivity patch step to order against")
                continue
            }
            guard let gskLine = job.firstLineIndex(matching: gskStepNamePattern) else {
                XCTFail("\(jobName) has no GSK-renderer patch step to order")
                continue
            }
            XCTAssertGreaterThan(gskLine, interactivityLine,
                "\(jobName)'s GSK-renderer patch step must run AFTER the interactivity patch step (apply " +
                "order interactivity -> gsk now that round 9 reverted the input-dispatch patch, " +
                "specs/CUESYNC-9-findings.md §0.8)")
        }
    }

    /// The GSK-renderer patch must land before `swift build`/`swift test` compiles GtkBackend.
    func testGskPatchStepRunsBeforeBuildOrTestOnEveryLeg() throws {
        let expectations: [(job: String, pattern: String)] = [
            ("macos", #"run:\s*swift build -c release"#),
            ("windows-build", #"run:\s*swift build -c release"#),
            ("windows-test", #"swift test -c release"#),
        ]
        for (jobName, invocationPattern) in expectations {
            let job = try JobBlocksGSK.require(jobName)
            guard let patchLine = job.firstLineIndex(matching: gskStepNamePattern) else {
                XCTFail("\(jobName) has no GSK-renderer patch step to order against build/test")
                continue
            }
            guard let invocationLine = job.firstLineIndex(matching: invocationPattern) else {
                XCTFail("\(jobName) must still invoke the expected build/test command")
                continue
            }
            XCTAssertLessThan(patchLine, invocationLine,
                "\(jobName)'s GSK-renderer patch step must run BEFORE the build/test step that compiles " +
                "GtkBackend (CUESYNC-9 §0.3)")
        }
    }
}

final class CUESYNC9GskRendererPatchIdempotencyAndScopeTests: XCTestCase {

    /// Idempotent (git apply --reverse --check) on every leg.
    func testGskPatchStepIsGuardedByReverseApplyCheckOnEveryLeg() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocksGSK.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui Windows GSK renderer"#)
            XCTAssertTrue(block.contains("git apply --reverse --check"),
                "\(jobName)'s GSK-renderer patch step must guard re-application with " +
                "`git apply --reverse --check` so a second run is a no-op")
        }
    }

    /// Clears the Windows read-only flag on exactly GtkBackend.swift on both Windows legs.
    func testGskPatchStepClearsWindowsReadOnlyFlagOnBothWindowsLegs() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocksGSK.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui Windows GSK renderer"#)
            XCTAssertTrue(block.contains("IsReadOnly"),
                "\(jobName)'s GSK-renderer patch step must clear the Windows read-only flag " +
                "(Set-ItemProperty ... -Name IsReadOnly -Value $false) before patching")
        }
    }

    /// Read-only clear scoped to exactly GtkBackend.swift — never Widget.swift, never a
    /// blanket -Recurse (the GSK patch touches only GtkBackend.swift).
    func testGskPatchStepClearsReadOnlyOnExactlyGtkBackendSwiftNotOtherFiles() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocksGSK.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui Windows GSK renderer"#)
            XCTAssertTrue(block.contains("GtkBackend.swift"),
                "\(jobName)'s GSK-renderer patch step must clear read-only naming GtkBackend.swift specifically")
            XCTAssertFalse(block.contains("Widget.swift"),
                "\(jobName)'s GSK-renderer patch step must not touch Widget.swift — out of scope for this patch")
            XCTAssertFalse(block.contains("-Recurse"),
                "\(jobName)'s read-only clear must target the one named file, not recurse over the checkout")
        }
    }

    /// Pinned in a comment naming the audited v0.8.0 commit on every leg.
    func testGskPatchStepNamesTheAuditedV080CommitOnEveryLeg() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocksGSK.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui Windows GSK renderer"#, includingPrecedingComments: true)
            XCTAssertTrue(block.contains(auditedRevision),
                "\(jobName)'s GSK-renderer patch step (or its preceding comment) must name the audited " +
                "v0.8.0 commit \(auditedRevision)")
        }
    }
}

final class CUESYNC9GskRendererPatchFileTests: XCTestCase {

    func testGskPatchFileExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: RepoPathsGSK.gskPatch.path),
            "\(gskPatchRelativePath) must exist — the fix must be a checked-in, reviewable patch, not an " +
            "in-place dependency edit")
    }

    /// Targets only GtkBackend.swift, exactly one diff header.
    func testGskPatchTargetsOnlyGtkBackendSwift() throws {
        let patch = try String(contentsOf: RepoPathsGSK.gskPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains("Sources/GtkBackend/GtkBackend.swift"),
            "the patch must touch Sources/GtkBackend/GtkBackend.swift (runMainLoop, the audited site)")
        let diffHeaderCount = patch.components(separatedBy: "diff --git a/").count - 1
        XCTAssertEqual(diffHeaderCount, 1,
            "the patch must touch exactly one file — found \(diffHeaderCount) diff --git headers")
    }

    /// A real unified diff, never sed/-replace.
    func testGskPatchFileIsARealUnifiedDiffNotATextSubstitutionScript() throws {
        let patch = try String(contentsOf: RepoPathsGSK.gskPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains("diff --git a/Sources/GtkBackend/GtkBackend.swift b/Sources/GtkBackend/GtkBackend.swift"),
            "expected a real `diff --git` unified-diff header for GtkBackend.swift")
        XCTAssertFalse(patch.contains("-replace") || patch.contains("sed -i") || patch.contains("sed 's"),
            "the checked-in patch must be a real diff, not a -replace/sed text-substitution script")
    }

    /// Uses GTK/GLib's own API (g_setenv) to set GSK_RENDERER=cairo, Windows-only, and
    /// introduces no new dependency/network/dynamic-load.
    func testGskPatchUsesGLibSetenvForCairoRendererWithNoNewDependency() throws {
        let patch = try String(contentsOf: RepoPathsGSK.gskPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains("g_setenv"),
            "the fix must set the env via GLib's own public API g_setenv — not a new dependency, not the " +
            "Windows-only ucrt _putenv_s")
        XCTAssertTrue(patch.contains("GSK_RENDERER") && patch.contains("cairo"),
            "the fix must force GTK's software Cairo renderer via GSK_RENDERER=cairo")
        XCTAssertTrue(patch.contains("#if os(Windows)"),
            "the fix must be guarded to Windows only — Linux/macOS keep their working default renderers")
        // Scoped to ADDED lines only, same rationale as the sibling windows-input
        // patch's equivalent guard (CUESYNC9WindowsInputDispatchWorkflowTests /
        // ATTACK 48's `_win_input_added_lines`): unchanged diff context and the
        // header's prose commentary reproduce/describe surrounding upstream source,
        // not bytes this patch injects, and must not trip a "no new dependency" scan.
        let addedLines = patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
            .joined(separator: "\n")
        for banned in ["import ", "dlopen", "Process(", "URLSession", "http://", "https://"] {
            XCTAssertFalse(addedLines.contains(banned),
                "the patch must not introduce '\(banned)' — no new dependency, no network, no dynamic load")
        }
    }

    /// No GtkFixed/absolute positioning introduced.
    func testGskPatchDoesNotIntroduceGtkFixedOrAbsolutePositioning() throws {
        let patch = try String(contentsOf: RepoPathsGSK.gskPatch, encoding: .utf8)
        XCTAssertFalse(patch.contains("Fixed("),
            "the GSK-renderer patch must not introduce a Gtk.Fixed/absolute-positioning usage")
    }

    /// LF-only bytes — a CRLF-corrupted diff fails `git apply` on the Windows legs.
    func testGskPatchFileContainsNoCarriageReturns() throws {
        let data = try Data(contentsOf: RepoPathsGSK.gskPatch)
        XCTAssertFalse(data.contains(0x0D),
            "\(gskPatchRelativePath) must be LF-only (no \\r) — a CRLF-corrupted diff can fail `git apply` " +
            "on the Windows legs this patch exists to fix")
    }

    /// Not a degenerate stub.
    func testGskPatchFileHasSubstantiveContentNotAnEmptyStub() throws {
        let patch = try String(contentsOf: RepoPathsGSK.gskPatch, encoding: .utf8)
        let lineCount = patch.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertGreaterThan(lineCount, 20,
            "\(gskPatchRelativePath) is suspiciously small (\(lineCount) lines) for a real, documented diff")
    }

    /// Kept SEPARATE from the other two patches (one root cause per patch, independently revertable).
    func testGskPatchIsADistinctFileFromTheOtherTwoPatches() {
        XCTAssertNotEqual(RepoPathsGSK.gskPatch.path, RepoPathsGSK.windowsInputPatch.path)
        XCTAssertNotEqual(RepoPathsGSK.gskPatch.path, RepoPathsGSK.interactivityPatch.path)
    }
}

final class CUESYNC9GskRendererDisjointHunkTests: XCTestCase {

    /// UPDATED for round 9 (specs/CUESYNC-9-findings.md §0.8): now only TWO patches
    /// remain live on GtkBackend.swift — the GSK patch is anchored at runMainLoop,
    /// distinct from the interactivity patch (createPathWidget) — so they apply
    /// cleanly in sequence. The third patch (input-dispatch, anchored at
    /// mainRunLoopTicklingLoop) was reverted; its file no longer exists to read, so
    /// it is dropped from this check (CUESYNC9WindowsInputDispatchWorkflowTests'
    /// testWindowsInputPatchFileNoLongerExists already locks the deletion, and
    /// CUESYNC9NoRegressionOnCUESYNC8PatchTests already locks the interactivity
    /// patch never absorbing that anchor). Was: "three patches ... disjoint anchors."
    func testTwoRemainingPatchesTargetDisjointAnchorsWithinGtkBackendSwift() throws {
        let interactivity = try String(contentsOf: RepoPathsGSK.interactivityPatch, encoding: .utf8)
        let gsk = try String(contentsOf: RepoPathsGSK.gskPatch, encoding: .utf8)

        // Inspect only the unified-diff body (from the first `diff --git` on): the
        // header comment above it legitimately NAMES the other anchor to explain
        // disjointness, so the exclusion must be checked against the actual hunk, not
        // the prose.
        guard let diffStart = gsk.range(of: "diff --git a/") else {
            XCTFail("GSK patch has no `diff --git` body")
            return
        }
        let gskDiffBody = String(gsk[diffStart.lowerBound...])

        XCTAssertTrue(gskDiffBody.contains("runMainLoop"),
            "the GSK patch's GtkBackend.swift hunk must be anchored at runMainLoop")
        XCTAssertFalse(gskDiffBody.contains("createPathWidget"),
            "the GSK patch hunk must not touch createPathWidget — that is the CUESYNC-8 interactivity patch's hunk")
        XCTAssertFalse(gskDiffBody.contains("mainRunLoopTicklingLoop"),
            "the GSK patch hunk must not touch mainRunLoopTicklingLoop — that was the reverted CUESYNC-9 " +
            "input-dispatch patch's hunk (specs/CUESYNC-9-findings.md §0.8)")
        XCTAssertFalse(interactivity.contains("g_setenv"),
            "the interactivity patch must not contain the GSK fix")
    }
}

final class CUESYNC9GskRendererDevScriptTests: XCTestCase {

    /// UPDATED for round 9 (specs/CUESYNC-9-findings.md §0.8): scripts/patch-swift-cross-ui.sh
    /// now applies exactly TWO patches in executable code, and must no longer
    /// reference the reverted input-dispatch patch at all (checked on the RAW file,
    /// not just the code-only view — a stray comment mention trips it too). Was:
    /// "applies all three patches."
    func testDevScriptReferencesBothRemainingPatchFilesAndNoLongerReferencesWindowsInput() throws {
        let codeOnly = try codeOnlyDevScript()
        XCTAssertTrue(codeOnly.contains(gskPatchRelativePath),
            "scripts/patch-swift-cross-ui.sh must apply \(gskPatchRelativePath) in executable code")
        XCTAssertTrue(codeOnly.contains(interactivityPatchRelativePath),
            "scripts/patch-swift-cross-ui.sh must still apply the interactivity patch")
        let raw = try String(contentsOf: RepoPathsGSK.devScript, encoding: .utf8)
        XCTAssertFalse(raw.contains("windows-input.patch"),
            "scripts/patch-swift-cross-ui.sh must not reference 'windows-input.patch' anywhere — reverted " +
            "in round 9 (specs/CUESYNC-9-findings.md §0.8)")
    }

    /// UPDATED for round 17 (specs/CUESYNC-9-findings.md §0.16): the round-13
    /// window-present patch is re-applied (the cairo-black + off-screen-cascade
    /// confounds that got it reverted in round 14 were later invalidated by
    /// §0.14/§0.15), so exactly THREE patches now apply (interactivity + GSK-renderer
    /// + window-present) — an exact count of 3, so the round-9-reverted windows-input
    /// patch quietly reappearing (count 4) would still trip this. Was (round 9): a
    /// count of 2.
    func testDevScriptAppliesBothRemainingPatchesIdempotentlyAndActually() throws {
        let codeOnly = try codeOnlyDevScript()
        let reverseCheckCount = codeOnly.components(separatedBy: "git apply --reverse --check").count - 1
        XCTAssertEqual(reverseCheckCount, 3,
            "scripts/patch-swift-cross-ui.sh must guard EACH of the three remaining patches with its own " +
            "`git apply --reverse --check` — found \(reverseCheckCount)")
        let withoutGuardChecks = codeOnly.replacingOccurrences(of: "git apply --reverse --check", with: "")
        let plainApplyCount = withoutGuardChecks.components(separatedBy: "git apply ").count - 1
        XCTAssertEqual(plainApplyCount, 3,
            "scripts/patch-swift-cross-ui.sh must contain a plain `git apply` for EACH of the three " +
            "remaining patches — found \(plainApplyCount)")
    }

    func testDevScriptStillFailsFastOnAnyError() throws {
        let codeOnly = try codeOnlyDevScript()
        XCTAssertTrue(codeOnly.contains("set -euo pipefail") || codeOnly.contains("set -eu") || codeOnly.contains("set -e"),
            "scripts/patch-swift-cross-ui.sh must keep fail-fast shell options")
    }

    private func codeOnlyDevScript() throws -> String {
        let text = try String(contentsOf: RepoPathsGSK.devScript, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }
}

final class CUESYNC9GskRendererNoRegressionTests: XCTestCase {

    /// UPDATED for round 9 (specs/CUESYNC-9-findings.md §0.8): the CUESYNC-9
    /// input-dispatch patch this test used to also check was reverted — its file no
    /// longer exists to read. Only the CUESYNC-8 interactivity patch's can-target
    /// hunk is checked here now. Was: "the prior TWO patches are unchanged."
    func testPriorInteractivityPatchIsUnchangedAndStillPresent() throws {
        let interactivity = try String(contentsOf: RepoPathsGSK.interactivityPatch, encoding: .utf8)
        XCTAssertTrue(interactivity.contains(#""can-target""#) && interactivity.contains("canTarget = false"),
            "the CUESYNC-8 interactivity patch's can-target hunk must stay intact")
    }

    /// REGRESSION LOCK (round 9): the input-dispatch patch step must now be ABSENT
    /// on all three legs — round 4's GSK-renderer patch must not have (and did not)
    /// resurrect it. INVERTED from "the input-dispatch patch step is still present."
    func testInputDispatchPatchStepIsAbsentOnAllLegs() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocksGSK.require(jobName)
            XCTAssertNil(job.firstLineIndex(matching: #"name:\s*Patch swift-cross-ui Windows input dispatch"#),
                "\(jobName) must NOT declare the CUESYNC-9 input-dispatch patch step — reverted in round 9 " +
                "(specs/CUESYNC-9-findings.md §0.8); the GSK-renderer patch (round 4) must not resurrect it")
        }
    }
}

final class CUESYNC9GskRendererFindingsTests: XCTestCase {

    /// specs/CUESYNC-9-findings.md documents the round-4 GSK-renderer root cause + fix.
    func testFindingsDocumentsRound4GskRendererRootCauseAndFix() throws {
        let text = try String(contentsOf: RepoPathsGSK.findings, encoding: .utf8)
        XCTAssertTrue(text.contains("GSK_RENDERER") && text.contains("cairo"),
            "specs/CUESYNC-9-findings.md must document the GSK_RENDERER=cairo fix (round 4)")
        XCTAssertTrue(text.lowercased().contains("remote desktop") || text.lowercased().contains("rustdesk") || text.contains("RDP"),
            "specs/CUESYNC-9-findings.md must ground the root cause in the remote-desktop environment evidence")
        XCTAssertTrue(text.contains("Fork W"),
            "specs/CUESYNC-9-findings.md must keep classifying the failure as Fork W")
        XCTAssertTrue(text.contains(auditedRevision),
            "specs/CUESYNC-9-findings.md must name the audited pinned commit \(auditedRevision)")
    }
}

// MARK: - Helpers (deliberately file-local — see the file header rationale)

private enum RepoPathsGSK {
    /// Tests/CueSyncCoreTests/<this file> -> Tests/CueSyncCoreTests -> Tests -> repo root
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let workflow = root.appendingPathComponent(".github/workflows/swift-windows.yml")
    static let gskPatch = root.appendingPathComponent(gskPatchRelativePath)
    static let windowsInputPatch = root.appendingPathComponent(windowsInputPatchRelativePath)
    static let interactivityPatch = root.appendingPathComponent(interactivityPatchRelativePath)
    static let devScript = root.appendingPathComponent("scripts/patch-swift-cross-ui.sh")
    static let findings = root.appendingPathComponent("specs/CUESYNC-9-findings.md")
}

private enum WorkflowFileGSK {
    static func contents() throws -> String {
        try String(contentsOf: RepoPathsGSK.workflow, encoding: .utf8)
    }
}

private struct JobBlockGSK {
    let text: String
    let lines: [String]

    func firstLineIndex(matching pattern: String, caseInsensitive: Bool = false) -> Int? {
        let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        return lines.firstIndex { $0.range(of: pattern, options: options) != nil }
    }

    func stepBlock(named namePattern: String, includingPrecedingComments: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let nameIndex = firstLineIndex(matching: #"name:\s*"# + namePattern) else {
            XCTFail("no step matching '\(namePattern)' found in job", file: file, line: line)
            return ""
        }
        var start = nameIndex
        if includingPrecedingComments {
            var cursor = nameIndex - 1
            while cursor >= 0, lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                start = cursor
                cursor -= 1
            }
        } else {
            start = nameIndex
        }
        var end = lines.count
        for i in (nameIndex + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- name:") || trimmed.hasPrefix("- uses:") {
                end = i
                break
            }
        }
        return lines[start..<end].joined(separator: "\n")
    }
}

private enum JobBlocksGSK {
    static func require(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> JobBlockGSK {
        let raw = try WorkflowFileGSK.contents()
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let allLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = allLines.firstIndex(of: "  \(name):") else {
            XCTFail("could not locate the top-level `\(name):` job in .github/workflows/swift-windows.yml",
                    file: file, line: line)
            return JobBlockGSK(text: "", lines: [])
        }
        var end = allLines.count
        for i in (start + 1)..<allLines.count {
            if allLines[i].range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil {
                end = i
                break
            }
        }
        let block = Array(allLines[start..<end])
        return JobBlockGSK(text: block.joined(separator: "\n"), lines: block)
    }
}
