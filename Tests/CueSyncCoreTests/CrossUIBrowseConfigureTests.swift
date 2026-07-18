import Foundation
import XCTest

// =============================================================================
// Coverage for spec CUESYNC-7 §F (BrowseSectionView) and §G — "the hard part"
// (EnvelopeCanvasView, CuePointsTableView, DurationInputView, ConfigureSectionView).
// Landed in commits 3fb0a6b and a1ab7ef with only allowlist bookkeeping, no
// behavioral tests (see CrossUIChromeTests.swift's header comment for the same gap
// analysis).
//
// §G.14/§4 call out the canvas as the single largest regression risk in this ticket:
// "Guard duration > 0 and clamp all normalized values to [0,1] so no non-finite
// coordinate reaches Cairo ... dropping any clamp during the re-host is the one real
// regression risk here." EnvelopeCanvasView.swift does this by *delegating* to
// CuePoint.normalizedX(duration:)/normalizedY (already unit-tested for the zero-
// duration and non-finite cases in ModelsTests.swift) rather than re-deriving the
// division inline — testEnvelopeCanvasDelegatesCoordinateMathToCuePointsGuardedAccessors
// below is the one test in this file that most directly guards against that
// regression: an inlined `cue.start / duration` would compile fine and pass every
// visual check, but divide by zero on an empty envelope.
//
// Same constraint as the sibling CrossUI*Tests files: `#if CUESYNC_CROSSUI`-gated,
// SwiftCrossUI-importing, so CueSyncCoreTests cannot compile or execute them — these
// tests pin source text.
// =============================================================================

final class CrossUIBrowseConfigureTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let sectionsDir = repoRoot.appendingPathComponent("CueSync/CueSync/UI/Sections")

    private func read(_ fileName: String) throws -> String {
        try String(contentsOf: Self.sectionsDir.appendingPathComponent(fileName), encoding: .utf8)
    }

    private func body(of funcSignature: String, in src: String, window: Int = 800) -> Substring? {
        guard let range = src.range(of: funcSignature) else { return nil }
        let end = src.index(range.upperBound, offsetBy: window, limitedBy: src.endIndex) ?? src.endIndex
        return src[range.upperBound..<end]
    }

    // MARK: - BrowseSectionView (spec §F.13)

    /// spec §F.13: "empty-state message when tracks.isEmpty."
    func testBrowseSectionShowsEmptyStateWhenNoTracksLoaded() throws {
        let src = try read("BrowseSectionView.swift")
        XCTAssertTrue(src.contains("if state.tracks.isEmpty {"),
                      "BrowseSectionView.swift must gate its empty state on state.tracks.isEmpty (spec §F.13)")
    }

    /// spec §F.13: "the playlist sidebar (... 'All Tracks' row then a recursive ForEach
    /// over state.playlists with folder expand/collapse driven by state.expandedFolders)."
    func testBrowseSectionAllTracksRowAndRecursivePlaylistTreeWireToState() throws {
        let src = try read("BrowseSectionView.swift")
        XCTAssertTrue(src.contains("name: \"All Tracks\""), "the sidebar must show an 'All Tracks' row (spec §F.13)")
        XCTAssertTrue(src.contains("state.selectedPlaylistId = \"all\""),
                      "the All Tracks row must select the sentinel playlist id \"all\" (spec §F.13)")
        XCTAssertTrue(src.contains("ForEach(state.playlists) { playlist in"),
                      "the sidebar must iterate state.playlists (spec §F.13)")
        XCTAssertTrue(src.contains("PlaylistItemView(playlist: child, depth: depth + 1)"),
                      "PlaylistItemView must recurse into child playlists (spec §F.13: recursive ForEach)")
        XCTAssertTrue(src.contains("state.expandedFolders.contains(playlist.id)"),
                      "folder expand/collapse must be driven by state.expandedFolders (spec §F.13)")
    }

    /// spec §F.13: "search TextField bound to state.searchQuery; Sort Picker .menu bound
    /// to state.sortBy over SortField.allCases."
    func testBrowseSectionSearchAndSortBindToStateSearchQueryAndSortBy() throws {
        let src = try read("BrowseSectionView.swift")
        XCTAssertTrue(src.contains("TextField(\"Search tracks, artists, albums...\", text: state.$searchQuery)"),
                      "the search field must be a two-way binding to state.searchQuery (spec §F.13)")
        XCTAssertTrue(src.contains("Picker(of: AppState.SortField.allCases, selection: sortBinding)"),
                      "the sort picker must be built over AppState.SortField.allCases (spec §F.13)")
        XCTAssertTrue(src.contains(".pickerStyle(.menu)"),
                      "the sort picker must use .menu style — spec §0.3: Picker is dropdown-only on Gtk")
        XCTAssertTrue(src.contains("get: { state.sortBy }"),
                      "the sort binding must read from state.sortBy (spec §F.13)")
    }

    /// spec §F.13: "a ScrollView+ForEach over state.filteredTracks of track rows ...
    /// 'Showing X of Y' footer." Row tap selects via state.selectTrack.
    func testBrowseSectionTrackListIteratesFilteredTracksAndFooterShowsCounts() throws {
        let src = try read("BrowseSectionView.swift")
        XCTAssertTrue(src.contains("ForEach(state.filteredTracks) { track in"),
                      "the track list must iterate state.filteredTracks, not state.tracks directly (spec §F.13)")
        XCTAssertTrue(src.contains("state.selectTrack(track)"),
                      "a track row tap must call state.selectTrack(track) (spec §F.13)")
        XCTAssertTrue(src.contains("Showing \\(state.filteredTracks.count) of \\(state.tracks.count) tracks"),
                      "the footer must show 'Showing <filtered> of <total> tracks' (spec §F.13)")
    }

    // MARK: - ConfigureSectionView (spec §G.17)

    /// spec §G.17: empty state only when there's neither a selected track nor any cues.
    func testConfigureSectionEmptyStateRequiresNoCuesAndNoSelectedTrack() throws {
        let src = try read("ConfigureSectionView.swift")
        XCTAssertTrue(src.contains("if state.cuePoints.isEmpty && state.selectedTrackId == nil {"),
                      "the empty state must require both state.cuePoints.isEmpty and state.selectedTrackId == nil " +
                      "(spec §G.17) — a manually-built envelope with no selected track must still show the editor")
    }

    /// spec §G.17: "Add Cue button -> state.addCuePoint." Must de-duplicate against an
    /// existing cue at (near) the same position first — the macOS behavior this ports.
    func testConfigureSectionAddCueButtonDedupesBeforeCallingAddCuePoint() throws {
        let src = try read("ConfigureSectionView.swift")
        guard let addBody = body(of: "private func addCueAtPosition() {", in: src) else {
            XCTFail("ConfigureSectionView.swift is missing addCueAtPosition()")
            return
        }
        XCTAssertTrue(addBody.contains("abs($0.start - time) < 0.001"),
                      "addCueAtPosition() must skip adding a duplicate within 1ms of an existing cue (spec §G.17)")
        XCTAssertTrue(addBody.contains("state.addCuePoint(at: time)"),
                      "addCueAtPosition() must call state.addCuePoint(at:) (spec §G.17)")
    }

    /// spec §G.17: "the offset tool -> state.duplicateSelectedWithOffset." Both -/+
    /// directions must be guarded on an actual selection (nil selectedPointIndex must be a
    /// no-op, not a crash from force-unwrapping).
    func testConfigureSectionOffsetToolGuardsOnSelectionBeforeDuplicating() throws {
        let src = try read("ConfigureSectionView.swift")
        guard let offsetBody = body(of: "private func offsetTool(_ colors: ThemeColors) -> some View {", in: src, window: 1500) else {
            XCTFail("ConfigureSectionView.swift is missing offsetTool(_:)")
            return
        }
        XCTAssertTrue(offsetBody.contains("let hasSelection = state.selectedPointIndex != nil"),
                      "offsetTool must compute hasSelection from state.selectedPointIndex (spec §G.17)")
        XCTAssertTrue(offsetBody.contains("guard hasSelection else { return }"),
                      "both offset buttons must guard on hasSelection before duplicating (spec §G.17)")
        XCTAssertTrue(offsetBody.contains("state.duplicateSelectedWithOffset(offsetMs: -offset)"),
                      "the minus button must call state.duplicateSelectedWithOffset with a negative offset (spec §G.17)")
        XCTAssertTrue(offsetBody.contains("state.duplicateSelectedWithOffset(offsetMs: offset)"),
                      "the plus button must call state.duplicateSelectedWithOffset with a positive offset (spec §G.17)")
    }

    /// spec §G.17: "the Lock X / Lock Y Toggles (checkbox style) bound to state.lockXAxis/
    /// lockYAxis."
    func testConfigureSectionLockTogglesBindToStateLockAxisFlagsWithCheckboxStyle() throws {
        let src = try read("ConfigureSectionView.swift")
        // Source text (read raw) carries `\u{1F512}` as an escape-sequence literal, not
        // the resolved 🔒 character — search for the escape text itself.
        XCTAssertTrue(src.contains("Toggle(\"\\u{1F512} Lock X\", isOn: state.$lockXAxis)"),
                      "Lock X toggle must bind to state.lockXAxis (spec §G.17)")
        XCTAssertTrue(src.contains("Toggle(\"\\u{1F512} Lock Y\", isOn: state.$lockYAxis)"),
                      "Lock Y toggle must bind to state.lockYAxis (spec §G.17)")
        XCTAssertTrue(src.contains(".toggleStyle(.checkbox)"),
                      "the Lock toggles must use checkbox style — spec §0.3: Toggle has no other portable style noted")
    }

    /// spec §G.17: "Delete-selected via a Remove button." Must guard on
    /// state.canRemoveSelectedPoint before calling state.removeSelectedPoint() — the
    /// macOS original never lets the fixed start/end points be removed.
    func testConfigureSectionRemoveButtonGuardsOnCanRemoveSelectedPoint() throws {
        let src = try read("ConfigureSectionView.swift")
        XCTAssertTrue(src.contains("if state.canRemoveSelectedPoint { state.removeSelectedPoint() }"),
                      "the Remove button must guard on state.canRemoveSelectedPoint before calling " +
                      "state.removeSelectedPoint() (spec §G.17)")
    }

    /// spec §G.17: "optional Load-Audio using AudioDuration from CueSyncCore instead of
    /// AVFoundation." Must route the parsed duration through AppState.safeDuration — the
    /// same clamp the Duration modal confirmation path uses (spec §4).
    func testConfigureSectionLoadAudioUsesCueSyncCoreAudioDurationAndSafeDurationGuard() throws {
        let src = try read("ConfigureSectionView.swift")
        guard let loadBody = body(of: "private func loadAudioFile() {", in: src) else {
            XCTFail("ConfigureSectionView.swift is missing loadAudioFile()")
            return
        }
        XCTAssertTrue(loadBody.contains("AudioDuration.duration(of: url)"),
                      "loadAudioFile() must use CueSyncCore.AudioDuration, not AVFoundation (spec §G.17, §0.1 premise 2)")
        XCTAssertTrue(loadBody.contains("AppState.safeDuration(duration)"),
                      "loadAudioFile() must clamp the parsed duration through AppState.safeDuration before " +
                      "assigning state.trackDuration (spec §4)")
    }

    // MARK: - EnvelopeCanvasView (spec §G.14 — "the hard part")

    /// spec §G.14/§4: the coordinate math must go through CuePoint's own guarded
    /// accessors — `normalizedX(duration:)` (guards duration > 0 and clamps to [0,1],
    /// verified in ModelsTests.testNormalizedXWithZeroDurationReturnsZero) and
    /// `normalizedY` (clamps non-finite yValue to 0, verified in ModelsTests) — rather
    /// than re-deriving `start / duration` or `yValue / 100` inline in the canvas. An
    /// inlined division would compile and render correctly on any populated envelope, and
    /// only misbehave (NaN passed to Cairo) on the one case that matters: a track with
    /// duration == 0 or a hostile file's non-finite yValue, which is exactly the failure
    /// mode spec §4 warns "a hostile file cannot produce NaN geometry" against.
    func testEnvelopeCanvasDelegatesCoordinateMathToCuePointsGuardedAccessors() throws {
        let src = try read("EnvelopeCanvasView.swift")
        // Every point-coordinate computation site (enabledSorted's map, the selection
        // guide, and pointView) must independently go through the guarded accessor — a
        // count check, not a presence check, so a regression at any *one* of the three
        // call sites (while the other two still delegate correctly) still fails this
        // test. A plain "does this substring appear anywhere" check was verified (via a
        // deliberate local mutation of enabledSorted's map to `$0.start / duration`,
        // reverted after) to keep passing as long as any other legitimate call site
        // survived — this count-based version catches that.
        let normXCount = src.components(separatedBy: ".normalizedX(duration:").count - 1
        let normYCount = src.components(separatedBy: ".normalizedY").count - 1
        XCTAssertEqual(normXCount, 3,
                       "expected exactly 3 call sites for CuePoint.normalizedX(duration:) — enabledSorted's map, " +
                       "the selection guide, and pointView — got \(normXCount) (spec §4)")
        XCTAssertEqual(normYCount, 2,
                       "expected exactly 2 call sites for CuePoint.normalizedY — enabledSorted's map and " +
                       "pointView — got \(normYCount) (spec §4)")
        for bannedDivision in ["start / duration", "start/duration", "yValue / 100", "yValue/100", "yValue / 100.0"] {
            XCTAssertFalse(src.contains(bannedDivision),
                           "EnvelopeCanvasView must not inline an unguarded division ('\(bannedDivision)') that " +
                           "bypasses CuePoint's normalizedX/normalizedY clamps (spec §4)")
        }
    }

    /// spec §G.14: "there is no Canvas and, critically, no drag/pointer API at 0.8.0" —
    /// the drawing must be Shape-based, not attempt the unavailable immediate-mode API.
    func testEnvelopeCanvasUsesShapesNotCanvasOrGraphicsContext() throws {
        let src = try read("EnvelopeCanvasView.swift")
        XCTAssertTrue(src.contains(": Shape"), "EnvelopeCanvasView's drawing layers must conform to Shape (spec §G.14)")
        // The file's own PORT comments name "GraphicsContext"/"DragGesture" explicitly to
        // document *why* they aren't used — strip comment lines before searching so that
        // explanatory prose can't trip a false positive on the very thing it's disclaiming.
        let codeOnly = src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let commentStart = line.range(of: "//") { return line[line.startIndex..<commentStart.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        for banned in ["Canvas {", "GraphicsContext", "DragGesture"] {
            XCTAssertFalse(codeOnly.contains(banned),
                           "EnvelopeCanvasView must not use '\(banned)' in actual code — no such API at the " +
                           "pinned swift-cross-ui revision (spec §0.3/§G.14)")
        }
    }

    /// spec §2.G.14: "the same margins/graph rect, the 10×4 grid."
    func testEnvelopeCanvasGridIsTenColumnsByFourRows() throws {
        let src = try read("EnvelopeCanvasView.swift")
        guard let gridBody = body(of: "private struct EnvelopeGridShape: Shape {", in: src, window: 500) else {
            XCTFail("EnvelopeCanvasView.swift is missing EnvelopeGridShape")
            return
        }
        XCTAssertTrue(gridBody.contains("let cols = 10"), "the envelope grid must have 10 columns (spec §G.14)")
        XCTAssertTrue(gridBody.contains("let rows = 4"), "the envelope grid must have 4 rows (spec §G.14)")
    }

    /// spec §G.14: "the per-segment eased curve (CurveType.evaluate(curve, t:), keyed off
    /// the destination point)" and "the point circles (normal / selected-larger /
    /// disabled-gray)."
    func testEnvelopeCanvasCurveEvaluationKeyedOffDestinationPointAndPointRadiiDifferByState() throws {
        let src = try read("EnvelopeCanvasView.swift")
        XCTAssertTrue(src.contains("CurveType.evaluate(curr.curve, t: t)"),
                      "the curve segment must ease using the destination point's curve (curr.curve), not the " +
                      "origin point's (spec §G.14: 'keyed off the destination point')")
        XCTAssertTrue(src.contains("radius: isSelected ? 7 : 5"),
                      "an enabled point's radius must be 7 when selected and 5 otherwise (spec §G.14)")
        XCTAssertTrue(src.contains("radius: 3") && src.contains("Color.gray.opacity(0.4)"),
                      "a disabled point must render smaller (radius 3) and gray (spec §G.14)")
    }

    // MARK: - CuePointsTableView (spec §G.15)

    /// spec §G.15: "header row of column labels" in the documented order.
    func testCuePointsTableHeaderColumnsAreInDocumentedOrder() throws {
        let src = try read("CuePointsTableView.swift")
        let expectedInOrder = ["\"ON\"", "\"NAME\"", "\"POSITION (S)\"", "\"X (0-100)\"", "\"Y (0-100)\"", "\"INTERPOLATION\""]
        var searchStart = src.startIndex
        for header in expectedInOrder {
            guard let range = src.range(of: header, range: searchStart..<src.endIndex) else {
                XCTFail("CuePointsTableView.swift is missing header \(header) or it is out of order (spec §G.15)")
                return
            }
            searchStart = range.upperBound
        }
    }

    /// spec §G.15: "an enable Toggle ... an editable name TextField ... Position and Y
    /// StepperFields ... writing through state.updateCuePoint(at:)."
    func testCuePointsTableEditsWriteThroughUpdateCuePointAt() throws {
        let src = try read("CuePointsTableView.swift")
        for mutation in [
            "state.updateCuePoint(at: index) { $0.enabled = newVal }",
            "state.updateCuePoint(at: index) { $0.name = newVal }",
            "state.updateCuePoint(at: index) { $0.start = newVal }",
            "state.updateCuePoint(at: index) { $0.yValue = newVal }",
            "state.updateCuePoint(at: index) { $0.curve = newVal.id }",
        ] {
            XCTAssertTrue(src.contains(mutation),
                          "cue row edits must write through state.updateCuePoint(at:): missing '\(mutation)' (spec §G.15)")
        }
    }

    /// spec §G.15: Position/Y editing must respect the Lock X/Lock Y toggles and the
    /// fixed start/end points — a hostile or careless edit to the envelope's first/last
    /// point would break `ensureStartAndEndPoints`'s invariant that x=0 and x=duration
    /// always exist.
    func testCuePointsTablePositionAndYFieldsRespectLockAxesAndStartEndPoints() throws {
        let src = try read("CuePointsTableView.swift")
        XCTAssertTrue(src.contains("let posDisabled = !cue.enabled || state.lockXAxis || isStartOrEnd"),
                      "Position must be disabled when the cue is off, Lock X is on, or it's the start/end point (spec §G.15)")
        XCTAssertTrue(src.contains("let yDisabled = !cue.enabled || state.lockYAxis"),
                      "Y must be disabled when the cue is off or Lock Y is on (spec §G.15)")
        XCTAssertTrue(src.contains("index == 0 || index == state.cuePoints.count - 1"),
                      "isStartOrEnd must identify the first and last cue points (spec §G.15)")
    }

    /// spec §G.15: "Row tap selects (state.selectedPointIndex) — this is the canvas's
    /// selection substitute." A disabled row must not become selectable (matches the
    /// canvas, which never draws a selection guide for a disabled point).
    func testCuePointsTableRowTapSelectsOnlyWhenCueEnabled() throws {
        let src = try read("CuePointsTableView.swift")
        guard let tapBody = body(of: ".onTapGesture {", in: src, window: 150) else {
            XCTFail("CuePointsTableView.swift's row is missing .onTapGesture")
            return
        }
        XCTAssertTrue(tapBody.contains("if cue.enabled {"),
                      "row tap-to-select must be gated on cue.enabled (spec §G.15)")
        XCTAssertTrue(tapBody.contains("state.selectedPointIndex = index"),
                      "row tap must set state.selectedPointIndex (spec §G.15)")
    }

    /// spec §0.3/§L: ColorPicker is Apple-only and its editing is deferred, not
    /// reproduced — the color cell must be a static swatch, never an interactive picker.
    func testCuePointsTableColorCellIsAStaticSwatchNotAColorPicker() throws {
        let src = try read("CuePointsTableView.swift")
        // The file's own PORT comment mentions "ColorPicker" by name to explain the
        // deferral — search for an actual invocation (with the call parenthesis), not
        // the bare word, so that explanatory comment doesn't trip a false positive.
        XCTAssertFalse(src.contains("ColorPicker("),
                       "CuePointsTableView.swift must not instantiate ColorPicker — Apple-only, deferred per spec §G.15/§L")
        let collapsed = src.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        XCTAssertTrue(collapsed.contains("Circle() .fill(Color(cssString: cue.color))"),
                      "the color cell must render a static Circle swatch via Color(cssString:) (spec §G.15)")
    }

    // MARK: - DurationInputView (spec §G.16)

    /// spec §G.16: "label (ENVELOPE LENGTH / TRACK DURATION per selectedTrackId)."
    func testDurationInputViewLabelSwitchesOnSelectedTrackId() throws {
        let src = try read("DurationInputView.swift")
        XCTAssertTrue(src.contains("let isEnvelope = state.selectedTrackId == nil"),
                      "DurationInputView must derive isEnvelope from state.selectedTrackId == nil (spec §G.16)")
        XCTAssertTrue(src.contains("isEnvelope ? \"ENVELOPE LENGTH\" : \"TRACK DURATION\""),
                      "the label must read ENVELOPE LENGTH with no track selected, TRACK DURATION otherwise (spec §G.16)")
    }

    /// spec §G.16: "writing through state.updateDurationWithScaling." Must not commit a
    /// zero/negative total (matches macOS: an empty or all-zero field shouldn't collapse
    /// the envelope to duration 0, which would make every cue's normalizedX 0/0).
    func testDurationInputViewCommitOnlyScalesWhenTotalIsPositive() throws {
        let src = try read("DurationInputView.swift")
        guard let commitBody = body(of: "private func commitDuration() {", in: src) else {
            XCTFail("DurationInputView.swift is missing commitDuration()")
            return
        }
        XCTAssertTrue(commitBody.contains("if total > 0 {"),
                      "commitDuration() must only call updateDurationWithScaling when total > 0 (spec §G.16, §4)")
        XCTAssertTrue(commitBody.contains("state.updateDurationWithScaling(total)"),
                      "commitDuration() must call state.updateDurationWithScaling(total) (spec §G.16)")
    }

    /// spec §G.16: the local sec/ms fields must stay in sync with state.trackDuration,
    /// both at first appearance and whenever it changes elsewhere (e.g. an import or the
    /// canvas's own scaling) — otherwise the fields could show stale values after an
    /// external duration change.
    func testDurationInputViewSyncsFromStateOnAppearAndOnDurationChange() throws {
        let src = try read("DurationInputView.swift")
        XCTAssertTrue(src.contains(".onAppear { syncFromState() }"),
                      "DurationInputView must sync its local fields from state on appear (spec §G.16)")
        XCTAssertTrue(src.contains(".onChange(of: state.trackDuration) { syncFromState() }"),
                      "DurationInputView must re-sync when state.trackDuration changes externally (spec §G.16)")
    }
}
