import Foundation
import XCTest

// =============================================================================
// CUESYNC-9 round 15 (specs/CUESYNC-9-findings.md §0.14, commit `9ed33bd`) — the
// round-4 GSK-renderer patch (CUESYNC9WindowsGskRendererWorkflowTests) forced
// `GSK_RENDERER=cairo` UNCONDITIONALLY on every Windows build for eleven rounds.
// Cairo software-renders CueSync's content BLACK, so every probe from round 4
// onward judged the pixels of a window that was painting black, not one that was
// failing to paint or dispatch input — the confound §0.14 names as the saga's
// capstone reversal. Round 15's fix gates the cairo force behind an explicit
// `CUESYNC_SOFTWARE_RENDER` opt-in and restores GTK's GL renderer as the default.
//
// This exact regression — the fix accidentally shipping without a regression
// lock — is real: commit 9ed33bd's own message states "String-level gsk tests
// still pass" (CUESYNC9WindowsGskRendererWorkflowTests only asserts g_setenv /
// GSK_RENDERER / cairo / #if os(Windows) are PRESENT somewhere in the patch; it
// never asserted the call is conditional). Nothing before this file would fail
// if someone re-hoisted the cairo g_setenv back out to run unconditionally,
// reintroducing the black-UI regression. These tests close that gap.
//
// `swift test` cannot launch a live GTK window on Windows/remote-desktop (the
// click-probe gate and the GTE are what prove live behaviour — see spec step 8),
// so these are source/doc-structural checks, mirroring the file-local helper
// convention already used by CUESYNC9WindowsGskRendererWorkflowTests /
// CUESYNC9WindowMinimumSizeRegressionTests.
// =============================================================================

private let auditedRevisionRound15 = "a6d206370812e3b9edba259d167e848892c5013d"
private let round15CommitSHA = "9ed33bd"

private enum RepoPathsRound15 {
    /// Tests/CueSyncCoreTests/<this file> -> Tests/CueSyncCoreTests -> Tests -> repo root
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let gskPatch = root.appendingPathComponent(
        "patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch")
    static let findings = root.appendingPathComponent("specs/CUESYNC-9-findings.md")
    static let agentsUiux = root.appendingPathComponent("agents/uiux.md")
}

final class CUESYNC9GskRendererCairoIsOptInNotDefaultTests: XCTestCase {

    /// The core round-15 regression lock: the cairo-forcing `g_setenv` call must
    /// be textually gated BEHIND the `g_getenv("CUESYNC_SOFTWARE_RENDER")` check,
    /// not merely present somewhere in the patch alongside it.
    func testCairoSetenvCallIsGatedBehindTheSoftwareRenderOptInCheck() throws {
        let patch = try String(contentsOf: RepoPathsRound15.gskPatch, encoding: .utf8)
        guard let optInRange = patch.range(of: #"g_getenv("CUESYNC_SOFTWARE_RENDER")"#) else {
            XCTFail("the patch must gate the software Cairo renderer behind an explicit " +
                "CUESYNC_SOFTWARE_RENDER opt-in check (round 15, specs/CUESYNC-9-findings.md §0.14) " +
                "— forcing GSK_RENDERER=cairo unconditionally software-rendered the UI BLACK")
            return
        }
        guard let cairoSetRange = patch.range(of: #"g_setenv("GSK_RENDERER", "cairo", 1)"#) else {
            XCTFail("the patch must still set GSK_RENDERER=cairo somewhere, now gated by the opt-in check")
            return
        }
        XCTAssertLessThan(optInRange.lowerBound, cairoSetRange.lowerBound,
            "the CUESYNC_SOFTWARE_RENDER opt-in check must appear BEFORE the cairo g_setenv call — " +
            "GL stays the default renderer and cairo is opt-in only (round 15)")
    }

    /// Nesting, not just ordering: the cairo `g_setenv` line must be the very
    /// next line after the `g_getenv("CUESYNC_SOFTWARE_RENDER")` if-check, so a
    /// future edit cannot dedent it back out to file/function scope (which would
    /// silently restore the unconditional-cairo regression while still passing a
    /// weaker "both strings present, in order" check).
    func testCairoSetenvIsTheImmediateNextLineInsideTheOptInIfBlock() throws {
        let patch = try String(contentsOf: RepoPathsRound15.gskPatch, encoding: .utf8)
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let ifLineIndex = lines.firstIndex(where: { $0.contains(#"g_getenv("CUESYNC_SOFTWARE_RENDER")"#) }) else {
            XCTFail("expected a line checking g_getenv(\"CUESYNC_SOFTWARE_RENDER\")")
            return
        }
        XCTAssertTrue(lines[ifLineIndex].contains("if "),
            "the CUESYNC_SOFTWARE_RENDER check must be an `if` condition, not an unconditional read")
        XCTAssertLessThan(ifLineIndex + 1, lines.count,
            "the opt-in check must not be the last line of the patch")
        XCTAssertTrue(lines[ifLineIndex + 1].contains(#"g_setenv("GSK_RENDERER", "cairo", 1)"#),
            "the cairo g_setenv call must be the line immediately inside the CUESYNC_SOFTWARE_RENDER " +
            "if-block (round 15) — not hoisted back out to run unconditionally on every Windows build")
    }

    /// Exactly one cairo-forcing call in the whole patch — guards against a
    /// second, unguarded `g_setenv("GSK_RENDERER", "cairo", ...)` being added
    /// elsewhere while the gated one stays in place purely to satisfy the tests
    /// above.
    func testExactlyOneCairoSetenvCallExistsInTheWholePatch() throws {
        let patch = try String(contentsOf: RepoPathsRound15.gskPatch, encoding: .utf8)
        let occurrences = patch.components(separatedBy: #"g_setenv("GSK_RENDERER", "cairo""#).count - 1
        XCTAssertEqual(occurrences, 1,
            "expected exactly one GSK_RENDERER=cairo g_setenv call, gated by the CUESYNC_SOFTWARE_RENDER " +
            "opt-in check — found \(occurrences)")
    }

    /// The opt-in check must test presence (`!= nil`), the actual shipped
    /// semantics (any set value opts in, matching `g_getenv`'s NULL-when-unset
    /// contract) — not some other comparison (e.g. an exact `== "1"` string
    /// match) that the findings/commit prose does not claim and CI cannot
    /// exercise.
    func testOptInCheckComparesAgainstNilNotAStringLiteral() throws {
        let patch = try String(contentsOf: RepoPathsRound15.gskPatch, encoding: .utf8)
        XCTAssertTrue(patch.contains(#"g_getenv("CUESYNC_SOFTWARE_RENDER") != nil"#),
            "the opt-in check must compare g_getenv's result against nil (GLib returns NULL when the " +
            "env var is unset) — got a patch that does not contain the exact `!= nil` guard")
    }
}

final class CUESYNC9GskRendererFindingsDocumentRound15Tests: XCTestCase {

    /// spec CUESYNC-9 §3 acceptance: the findings doc must name the round-15 root
    /// cause (the round-4 workaround itself was a confound) with the concrete
    /// evidence, not just restate round 4's original diagnosis.
    func testFindingsDocumentsRound15CairoBlackConfoundAndOptInFix() throws {
        let text = try String(contentsOf: RepoPathsRound15.findings, encoding: .utf8)
        XCTAssertTrue(text.contains("§0.14"),
            "specs/CUESYNC-9-findings.md must contain a §0.14 section for round 15")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("round 15"),
            "specs/CUESYNC-9-findings.md must label the section as round 15")
        XCTAssertTrue(text.contains("CUESYNC_SOFTWARE_RENDER"),
            "specs/CUESYNC-9-findings.md §0.14 must name the CUESYNC_SOFTWARE_RENDER opt-in env var")
        XCTAssertTrue(text.contains("BLACK"),
            "specs/CUESYNC-9-findings.md §0.14 must state that cairo software-renders content BLACK " +
            "— the confound that invalidated rounds 5-14's pixel evidence")
        XCTAssertTrue(text.contains(round15CommitSHA),
            "specs/CUESYNC-9-findings.md §0.14 must cite the round-15 commit \(round15CommitSHA)")
        XCTAssertTrue(text.contains(auditedRevisionRound15),
            "specs/CUESYNC-9-findings.md §0.14 must still cite the audited pinned swift-cross-ui commit")
    }

    /// The doc must record that this is a REVERSAL of the prior rounds' pixel
    /// evidence, not merely append a coexisting theory — mirrors the round-8
    /// precedent (CUESYNC9WindowMinimumSizeRegressionTests
    /// .testFindingsRecordsThatRound8DisprovesThePriorMainLoopStarvationTheory).
    func testFindingsRecordsThatRound15InvalidatesRounds5Through14sPixelEvidence() throws {
        let text = try String(contentsOf: RepoPathsRound15.findings, encoding: .utf8)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("confound"),
            "specs/CUESYNC-9-findings.md §0.14 must name the cairo-black confound explicitly")
        XCTAssertTrue(text.contains("reopen") || text.contains("reframing") || text.contains("REOPEN"),
            "specs/CUESYNC-9-findings.md §0.14 must record that the input question is reopened, not " +
            "resolved by the earlier rounds' now-invalidated pixel evidence")
    }
}

final class CUESYNC9UiuxDocumentsRound15DiagnosticFallbackLessonTests: XCTestCase {

    /// spec CUESYNC-9 §7 acceptance: agents/uiux.md must gain a distinct new
    /// section for round 15, grounded in the concrete opt-in mechanism, without
    /// removing any prior round's section (additive only).
    func testUiuxGainsARound15SectionNamingTheOptInEnvVar() throws {
        let text = try String(contentsOf: RepoPathsRound15.agentsUiux, encoding: .utf8)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("round 15"),
            "agents/uiux.md must gain a new section labelled round 15 (CUESYNC-9)")
        XCTAssertTrue(text.contains("CUESYNC_SOFTWARE_RENDER"),
            "agents/uiux.md's round-15 section must name the concrete CUESYNC_SOFTWARE_RENDER opt-in " +
            "mechanism, not just restate the generic 'verify with a real click' lesson")
        XCTAssertTrue(text.contains(round15CommitSHA),
            "agents/uiux.md's round-15 section must ground the lesson in commit \(round15CommitSHA)")
    }

    /// Additive, not destructive: every prior round's section header must
    /// survive — mirrors CUESYNC9WindowsInputDispatchWorkflowTests' equivalent
    /// "must still contain the existing CUESYNC-8 can-target section" guard.
    func testUiuxRound15SectionDoesNotRemoveAnyPriorRoundSection() throws {
        let text = try String(contentsOf: RepoPathsRound15.agentsUiux, encoding: .utf8)
        let expectedPriorHeadingFragments = [
            "A compiling modifier is not a working control",
            "A window that paints but never dispatches input is not a hit-testing bug",
            "round 3", "round 4", "round 5", "round 6", "round 8", "round 10", "round 11",
            "round 12", "round 13",
        ]
        for fragment in expectedPriorHeadingFragments {
            XCTAssertTrue(text.localizedCaseInsensitiveContains(fragment),
                "agents/uiux.md must still contain prior-round content '\(fragment)' — the round-15 " +
                "section must be additive, never a replacement of earlier lessons")
        }
    }
}
