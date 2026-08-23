import Foundation
import XCTest

// =============================================================================
// CUESYNC-9 §0.16 / step-4-contingency compliance — the GtkBackend Windows
// window-present patch (round 17, re-applying round 13's fix): its presence,
// placement, idempotency, read-only scoping, pin, disjoint hunk, and no-regression on
// the two prior patches, across all three GtkBackend-compiling CI legs (macos,
// windows-build, windows-test), and the checked-in `.patch` file itself.
//
// Root cause (findings §0.16, re-confirming §0.12): SwiftCrossUI shows the INITIAL
// WindowGroup window via backend.show(window:) on isFirstUpdate (gtk_widget_set_visible)
// and NEVER backend.activate(window:) — activate/present is reached only via
// openWindow(id:). On Windows, show maps but does not RAISE the surface, so the window
// stays behind the foreground cmd.exe launcher console the probe box starts CueSync.exe
// from — .factory/probe/before.png shows only that console + the PowerShell build
// console, no CueSync window. The patch makes GtkBackend.show also present() the initial
// window on Windows, via GTK's own gtk_window_present(). Round 13 added this same call;
// round 14 reverted it on the cairo-black + off-screen-cascade confounds §0.14/§0.15
// later invalidated (rounds 5–14 judged pixels of a window cairo was painting black),
// so round 17 re-applies it now that the confounds are lifted and the window paints
// real content at a favorable on-screen offset.
//
// This is a DIFFERENT patch, in a different function (show(window:)), from the
// round-9-reverted Win32-message-queue input patch (anchored at
// mainRunLoopTicklingLoop, findings §0.8) — that one's ABSENCE is locked by
// CUESYNC9WindowsInputDispatchWorkflowTests; this file locks the window-present
// patch's PRESENCE the way CUESYNC9WindowsGskRendererWorkflowTests locks the GSK
// patch's.
//
// Same rationale as the sibling GSK/input files: `swift test` is deterministic and
// network-free, so it cannot spin up a real Windows build box + click-probe gate to
// prove the window now raises — what it CAN verify is that the workflow declares the
// step the spec's step-4 contingency requires, in the order it requires, and that
// the checked-in `.patch` is a real, scoped, pinned unified diff. The YAML-scoping
// helpers are intentionally file-local (mirrors the repo convention of each
// compliance file keeping its own parser).
// =============================================================================

private let auditedRevisionWP = "a6d206370812e3b9edba259d167e848892c5013d"
private let windowPresentPatchRelativePath = "patches/swift-cross-ui-0.8.0-windows-window-present.patch"
private let gskPatchRelativePathWP = "patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch"
private let interactivityPatchRelativePathWP = "patches/swift-cross-ui-0.8.0-gtk-interactivity.patch"
// CUESYNC-9 round 20: CI delegates all patching to scripts/patch-swift-cross-ui.sh
// (see CUESYNC9WindowsGskRendererWorkflowTests' header for why). These guards moved
// with the behaviour: per-leg step structure became "the leg delegates to the script"
// plus "the script applies this patch, guarded and in order".
private let windowPresentStepNamePattern = #"name:\s*Patch swift-cross-ui \(all five"#

final class CUESYNC9WindowPresentPatchStepPlacementTests: XCTestCase {

    /// Every GtkBackend-compiling leg must delegate to the script, and the script must
    /// actually apply this patch — otherwise the delegation is a vacuous green.
    func testWindowPresentPatchStepExistsOnAllThreeGtkBackendCompilingLegs() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocksWP.require(jobName)
            XCTAssertNotNil(
                job.firstLineIndex(matching: windowPresentStepNamePattern),
                "\(jobName) must delegate patching to scripts/patch-swift-cross-ui.sh (CUESYNC-9 §0.12)")
        }
        let script = try String(contentsOf: RepoPathsWP.devScript, encoding: .utf8)
        XCTAssertTrue(script.contains("swift-cross-ui-0.8.0-windows-window-present.patch"),
            "scripts/patch-swift-cross-ui.sh must apply the window-present patch — CI delegates to it")
    }

    /// Apply order interactivity -> gsk -> window-present is now a property of the script.
    func testWindowPresentPatchStepRunsAfterTheGskPatchOnEveryLeg() throws {
        let script = try String(contentsOf: RepoPathsWP.devScript, encoding: .utf8)
        guard let gskIndex = script.range(of: "GSK_RENDERER_PATCH\"")?.lowerBound,
            let presentIndex = script.range(of: "WINDOW_PRESENT_PATCH\"")?.lowerBound
        else {
            XCTFail("scripts/patch-swift-cross-ui.sh must apply both the GSK and window-present patches")
            return
        }
        XCTAssertLessThan(gskIndex, presentIndex,
            "the GSK-renderer patch must be applied BEFORE the window-present patch (apply order " +
            "interactivity -> gsk -> window-present, specs/CUESYNC-9-findings.md §0.12)")
    }

    /// The patching step must still land before `swift build`/`swift test` compiles GtkBackend.
    func testWindowPresentPatchStepRunsBeforeBuildOrTestOnEveryLeg() throws {
        let expectations: [(job: String, pattern: String)] = [
            ("macos", #"run:\s*swift build -c release"#),
            ("windows-build", #"run:\s*swift build -c release"#),
            ("windows-test", #"swift test -c release"#),
        ]
        for (jobName, invocationPattern) in expectations {
            let job = try JobBlocksWP.require(jobName)
            guard let patchLine = job.firstLineIndex(matching: windowPresentStepNamePattern) else {
                XCTFail("\(jobName) has no patch step to order against build/test")
                continue
            }
            guard let invocationLine = job.firstLineIndex(matching: invocationPattern) else {
                XCTFail("\(jobName) must still invoke the expected build/test command")
                continue
            }
            XCTAssertLessThan(patchLine, invocationLine,
                "\(jobName)'s patch step must run BEFORE the build/test step that compiles " +
                "GtkBackend (CUESYNC-9 §0.12)")
        }
    }
}

final class CUESYNC9WindowPresentPatchIdempotencyAndScopeTests: XCTestCase {

    /// Idempotency is a property of the script every leg calls.
    func testWindowPresentPatchStepIsGuardedByReverseApplyCheckOnEveryLeg() throws {
        let script = try String(contentsOf: RepoPathsWP.devScript, encoding: .utf8)
        XCTAssertTrue(script.contains("git apply --reverse --check \"$WINDOW_PRESENT_PATCH\""),
            "the window-present patch must be guarded with `git apply --reverse --check` in " +
            "scripts/patch-swift-cross-ui.sh so a second run is a no-op")
    }

    /// Dependency sources check out read-only on Windows; the script clears that.
    func testWindowPresentPatchStepClearsWindowsReadOnlyFlagOnBothWindowsLegs() throws {
        let script = try String(contentsOf: RepoPathsWP.devScript, encoding: .utf8)
        XCTAssertTrue(script.contains("chmod -R u+w"),
            "scripts/patch-swift-cross-ui.sh must clear the read-only flag before patching")
    }

    /// NEW-STATE CHECK (round 20): every leg runs the SAME apply path, so CI can no
    /// longer apply a different patch set than the script — the drift that let CI
    /// build without the container-hit-testing and entry-styling patches entirely.
    func testWindowPresentPatchStepClearsReadOnlyOnExactlyGtkBackendSwiftNotOtherFiles() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocksWP.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui \(all five"#)
            XCTAssertTrue(block.contains("scripts/patch-swift-cross-ui.sh"),
                "\(jobName)'s patch step must invoke scripts/patch-swift-cross-ui.sh rather than " +
                "hand-rolling `git apply` per patch — one list, one order, no drift")
            XCTAssertFalse(block.contains("git apply"),
                "\(jobName) must not hand-roll `git apply` alongside the script — that is exactly how " +
                "the YAML came to apply only three of the five live patches")
        }
    }

    /// Pinned: the audited v0.8.0 commit must still be named where the patches are
    /// applied. Round 20 moved that from a per-leg YAML comment to the script every
    /// leg calls — one place, so it cannot go stale on one leg and not another.
    func testWindowPresentPatchStepNamesTheAuditedV080CommitOnEveryLeg() throws {
        let script = try String(contentsOf: RepoPathsWP.devScript, encoding: .utf8)
        XCTAssertTrue(script.contains(auditedRevisionWP),
            "scripts/patch-swift-cross-ui.sh — the single apply path every CI leg calls — must name " +
            "the audited v0.8.0 commit \(auditedRevisionWP)")
    }
}

final class CUESYNC9WindowPresentPatchFileTests: XCTestCase {

    func testWindowPresentPatchFileExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: RepoPathsWP.presentPatch.path),
            "\(windowPresentPatchRelativePath) must exist — the fix must be a checked-in, reviewable patch, " +
            "not an in-place dependency edit")
    }

    /// Targets only GtkBackend.swift, exactly one diff header.
    func testWindowPresentPatchTargetsOnlyGtkBackendSwift() throws {
        let patch = try String(contentsOf: RepoPathsWP.presentPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains("Sources/GtkBackend/GtkBackend.swift"),
            "the patch must touch Sources/GtkBackend/GtkBackend.swift (show(window:), the audited site)")
        let diffHeaderCount = patch.components(separatedBy: "diff --git a/").count - 1
        XCTAssertEqual(diffHeaderCount, 1,
            "the patch must touch exactly one file — found \(diffHeaderCount) diff --git headers")
    }

    /// A real unified diff, never sed/-replace.
    func testWindowPresentPatchFileIsARealUnifiedDiffNotATextSubstitutionScript() throws {
        let patch = try String(contentsOf: RepoPathsWP.presentPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains("diff --git a/Sources/GtkBackend/GtkBackend.swift b/Sources/GtkBackend/GtkBackend.swift"),
            "expected a real `diff --git` unified-diff header for GtkBackend.swift")
        XCTAssertFalse(patch.contains("-replace") || patch.contains("sed -i") || patch.contains("sed 's"),
            "the checked-in patch must be a real diff, not a -replace/sed text-substitution script")
    }

    /// Uses GTK's own API (gtk_window_present via Window.present()), Windows-only, and
    /// introduces no new dependency/network/dynamic-load.
    func testWindowPresentPatchUsesGtkWindowPresentWindowsGuardedWithNoNewDependency() throws {
        let patch = try String(contentsOf: RepoPathsWP.presentPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains("window.present()"),
            "the fix must raise the window via SwiftCrossUI's own Window.present() wrapper of gtk_window_present")
        XCTAssertTrue(patch.contains("#if os(Windows)"),
            "the fix must be guarded to Windows only — macOS/Linux keep their working gtk_widget_show default")
        // Scoped to ADDED lines only (same rationale as the GSK patch's equivalent
        // guard): unchanged diff context and header prose describe surrounding upstream
        // source, not bytes this patch injects, and must not trip a "no new dependency" scan.
        let addedLines = patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
            .joined(separator: "\n")
        XCTAssertTrue(addedLines.contains("window.present()"),
            "the ADDED lines (not just context) must contain the present() call")
        for banned in ["import ", "dlopen", "Process(", "URLSession", "http://", "https://", "@_silgen_name"] {
            XCTAssertFalse(addedLines.contains(banned),
                "the patch must not introduce '\(banned)' — no new dependency, no network, no dynamic load, " +
                "no private-symbol binding")
        }
    }

    /// No GtkFixed/absolute positioning introduced (DoD invariant).
    func testWindowPresentPatchDoesNotIntroduceGtkFixedOrAbsolutePositioning() throws {
        let patch = try String(contentsOf: RepoPathsWP.presentPatch, encoding: .utf8)
        XCTAssertFalse(patch.contains("Fixed("),
            "the window-present patch must not introduce a Gtk.Fixed/absolute-positioning usage")
    }

    /// LF-only bytes — a CRLF-corrupted diff fails `git apply` on the Windows legs.
    func testWindowPresentPatchFileContainsNoCarriageReturns() throws {
        let data = try Data(contentsOf: RepoPathsWP.presentPatch)
        XCTAssertFalse(data.contains(0x0D),
            "\(windowPresentPatchRelativePath) must be LF-only (no \\r) — a CRLF-corrupted diff can fail " +
            "`git apply` on the Windows legs this patch exists to fix")
    }

    /// Not a degenerate stub.
    func testWindowPresentPatchFileHasSubstantiveContentNotAnEmptyStub() throws {
        let patch = try String(contentsOf: RepoPathsWP.presentPatch, encoding: .utf8)
        let lineCount = patch.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertGreaterThan(lineCount, 15,
            "\(windowPresentPatchRelativePath) is suspiciously small (\(lineCount) lines) for a real, documented diff")
    }

    /// Kept SEPARATE from the other patches (one root cause per patch, independently revertable).
    func testWindowPresentPatchIsADistinctFileFromTheOtherPatches() {
        XCTAssertNotEqual(RepoPathsWP.presentPatch.path, RepoPathsWP.gskPatch.path)
        XCTAssertNotEqual(RepoPathsWP.presentPatch.path, RepoPathsWP.interactivityPatch.path)
    }
}

final class CUESYNC9WindowPresentDisjointHunkTests: XCTestCase {

    /// The window-present patch's GtkBackend.swift hunk is anchored at show(window:),
    /// disjoint from the interactivity hunk (createPathWidget), the GSK hunk
    /// (runMainLoop), and the reverted input patch's anchor (mainRunLoopTicklingLoop) —
    /// so all live patches apply cleanly in sequence.
    func testWindowPresentPatchTargetsShowWindowAnchorDisjointFromTheOtherHunks() throws {
        let present = try String(contentsOf: RepoPathsWP.presentPatch, encoding: .utf8)

        // Inspect only the unified-diff body (from the first `diff --git` on): the
        // header comment legitimately names other symbols to explain disjointness.
        guard let diffStart = present.range(of: "diff --git a/") else {
            XCTFail("window-present patch has no `diff --git` body")
            return
        }
        let presentDiffBody = String(present[diffStart.lowerBound...])

        XCTAssertTrue(presentDiffBody.contains("show(window:"),
            "the window-present patch's GtkBackend.swift hunk must be anchored at show(window:)")
        XCTAssertFalse(presentDiffBody.contains("createPathWidget"),
            "the window-present patch hunk must not touch createPathWidget — that is the CUESYNC-8 " +
            "interactivity patch's hunk")
        XCTAssertFalse(presentDiffBody.contains("runMainLoop"),
            "the window-present patch hunk must not touch runMainLoop — that is the GSK-renderer patch's hunk")
        XCTAssertFalse(presentDiffBody.contains("mainRunLoopTicklingLoop"),
            "the window-present patch hunk must not touch mainRunLoopTicklingLoop — that was the reverted " +
            "CUESYNC-9 input-dispatch patch's hunk (specs/CUESYNC-9-findings.md §0.8)")
        XCTAssertFalse(presentDiffBody.contains("g_setenv"),
            "the window-present patch must not contain the GSK-renderer fix (g_setenv)")
    }
}

final class CUESYNC9WindowPresentFindingsTests: XCTestCase {

    /// specs/CUESYNC-9-findings.md documents the round-17 re-application of the
    /// window-present root cause + fix (and retains §0.12's original diagnosis as trail).
    func testFindingsDocumentsRound17WindowPresentRootCauseAndFix() throws {
        let text = try String(contentsOf: RepoPathsWP.findings, encoding: .utf8)
        XCTAssertTrue(text.contains("§0.16"),
            "specs/CUESYNC-9-findings.md must contain a §0.16 section documenting the round-17 re-application")
        XCTAssertTrue(text.contains("gtk_window_present") || text.contains("window.present()"),
            "specs/CUESYNC-9-findings.md must document the gtk_window_present()/Window.present() fix")
        XCTAssertTrue(text.contains("show(window:"),
            "specs/CUESYNC-9-findings.md must cite the show(window:) site the initial window is only shown through")
        XCTAssertTrue(text.contains("Fork W"),
            "specs/CUESYNC-9-findings.md must keep classifying the failure as Fork W")
        XCTAssertTrue(text.contains(auditedRevisionWP),
            "specs/CUESYNC-9-findings.md must name the audited pinned commit \(auditedRevisionWP)")
    }
}

// MARK: - Helpers (deliberately file-local — see the file header rationale)

private enum RepoPathsWP {
    /// Tests/CueSyncCoreTests/<this file> -> Tests/CueSyncCoreTests -> Tests -> repo root
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let workflow = root.appendingPathComponent(".github/workflows/swift-windows.yml")
    static let presentPatch = root.appendingPathComponent(windowPresentPatchRelativePath)
    static let gskPatch = root.appendingPathComponent(gskPatchRelativePathWP)
    static let interactivityPatch = root.appendingPathComponent(interactivityPatchRelativePathWP)
    static let devScript = root.appendingPathComponent("scripts/patch-swift-cross-ui.sh")
    static let findings = root.appendingPathComponent("specs/CUESYNC-9-findings.md")
}

private enum WorkflowFileWP {
    static func contents() throws -> String {
        try String(contentsOf: RepoPathsWP.workflow, encoding: .utf8)
    }
}

private struct JobBlockWP {
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

private enum JobBlocksWP {
    static func require(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> JobBlockWP {
        let raw = try WorkflowFileWP.contents()
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let allLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = allLines.firstIndex(of: "  \(name):") else {
            XCTFail("could not locate the top-level `\(name):` job in .github/workflows/swift-windows.yml",
                    file: file, line: line)
            return JobBlockWP(text: "", lines: [])
        }
        var end = allLines.count
        for i in (start + 1)..<allLines.count {
            if allLines[i].range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil {
                end = i
                break
            }
        }
        let block = Array(allLines[start..<end])
        return JobBlockWP(text: block.joined(separator: "\n"), lines: block)
    }
}
