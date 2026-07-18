import Foundation
import XCTest

// =============================================================================
// Coverage for spec CUESYNC-7 §C (Header/Footer), §D.8 (CollapsibleSection), and the
// parts of §D.9/§K (ContentView/CueSyncApp) not already exercised by
// PortComplianceTests' wiring/menu checks. Landed in commits 9fc2f73/5148505/a017516
// with only allowlist bookkeeping (no behavioral tests) — see 88a9461 "test: add
// suite", which predates all three commits and only covers §A/§B.
//
// Like CrossUIFoundationTests.swift, these files compile only under
// `#if CUESYNC_CROSSUI` with a `SwiftCrossUI` import, so CueSyncCoreTests (which
// depends on CueSyncCore/CSQLite/CZlib only) cannot import or execute them — these
// tests pin source text instead: the exact glyphs/strings spec §C calls out
// ("do not invent"), the drag-reorder omission spec §D.8 requires, and the
// state-wiring spec §D.9/§K require.
// =============================================================================

final class CrossUIChromeTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let sourceRoot = repoRoot.appendingPathComponent("CueSync/CueSync")
    private static let uiDir = sourceRoot.appendingPathComponent("UI")

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.uiDir.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - HeaderView (spec §C.6)

    /// spec §C.6: "the tagline Text (exact string + •/→ glyphs from the source — do not
    /// invent)". Pins the literal brand sequence and separators so a future edit can't
    /// silently drop or reorder a partner name.
    func testHeaderViewTaglineListsAllFourImportSourcesInOrderWithExactGlyphs() throws {
        let src = try read("HeaderView.swift")
        let brands = ["Rekordbox", "Serato", "Engine DJ", "ShowKontrol", "Resolume"]
        var searchStart = src.startIndex
        for brand in brands {
            guard let range = src.range(of: brand, range: searchStart..<src.endIndex) else {
                XCTFail("HeaderView.swift tagline is missing '\(brand)' or it is out of order (spec §C.6)")
                return
            }
            searchStart = range.upperBound
        }
        // Source text (read raw, unparsed) still carries `\u{2022}` as an escape-sequence
        // literal, not the resolved • character — search for the escape text itself,
        // not `"\u{2022}"` (which would compile to the resolved glyph in *this* test
        // file and could only match by coincidence, e.g. an adjacent human-readable
        // comment repeating the same glyph).
        XCTAssertTrue(src.contains("\\u{2022}"), "HeaderView.swift tagline must use the \\u{2022} (•) separator glyph")
        XCTAssertTrue(src.contains("\\u{2192}"), "HeaderView.swift tagline must use the \\u{2192} (→) glyph before Resolume")
    }

    /// spec §C.6: logo is "◈ / CUE white / SYNC accent-green via three Text", the unsaved
    /// indicator binds `state.hasUnsavedChanges`, and the version badge is a fixed "v1.0.0"
    /// built from a stroked RoundedRectangle background (no `.border`, which spec §0.3
    /// establishes has no swift-cross-ui equivalent).
    func testHeaderViewBindsProjectNameAndUnsavedIndicatorAndDeclaresVersionBadge() throws {
        let src = try read("HeaderView.swift")
        XCTAssertTrue(src.contains("\\u{25C8}"), "HeaderView.swift must render the \\u{25C8} (◈) logo glyph (spec §C.6)")
        XCTAssertTrue(src.contains("Text(\"CUE\")"), "HeaderView.swift must render a literal 'CUE' Text (spec §C.6)")
        XCTAssertTrue(src.contains("Text(\"SYNC\")"), "HeaderView.swift must render a literal 'SYNC' Text (spec §C.6)")
        XCTAssertTrue(src.contains("state.projectName"),
                      "HeaderView.swift must bind the project-name Text to state.projectName (spec §C.6)")
        XCTAssertTrue(src.contains("state.hasUnsavedChanges"),
                      "HeaderView.swift must bind the unsaved indicator to state.hasUnsavedChanges (spec §C.6)")
        XCTAssertTrue(src.contains("\"v1.0.0\""), "HeaderView.swift must render the version badge text v1.0.0 (spec §C.6)")
        XCTAssertFalse(src.contains(".border("),
                       "HeaderView.swift must not call .border — spec §0.3 says it has no swift-cross-ui " +
                       "equivalent; the version badge border must be a stroked RoundedRectangle instead")
    }

    // MARK: - FooterView (spec §C.7)

    /// spec §C.7: "full-width HStack of the exact footer strings/glyphs ... with the top
    /// hairline as a thin Rectangle in a ZStack." Pins the exact sequence macOS's
    /// Views/FooterView.swift renders, in order, so a re-host edit can't drop or reorder one.
    func testFooterViewListsExactStringsInOrderWithTopHairline() throws {
        let src = try read("FooterView.swift")
        let expectedInOrder = [
            "Built for VJs", "Rekordbox", "Serato", "Engine DJ", "ShowKontrol", "Resolume",
        ]
        var searchStart = src.startIndex
        for text in expectedInOrder {
            guard let range = src.range(of: "\"\(text)\"", range: searchStart..<src.endIndex) else {
                XCTFail("FooterView.swift is missing '\(text)' or it is out of order (spec §C.7)")
                return
            }
            searchStart = range.upperBound
        }
        XCTAssertTrue(src.contains(".overlay(alignment: .top)"),
                      "FooterView.swift must draw the top hairline via .overlay(alignment: .top) (spec §C.7)")
        XCTAssertTrue(src.contains("colors.sectionBG"),
                      "FooterView.swift must sit on colors.sectionBG (spec §C.7)")
    }

    // MARK: - CollapsibleSection (spec §D.8)

    /// spec §D.8: "minus the drag-reorder ... Omit .draggable/.dropDestination reordering
    /// and the hover/opacity/animation ... section order stays the fixed logical order."
    /// The macOS original (Views/CollapsibleSection.swift) uses all of these — this test
    /// guards against a future edit re-introducing any of them from the macOS file, which
    /// would either fail to compile (no such API at 0.8.0) or silently reintroduce
    /// unportable drag state.
    func testCollapsibleSectionOmitsDragReorderAPIsNotAvailableAtPinnedSwiftCrossUIVersion() throws {
        let src = try read("CollapsibleSection.swift")
        for banned in [".draggable(", ".dropDestination(", ".onKeyPress(", "draggedSection", "preDragSectionOrder"] {
            XCTAssertFalse(src.contains(banned),
                           "UI/CollapsibleSection.swift must not use '\(banned)' — spec §D.8 explicitly omits " +
                           "section drag-reorder (no 0.8.0 equivalent)")
        }
    }

    /// spec §D.8: the header row toggles membership in `state.collapsedSections` and
    /// persists via `state.savePreferences()` — the behavioral core of "a generic wrapper
    /// mirroring Views/CollapsibleSection.swift".
    func testCollapsibleSectionHeaderTapTogglesCollapsedSectionsAndSavesPreferences() throws {
        let src = try read("CollapsibleSection.swift")
        for required in ["state.collapsedSections.remove(id)", "state.collapsedSections.insert(id)", "state.savePreferences()"] {
            XCTAssertTrue(src.contains(required),
                          "UI/CollapsibleSection.swift must call '\(required)' from its header tap handler (spec §D.8)")
        }
        XCTAssertTrue(src.contains(".onTapGesture"),
                      "UI/CollapsibleSection.swift header must use .onTapGesture — swift-cross-ui's Button has " +
                      "no ViewBuilder label (spec §0.3), so the header can't be a real Button { } label: { }")
    }

    /// spec §D.8: "▶/▼ collapse glyph" — the visual state cue that isCollapsed actually drives.
    func testCollapsibleSectionCollapseGlyphSwitchesOnIsCollapsedState() throws {
        let src = try read("CollapsibleSection.swift")
        XCTAssertTrue(src.contains("isCollapsed ? \"\\u{25B6}\" : \"\\u{25BC}\""),
                      "UI/CollapsibleSection.swift must show \\u{25B6} (▶) when collapsed and \\u{25BC} (▼) when expanded (spec §D.8)")
    }

    // MARK: - ContentView side-by-side + trailing label (spec §D.9)

    /// spec §D.9: "Support state.sideBySideMode as an HStack of two VStack columns." Confirms
    /// ContentView actually reads the two column-partition properties AppState exposes
    /// (`leftColumnSections`/`rightColumnSections`), not just `sectionOrder` twice.
    func testContentViewSideBySideModeUsesLeftAndRightColumnSectionsFromState() throws {
        let src = try read("ContentView.swift")
        XCTAssertTrue(src.contains("state.sideBySideMode"),
                      "UI/ContentView.swift must branch on state.sideBySideMode (spec §D.9)")
        XCTAssertTrue(src.contains("state.leftColumnSections"),
                      "UI/ContentView.swift must render state.leftColumnSections in the side-by-side left column (spec §D.9)")
        XCTAssertTrue(src.contains("state.rightColumnSections"),
                      "UI/ContentView.swift must render state.rightColumnSections in the side-by-side right column (spec §D.9)")
    }

    /// spec §D.9: "the Configure trailing 'active/total points active' label."
    func testContentViewConfigureSectionShowsActiveOverTotalPointsTrailingLabel() throws {
        let src = try read("ContentView.swift")
        XCTAssertTrue(src.contains("points active"),
                      "UI/ContentView.swift must show a 'N/M points active' trailing label on the Configure section (spec §D.9)")
        XCTAssertTrue(src.contains("state.cuePoints.filter(\\.enabled).count"),
                      "UI/ContentView.swift's active-points count must come from state.cuePoints.filter(\\.enabled).count")
    }

    /// spec §D.9: every section id in AppState.sectionOrder's default set must route to a
    /// real section view — an unhandled id would silently render EmptyView() and the user
    /// would see a missing section with no error.
    func testContentViewSwitchHandlesAllFourDefaultSectionIds() throws {
        let src = try read("ContentView.swift")
        for id in ["\"project\"", "\"browse\"", "\"configure\"", "\"export\""] {
            XCTAssertTrue(src.contains("case \(id):"),
                          "UI/ContentView.swift's section switch must handle \(id) (spec §D.9)")
        }
    }

    // MARK: - CueSyncApp menu commands (spec §K.25)

    /// spec §K.25: "Add menu commands via Scene.commands/CommandMenu ... New/Open/Save/
    /// Export/Undo/Redo." §K's own PORT note narrows this to the dialog-free subset (New/
    /// Undo/Redo) since Open/Save/Export need a View's @Environment file-dialog actions.
    /// This pins that the three that *are* wired actually call the AppState methods, not
    /// just that the words ".commands"/"CommandMenu" appear somewhere (which
    /// `testUICueSyncAppWiresAppStateAndDeclaresMenuCommands` already checks).
    func testCueSyncAppMenuCommandsCallTheDocumentedAppStateMethods() throws {
        let src = try read("CueSyncApp.swift")
        XCTAssertTrue(src.contains("CommandMenu(\"File\")"), "UI/CueSyncApp.swift must declare a \"File\" CommandMenu (spec §K.25)")
        XCTAssertTrue(src.contains("CommandMenu(\"Edit\")"), "UI/CueSyncApp.swift must declare an \"Edit\" CommandMenu (spec §K.25)")
        XCTAssertTrue(src.contains("Button(\"New Project\") { state.confirmNewProject() }"),
                      "UI/CueSyncApp.swift's File menu must wire New Project to state.confirmNewProject() (spec §K.25)")
        XCTAssertTrue(src.contains("Button(\"Undo\") { state.undo() }"),
                      "UI/CueSyncApp.swift's Edit menu must wire Undo to state.undo() (spec §K.25)")
        XCTAssertTrue(src.contains("Button(\"Redo\") { state.redo() }"),
                      "UI/CueSyncApp.swift's Edit menu must wire Redo to state.redo() (spec §K.25)")
    }
}
