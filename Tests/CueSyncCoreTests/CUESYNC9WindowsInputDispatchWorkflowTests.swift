import Foundation
import XCTest

// =============================================================================
// CUESYNC-9 §3/§8/§0.8 compliance — round 9's REVERT of the GtkBackend Windows
// input-dispatch patch shipped in rounds 1-2/7.
//
// specs/CUESYNC-9-findings.md §0.7 proved from the app's OWN auditable Windows
// stderr that the real input death was an unsatisfiable-window-minimum relayout
// loop (fixed in CueSync/CueSync/UI/CueSyncApp.swift), independent of the
// Win32-message-queue race `windows-input.patch` targeted — and §0.7 explicitly
// flagged that patch "do not treat it as load-bearing." §0.8 (round 9) acted on
// that: the patch file, its three CI `git apply` steps, and its dev-script
// application were all removed per spec step 5 ("never stack speculative
// patches"). This file, which used to assert the patch's presence/placement/
// idempotency, now asserts its ABSENCE — durable regression locks so the
// disproven patch cannot silently reappear on a leg or in the dev loop.
//
// Same style and rationale as CUESYNC8GtkInteractivityWorkflowTests: `swift test`
// is deterministic and network-free, so it cannot itself spin up a real Windows
// build box and click-probe gate — what it CAN verify is what the workflow
// declares (or, now, no longer declares), without the vacuous-green shapes
// earlier findings docs warn about. The YAML-scoping helpers below intentionally
// duplicate (rather than import) CUESYNC8GtkInteractivityWorkflowTests'
// equivalents — mirrors the existing repo convention (AdversarialSupplyChainTests'
// WorkflowParser, CUESYNC6WindowsGtkWorkflowTests' JobBlock/JobBlocks, CUESYNC8's
// own JobBlock8) of keeping each compliance-test file's YAML-parsing helpers
// self-contained.
// =============================================================================

private let auditedRevision = "a6d206370812e3b9edba259d167e848892c5013d"
private let windowsInputPatchRelativePath = "patches/swift-cross-ui-0.8.0-windows-input.patch"
private let interactivityPatchRelativePath = "patches/swift-cross-ui-0.8.0-gtk-interactivity.patch"
private let gskPatchRelativePath = "patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch"
// CUESYNC-9 round 17 (specs/CUESYNC-9-findings.md §0.16): the re-applied window-present
// patch — a THIRD live patch on GtkBackend.swift, distinct in root cause/file-region/
// mechanism from the round-9-reverted windows-input patch above (this one anchors at
// show(window:) and gtk_window_present()s the initial window; that one anchored at
// mainRunLoopTicklingLoop).
private let windowsWindowPresentPatchRelativePath = "patches/swift-cross-ui-0.8.0-windows-window-present.patch"
/// CUESYNC-9 round 18 (specs/CUESYNC-9-findings.md §0.17) — the patch that restored
/// input by deriving a layout container's `can-target` from its children.
private let containerHitTestingPatchRelativePath = "patches/swift-cross-ui-0.8.0-gtk-container-hit-testing.patch"
/// CUESYNC-9 round 19 (specs/CUESYNC-9-findings.md §0.18) — GtkEntry paint fix so the
/// app's .foregroundColor/.background reach the entry instead of being discarded.
private let entryStylingPatchRelativePath = "patches/swift-cross-ui-0.8.0-gtk-entry-styling.patch"
private let windowsInputStepNamePattern = #"name:\s*Patch swift-cross-ui Windows input dispatch"#

final class CUESYNC9WindowsInputPatchStepPlacementTests: XCTestCase {

    /// REGRESSION LOCK (round 9, specs/CUESYNC-9-findings.md §0.8): the Windows
    /// input-dispatch patch step must be ABSENT on all three legs that compile
    /// GtkBackend (macos, windows-build, windows-test) — it was reverted as a
    /// disproven, non-load-bearing patch per spec step 5. Was: "step must exist."
    func testWindowsInputPatchStepIsAbsentOnAllThreeGtkBackendCompilingLegs() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            XCTAssertNil(
                job.firstLineIndex(matching: windowsInputStepNamePattern),
                "\(jobName) must NOT declare a 'Patch swift-cross-ui Windows input dispatch' step — " +
                "reverted in round 9 (specs/CUESYNC-9-findings.md §0.8); its reappearance is a regression")
        }
    }

    /// REGRESSION LOCK (round 9): no step named "Patch swift-cross-ui Windows input
    /// dispatch" exists anywhere in the region between the CUESYNC-8 interactivity
    /// step and the GSK-renderer step that now runs immediately after it — the exact
    /// slot the reverted step used to occupy. Was: "runs after the interactivity patch."
    /// UPDATED round 20: the interactivity and GSK steps no longer exist as separate
    /// YAML anchors — every leg delegates to scripts/patch-swift-cross-ui.sh. The
    /// regression lock is unchanged in intent: the reverted input-dispatch patch must
    /// not reappear in the apply path, which is now the script.
    func testNoWindowsInputPatchStepExistsBetweenTheInteractivityAndGskStepsOnEveryLeg() throws {
        let script = try String(contentsOf: RepoPaths9.devScript, encoding: .utf8)
        XCTAssertFalse(script.contains("windows-input.patch"),
            "scripts/patch-swift-cross-ui.sh must not apply the round-9-reverted windows-input patch " +
            "(specs/CUESYNC-9-findings.md §0.8)")
        guard let interactivityIndex = script.range(of: "INTERACTIVITY_PATCH\"")?.lowerBound,
            let gskIndex = script.range(of: "GSK_RENDERER_PATCH\"")?.lowerBound
        else {
            XCTFail("the script must apply both the interactivity and GSK patches")
            return
        }
        XCTAssertLessThan(interactivityIndex, gskIndex,
            "interactivity must still be applied before the GSK-renderer patch — the slot between " +
            "them was vacated by round 9's revert and must stay empty")
    }

    /// REGRESSION LOCK (round 9): the literal step name never appears anywhere in a
    /// job's text at all (whole-block substring sweep, not just a line-anchored
    /// regex), on every leg, ahead of the build/test invocation that used to follow
    /// it. Was: "runs before build/test."
    func testWindowsInputPatchStepNameNeverAppearsInAnyJobBlockOnEveryLeg() throws {
        let expectations: [(job: String, pattern: String)] = [
            ("macos", #"run:\s*swift build -c release"#),
            ("windows-build", #"run:\s*swift build -c release"#),
            ("windows-test", #"swift test -c release"#),
        ]
        for (jobName, invocationPattern) in expectations {
            let job = try JobBlocks9.require(jobName)
            XCTAssertFalse(job.text.contains("Patch swift-cross-ui Windows input dispatch"),
                "\(jobName): the reverted step's literal name must not appear anywhere in the job block")
            XCTAssertNotNil(job.firstLineIndex(matching: invocationPattern),
                "\(jobName) must still invoke the expected build/test command")
        }
    }
}

final class CUESYNC9WindowsInputPatchIdempotencyAndPinTests: XCTestCase {

    /// REGRESSION LOCK (round 9): no job block anywhere contains a step named
    /// "Patch swift-cross-ui Windows input dispatch" — checked as a substring over
    /// the WHOLE job block text (not a line-anchored regex, unlike the placement
    /// tests), so this catches the name reappearing with different indentation or
    /// step-key ordering too. Was: "idempotent (git apply --reverse --check)."
    func testNoJobBlockContainsAStepNamedWindowsInputDispatch() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            XCTAssertFalse(job.text.contains("Patch swift-cross-ui Windows input dispatch"),
                "\(jobName): reverted in round 9 (specs/CUESYNC-9-findings.md §0.8) — this step name must " +
                "not reappear in any job block")
        }
    }

    /// REGRESSION LOCK (round 9), a stronger single sweep than the per-job check
    /// above: the workflow file must nowhere contain the reverted patch's filename
    /// string at all — not in a step, not in a comment, not anywhere. Was: "clears
    /// the Windows read-only flag."
    func testWorkflowFileNowhereContainsTheWindowsInputPatchFilenameString() throws {
        let raw = try WorkflowFile9.contents()
        XCTAssertFalse(raw.contains("windows-input.patch"),
            "the workflow file must not reference 'windows-input.patch' anywhere — the patch was deleted " +
            "in round 9 (specs/CUESYNC-9-findings.md §0.8); a stray reference (even in a comment) risks " +
            "someone re-adding the apply step against a file that no longer exists")
    }

    /// NEW-STATE CHECK (round 9): the removal must be documented in place, not
    /// silent — each job block must contain a comment naming round 9 AND citing
    /// specs/CUESYNC-9-findings.md, sitting before the CUESYNC-8 interactivity
    /// step's step-block end and the GSK-renderer step that now runs immediately
    /// after it (the slot the reverted input-dispatch step vacated). Was: "pinned
    /// in a comment naming the audited commit."
    /// UPDATED round 20: the revert's rationale must stay discoverable, but the slot it
    /// used to occupy (between two per-patch YAML steps) no longer exists — the apply
    /// path is the script. Assert the script documents the revert instead.
    func testWorkflowDocumentsTheRound9RevertInPlaceOfTheRemovedStepOnEveryLeg() throws {
        let script = try String(contentsOf: RepoPaths9.devScript, encoding: .utf8)
        XCTAssertTrue(script.lowercased().contains("round 9"),
            "scripts/patch-swift-cross-ui.sh — now the single apply path every CI leg calls — must " +
            "document round 9's revert so the reverted patch's absence is explained where a reader " +
            "would otherwise be tempted to re-add it")
        XCTAssertTrue(script.contains("CUESYNC-9-findings.md"),
            "the script must cite specs/CUESYNC-9-findings.md so the revert's rationale is discoverable")
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

    /// REGRESSION LOCK (round 9, specs/CUESYNC-9-findings.md §0.8): the patch file
    /// must NOT exist — it was `git rm`'d as a disproven, non-load-bearing fix per
    /// spec step 5. Was: "a new checked-in ... exists."
    func testWindowsInputPatchFileNoLongerExists() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: RepoPaths9.windowsInputPatch.path),
            "\(windowsInputPatchRelativePath) must NOT exist — reverted in round 9 " +
            "(specs/CUESYNC-9-findings.md §0.8); its reappearance is a regression to a disproven fix")
    }

    /// NEW-STATE CHECK (updated round 18, specs/CUESYNC-9-findings.md §0.17): exactly
    /// the four surviving, audited patches touch GtkBackend.swift now — the CUESYNC-8
    /// interactivity patch, the round-4/16 GSK-renderer patch, the re-applied
    /// round-13/17 window-present patch, and the round-18 container hit-testing patch
    /// (the one that finally restored input: GTK's `gtk_widget_pick()` stopped at any
    /// targetable container, so the `Gtk.Fixed` wrapping a CUESYNC-8 `canTarget = false`
    /// Shape still swallowed clicks meant for the control beneath). Mirrors what
    /// Tests/test_adversarial.py enforces on the Python side. A FIFTH file, or the
    /// round-9-reverted windows-input patch reappearing, is a supply-chain regression.
    /// Was (round 17): "exactly the three surviving patches."
    func testExactlyTheTwoSurvivingPatchesTouchGtkBackendSwift() throws {
        let patchesDir = RepoPaths9.root.appendingPathComponent("patches")
        let entries = try FileManager.default.contentsOfDirectory(at: patchesDir, includingPropertiesForKeys: nil)
        let gtkBackendPatches = try entries
            .filter { $0.pathExtension == "patch" }
            .filter { try String(contentsOf: $0, encoding: .utf8).contains("Sources/GtkBackend/GtkBackend.swift") }
            .map { $0.lastPathComponent }
            .sorted()
        let expected = [
            (interactivityPatchRelativePath as NSString).lastPathComponent,
            (gskPatchRelativePath as NSString).lastPathComponent,
            (windowsWindowPresentPatchRelativePath as NSString).lastPathComponent,
            (containerHitTestingPatchRelativePath as NSString).lastPathComponent,
            (entryStylingPatchRelativePath as NSString).lastPathComponent,
        ].sorted()
        XCTAssertEqual(gtkBackendPatches, expected,
            "expected exactly the five surviving patches touching GtkBackend.swift (\(expected)) — a SIXTH " +
            "file, or the reverted windows-input patch reappearing, is a supply-chain regression. Found: " +
            "\(gtkBackendPatches)")
        XCTAssertFalse(gtkBackendPatches.contains((windowsInputPatchRelativePath as NSString).lastPathComponent),
            "the round-9-reverted windows-input patch must not reappear as a checked-in patch")
    }

    /// NEW-STATE CHECK (round 9): specs/CUESYNC-9-findings.md's §0.8 section, which
    /// documents this revert, must cite BOTH redteam adversarial tests that forced
    /// it by exact function name — the record of what drove the cleanup must stay
    /// discoverable from the findings doc itself. Was: "never sed/-replace" (a check
    /// that only made sense while the now-deleted file still existed to read).
    func testFindingsSectionZeroEightCitesBothRedteamTestsByName() throws {
        let text = try String(contentsOf: RepoPaths9.findings, encoding: .utf8)
        XCTAssertTrue(text.contains("§0.8"),
            "specs/CUESYNC-9-findings.md must contain a §0.8 section documenting the round-9 revert")
        XCTAssertTrue(text.contains("test_windows_input_patch_premise_is_disproven_yet_it_is_still_applied_on_every_leg"),
            "specs/CUESYNC-9-findings.md §0.8 must cite the redteam test that forced this revert by name")
        XCTAssertTrue(text.contains("test_windows_input_patch_binds_no_undocumented_private_symbol_via_silgen_name"),
            "specs/CUESYNC-9-findings.md §0.8 must cite the second redteam test (the @_silgen_name finding) by name")
    }

    /// NEW-STATE CHECK (round 9): the two surviving patches remain distinct,
    /// existing files, and neither collides with (or was accidentally left at) the
    /// now-deleted windows-input patch's path. Was: "uses GTK/GLib's own APIs ..."
    /// (a check that only made sense while the now-deleted file still existed to
    /// read).
    func testTheTwoSurvivingPatchesExistAndAreDistinctFromTheDeletedWindowsInputPath() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: RepoPaths9.interactivityPatch.path),
            "\(interactivityPatchRelativePath) must still exist — untouched by this ticket's revert")
        XCTAssertTrue(FileManager.default.fileExists(atPath: RepoPaths9.gskPatch.path),
            "\(gskPatchRelativePath) must still exist — untouched by this ticket's revert")
        XCTAssertNotEqual(RepoPaths9.interactivityPatch.path, RepoPaths9.windowsInputPatch.path)
        XCTAssertNotEqual(RepoPaths9.gskPatch.path, RepoPaths9.windowsInputPatch.path)
        XCTAssertNotEqual(RepoPaths9.interactivityPatch.path, RepoPaths9.gskPatch.path)
    }

    /// REGRESSION LOCK (round 9): scripts/patch-swift-cross-ui.sh must no longer
    /// declare the `WINDOWS_INPUT_PATCH` shell variable that used to name the
    /// reverted patch file — a distinct sweep from the CI-workflow filename sweep
    /// above (different file, different token: the shell variable, not the patch
    /// filename). Was: "no GtkFixed/absolute-position API is introduced."
    func testDevScriptNoLongerDeclaresAWindowsInputPatchVariable() throws {
        let raw = try String(contentsOf: RepoPaths9.devScript, encoding: .utf8)
        XCTAssertFalse(raw.contains("WINDOWS_INPUT_PATCH"),
            "scripts/patch-swift-cross-ui.sh must not declare a WINDOWS_INPUT_PATCH variable — the patch " +
            "it named was reverted in round 9 (specs/CUESYNC-9-findings.md §0.8)")
    }

    /// REGRESSION LOCK (round 9), the GSK-renderer-patch side of this check (the
    /// CUESYNC9NoRegressionOnCUESYNC8PatchTests class above already covers the
    /// interactivity-patch side, per its own repurposed test — this deliberately
    /// checks the OTHER surviving patch rather than duplicate that assertion):
    /// `mainRunLoopTicklingLoop`, the reverted patch's sole anchor, must not have
    /// crept into the GSK-renderer patch's actual DIFF BODY either — the file's own
    /// header comment legitimately NAMES that anchor in prose to explain why the
    /// three original patches were disjoint, so the exclusion is checked against the
    /// unified-diff hunk only, not the whole file (same scoping the GSK compliance
    /// file's own disjoint-hunk test uses). Was: "kept SEPARATE from the CUESYNC-8
    /// interactivity patch."
    func testGskRendererPatchDoesNotContainTheRevertedPatchsAnchor() throws {
        let gsk = try String(contentsOf: RepoPaths9.gskPatch, encoding: .utf8)
        guard let diffStart = gsk.range(of: "diff --git a/") else {
            XCTFail("GSK patch has no `diff --git` body")
            return
        }
        let gskDiffBody = String(gsk[diffStart.lowerBound...])
        XCTAssertFalse(gskDiffBody.contains("mainRunLoopTicklingLoop"),
            "the GSK-renderer patch's diff body must not contain mainRunLoopTicklingLoop — that was the " +
            "reverted windows-input patch's sole anchor (specs/CUESYNC-9-findings.md §0.8); its " +
            "reappearance here would mean the reverted hunk crept into the wrong, still-live patch")
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

    /// REGRESSION LOCK (round 9): the reverted windows-input patch's sole anchor,
    /// `mainRunLoopTicklingLoop`, must not have crept back into the CUESYNC-8
    /// interactivity patch — the one GtkBackend.swift-touching patch still live
    /// besides the GSK-renderer patch. Was: "the two patches target disjoint line
    /// ranges" (a check that read the now-deleted windows-input patch file).
    func testBothPatchesTargetDisjointLineRangesWithinGtkBackendSwift() throws {
        let interactivity = try String(contentsOf: RepoPaths9.interactivityPatch, encoding: .utf8)
        XCTAssertTrue(interactivity.contains("createPathWidget"),
            "sanity check: the CUESYNC-8 patch's GtkBackend.swift hunk is anchored at createPathWidget")
        XCTAssertFalse(interactivity.contains("mainRunLoopTicklingLoop"),
            "the interactivity patch must not contain mainRunLoopTicklingLoop — that was the reverted " +
            "windows-input patch's hunk (specs/CUESYNC-9-findings.md §0.8); its reappearance here would " +
            "mean the reverted hunk crept back into the wrong, still-live patch")
    }
}

final class CUESYNC9DevScriptAppliesBothPatchesTests: XCTestCase {

    /// UPDATED for round 9: scripts/patch-swift-cross-ui.sh now applies exactly TWO
    /// patches (interactivity + GSK-renderer) in executable code, and must no
    /// longer reference the reverted windows-input patch at all (regression lock —
    /// checked on the RAW file, not just the code-only view, so a stray comment
    /// mention trips it too). Was: "applies the new patch too."
    func testDevScriptAppliesExactlyTwoPatchesAndNoLongerReferencesWindowsInput() throws {
        let codeOnly = try codeOnlyDevScript()
        XCTAssertTrue(codeOnly.contains(interactivityPatchRelativePath),
            "scripts/patch-swift-cross-ui.sh must still apply the existing CUESYNC-8 interactivity patch " +
            "too — this ticket must not remove it")
        XCTAssertTrue(codeOnly.contains(gskPatchRelativePath),
            "scripts/patch-swift-cross-ui.sh must still apply the GSK-renderer patch")
        let raw = try String(contentsOf: RepoPaths9.devScript, encoding: .utf8)
        XCTAssertFalse(raw.contains("windows-input.patch"),
            "scripts/patch-swift-cross-ui.sh must not reference 'windows-input.patch' anywhere — reverted " +
            "in round 9 (specs/CUESYNC-9-findings.md §0.8)")
    }

    /// UPDATED for round 17 (specs/CUESYNC-9-findings.md §0.16): with the window-present
    /// patch re-applied, exactly THREE patches now apply (interactivity + GSK-renderer +
    /// window-present), each still guarded idempotently and actually applied. The exact
    /// count still catches the round-9-reverted windows-input patch (or any rogue extra)
    /// quietly reappearing — it would push the count to 4. Was (round 9): a count of 2.
    func testDevScriptAppliesBothRemainingPatchesIdempotentlyAndActually() throws {
        let codeOnly = try codeOnlyDevScript()
        let reverseCheckCount = codeOnly.components(separatedBy: "git apply --reverse --check").count - 1
        XCTAssertEqual(reverseCheckCount, 5,
            "scripts/patch-swift-cross-ui.sh must guard EACH of the four remaining patches (interactivity, " +
            "GSK-renderer, window-present) with its own `git apply --reverse --check` — found \(reverseCheckCount) " +
            "guard(s); a count above 3 would mean the reverted windows-input patch or an extra crept back in")

        let withoutGuardChecks = codeOnly.replacingOccurrences(of: "git apply --reverse --check", with: "")
        let plainApplyCount = withoutGuardChecks.components(separatedBy: "git apply ").count - 1
        XCTAssertEqual(plainApplyCount, 5,
            "scripts/patch-swift-cross-ui.sh must contain a plain `git apply` call for EACH of the three " +
            "remaining patches, distinct from the `--reverse --check` guards — found \(plainApplyCount)")
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

    /// REGRESSION LOCK (round 9): there is no windows-input patch step block left
    /// to scope a read-only clear for — assert its name is absent from both
    /// Windows legs. Was: "clears the read-only flag on exactly GtkBackend.swift,"
    /// which required a step block that no longer exists (calling `stepBlock(named:)`
    /// for a step that isn't there would itself XCTFail).
    func testNoWindowsInputPatchStepBlockExistsToScopeAReadOnlyClearFor() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            XCTAssertNil(job.firstLineIndex(matching: windowsInputStepNamePattern),
                "\(jobName): no 'Patch swift-cross-ui Windows input dispatch' step should exist — reverted " +
                "in round 9 (specs/CUESYNC-9-findings.md §0.8), so there is nothing left to scope a " +
                "read-only clear for")
        }
    }
}

final class CUESYNC9PatchFilePlatformQuirkTests: XCTestCase {

    /// Platform-quirk edge case, folded into confirming the round-9 deletion is
    /// real: Windows filesystems are commonly case-insensitive, so a residual
    /// differently-cased copy of the deleted patch (e.g. left by a bad merge or a
    /// case-only rename) could sit undetected by an exact-case `fileExists` check
    /// alone. Scan the whole patches/ directory case-insensitively for any
    /// "windows-input" file. Was: "the checked-in patch bytes must stay LF-only"
    /// (a check that read the now-deleted file).
    func testPatchesDirectoryContainsNoResidualWindowsInputFileUnderAnyCasing() throws {
        let patchesDir = RepoPaths9.root.appendingPathComponent("patches")
        let entries = try FileManager.default.contentsOfDirectory(at: patchesDir, includingPropertiesForKeys: nil)
        for entry in entries {
            XCTAssertFalse(entry.lastPathComponent.lowercased().contains("windows-input"),
                "found a residual windows-input file at \(entry.lastPathComponent) — the patch was fully " +
                "deleted in round 9 (specs/CUESYNC-9-findings.md §0.8); no case-variant copy may remain")
        }
    }

    /// UPDATED for round 9: with the windows-input patch deleted, re-target the
    /// "not a degenerate stub" guard at the CUESYNC-8 interactivity patch — neither
    /// this file nor CUESYNC8GtkInteractivityWorkflowTests previously wrote this
    /// specific guard for it (CUESYNC9GskRendererPatchFileTests already covers the
    /// GSK-renderer patch). Was: the same guard for the now-deleted windows-input
    /// patch file.
    func testInteractivityPatchFileHasSubstantiveContentNotAnEmptyStub() throws {
        let patch = try String(contentsOf: RepoPaths9.interactivityPatch, encoding: .utf8)
        let lineCount = patch.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertGreaterThan(lineCount, 20,
            "\(interactivityPatchRelativePath) is suspiciously small (\(lineCount) lines) for a real, " +
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
    static let gskPatch = root.appendingPathComponent(gskPatchRelativePath)
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

// =============================================================================
// CUESYNC-9 round 20 — CI must apply the SAME patch set the script does.
//
// On 72c518f the Windows legs went red and, worse, would have been GREEN-but-
// meaningless if they hadn't: `.github/workflows/swift-windows.yml` hand-rolled one
// `git apply` step per patch and listed only THREE of the five live patches, so CI
// built without the container-hit-testing and entry-styling fixes the commit existed
// to prove — while `scripts/patch-swift-cross-ui.sh` applied all five. The YAML and
// the script had silently drifted, and nothing asserted they agreed.
//
// Round 20 removed the ability to drift (every leg now calls the script) and this
// suite locks that shut: every patch file in patches/ must be applied by the script,
// every leg must delegate to the script, and no leg may hand-roll `git apply`.
// =============================================================================

final class CUESYNC9CIAppliesSamePatchSetAsScriptTests: XCTestCase {

    private var scriptText: String {
        get throws { try String(contentsOf: RepoPaths9.devScript, encoding: .utf8) }
    }

    /// Every checked-in patch must be applied by the script — a patch file that no
    /// apply path references is dead weight that reviewers will assume is live.
    func testScriptAppliesEveryCheckedInPatch() throws {
        let patchesDir = RepoPaths9.root.appendingPathComponent("patches")
        let patchFiles = try FileManager.default
            .contentsOfDirectory(at: patchesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "patch" }
            .map { $0.lastPathComponent }
            .sorted()
        XCTAssertFalse(patchFiles.isEmpty, "patches/ must contain at least one patch")

        let script = try scriptText
        for patchFile in patchFiles {
            XCTAssertTrue(script.contains(patchFile),
                "scripts/patch-swift-cross-ui.sh must apply \(patchFile) — every CI leg delegates to " +
                "this script, so a patch it does not name is a patch CI never applies")
        }
    }

    /// Every GtkBackend-compiling leg delegates to the script.
    func testEveryGtkBackendCompilingLegDelegatesToTheScript() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            XCTAssertTrue(job.text.contains("scripts/patch-swift-cross-ui.sh"),
                "\(jobName) must apply dependency patches by calling scripts/patch-swift-cross-ui.sh")
        }
    }

    /// No leg may hand-roll `git apply` — that is precisely how the YAML came to apply
    /// a different (smaller) patch set than the script.
    func testNoLegHandRollsGitApply() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks9.require(jobName)
            let runLines = job.lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            let handRolled = runLines.filter { $0.contains("git apply") }
            XCTAssertTrue(handRolled.isEmpty,
                "\(jobName) must not run `git apply` directly — patching goes through " +
                "scripts/patch-swift-cross-ui.sh so the YAML cannot drift from it. Found: \(handRolled)")
        }
    }

    /// The script normalizes line endings before applying. swift-cross-ui ships no
    /// .gitattributes, so windows-latest (core.autocrlf=true) checks its sources out as
    /// CRLF and every LF-only patch fails `git apply` at GtkBackend.swift:116 — the
    /// exact asymmetry that turned 72c518f red on Windows while macOS passed.
    func testScriptNormalizesCheckoutToLFBeforeApplying() throws {
        let script = try scriptText
        XCTAssertTrue(script.contains("core.autocrlf false"),
            "the script must set core.autocrlf=false on the swift-cross-ui checkout")
        XCTAssertTrue(script.contains("core.eol lf"),
            "the script must set core.eol=lf on the swift-cross-ui checkout")
        guard let normalize = script.range(of: "core.autocrlf false")?.lowerBound,
            let firstApply = script.range(of: "git apply --reverse --check \"$")?.lowerBound
        else {
            XCTFail("expected both LF normalization and a `git apply` in the script")
            return
        }
        XCTAssertLessThan(normalize, firstApply,
            "LF normalization must precede every apply — normalizing after a failed apply is useless")
    }

    /// NEW-STATE CHECK (round 20): a repo-root .gitattributes must pin shell scripts
    /// to LF. cuesync-releases ships none by default, so on windows-latest
    /// (core.autocrlf=true) `scripts/patch-swift-cross-ui.sh` checks out CRLF and
    /// `bash scripts/patch-swift-cross-ui.sh` dies on line 2 —
    /// `set -euo pipefail\r` → "set: pipefail: invalid option name" — before the
    /// script's first `==>` progress line prints, so the CI log carries no clue.
    /// macOS checks the same file out as LF and runs the identical step fine. That
    /// asymmetry turned run 32666982677 red on both Windows legs; this locks it shut.
    ///
    /// Note this is the SCRIPT's line endings, not the patches'. `git apply` honours
    /// core.autocrlf when applying to a CRLF working tree, so LF-only patches apply
    /// cleanly there (verified: all five apply individually and cumulatively against
    /// a genuine CRLF checkout). The executable shell script is the fragile one.
    func testGitAttributesPinsShellScriptsToLF() throws {
        let gitattributes = RepoPaths9.root.appendingPathComponent(".gitattributes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitattributes.path),
            "a repo-root .gitattributes must exist — without it windows-latest checks " +
            "scripts/*.sh out as CRLF and every `bash <script>.sh` CI step dies at " +
            "`set -euo pipefail`")

        let text = try String(contentsOf: gitattributes, encoding: .utf8)
        let rules = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        XCTAssertTrue(
            rules.contains { $0.hasPrefix("*.sh") && $0.contains("eol=lf") },
            "`.gitattributes` must pin `*.sh` to `eol=lf` — CI runs " +
            "scripts/patch-swift-cross-ui.sh through bash on windows-latest. Found: \(rules)")
        XCTAssertTrue(
            rules.contains { $0.hasPrefix("*.patch") && $0.contains("eol=lf") },
            "`.gitattributes` must pin `*.patch` to `eol=lf` — those bytes are fed " +
            "straight to `git apply`. Found: \(rules)")
    }

    /// All five live patches are named, in the audited apply order.
    func testScriptAppliesTheFiveLivePatchesInOrder() throws {
        let script = try scriptText
        let ordered = [
            "swift-cross-ui-0.8.0-gtk-interactivity.patch",
            "swift-cross-ui-0.8.0-windows-gsk-renderer.patch",
            "swift-cross-ui-0.8.0-windows-window-present.patch",
            "swift-cross-ui-0.8.0-gtk-container-hit-testing.patch",
            "swift-cross-ui-0.8.0-gtk-entry-styling.patch",
        ]
        var previous = script.startIndex
        for patch in ordered {
            guard let found = script.range(of: patch, range: previous..<script.endIndex)?.lowerBound else {
                XCTFail("scripts/patch-swift-cross-ui.sh must apply \(patch) after the preceding patch — " +
                    "apply order is audited (specs/CUESYNC-9-findings.md)")
                return
            }
            previous = found
        }
    }
}
