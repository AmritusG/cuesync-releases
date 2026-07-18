import Foundation
import XCTest

// =============================================================================
// Coverage for spec CUESYNC-7 §E (ProjectSectionView), §I (DurationInputModal), and
// §H (ExportSectionView) — landed in commits b3d3b9b and a017516 with only allowlist
// bookkeeping, no behavioral tests (see CrossUIChromeTests.swift's header comment for
// the same gap analysis). These three views share one file because they're the
// import/export "file I/O wiring" trio §E.11/§H.18 describe, and the duration modal is
// the shared hand-off point between them (§E.11 -> §I.19).
//
// Same constraint as the sibling CrossUI*Tests files: `#if CUESYNC_CROSSUI`-gated,
// SwiftCrossUI-importing, so CueSyncCoreTests (CueSyncCore/CSQLite/CZlib only) cannot
// compile or execute them — these tests pin source text: the exact AppState method
// each button calls (the wiring spec §E.11/§H.18 mandate), and the safeDuration/
// atomic-write guards spec §4's threat model calls out by name.
// =============================================================================

final class CrossUIProjectExportTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let sectionsDir = repoRoot.appendingPathComponent("CueSync/CueSync/UI/Sections")

    private func read(_ fileName: String) throws -> String {
        try String(contentsOf: Self.sectionsDir.appendingPathComponent(fileName), encoding: .utf8)
    }

    // MARK: - ProjectSectionView (spec §E.10/§E.11/§E.12)

    /// spec §E.10: "the labelled column groups — Project (New/Open/Save buttons)."
    /// New must never prompt about unsaved changes (it's the prompt itself, via
    /// confirmNewProject); Open must go through confirmAction so an unsaved project isn't
    /// silently discarded; Save must go through state.saveProject.
    func testProjectSectionNewOpenSaveButtonsCallDocumentedAppStateMethods() throws {
        let src = try read("ProjectSectionView.swift")
        XCTAssertTrue(src.contains("state.confirmNewProject()"),
                      "New button must call state.confirmNewProject() (spec §E.10/§E.12)")
        XCTAssertTrue(src.contains("state.confirmAction { openProject() }"),
                      "Open button must route through state.confirmAction so unsaved changes are guarded (spec §E.12)")
        XCTAssertTrue(src.contains("try state.loadProject(from: url)"),
                      "openProject() must call state.loadProject(from:) (spec §E.11)")
        XCTAssertTrue(src.contains("try state.saveProject(to: url)"),
                      "saveProject() must call state.saveProject(to:) (spec §E.11)")
    }

    /// spec §E.10: "Project Name (TextField bound to state.projectName)."
    func testProjectSectionNameFieldBindsToStateProjectName() throws {
        let src = try read("ProjectSectionView.swift")
        XCTAssertTrue(src.contains("TextField(\"Project Name\", text: state.$projectName)"),
                      "the Project Name field must be a two-way binding to state.projectName (spec §E.10)")
    }

    /// spec §E.10: "Design from Scratch (Create Envelope, gold)."
    func testProjectSectionCreateEnvelopeButtonCallsCreateBlankEnvelope() throws {
        let src = try read("ProjectSectionView.swift")
        XCTAssertTrue(src.contains("state.createBlankEnvelope()"),
                      "Create Envelope button must call state.createBlankEnvelope() (spec §E.10)")
        XCTAssertTrue(src.contains("accent: colors.accentGold"),
                      "Create Envelope button must use the gold accent (spec §E.10)")
    }

    /// spec §E.11: "Import/open/save wiring uses swift-cross-ui's file dialog actions ...
    /// calling the re-hosted state.loadRekordbox/loadSerato/loadEngineDJ/loadShowKontrol/
    /// loadResolumeEnvelope." One test per importer keeps a future accidental swap
    /// (e.g. Serato calling loadEngineDJ) from silently passing a looser "some import
    /// method is called somewhere" check.
    func testProjectSectionEachImportButtonCallsItsDocumentedLoader() throws {
        let src = try read("ProjectSectionView.swift")
        let expectations: [(action: String, loader: String)] = [
            ("importRekordbox", "try state.loadRekordbox(from: url)"),
            ("importSerato", "state.loadSerato(from: [url])"),
            ("importEngineDJ", "try state.loadEngineDJ(from: url)"),
            ("importShowKontrol", "try state.loadShowKontrol(from: url)"),
        ]
        for (action, loader) in expectations {
            guard let funcRange = src.range(of: "private func \(action)(") else {
                XCTFail("ProjectSectionView.swift is missing \(action)() (spec §E.11)")
                continue
            }
            let bodyStart = funcRange.upperBound
            // Bound the search to a reasonable window after the func signature so a match
            // in a later, unrelated function can't produce a false pass.
            let windowEnd = src.index(bodyStart, offsetBy: 700, limitedBy: src.endIndex) ?? src.endIndex
            XCTAssertTrue(src[bodyStart..<windowEnd].contains(loader),
                          "\(action)() must call \(loader) (spec §E.11)")
        }
    }

    /// spec §E.11: "ShowKontrol and Resolume imports (no embedded duration) present the
    /// Duration modal (§I) before committing, exactly as macOS does."
    func testProjectSectionResolumeAndShowKontrolWithoutTimingPresentDurationModal() throws {
        let src = try read("ProjectSectionView.swift")
        // importResolume unconditionally stages the duration modal.
        guard let resolumeFunc = src.range(of: "private func importResolume()") else {
            XCTFail("ProjectSectionView.swift is missing importResolume()")
            return
        }
        let resolumeWindowEnd = src.index(resolumeFunc.upperBound, offsetBy: 300, limitedBy: src.endIndex) ?? src.endIndex
        XCTAssertTrue(src[resolumeFunc.upperBound..<resolumeWindowEnd].contains("showDurationModal = true"),
                      "importResolume() must stage the Duration modal — Resolume envelopes carry no duration (spec §E.11)")

        // importShowKontrol only stages it when the parser didn't auto-detect timing.
        guard let showKontrolFunc = src.range(of: "private func importShowKontrol()") else {
            XCTFail("ProjectSectionView.swift is missing importShowKontrol()")
            return
        }
        let skWindowEnd = src.index(showKontrolFunc.upperBound, offsetBy: 500, limitedBy: src.endIndex) ?? src.endIndex
        let skBody = src[showKontrolFunc.upperBound..<skWindowEnd]
        XCTAssertTrue(skBody.contains("if !durationAutoDetected"),
                      "importShowKontrol() must only present the Duration modal when timing wasn't auto-detected (spec §E.11)")
        XCTAssertTrue(skBody.contains("showDurationModal = true"),
                      "importShowKontrol() must stage the Duration modal on the durationAutoDetected == false path (spec §E.11)")
    }

    /// spec §E.10: Viewport Reset/Side-By-Side, Theme Dark/Light, and Import Settings
    /// True/False all persist via state.savePreferences() (except Reset, which calls
    /// state.resetLayout() — the macOS behavior this ports verbatim).
    func testProjectSectionViewportThemeAndImportSettingsTogglesPersistPreferences() throws {
        let src = try read("ProjectSectionView.swift")
        XCTAssertTrue(src.contains("state.resetLayout()"), "Reset button must call state.resetLayout() (spec §E.10)")
        XCTAssertTrue(src.contains("state.sideBySideMode.toggle()"), "Side-By-Side button must toggle state.sideBySideMode (spec §E.10)")
        XCTAssertTrue(src.contains("state.theme = .dark"), "Dark button must set state.theme = .dark (spec §E.10)")
        XCTAssertTrue(src.contains("state.theme = .light"), "Light button must set state.theme = .light (spec §E.10)")
        XCTAssertTrue(src.contains("state.forceYZeroOnImport = true"), "True button must set state.forceYZeroOnImport = true (spec §E.10)")
        XCTAssertTrue(src.contains("state.forceYZeroOnImport = false"), "False button must set state.forceYZeroOnImport = false (spec §E.10)")
        // Every one of the four toggle actions above must persist — count occurrences of
        // savePreferences() rather than just asserting presence once, so a toggle that
        // silently drops its own save call (but leaves the string present elsewhere) is caught.
        let saveCallCount = src.components(separatedBy: "state.savePreferences()").count - 1
        XCTAssertGreaterThanOrEqual(saveCallCount, 4,
                                    "expected at least 4 state.savePreferences() calls (Side-By-Side, Dark, Light, " +
                                    "True/False) — got \(saveCallCount) (spec §E.10)")
    }

    /// spec §E.10: "the '✓ N tracks loaded' indicator" — only rendered once tracks exist.
    func testProjectSectionTracksLoadedIndicatorGatedOnNonEmptyTracks() throws {
        let src = try read("ProjectSectionView.swift")
        XCTAssertTrue(src.contains("if !state.tracks.isEmpty {"),
                      "the tracks-loaded indicator must be gated on !state.tracks.isEmpty (spec §E.10)")
        XCTAssertTrue(src.contains("\\(state.tracks.count) tracks loaded"),
                      "the indicator must show the live track count (spec §E.10)")
    }

    /// spec §E.12: "Keep the destructive/cancel semantics of confirmNewProject/
    /// confirmAction/executePendingAction." Discard must actually run the deferred action;
    /// Cancel must clear it without running it — losing either half would silently
    /// discard-without-asking or hang the pending action forever.
    func testProjectSectionUnsavedChangesAlertDiscardAndCancelHaveCorrectSemantics() throws {
        let src = try read("ProjectSectionView.swift")
        XCTAssertTrue(src.contains("Button(\"Discard\") { state.executePendingAction() }"),
                      "Discard must call state.executePendingAction() (spec §E.12)")
        XCTAssertTrue(src.contains("Button(\"Cancel\") { state.pendingAction = nil }"),
                      "Cancel must clear state.pendingAction without executing it (spec §E.12)")
    }

    // MARK: - DurationInputModal (spec §I.19)

    /// spec §I.19: "title, instruction, min/sec/ms TextFields, Cancel + Import buttons
    /// calling the onCancel/onConfirm closures passed from Project."
    func testDurationInputModalTitleFieldsAndButtonsWireToClosures() throws {
        let src = try read("DurationInputModal.swift")
        XCTAssertTrue(src.contains("\"Set Track Duration\""), "modal must show the title 'Set Track Duration' (spec §I.19)")
        for placeholder in ["\"01\"", "\"00\"", "\"000\""] {
            XCTAssertTrue(src.contains(placeholder), "modal must have a field placeholder \(placeholder) (spec §I.19)")
        }
        XCTAssertTrue(src.contains(".onTapGesture { onCancel() }"), "Cancel must call the onCancel closure (spec §I.19)")
        XCTAssertTrue(src.contains(".onTapGesture { onConfirm() }"), "Import must call the onConfirm closure (spec §I.19)")
    }

    /// spec §L: ".shadow ... dropped — no swift-cross-ui equivalent." Guards against
    /// re-copying `.shadow(color: .black.opacity(0.5), radius: 30, y: 10)` from the macOS
    /// original, which spec §I.19's own PORT note calls out by name.
    func testDurationInputModalDoesNotUseShadowModifier() throws {
        let src = try read("DurationInputModal.swift")
        XCTAssertFalse(src.contains(".shadow("),
                       "DurationInputModal.swift must not call .shadow — spec §I.19/§L says it has no " +
                       "swift-cross-ui equivalent and is dropped")
    }

    /// confirmDurationImport() in the caller (ProjectSectionView) must route the parsed
    /// total through AppState.safeDuration before ever assigning trackDuration directly —
    /// spec §4's threat model: "AppState.safeDuration clamping duration finite/positive/
    /// Int-safe ... dropping any clamp during the re-host is the one real regression risk."
    /// A hand-typed "nan"/"inf" string in any of the three fields must never reach
    /// trackDuration unclamped.
    func testProjectSectionDurationImportConfirmationRoutesThroughSafeDuration() throws {
        let src = try read("ProjectSectionView.swift")
        guard let confirmFunc = src.range(of: "private func confirmDurationImport()") else {
            XCTFail("ProjectSectionView.swift is missing confirmDurationImport()")
            return
        }
        let windowEnd = src.index(confirmFunc.upperBound, offsetBy: 700, limitedBy: src.endIndex) ?? src.endIndex
        let body = src[confirmFunc.upperBound..<windowEnd]
        XCTAssertTrue(body.contains("AppState.safeDuration(totalSeconds)"),
                      "confirmDurationImport()'s ShowKontrol path must clamp through AppState.safeDuration " +
                      "before assigning state.trackDuration (spec §4)")
    }

    // MARK: - ExportSectionView (spec §H.18)

    /// spec §H.18: "empty-state when no cues."
    func testExportSectionShowsEmptyStateWhenNoCuePoints() throws {
        let src = try read("ExportSectionView.swift")
        XCTAssertTrue(src.contains("if state.cuePoints.isEmpty {"),
                      "ExportSectionView.swift must gate its empty state on state.cuePoints.isEmpty (spec §H.18)")
    }

    /// spec §H.18: "the Preset-name TextField (bound to state.presetName)."
    func testExportSectionPresetNameFieldBindsToStatePresetName() throws {
        let src = try read("ExportSectionView.swift")
        XCTAssertTrue(src.contains("TextField(\"Preset Name\", text: state.$presetName)"),
                      "the Preset Name field must be a two-way binding to state.presetName (spec §H.18)")
    }

    /// spec §H.18: "Wire both to the save-file dialog (§J) writing state.xmlPreview /
    /// ShowKontrolExporter.generate(cuePoints:) via String.write(to:atomically:encoding:)."
    /// Both must guard against an empty payload (no cues yet) before ever opening the save
    /// dialog — the macOS behavior this ports verbatim.
    func testExportSectionSaveButtonsWriteDocumentedPayloadsAtomically() throws {
        let src = try read("ExportSectionView.swift")
        guard let xmlFunc = src.range(of: "private func exportXML()") else {
            XCTFail("ExportSectionView.swift is missing exportXML()")
            return
        }
        let xmlWindowEnd = src.index(xmlFunc.upperBound, offsetBy: 700, limitedBy: src.endIndex) ?? src.endIndex
        let xmlBody = src[xmlFunc.upperBound..<xmlWindowEnd]
        XCTAssertTrue(xmlBody.contains("let xml = state.xmlPreview"), "exportXML() must source its payload from state.xmlPreview (spec §H.18)")
        XCTAssertTrue(xmlBody.contains("guard !xml.isEmpty else"), "exportXML() must guard against an empty xmlPreview (spec §H.18)")
        XCTAssertTrue(xmlBody.contains("try xml.write(to: url, atomically: true, encoding: .utf8)"),
                      "exportXML() must write atomically via Foundation's String.write (spec §H.18)")

        guard let skFunc = src.range(of: "private func exportShowKontrol()") else {
            XCTFail("ExportSectionView.swift is missing exportShowKontrol()")
            return
        }
        let skWindowEnd = src.index(skFunc.upperBound, offsetBy: 700, limitedBy: src.endIndex) ?? src.endIndex
        let skBody = src[skFunc.upperBound..<skWindowEnd]
        XCTAssertTrue(skBody.contains("ShowKontrolExporter.generate(cuePoints: state.cuePoints)"),
                      "exportShowKontrol() must source its payload from ShowKontrolExporter.generate (spec §H.18)")
        XCTAssertTrue(skBody.contains("try data.write(to: url, atomically: true, encoding: .utf8)"),
                      "exportShowKontrol() must write atomically via Foundation's String.write (spec §H.18)")
    }

    /// spec §H.18: "The macOS Swift source has no clipboard action, so none is added
    /// (clipboard is unavailable at 0.8.0 anyway)."
    func testExportSectionAddsNoClipboardAction() throws {
        let src = try read("ExportSectionView.swift")
        for banned in ["Clipboard", "Pasteboard", "clipboard"] {
            XCTAssertFalse(src.contains(banned),
                           "ExportSectionView.swift must add no clipboard action — the macOS original has none " +
                           "and swift-cross-ui exposes no clipboard API at 0.8.0 (spec §H.18)")
        }
    }
}
