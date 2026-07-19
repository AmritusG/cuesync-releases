import Foundation
import XCTest

// =============================================================================
// CUESYNC-9 round 8 (specs/CUESYNC-9-findings.md §0.7) — the window/main-loop
// input-death root cause was NOT the run-loop tickler rounds 1-7 patched, but a
// hard content `.frame(minWidth:/minHeight:)` on the WindowGroup's content that
// swift-cross-ui turns into an unsatisfiable `minimumWindowSize`: when the
// display can't grant it, `WindowReference.update` and the GTK resize callback
// clamp back and forth forever (an infinite relayout loop), which renders the
// window collapsed and dispatches no input at all.
//
// This ticket's fix is deliberately NOT a new swift-cross-ui patch — it is the
// spec step-4 contingency path, applied at the app-shell layer by deleting the
// offending `.frame(min...)` modifier. `swift test` cannot launch a live GTK
// window (`UI/` compiles only under `CUESYNC_CROSSUI`, which this target does
// not define — see PortComplianceTests.swift), so these are source/doc
// structural checks: (a) the findings doc records the evidence and the
// evidence-based reversal of the prior seven rounds' theory so it cannot be
// quietly rewritten away, and (b) no file under `UI/` reintroduces the
// unsatisfiable-minimum pattern the fix removed. Mirrors the self-contained
// per-file helper convention already used by CUESYNC9WindowsInputDispatchWorkflowTests /
// CUESYNC9WindowsGskRendererWorkflowTests.
// =============================================================================

private let auditedRevisionR8 = "a6d206370812e3b9edba259d167e848892c5013d"

private enum RepoPaths9Round8 {
    /// Tests/CueSyncCoreTests/<this file> -> Tests/CueSyncCoreTests -> Tests -> repo root
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let findings = root.appendingPathComponent("specs/CUESYNC-9-findings.md")
    static let agentsUiux = root.appendingPathComponent("agents/uiux.md")
    static let uiDirectory = root.appendingPathComponent("CueSync/CueSync/UI")
}

final class CUESYNC9WindowLayoutThrashFindingsTests: XCTestCase {

    /// spec CUESYNC-9 §3 acceptance: "names one root cause with file:line
    /// citations, ruling out the other suspects." Round 8's root cause is a
    /// specific, mechanically-traced boundary condition — the display granting
    /// 1200x657 against an enforced 1200x700 minimum — not a vague description;
    /// pin the exact boundary values so the finding can't drift into vagueness.
    func testFindingsDocumentsTheRound8BoundaryValuesOfTheLayoutThrashLoop() throws {
        let text = try String(contentsOf: RepoPaths9Round8.findings, encoding: .utf8)
        XCTAssertTrue(text.contains("657"),
            "specs/CUESYNC-9-findings.md must cite the 657px height the display actually grants "
            + "(the boundary that makes the 700 minimum unsatisfiable)")
        XCTAssertTrue(text.contains("700"),
            "specs/CUESYNC-9-findings.md must cite the 700px hard minimum that the display cannot "
            + "grant, driving the relayout loop")
        XCTAssertTrue(text.contains("Gtk-CRITICAL"),
            "specs/CUESYNC-9-findings.md must cite the Gtk-CRITICAL allocation message that is the "
            + "machine evidence for the relayout loop, distinguishing it from mere Gtk-WARNING noise")
        XCTAssertTrue(text.contains(auditedRevisionR8),
            "specs/CUESYNC-9-findings.md round 8 section must still cite the audited pinned commit")
    }

    /// spec CUESYNC-9 §3 acceptance / agents/uiux.md lesson: round 8 explicitly
    /// OVERTURNS rounds 1-7's main-loop-starvation theory on real evidence rather
    /// than layering an eighth guess on top of it — the findings doc must record
    /// that reversal, not just append another candidate cause.
    func testFindingsRecordsThatRound8DisprovesThePriorMainLoopStarvationTheory() throws {
        let text = try String(contentsOf: RepoPaths9Round8.findings, encoding: .utf8)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("disprove"),
            "specs/CUESYNC-9-findings.md must record that round 8's evidence disproves the prior "
            + "main-loop-starvation theory (rounds 1-7), not merely add a coexisting theory")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("starvation"),
            "specs/CUESYNC-9-findings.md must name the superseded starvation theory explicitly so "
            + "the reversal is legible to the next round")
    }

    /// spec CUESYNC-9 §7 acceptance: agents/uiux.md's new section must be
    /// grounded in the concrete round-8 mechanism (the unsatisfiable minimum),
    /// not just a generic restatement of "verify input with a real click."
    func testAgentsUiuxRound8SectionNamesTheUnsatisfiableMinimumMechanism() throws {
        let text = try String(contentsOf: RepoPaths9Round8.agentsUiux, encoding: .utf8)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("minimum"),
            "agents/uiux.md's round-8 section must name the unsatisfiable hard-minimum-size "
            + "mechanism, not just the generic main-loop lesson")
        XCTAssertTrue(text.contains("CueSyncApp.swift"),
            "agents/uiux.md's round-8 section must ground the lesson in the concrete "
            + "CueSync/CueSync/UI/CueSyncApp.swift instance (spec §7)")
    }
}

final class CUESYNC9NoHardWindowMinimumHeightRegressionTests: XCTestCase {

    /// spec CUESYNC-9 §3 no-regression acceptance (root-cause fix must not
    /// silently regress). Round 8's fix is a deletion, not an addition, so
    /// there is no new patch file to pin it in place — the only durable guard
    /// is scanning source.
    ///
    /// Scoped to the window's outer chrome — the top-level files directly under
    /// `UI/` (`CueSyncApp.swift`, `ContentView.swift`, `HeaderView.swift`,
    /// `FooterView.swift`, `CollapsibleSection.swift`, ...) — NOT the recursive
    /// tree. Per findings §0.7, "the inner ScrollView already returns the
    /// proposed height when one is given ... it absorbs vertical overflow":
    /// `Sections/BrowseSectionView.swift`, `ConfigureSectionView.swift`, and
    /// `EnvelopeCanvasView.swift` legitimately set `.frame(minHeight:)` on
    /// content that lives INSIDE `ContentView`'s `ScrollView`, where it is
    /// bounded/absorbed and cannot inflate `WindowReference`'s
    /// `minimumWindowSize`. Only a hard minHeight on the chrome siblings of
    /// that ScrollView (or on the WindowGroup content itself) reproduces the
    /// unsatisfiable-minimum mechanism that caused the round-8 infinite
    /// relayout loop, so only those top-level files are guarded here.
    func testNoTopLevelUIShellFileReintroducesAHardMinHeightOnWindowContent() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: RepoPaths9Round8.uiDirectory, includingPropertiesForKeys: nil)
        var checked = 0
        for file in entries where file.pathExtension == "swift" {
            let src = try String(contentsOf: file, encoding: .utf8)
            checked += 1
            // Explanatory comments (this file's own header, and CueSyncApp.swift's
            // round-8 inline comment) legitimately name the forbidden pattern in
            // prose — only actual code may not contain it.
            let codeLines = src.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for line in codeLines {
                XCTAssertFalse(line.contains("minHeight:"),
                    "\(file.lastPathComponent) sets a hard .frame(minHeight:) on the window's outer "
                    + "chrome — this is the exact unsatisfiable-window-minimum pattern that caused "
                    + "the CUESYNC-9 round-8 infinite relayout loop (specs/CUESYNC-9-findings.md "
                    + "§0.7): \(line)")
            }
        }
        XCTAssertGreaterThan(checked, 0, "expected to scan at least one top-level file under CueSync/CueSync/UI")
    }

    /// Edge case: the window's preferred size must still be expressed, so the
    /// fix is "use a display-yielding default" and not "declare no size at
    /// all" (which would leave the opening size undocumented/unspecced).
    func testWindowSceneStillDeclaresADefaultSizeAfterTheMinimumWasRemoved() throws {
        let url = RepoPaths9Round8.root.appendingPathComponent("CueSync/CueSync/UI/CueSyncApp.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains(".defaultSize(width: 1200, height: 800)"),
            "UI/CueSyncApp.swift must keep declaring the preferred 1200x800 opening size via "
            + ".defaultSize even though the hard .frame(minWidth:/minHeight:) was removed "
            + "(spec §B.10 / CUESYNC-9 findings §0.7)")
    }
}
