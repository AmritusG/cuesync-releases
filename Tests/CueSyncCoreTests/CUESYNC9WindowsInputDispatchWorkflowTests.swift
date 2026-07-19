import Foundation
import XCTest

// =============================================================================
// CUESYNC-9 §3/§8 compliance — the GtkBackend Windows input-dispatch patch: its
// presence, placement, idempotency, and no-regression on the CUESYNC-8 patch,
// across all three GtkBackend-compiling CI legs (macos, windows-build,
// windows-test), and the checked-in `.patch` file itself.
//
// Same style and rationale as CUESYNC8GtkInteractivityWorkflowTests: `swift test`
// is deterministic and network-free, so it cannot itself spin up a real Windows
// build box and click-probe gate to prove input is actually delivered — what it
// CAN verify is that the workflow declares the patch step the spec requires, in
// the order the spec requires, without the vacuous-green shapes earlier findings
// docs warn about. The YAML-scoping helpers below intentionally duplicate (rather
// than import) CUESYNC8GtkInteractivityWorkflowTests' equivalents — mirrors the
// existing repo convention (AdversarialSupplyChainTests' WorkflowParser,
// CUESYNC6WindowsGtkWorkflowTests' JobBlock/JobBlocks, CUESYNC8's own JobBlock8)
// of keeping each compliance-test file's YAML-parsing helpers self-contained.
// =============================================================================

private let auditedRevision = "a6d206370812e3b9edba259d167e848892c5013d"
private let windowsInputPatchRelativePath = "patches/swift-cross-ui-0.8.0-windows-input.patch"
private let interactivityPatchRelativePath = "patches/swift-cross-ui-0.8.0-gtk-interactivity.patch"

final class CUESYNC9WindowsInputPatchStepPlacementTests: XCTestCase {

    /// spec CUESYNC-9 §4/acceptance: the Windows input-dispatch patch step must exist
    /// on all three legs that compile GtkBackend (macos, windows-build, windows-test).
    func testWindowsInputPatchStepExistsOnAllThreeGtkBackendCompilingLegs() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            XCTAssertNotNil(
                job.firstLineIndex(matching: #"name:\s*Patch swift-cross-ui Windows input dispatch"#),
                "\(jobName) must declare a 'Patch swift-cross-ui Windows input dispatch' step (spec CUESYNC-9 §4)")
        }
    }

    /// spec CUESYNC-9 §4: "runs after resolve/existing patches and before build/test."
    /// The new step must come after the CUESYNC-8 interactivity patch step on every leg.
    func testWindowsInputPatchStepRunsAfterTheCUESYNC8InteractivityPatchOnEveryLeg() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            guard let interactivityLine = job.firstLineIndex(matching: #"name:\s*Patch swift-cross-ui GTK interactivity"#) else {
                XCTFail("\(jobName) has no CUESYNC-8 interactivity-patch step to order against")
                continue
            }
            guard let windowsInputLine = job.firstLineIndex(matching: #"name:\s*Patch swift-cross-ui Windows input dispatch"#) else {
                XCTFail("\(jobName) has no Windows input-dispatch patch step to order")
                continue
            }
            XCTAssertGreaterThan(windowsInputLine, interactivityLine,
                "\(jobName)'s Windows input-dispatch patch step must run AFTER the existing CUESYNC-8 " +
                "interactivity patch step (spec CUESYNC-9 §4)")
        }
    }

    /// spec CUESYNC-9 §4: the patch must land before `swift build`/`swift test` actually
    /// compiles GtkBackend, on every leg.
    func testWindowsInputPatchStepRunsBeforeBuildOrTestOnEveryLeg() throws {
        let expectations: [(job: String, pattern: String)] = [
            ("macos", #"run:\s*swift build -c release"#),
            ("windows-build", #"run:\s*swift build -c release"#),
            ("windows-test", #"swift test -c release"#),
        ]
        for (jobName, invocationPattern) in expectations {
            let job = try JobBlocks9.require(jobName)
            guard let patchLine = job.firstLineIndex(matching: #"name:\s*Patch swift-cross-ui Windows input dispatch"#) else {
                XCTFail("\(jobName) has no Windows input-dispatch patch step to order against build/test")
                continue
            }
            guard let invocationLine = job.firstLineIndex(matching: invocationPattern) else {
                XCTFail("\(jobName) must still invoke the expected build/test command")
                continue
            }
            XCTAssertLessThan(patchLine, invocationLine,
                "\(jobName)'s Windows input-dispatch patch step must run BEFORE the build/test step that " +
                "actually compiles GtkBackend (spec CUESYNC-9 §4)")
        }
    }
}

final class CUESYNC9WindowsInputPatchIdempotencyAndPinTests: XCTestCase {

    /// spec CUESYNC-9 §4: "idempotent (git apply --reverse --check)."
    func testWindowsInputPatchStepIsGuardedByReverseApplyCheckOnEveryLeg() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui Windows input dispatch"#)
            XCTAssertTrue(block.contains("git apply --reverse --check"),
                "\(jobName)'s Windows input-dispatch patch step must guard re-application with " +
                "`git apply --reverse --check` (spec CUESYNC-9 §4) so a second run is a no-op")
        }
    }

    /// spec CUESYNC-9 §4: "clears the Windows read-only flag on exactly the file(s) it
    /// patches." Windows-only requirement, same as CUESYNC-8's equivalent.
    func testWindowsInputPatchStepClearsWindowsReadOnlyFlagOnBothWindowsLegs() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui Windows input dispatch"#)
            XCTAssertTrue(block.contains("IsReadOnly"),
                "\(jobName)'s Windows input-dispatch patch step must clear the Windows read-only flag " +
                "(Set-ItemProperty ... -Name IsReadOnly -Value $false) before patching")
        }
    }

    /// spec CUESYNC-9 §4: "pinned in a comment naming commit a6d206370812e3b9edba259d167e848892c5013d."
    func testWindowsInputPatchStepNamesTheAuditedV080CommitOnEveryLeg() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui Windows input dispatch"#, includingPrecedingComments: true)
            XCTAssertTrue(block.contains(auditedRevision),
                "\(jobName)'s Windows input-dispatch patch step (or its immediately preceding comment) must " +
                "name the audited v0.8.0 commit \(auditedRevision) (spec CUESYNC-9 §4)")
        }
    }

    /// spec CUESYNC-9 acceptance: the pin stays exact: "0.8.0"; Package.resolved is
    /// untouched by this ticket.
    func testSwiftCrossUIPinIsUnchangedByThisTicket() throws {
        let manifest = try String(contentsOf: RepoPaths9.packageSwift, encoding: .utf8)
        XCTAssertTrue(manifest.contains(#"exact: "0.8.0""#),
            "Package.swift must keep swift-cross-ui pinned to exact: \"0.8.0\"")

        let resolvedData = try Data(contentsOf: RepoPaths9.packageResolved)
        let json = try JSONSerialization.jsonObject(with: resolvedData) as? [String: Any]
        let pins = (json?["pins"] as? [[String: Any]])
            ?? ((json?["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
        for pin in pins {
            let identity = ((pin["identity"] as? String) ?? (pin["package"] as? String) ?? "").lowercased()
            guard identity == "swift-cross-ui" else { continue }
            let revision = (pin["state"] as? [String: Any])?["revision"] as? String
            XCTAssertEqual(revision, auditedRevision,
                "Package.resolved's swift-cross-ui pin must stay exactly the audited revision")
            return
        }
        XCTFail("Package.resolved contains no swift-cross-ui pin at all")
    }
}

final class CUESYNC9PatchFileTests: XCTestCase {

    /// spec CUESYNC-9 §4/acceptance: "a new checked-in patches/swift-cross-ui-0.8.0-windows-input.patch
    /// exists."
    func testWindowsInputPatchFileExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: RepoPaths9.windowsInputPatch.path),
            "\(windowsInputPatchRelativePath) must exist — spec CUESYNC-9 requires the fix be a checked-in, " +
            "reviewable patch, not an in-place dependency edit")
    }

    /// spec CUESYNC-9 acceptance: "targets only the file(s) named in the findings" —
    /// findings §2.5/§3 name Sources/GtkBackend/GtkBackend.swift as the sole root-cause
    /// site (mainRunLoopTicklingLoop).
    func testWindowsInputPatchTargetsOnlyGtkBackendSwift() throws {
        let patch = try String(contentsOf: RepoPaths9.windowsInputPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains("Sources/GtkBackend/GtkBackend.swift"),
            "the patch must touch Sources/GtkBackend/GtkBackend.swift (mainRunLoopTicklingLoop, the " +
            "audited root cause per specs/CUESYNC-9-findings.md §2.5/§3)")
        let diffHeaderCount = patch.components(separatedBy: "diff --git a/").count - 1
        XCTAssertEqual(diffHeaderCount, 1,
            "the patch must touch exactly one file (Sources/GtkBackend/GtkBackend.swift) — found " +
            "\(diffHeaderCount) diff --git headers")
    }

    /// spec CUESYNC-9 acceptance: "never sed/-replace"; must be a real unified diff.
    func testWindowsInputPatchFileIsARealUnifiedDiffNotATextSubstitutionScript() throws {
        let patch = try String(contentsOf: RepoPaths9.windowsInputPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains("diff --git a/Sources/GtkBackend/GtkBackend.swift b/Sources/GtkBackend/GtkBackend.swift"),
            "expected a real `diff --git` unified-diff header for GtkBackend.swift")
        XCTAssertFalse(patch.contains("-replace") || patch.contains("sed -i") || patch.contains("sed 's"),
            "the checked-in patch must be a real diff, not a -replace/sed text-substitution script " +
            "(spec CUESYNC-9 §4: \"never sed/-replace\")")
    }

    /// spec CUESYNC-9 acceptance: "uses GTK/GLib's own APIs — no new dependency, no
    /// network, no dynamic load." Structural proxy: the fix must call GLib's own
    /// g_main_context_iteration, guarded to Windows only, and must not introduce any
    /// new package/network/dlopen call.
    func testWindowsInputPatchUsesGLibsOwnAPIWithNoNewDependency() throws {
        let patch = try String(contentsOf: RepoPaths9.windowsInputPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains("g_main_context_iteration"),
            "the fix must drain GLib's own default GMainContext via g_main_context_iteration — GTK/GLib's " +
            "own public API, not a new dependency")
        XCTAssertTrue(patch.contains("#if os(Windows)"),
            "the fix must be guarded to Windows only — the message-queue-ownership race is Windows-specific " +
            "(findings §2.5), Linux has no Win32 message queue to race for")
        // Only ADDED lines ('+', excluding the '+++' file header) are bytes this patch
        // injects into GtkBackend.swift. Context lines and the `@@ … @@` hunk headers
        // reproduce unchanged upstream source — round 7's `@_silgen_name` insertion
        // point sits directly below the existing `import SwiftCrossUI` / `import
        // GtkCHelpers`, so those imports appear as diff context and must NOT trip a
        // "no new dependency" guard. Scoped to added lines, mirroring the Python
        // adversarial suite's ATTACK 48 (`_win_input_added_lines`), which already
        // scanned only added lines here.
        let addedLines = patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
            .joined(separator: "\n")
        for banned in ["import ", "dlopen", "Process(", "URLSession", "http://", "https://"] {
            XCTAssertFalse(addedLines.contains(banned),
                "the patch must not introduce '\(banned)' — no new dependency, no network, no dynamic load " +
                "(spec CUESYNC-9 threat model)")
        }
    }

    /// spec CUESYNC-9 acceptance: "no GtkFixed/absolute-position API is introduced
    /// anywhere (patch or app code)" — re-asserted here for this specific patch file,
    /// mirroring CUESYNC8NoGtkFixedOrAbsolutePositioningIntroducedTests.
    func testWindowsInputPatchDoesNotIntroduceGtkFixedOrAbsolutePositioning() throws {
        let patch = try String(contentsOf: RepoPaths9.windowsInputPatch, encoding: .utf8)
        XCTAssertFalse(patch.contains("Fixed("),
            "the Windows input-dispatch patch must not introduce a new Gtk.Fixed/absolute-positioning usage " +
            "(spec CUESYNC-9 acceptance criteria)")
    }

    /// The patch must be kept SEPARATE from the CUESYNC-8 interactivity patch (spec §4:
    /// "kept separate ... so each patch documents exactly one root cause").
    func testWindowsInputPatchIsAFileDistinctFromTheCUESYNC8InteractivityPatch() {
        XCTAssertNotEqual(RepoPaths9.windowsInputPatch.path, RepoPaths9.interactivityPatch.path,
            "the Windows input-dispatch patch must be a separate checked-in file from the CUESYNC-8 " +
            "interactivity patch")
    }
}

final class CUESYNC9FindingsFileTests: XCTestCase {

    /// spec CUESYNC-9 §1/acceptance: "specs/CUESYNC-9-findings.md exists, classifies the
    /// failure as Fork W or Fork D ... and names one root cause with file:line citations."
    func testFindingsFileExistsAndClassifiesForkAndNamesRootCause() throws {
        guard FileManager.default.fileExists(atPath: RepoPaths9.findings.path) else {
            XCTFail("specs/CUESYNC-9-findings.md must exist (spec CUESYNC-9 §1/§3)")
            return
        }
        let text = try String(contentsOf: RepoPaths9.findings, encoding: .utf8)
        XCTAssertTrue(text.contains("Fork W") || text.contains("Fork D"),
            "specs/CUESYNC-9-findings.md must classify the failure into Fork W or Fork D (spec §1)")
        XCTAssertTrue(text.contains("GtkBackend.swift"),
            "specs/CUESYNC-9-findings.md must cite file:line locations in GtkBackend.swift for the root cause")
        XCTAssertTrue(text.contains(auditedRevision),
            "specs/CUESYNC-9-findings.md must name the audited pinned commit \(auditedRevision)")
    }
}

final class CUESYNC9NoRegressionOnCUESYNC8PatchTests: XCTestCase {

    /// spec CUESYNC-9 acceptance: "the CUESYNC-8 interactivity patch is unchanged — still
    /// targets exactly Widget.swift + GtkBackend.swift, can-target hunk intact."
    func testCUESYNC8InteractivityPatchStillTargetsExactlyItsTwoAuditedFiles() throws {
        let patch = try String(contentsOf: RepoPaths9.interactivityPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains("diff --git a/Sources/Gtk/Widgets/Widget.swift b/Sources/Gtk/Widgets/Widget.swift"),
            "the CUESYNC-8 patch must still touch Sources/Gtk/Widgets/Widget.swift — CUESYNC-9 must not " +
            "regress it")
        XCTAssertTrue(patch.contains("diff --git a/Sources/GtkBackend/GtkBackend.swift b/Sources/GtkBackend/GtkBackend.swift"),
            "the CUESYNC-8 patch must still touch Sources/GtkBackend/GtkBackend.swift — CUESYNC-9 must not " +
            "regress it")
        XCTAssertTrue(patch.contains(#""can-target""#) && patch.contains("canTarget = false"),
            "the CUESYNC-8 patch's can-target hunk must stay intact (spec CUESYNC-9 acceptance criteria)")
    }

    /// The two patches must apply cleanly in sequence against the pinned checkout —
    /// this is exercised for real by scripts/patch-swift-cross-ui.sh and the CI workflow
    /// (both apply interactivity first, then windows-input), so this test only pins the
    /// STATIC ordering invariant that would make that sequential application fail: the
    /// windows-input patch's hunk context must not overlap a line range the interactivity
    /// patch also touches in the same file (both touch GtkBackend.swift, but at disjoint
    /// line ranges — mainRunLoopTicklingLoop vs. createPathWidget).
    func testBothPatchesTargetDisjointLineRangesWithinGtkBackendSwift() throws {
        let interactivity = try String(contentsOf: RepoPaths9.interactivityPatch, encoding: .utf8)
        let windowsInput = try String(contentsOf: RepoPaths9.windowsInputPatch, encoding: .utf8)
        XCTAssertTrue(interactivity.contains("createPathWidget"),
            "sanity check: the CUESYNC-8 patch's GtkBackend.swift hunk is anchored at createPathWidget")
        XCTAssertTrue(windowsInput.contains("mainRunLoopTicklingLoop"),
            "sanity check: the CUESYNC-9 patch's GtkBackend.swift hunk is anchored at mainRunLoopTicklingLoop")
        XCTAssertFalse(windowsInput.contains("createPathWidget"),
            "the windows-input patch must not touch createPathWidget — that is the CUESYNC-8 patch's " +
            "hunk, and touching it here would risk a merge/apply conflict between the two patches")
        XCTAssertFalse(interactivity.contains("mainRunLoopTicklingLoop"),
            "the interactivity patch must not touch mainRunLoopTicklingLoop — that is the CUESYNC-9 " +
            "patch's hunk, kept separate per spec §4")
    }
}

final class CUESYNC9DevScriptAppliesBothPatchesTests: XCTestCase {

    /// spec CUESYNC-9 acceptance: "scripts/patch-swift-cross-ui.sh applies the new patch
    /// too, in executable code, idempotently and fail-fast."
    func testDevScriptReferencesBothPatchFilesInExecutableCode() throws {
        let codeOnly = try codeOnlyDevScript()
        XCTAssertTrue(codeOnly.contains(windowsInputPatchRelativePath),
            "scripts/patch-swift-cross-ui.sh must apply \(windowsInputPatchRelativePath) in executable " +
            "code, not just describe it in a comment")
        XCTAssertTrue(codeOnly.contains(interactivityPatchRelativePath),
            "scripts/patch-swift-cross-ui.sh must still apply the existing CUESYNC-8 interactivity patch " +
            "too — this ticket must not remove it")
    }

    /// The Windows-input application must be idempotent and must actually apply the
    /// patch (not merely check it) — same requirement CUESYNC8DevScriptMirrorsCIPatchStepTests
    /// pins for the interactivity patch.
    func testDevScriptAppliesWindowsInputPatchIdempotentlyAndActually() throws {
        let codeOnly = try codeOnlyDevScript()
        let reverseCheckCount = codeOnly.components(separatedBy: "git apply --reverse --check").count - 1
        XCTAssertGreaterThanOrEqual(reverseCheckCount, 2,
            "scripts/patch-swift-cross-ui.sh must guard EACH patch (interactivity and windows-input) " +
            "with its own `git apply --reverse --check` — found only \(reverseCheckCount) guard(s)")

        let withoutGuardChecks = codeOnly.replacingOccurrences(of: "git apply --reverse --check", with: "")
        let plainApplyCount = withoutGuardChecks.components(separatedBy: "git apply ").count - 1
        XCTAssertGreaterThanOrEqual(plainApplyCount, 2,
            "scripts/patch-swift-cross-ui.sh must contain a plain `git apply` call for EACH patch, " +
            "distinct from the `--reverse --check` guards — found only \(plainApplyCount)")
    }

    /// Shell-script quality guard, re-asserted for this ticket's edit to the script.
    func testDevScriptStillFailsFastOnAnyError() throws {
        let codeOnly = try codeOnlyDevScript()
        XCTAssertTrue(codeOnly.contains("set -euo pipefail") || codeOnly.contains("set -eu") || codeOnly.contains("set -e"),
            "scripts/patch-swift-cross-ui.sh must keep fail-fast shell options (set -euo pipefail)")
    }

    private func codeOnlyDevScript() throws -> String {
        let text = try String(contentsOf: RepoPaths9.devScript, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }
}

final class CUESYNC9AgentsLessonFileTests: XCTestCase {

    /// spec CUESYNC-9 §7/acceptance: "agents/uiux.md gains a new section stating the
    /// window/main-loop input-death lesson ... in addition to the existing can-target
    /// section, which stays."
    func testAgentsUiuxGainsANewWindowMainLoopSectionAndKeepsTheExistingCanTargetSection() throws {
        let text = try String(contentsOf: RepoPaths9.agentsUiux, encoding: .utf8)
        XCTAssertTrue(text.lowercased().contains("can-target") || text.lowercased().contains("cantarget"),
            "agents/uiux.md must still contain the existing CUESYNC-8 can-target section (must not be removed)")
        XCTAssertTrue(text.lowercased().contains("main loop") || text.lowercased().contains("main-loop"),
            "agents/uiux.md must gain a new section about the window/main-loop input-death lesson (spec §7)")
        XCTAssertTrue(text.contains("CUESYNC-9"),
            "agents/uiux.md's new section must ground the generalized rule in the concrete CUESYNC-9 instance")
    }
}

final class CUESYNC9NoLinuxOrArmRunnerRegressionTests: XCTestCase {

    /// spec CUESYNC-9 acceptance: "no Linux or Windows-ARM64 runner is added to the
    /// matrix." Re-asserted here (CUESYNC6WindowsGtkWorkflowTests already covers the
    /// general shape) so this ticket's own compliance file records the check too.
    func testWorkflowStillHasExactlyThreeJobsNoLinuxOrArm64Added() throws {
        let raw = try String(contentsOf: RepoPaths9.workflow, encoding: .utf8)
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        for bannedJobName in ["  linux:", "  ubuntu:", "  windows-arm64:", "  windows-arm:"] {
            XCTAssertFalse(normalized.contains(bannedJobName),
                "swift-windows.yml must not gain a '\(bannedJobName.trimmingCharacters(in: .whitespaces))' job")
        }
    }
}

final class CUESYNC9FindingsRulesOutOtherSuspectsTests: XCTestCase {

    /// spec CUESYNC-9 §3/acceptance: "names one root cause with file:line citations,
    /// ruling out the other suspects." "Rule out the other two with evidence, not
    /// vibes." Behavioural check that the findings doc actually disposes of suspect
    /// (2), not merely mentions it in passing.
    func testFindingsRulesOutSuspectTwoModalOrInvisibleGrabWithEvidence() throws {
        let text = try String(contentsOf: RepoPaths9.findings, encoding: .utf8)
        guard let suspectLine = text.range(of: #"Suspect \(2\)"#, options: .regularExpression) else {
            XCTFail("specs/CUESYNC-9-findings.md must name suspect (2) — modal/invisible grab")
            return
        }
        let tail = text[suspectLine.lowerBound...].prefix(400)
        XCTAssertTrue(tail.contains("ruled out"),
            "specs/CUESYNC-9-findings.md must rule out suspect (2) with evidence near where it is named, " +
            "not just assert the winning suspect (spec §3: \"rule out the other two with evidence\")")
    }

    /// Same as above for suspect (3) — window-level flags.
    func testFindingsRulesOutSuspectThreeWindowLevelFlagsWithEvidence() throws {
        let text = try String(contentsOf: RepoPaths9.findings, encoding: .utf8)
        guard let suspectLine = text.range(of: #"Suspect \(3\)"#, options: .regularExpression) else {
            XCTFail("specs/CUESYNC-9-findings.md must name suspect (3) — window-level flags")
            return
        }
        let tail = text[suspectLine.lowerBound...].prefix(400)
        XCTAssertTrue(tail.contains("ruled out"),
            "specs/CUESYNC-9-findings.md must rule out suspect (3) with evidence near where it is named " +
            "(spec §3: \"rule out the other two with evidence\")")
    }
}

final class CUESYNC9WindowsInputPatchReadOnlyScopeTests: XCTestCase {

    /// spec CUESYNC-9 §4/acceptance: "clears the Windows read-only flag first on
    /// EXACTLY the file(s) it patches." The windows-input patch touches only
    /// GtkBackend.swift (not Widget.swift, which is the CUESYNC-8 patch's file) —
    /// the read-only clear on both Windows legs must be scoped to that one file,
    /// never widened to also cover Widget.swift or a blanket `-Recurse`.
    func testWindowsInputPatchStepClearsReadOnlyOnExactlyGtkBackendSwiftNotOtherFiles() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui Windows input dispatch"#)
            XCTAssertTrue(block.contains("GtkBackend.swift"),
                "\(jobName)'s Windows input-dispatch patch step must clear the read-only flag naming " +
                "GtkBackend.swift specifically")
            XCTAssertFalse(block.contains("Widget.swift"),
                "\(jobName)'s Windows input-dispatch patch step must not touch Widget.swift — that is the " +
                "CUESYNC-8 interactivity patch's file, out of scope for this step (spec §4: \"exactly the " +
                "file(s) it patches\")")
            XCTAssertFalse(block.contains("-Recurse"),
                "\(jobName)'s read-only clear must target the one named file, not recurse over the checkout")
        }
    }
}

final class CUESYNC9PatchFilePlatformQuirkTests: XCTestCase {

    /// Platform-quirk edge case: `git apply` is sensitive to line-ending corruption,
    /// and this exact patch is applied on Windows runners (windows-build/windows-test)
    /// where a checkout-time autocrlf setting could silently rewrite a checked-in LF
    /// patch to CRLF, breaking `git apply` on precisely the platform this ticket
    /// targets. The checked-in patch bytes must stay LF-only.
    func testWindowsInputPatchFileContainsNoCarriageReturns() throws {
        let data = try Data(contentsOf: RepoPaths9.windowsInputPatch)
        XCTAssertFalse(data.contains(0x0D),
            "\(windowsInputPatchRelativePath) must be LF-only (no \\r) — a CRLF-corrupted unified diff can " +
            "fail `git apply` on the Windows legs this patch exists to fix")
    }

    /// Empty-input/stub-file edge case: guards against a placeholder patch file that
    /// satisfies the string-content assertions above via a minimal/degenerate diff
    /// (e.g. a single near-empty hunk) rather than the real fix.
    func testWindowsInputPatchFileHasSubstantiveContentNotAnEmptyStub() throws {
        let patch = try String(contentsOf: RepoPaths9.windowsInputPatch, encoding: .utf8)
        let lineCount = patch.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertGreaterThan(lineCount, 20,
            "\(windowsInputPatchRelativePath) is suspiciously small (\(lineCount) lines) for a real, " +
            "documented unified diff with rationale comments")
    }

    /// Platform-quirk edge case, extended to the FIRST patch in the apply order.
    /// The windows-input and windows-gsk-renderer patches (this class and
    /// CUESYNC9GskRendererPatchFileTests) both guard against CRLF corruption, but
    /// neither this suite nor CUESYNC8GtkInteractivityWorkflowTests ever wrote the
    /// same guard for the CUESYNC-8 gtk-interactivity patch — even though it applies
    /// on the identical two Windows legs, and applies FIRST (interactivity ->
    /// windows-input -> gsk-renderer, per scripts/patch-swift-cross-ui.sh and
    /// swift-windows.yml). A CRLF-corrupted interactivity patch would fail `git
    /// apply` before the other two are even attempted, breaking every
    /// GtkBackend-compiling leg — exactly the failure mode this ticket's own
    /// no-regression requirement ("the CUESYNC-8 interactivity patch is unchanged")
    /// exists to catch.
    func testCUESYNC8InteractivityPatchFileContainsNoCarriageReturns() throws {
        let data = try Data(contentsOf: RepoPaths9.interactivityPatch)
        XCTAssertFalse(data.contains(0x0D),
            "\(interactivityPatchRelativePath) must be LF-only (no \\r) — a CRLF-corrupted unified diff " +
            "would fail `git apply` on the Windows legs, ahead of the windows-input and gsk-renderer " +
            "patches this suite already guards")
    }
}

// MARK: - Helpers (deliberately file-local — see the file header rationale)

private enum RepoPaths9 {
    /// Tests/CueSyncCoreTests/<this file> -> Tests/CueSyncCoreTests -> Tests -> repo root
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let packageSwift = root.appendingPathComponent("Package.swift")
    static let packageResolved = root.appendingPathComponent("Package.resolved")
    static let workflow = root.appendingPathComponent(".github/workflows/swift-windows.yml")
    static let windowsInputPatch = root.appendingPathComponent(windowsInputPatchRelativePath)
    static let interactivityPatch = root.appendingPathComponent(interactivityPatchRelativePath)
    static let devScript = root.appendingPathComponent("scripts/patch-swift-cross-ui.sh")
    static let findings = root.appendingPathComponent("specs/CUESYNC-9-findings.md")
    static let agentsUiux = root.appendingPathComponent("agents/uiux.md")
}

private enum WorkflowFile9 {
    static func contents() throws -> String {
        try String(contentsOf: RepoPaths9.workflow, encoding: .utf8)
    }
}

/// A single top-level GitHub Actions job's YAML text. Mirrors
/// CUESYNC8GtkInteractivityWorkflowTests' JobBlock8 (kept file-local rather than
/// shared — see file header).
private struct JobBlock9 {
    let text: String
    let lines: [String]

    func firstLineIndex(matching pattern: String, caseInsensitive: Bool = false) -> Int? {
        let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        return lines.firstIndex { $0.range(of: pattern, options: options) != nil }
    }

    /// Text of one `- name: <matching namePattern>` step, from its `name:` line up
    /// to (not including) the next `- name:`/`- uses:` step at the same indent, or
    /// end of job. `includingPrecedingComments` widens the start to also capture
    /// the contiguous `#`-comment block immediately above the step.
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

private enum JobBlocks9 {
    static func require(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> JobBlock9 {
        let raw = try WorkflowFile9.contents()
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let allLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = allLines.firstIndex(of: "  \(name):") else {
            XCTFail("could not locate the top-level `\(name):` job in .github/workflows/swift-windows.yml",
                    file: file, line: line)
            return JobBlock9(text: "", lines: [])
        }
        var end = allLines.count
        for i in (start + 1)..<allLines.count {
            if allLines[i].range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil {
                end = i
                break
            }
        }
        let block = Array(allLines[start..<end])
        return JobBlock9(text: block.joined(separator: "\n"), lines: block)
    }
}
