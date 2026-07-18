import Foundation
import XCTest

// =============================================================================
// Coverage for spec CUESYNC-7 §B: re-hosting AppState/ThemeColors/color-parsing onto
// swift-cross-ui. UI/State/AppState.swift and UI/Theme/{ThemeColors,ColorParsing}.swift
// compile only under `#if CUESYNC_CROSSUI` with a `SwiftCrossUI` import — CueSyncCoreTests
// (Package.swift: depends on CueSyncCore/CSQLite/CZlib only, never the CueSync executable
// target) cannot import or execute them directly. These tests instead pin their *source
// text*: structural guards a build-time #if can't express on its own (no Combine, no
// Swift's @Observable, fully wrapped in the flag), the exact STYLES.md palette values, and
// — the highest-value check here — line-for-line body parity between the ported methods in
// UI/State/AppState.swift and their macOS original in App/AppState.swift, which is exactly
// what spec §B.3 ("port the methods verbatim in behavior") and §4's threat model ("dropping
// any clamp during the re-host is the one real regression risk here") call for.
// =============================================================================

final class CrossUIFoundationTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let sourceRoot = repoRoot.appendingPathComponent("CueSync/CueSync")

    private static let crossUIAppStateURL = sourceRoot.appendingPathComponent("UI/State/AppState.swift")
    private static let macAppStateURL = sourceRoot.appendingPathComponent("App/AppState.swift")
    private static let themeColorsURL = sourceRoot.appendingPathComponent("UI/Theme/ThemeColors.swift")
    private static let colorParsingURL = sourceRoot.appendingPathComponent("UI/Theme/ColorParsing.swift")

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Existence + guard wrapping (spec §B.3/§B.4/§B.5, §3 acceptance criteria)

    func testUIStateAppStateExistsAndIsFullyWrappedInCUESYNCCROSSUI() throws {
        try assertFullyWrapped(Self.crossUIAppStateURL)
    }

    func testUIThemeThemeColorsExistsAndIsFullyWrappedInCUESYNCCROSSUI() throws {
        try assertFullyWrapped(Self.themeColorsURL)
    }

    func testUIThemeColorParsingExistsAndIsFullyWrappedInCUESYNCCROSSUI() throws {
        try assertFullyWrapped(Self.colorParsingURL)
    }

    private func assertFullyWrapped(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let src = try read(url)
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasPrefix("#if CUESYNC_CROSSUI"),
                      "\(url.lastPathComponent) must open with #if CUESYNC_CROSSUI", file: file, line: line)
        XCTAssertTrue(trimmed.hasSuffix("#endif"),
                      "\(url.lastPathComponent) must close with #endif so nothing in it compiles outside the flag",
                      file: file, line: line)
    }

    // MARK: - Forbidden imports / observation mechanism (spec §0.1 premise 1, §B.3)

    /// `PortComplianceTests.testNoFileUnderUIImportsBannedAppleFrameworksEvenIfGuarded`
    /// already bans (and, as of this ticket, includes Combine in) a fixed list for every
    /// file under UI/. This test pins the same requirement specifically for AppState.swift
    /// — the one file the spec calls out by name as the file that must not carry
    /// `import Combine` over from the AppKit original.
    func testUIStateAppStateDoesNotImportCombine() throws {
        let src = try read(Self.crossUIAppStateURL)
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(lines.contains("import Combine"),
                       "UI/State/AppState.swift must not import Combine — unavailable on Windows (spec §B.3)")
    }

    /// spec §0.1 premise 1 / §B.3: re-host onto SwiftCrossUI's own `ObservableObject`
    /// mechanism, never Swift's Observation module (`@Observable`) the AppKit original
    /// uses. `@Observable` wouldn't even compile in this file (no SwiftUI/Observation
    /// import), but pin the absence explicitly so a future edit can't reintroduce it by
    /// copying the macOS class attribute verbatim during later sections of this port.
    func testUIStateAppStateUsesSwiftCrossUIObservableObjectNotSwiftObservation() throws {
        let src = try read(Self.crossUIAppStateURL)
        XCTAssertTrue(src.contains("ObservableObject"),
                      "UI/State/AppState.swift must be a SwiftCrossUI ObservableObject (spec §B.3)")
        // "@ObservableObject" itself contains "@Observable" as a prefix substring, so a
        // plain `.contains("@Observable")` would false-positive on the very macro this file
        // is required to use — check the exact standalone attribute line instead.
        let lines = normalizedLines(src)
        XCTAssertFalse(lines.contains("@Observable"),
                       "UI/State/AppState.swift must not use Swift's @Observable macro (spec §0.1 premise 1 / §B.3)")
    }

    func testUIStateAppStateDeclaresFinalClassNamedAppState() throws {
        let src = try read(Self.crossUIAppStateURL)
        XCTAssertTrue(src.contains("final class AppState"),
                      "UI/State/AppState.swift must declare `final class AppState` (spec §B.3)")
    }

    // MARK: - Method-body behavioral parity vs. the macOS original (spec §B.3: "verbatim")

    /// Extracts the balanced-brace declaration starting at `signature`, which must itself
    /// end with the declaration's opening `{` (true for every `func .../var ... { ... }`
    /// signature used below). Depth-counts braces from just after that opening brace
    /// through to its match, so nested single-line braces (`if ... { ... }`, closures)
    /// don't terminate the scan early.
    private func extractDeclaration(signature: String, in source: String) -> String? {
        guard signature.hasSuffix("{"), let sigRange = source.range(of: signature) else { return nil }
        var depth = 1
        var idx = sigRange.upperBound
        while idx < source.endIndex {
            let c = source[idx]
            if c == "{" { depth += 1 } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(source[sigRange.lowerBound...idx]) }
            }
            idx = source.index(after: idx)
        }
        return nil
    }

    private func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Every signature below appears verbatim (identical literal source text) in both
    /// App/AppState.swift and UI/State/AppState.swift as of the CUESYNC-7 §B.3 port.
    /// Deliberately excludes only what the spec says is intentionally NOT ported
    /// (`draggedSection`/`preDragSectionOrder` section-reorder state, §D.8) or is expected
    /// to differ structurally (the class attribute, imports, the standalone `ParseError`
    /// enum now sourced from CueSyncCore). Asserts the extracted bodies are line-for-line
    /// identical after whitespace/blank-line normalization, so a future edit to either file
    /// can't silently drift the two presentations out of behavioral sync.
    func testCrossUIAppStatePortedDeclarationsMatchMacOSOriginalVerbatim() throws {
        let crossUI = try read(Self.crossUIAppStateURL)
        let macOS = try read(Self.macAppStateURL)

        let signatures = [
            "var selectedTrack: Track? {",
            "var filteredTracks: [Track] {",
            "var xmlPreview: String {",
            "func selectTrack(_ track: Track) {",
            "func createBlankEnvelope() {",
            "func addCuePoint(at time: Double, yValue: Double = 0) {",
            "func duplicateSelectedWithOffset(offsetMs: Int) {",
            "var canRemoveSelectedPoint: Bool {",
            "func removeSelectedPoint() {",
            "func updateCuePoint(at index: Int, _ transform: (inout CuePoint) -> Void) {",
            "func updateCuePointSilently(at index: Int, _ transform: (inout CuePoint) -> Void) {",
            "func pushUndoSnapshot() {",
            "func loadRekordbox(from url: URL) throws {",
            "func loadShowKontrol(from url: URL) throws -> Bool {",
            "func loadSerato(from urls: [URL]) {",
            "func loadEngineDJ(from url: URL) throws {",
            "func loadResolumeEnvelope(from url: URL, duration: Double) throws {",
            "private func applyYZeroIfNeeded(to cues: inout [CuePoint]) {",
            "private func applyYZeroIfNeeded(to tracks: [Track]) -> [Track] {",
            "func confirmNewProject() {",
            "func confirmAction(_ action: @escaping () -> Void) {",
            "func executePendingAction() {",
            "static func safeDuration(_ d: Double) -> Double {",
            "func updateDurationWithScaling(_ newDuration: Double) {",
            "func newProject() {",
            "func saveProject(to url: URL) throws {",
            "func loadProject(from url: URL) throws {",
            "private func pushUndo() {",
            "func undo() {",
            "func redo() {",
            "private func apply(_ state: UndoState) {",
            "private struct UndoState {",
            "private func ensureStartAndEndPoints() {",
            "func loadPreferences() {",
            "func savePreferences() {",
            "func resetLayout() {",
            "private func trackIdsForPlaylist(_ id: String) -> Set<String> {",
        ]

        for signature in signatures {
            guard let crossUIBody = extractDeclaration(signature: signature, in: crossUI) else {
                XCTFail("UI/State/AppState.swift is missing the ported declaration `\(signature)` (spec §B.3)")
                continue
            }
            guard let macOSBody = extractDeclaration(signature: signature, in: macOS) else {
                XCTFail("App/AppState.swift (the port's own source of truth) unexpectedly lacks `\(signature)` " +
                        "— update this test's signature list if the macOS original legitimately changed")
                continue
            }
            XCTAssertEqual(normalizedLines(crossUIBody), normalizedLines(macOSBody),
                           "`\(signature)` body diverged from the macOS original — spec §B.3 requires ported " +
                           "methods to stay behaviorally verbatim so the two presentations never diverge in meaning")
        }
    }

    /// Belt-and-suspenders on top of the full-body parity test above: the exact
    /// input-sanitization guards spec §4's threat model calls out by name, so an outright
    /// deletion of one is caught even if the parity test above were ever loosened.
    func testCrossUIAppStatePreservesEveryInputSanitizationGuard() throws {
        let src = try read(Self.crossUIAppStateURL)
        for guardText in [".sanitized()", "safeDuration", "ensureStartAndEndPoints", "isFinite"] {
            XCTAssertTrue(src.contains(guardText),
                          "UI/State/AppState.swift must preserve the `\(guardText)` guard carried over from the " +
                          "macOS original (spec §4: 'dropping any clamp during the re-host is the one real " +
                          "regression risk here')")
        }
    }

    // MARK: - ColorParsing.swift re-host (spec §B.5)

    func testColorParsingDelegatesToCueSyncCoreHexParseCSSColor() throws {
        let src = try read(Self.colorParsingURL)
        XCTAssertTrue(src.contains("Hex.parseCSSColor"),
                      "UI/Theme/ColorParsing.swift's Color(cssString:) must delegate to the shared, unit-tested " +
                      "CueSyncCore.Hex.parseCSSColor (spec §B.5) so the accent-green fallback and clamping " +
                      "behavior can never drift from the pure-logic tests in SupportLayerTests.swift")
    }

    // MARK: - ThemeColors.swift palette values (spec §B.4: "exact STYLES.md hex values")

    /// Regex/execution can't reach these values (SwiftCrossUI-gated), so this pins the
    /// exact `Color(red:green:blue:)` literal for every documented accent/background color,
    /// tolerant of surrounding alignment whitespace but not of a changed number — a future
    /// edit that "looks like" the same Color init with a drifted byte still fails.
    func testThemeColorsDarkPaletteMatchesSTYLESExactHexValues() throws {
        let collapsed = collapsedWhitespace(try read(Self.themeColorsURL))
        let expected = [
            "Color(red: 10 / 255, green: 10 / 255, blue: 15 / 255)",    // background #0a0a0f
            "Color(red: 20 / 255, green: 20 / 255, blue: 30 / 255)",    // sectionBG  #14141e
            "Color(red: 26 / 255, green: 26 / 255, blue: 46 / 255)",    // surface    #1a1a2e
            "Color(red: 30 / 255, green: 215 / 255, blue: 96 / 255)",   // accentGreen #1ed760
            "Color(red: 239 / 255, green: 40 / 255, blue: 138 / 255)",  // accentPink  #ef288a
            "Color(red: 255 / 255, green: 215 / 255, blue: 0 / 255)",   // accentGold  #ffd700
            "Color(red: 93 / 255, green: 228 / 255, blue: 199 / 255)",  // accentTeal  #5de4c7
            "Color(red: 0 / 255, green: 104 / 255, blue: 169 / 255)",   // accentBlue  #0068a9
            "Color(red: 91 / 255, green: 210 / 255, blue: 159 / 255)",  // accentMint  #5bd29f
        ]
        for literal in expected {
            XCTAssertTrue(collapsed.contains(literal),
                          "ThemeColors.dark is missing the STYLES.md-exact literal: \(literal) (spec §B.4)")
        }
    }

    func testThemeColorsLightPaletteMatchesSTYLESExactHexValues() throws {
        let collapsed = collapsedWhitespace(try read(Self.themeColorsURL))
        let expected = [
            "Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)", // background  #f5f5f7
            "Color(red: 29 / 255, green: 185 / 255, blue: 84 / 255)",   // accentGreen #1db954
            "Color(red: 239 / 255, green: 40 / 255, blue: 138 / 255)",  // accentPink  #ef288a
            "Color(red: 255 / 255, green: 215 / 255, blue: 0 / 255)",   // accentGold  #ffd700
            "Color(red: 93 / 255, green: 228 / 255, blue: 199 / 255)",  // accentTeal  #5de4c7
            "Color(red: 0 / 255, green: 104 / 255, blue: 169 / 255)",   // accentBlue  #0068a9
            "Color(red: 91 / 255, green: 210 / 255, blue: 159 / 255)",  // accentMint  #5bd29f
        ]
        for literal in expected {
            XCTAssertTrue(collapsed.contains(literal),
                          "ThemeColors.light is missing the STYLES.md-exact literal: \(literal) (spec §B.4)")
        }
    }

    /// spec §B.4: "Reproduce the computed contextual colors ... with the same
    /// `isDark ? … : …` logic." Confirms every contextual color is still theme-branching
    /// rather than a flat constant — the specific regression this ticket's re-host could
    /// introduce (e.g. a paste error that drops the ternary).
    func testThemeColorsContextualColorsAllBranchOnIsDark() throws {
        let src = try read(Self.themeColorsURL)
        for property in [
            "inputBg", "inputBorder", "buttonBg", "buttonBorder", "buttonHoverBg", "buttonHoverBorder",
            "emptyStateBg", "emptyStateBorder", "cardBg", "cardBorder", "sectionShadow", "canvasBg",
            "envelopeContainerBg", "envelopeContainerBorder", "tableHeaderBg", "stepperDivider",
            "stepperArrowBg", "disabledRowBg", "countBadgeBg", "footerBg", "gridColor", "pillBg",
        ] {
            guard let range = src.range(of: "var \(property): Color {") else {
                XCTFail("ThemeColors is missing the contextual color `\(property)` (spec §B.4)")
                continue
            }
            let lineEnd = src[range.upperBound...].firstIndex(of: "\n") ?? src.endIndex
            let line = src[range.upperBound..<lineEnd]
            XCTAssertTrue(line.contains("isDark ?"),
                          "ThemeColors.\(property) must branch on `isDark ? … : …` (spec §B.4), got: \(line)")
        }
    }

    private func collapsedWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
