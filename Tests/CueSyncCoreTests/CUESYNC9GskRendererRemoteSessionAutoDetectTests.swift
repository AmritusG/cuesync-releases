import Foundation
import XCTest

// =============================================================================
// CUESYNC-9 round 16 (specs/CUESYNC-9-findings.md §0.15) — round 15 correctly made
// the software-Cairo fallback an opt-in (CUESYNC_SOFTWARE_RENDER) and restored GTK's
// GL renderer as the Windows default, but wired the opt-in to a launch-time env var
// the click-probe gate never sets. On the remote-desktop probe box (where GL cannot
// realize a surface, §0.3) that default is GL-that-crashes, so the probe regressed
// from a black-but-present window (rounds 4-14) to NO window — "process exited before
// showing a window" (result.json: window_found=false, rect=null).
//
// Round 16 keeps GL the default yet AUTO-selects Cairo when the process is in a
// remote-desktop session, detected from the Windows-set SESSIONNAME / CLIENTNAME
// markers via Foundation's ProcessInfo (no new import — the GSK patch's own supply-
// chain guard forbids adding one, so Win32 GetSystemMetrics/SM_REMOTESESSION could
// not be used). These are source/doc-structural checks: `swift test` cannot launch a
// live GTK window on a remote-desktop box (the click-probe gate is what proves live
// behaviour, spec step 8). They mirror the file-local convention of
// CUESYNC9GskRendererOptInRegressionTests.
// =============================================================================

private let round16FindingsSection = "§0.15"

private enum RepoPathsRound16 {
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

final class CUESYNC9GskRendererRemoteSessionAutoDetectTests: XCTestCase {

    /// The core round-16 behaviour: Cairo is auto-selected in a remote-desktop
    /// session, detected from the Windows SESSIONNAME/CLIENTNAME environment
    /// markers — so the probe box gets a window without the launcher setting any
    /// env var. Both markers must be consulted in the patch's added code.
    func testPatchAutoSelectsCairoFromRemoteDesktopEnvironmentMarkers() throws {
        let added = try gskAddedLines()
        XCTAssertTrue(added.contains("SESSIONNAME"),
            "round 16 (§0.15): the GSK patch must detect a remote-desktop session from the Windows " +
            "SESSIONNAME marker so the probe box auto-selects software Cairo with no env var set")
        XCTAssertTrue(added.contains("CLIENTNAME"),
            "round 16 (§0.15): the GSK patch must also consult the CLIENTNAME marker (set for a " +
            "connected RDP client) as a remote-desktop signal")
        XCTAssertTrue(added.contains("ProcessInfo"),
            "round 16 (§0.15): the markers must be read via Foundation's already-imported ProcessInfo " +
            "— the no-new-import path chosen over Win32 GetSystemMetrics/SM_REMOTESESSION")
    }

    /// The remote-desktop trigger must be OR-ed with — not a replacement for — the
    /// CUESYNC_SOFTWARE_RENDER opt-in, so round 15's explicit override survives and
    /// Cairo stays conditional (never unconditional — the black-UI regression lock).
    func testCairoTriggerIsRemoteSessionOrExplicitOptInStillGated() throws {
        let added = try gskAddedLines()
        // The single cairo-forcing `if` must reference BOTH the opt-in and the
        // remote-session predicate — i.e. cairo fires on (opt-in OR remote), never
        // hoisted out to run unconditionally.
        guard let ifLine = added.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first(where: { $0.contains(#"g_getenv("CUESYNC_SOFTWARE_RENDER")"#) })
        else {
            XCTFail("round 16: expected the CUESYNC_SOFTWARE_RENDER opt-in check to survive in the patch")
            return
        }
        XCTAssertTrue(ifLine.contains("||"),
            "round 16 (§0.15): the cairo gate must be `CUESYNC_SOFTWARE_RENDER opt-in OR remote-desktop " +
            "session` — the two triggers OR-ed on one `if`, so the opt-in remains and cairo stays conditional")
        XCTAssertTrue(ifLine.contains("if "),
            "round 16: the combined trigger must be an `if` condition, not an unconditional set")
    }

    /// Exactly one cairo-forcing call — round 16 widens WHEN it fires, it does not
    /// add a second, unguarded set (reinforces the round-15 lock against the new
    /// compound condition).
    func testStillExactlyOneCairoSetenvCall() throws {
        let patch = try String(contentsOf: RepoPathsRound16.gskPatch, encoding: .utf8)
        let occurrences = patch.components(separatedBy: #"g_setenv("GSK_RENDERER", "cairo""#).count - 1
        XCTAssertEqual(occurrences, 1,
            "round 16: still exactly one GSK_RENDERER=cairo g_setenv call, now gated by " +
            "(CUESYNC_SOFTWARE_RENDER opt-in OR remote-desktop detection) — found \(occurrences)")
    }

    /// The no-new-dependency guard, re-checked against round 16's added lines: the
    /// auto-detect must not smuggle in an `import` (e.g. `import WinSDK` for
    /// GetSystemMetrics) — the reason SESSIONNAME/CLIENTNAME via ProcessInfo was
    /// chosen in the first place.
    func testRound16AddsNoNewImport() throws {
        let added = try gskAddedLines()
        XCTAssertFalse(added.contains("import "),
            "round 16 (§0.15): the remote-desktop auto-detect must add no `import` — it reads the " +
            "SESSIONNAME/CLIENTNAME markers through Foundation's already-imported ProcessInfo, not a " +
            "new WinSDK import for GetSystemMetrics/SM_REMOTESESSION")
    }

    private func gskAddedLines() throws -> String {
        let patch = try String(contentsOf: RepoPathsRound16.gskPatch, encoding: .utf8)
        return patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
            .joined(separator: "\n")
    }
}

final class CUESYNC9GskRendererFindingsDocumentRound16Tests: XCTestCase {

    /// The findings doc must name the round-16 root cause: round 15's GL-default
    /// regressed the probe box to "process exited before showing a window" because
    /// the opt-in env var is never set by the probe.
    func testFindingsDocumentsRound16NoWindowRegressionAndAutoDetectFix() throws {
        let text = try String(contentsOf: RepoPathsRound16.findings, encoding: .utf8)
        XCTAssertTrue(text.contains(round16FindingsSection),
            "specs/CUESYNC-9-findings.md must contain a §0.15 section for round 16")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("round 16"),
            "specs/CUESYNC-9-findings.md must label the section as round 16")
        XCTAssertTrue(text.contains("process exited before showing a window"),
            "specs/CUESYNC-9-findings.md §0.15 must quote the gate finding round 16 fixes — the " +
            "no-window regression round 15's GL-default introduced")
        XCTAssertTrue(text.contains("SESSIONNAME") && text.contains("CLIENTNAME"),
            "specs/CUESYNC-9-findings.md §0.15 must name the SESSIONNAME/CLIENTNAME markers the fix detects")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("regress"),
            "specs/CUESYNC-9-findings.md §0.15 must record that round 15's GL-default REGRESSED the probe box")
    }

    /// §0.14 (round 15) must survive — the round-16 section is additive, not a
    /// replacement (mirrors the round-15 file's own additivity guard).
    func testFindingsRound16DoesNotRemoveRound15Section() throws {
        let text = try String(contentsOf: RepoPathsRound16.findings, encoding: .utf8)
        XCTAssertTrue(text.contains("§0.14"),
            "specs/CUESYNC-9-findings.md must keep the §0.14 (round 15) section — round 16 is additive")
        XCTAssertTrue(text.contains("§0.3"),
            "specs/CUESYNC-9-findings.md must keep §0.3's remote-desktop root-cause trail that round 16 builds on")
    }
}

final class CUESYNC9UiuxDocumentsRound16LessonTests: XCTestCase {

    /// agents/uiux.md must gain a round-16 section grounded in the concrete
    /// mechanism (an unset opt-in is an off switch to the automated gate;
    /// SESSIONNAME/CLIENTNAME auto-detect), additive to every prior round.
    func testUiuxGainsARound16SectionNamingTheAutoDetectMechanism() throws {
        let text = try String(contentsOf: RepoPathsRound16.agentsUiux, encoding: .utf8)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("round 16"),
            "agents/uiux.md must gain a new section labelled round 16 (CUESYNC-9)")
        XCTAssertTrue(text.contains("SESSIONNAME") && text.contains("CLIENTNAME"),
            "agents/uiux.md's round-16 section must name the concrete SESSIONNAME/CLIENTNAME auto-detect, " +
            "not just restate the generic 'default to the real path' lesson")
    }

    /// Additive, not destructive: the round-15 lesson must survive.
    func testUiuxRound16SectionDoesNotRemoveTheRound15Section() throws {
        let text = try String(contentsOf: RepoPathsRound16.agentsUiux, encoding: .utf8)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("round 15"),
            "agents/uiux.md must still contain the round-15 lesson — round 16 is additive")
    }
}
