import Foundation
import XCTest

// =============================================================================
// Coverage for spec CUESYNC-7 §J.20 (StepperField/StepperIntField), §J.21
// (HoverButton), and §J.22 (BrandButtons: ActionButton/BrandButton/ToggleButton).
// Landed in commit 9fc2f73 (StepperField/HoverButton) and b3d3b9b (BrandButtons) with
// only allowlist bookkeeping, no behavioral tests (see CrossUIChromeTests.swift's
// header comment for the same gap analysis).
//
// §J.20's own comment calls out the highest-value regression risk directly: "Numeric
// parsing, clamping, the isFinite guard, and overflow-safe Int handling are preserved
// verbatim from the AppKit original (§4: 'a hostile file cannot produce NaN
// geometry')." testStepperFieldCommitTextRejectsNonFiniteParsedValues and
// testStepperIntFieldAdjustUsesOverflowSafeArithmetic below are the two tests that
// most directly guard that regression.
// =============================================================================

final class CrossUIControlsTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let controlsDir = repoRoot.appendingPathComponent("CueSync/CueSync/UI/Controls")

    private func read(_ fileName: String) throws -> String {
        try String(contentsOf: Self.controlsDir.appendingPathComponent(fileName), encoding: .utf8)
    }

    private func body(of funcSignature: String, in src: String, window: Int = 500) -> Substring? {
        guard let range = src.range(of: funcSignature) else { return nil }
        let end = src.index(range.upperBound, offsetBy: window, limitedBy: src.endIndex) ?? src.endIndex
        return src[range.upperBound..<end]
    }

    /// Every file in this suite documents its port decisions with `// PORT:`/header
    /// comments that often name the exact Apple-only API being avoided (e.g. "no
    /// NSImage", "not Color.description"), so a banned-API absence check must search
    /// code only — otherwise the explanatory prose trips a false positive on the very
    /// thing it's disclaiming.
    private func stripComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let commentStart = line.range(of: "//") { return line[line.startIndex..<commentStart.lowerBound] }
                return line
            }
            .joined(separator: "\n")
    }

    // MARK: - StepperField (spec §J.20)

    /// spec §J.20/§4: `Double("nan")`/`Double("inf")` both parse successfully in Swift,
    /// and `min`/`max` clamping does NOT sanitize a non-finite value (`Swift.min(.nan,
    /// x)` is itself NaN) — the field must reject a non-finite parse outright rather than
    /// clamp it, or a hand-typed "nan" in a cue-position field would reach `cue.start`
    /// and eventually Cairo.
    func testStepperFieldCommitTextRejectsNonFiniteParsedValues() throws {
        let src = try read("StepperField.swift")
        guard let commitBody = body(of: "private func commitText() {", in: src) else {
            XCTFail("StepperField.swift is missing commitText()")
            return
        }
        XCTAssertTrue(commitBody.contains("if let parsed = Double(text), parsed.isFinite {"),
                      "commitText() must guard on parsed.isFinite before assigning value (spec §J.20, §4)")
    }

    /// spec §J.20: "the numeric parsing, clamping ... from Views/Sections/StepperField.swift."
    func testStepperFieldClampsCommittedAndAdjustedValuesIntoMinMaxRange() throws {
        let src = try read("StepperField.swift")
        XCTAssertTrue(src.contains("value = Swift.min(Swift.max(parsed, min), max)"),
                      "commitText() must clamp the parsed value into [min, max] (spec §J.20)")
        guard let adjustBody = body(of: "private func adjustValue(by delta: Double) {", in: src) else {
            XCTFail("StepperField.swift is missing adjustValue(by:)")
            return
        }
        XCTAssertTrue(adjustBody.contains("Swift.min(Swift.max(value + delta, min), max)"),
                      "adjustValue(by:) must clamp the stepped value into [min, max] (spec §J.20)")
    }

    /// spec §J.20: "overflow-safe Int handling" — StepperIntField.adjust(by:) must not
    /// trap when the current value sits at Int.max/Int.min and the arrow is tapped again.
    func testStepperIntFieldAdjustUsesOverflowSafeArithmetic() throws {
        let src = try read("StepperField.swift")
        guard let adjustBody = body(of: "private func adjust(by delta: Int) {", in: src) else {
            XCTFail("StepperField.swift is missing StepperIntField.adjust(by:)")
            return
        }
        XCTAssertTrue(adjustBody.contains("addingReportingOverflow(delta)"),
                      "StepperIntField.adjust(by:) must use addingReportingOverflow instead of +, which traps " +
                      "on overflow at Int.max/Int.min (spec §J.20)")
        XCTAssertTrue(adjustBody.contains("overflow ? (delta > 0 ? max : min) : sum"),
                      "on overflow, adjust(by:) must saturate to max (positive delta) or min (negative delta), " +
                      "not propagate garbage from the wrapped sum (spec §J.20)")
    }

    /// spec §J.20: "Chevron glyphs -> simple Text('▲')/Text('▼')" — swift-cross-ui's
    /// Button has no ViewBuilder label (established re-hosting CollapsibleSection, §D.8),
    /// so the up/down controls must be tappable Text, not SF Symbols or a real Button.
    func testStepperFieldUsesTextGlyphArrowsNotSFSymbols() throws {
        for fileName in ["StepperField.swift"] {
            let src = try read(fileName)
            // Source text (read raw) carries `\u{25B2}` as an escape-sequence literal, not
            // the resolved ▲ character — search for the escape text itself.
            XCTAssertTrue(src.contains("\"\\u{25B2}\"") && src.contains("\"\\u{25BC}\""),
                          "\(fileName) must use \\u{25B2}/\\u{25BC} (▲/▼) text glyphs for its stepper arrows (spec §J.20)")
            XCTAssertFalse(stripComments(src).contains("Image(systemName:"),
                           "\(fileName) must not use Image(systemName:) in actual code — SF Symbols are Apple-only (spec §0.3)")
        }
    }

    // MARK: - HoverButton (spec §J.21)

    /// spec §J.21: "the string-Color.description-.contains('green') hack in the macOS
    /// file does not port; pass explicit colors" — callers must supply hoverFg/hoverBg/
    /// hoverBorder rather than the button trying to infer a hover color by introspecting
    /// its own fill color's description string.
    func testHoverButtonTakesExplicitHoverColorsInsteadOfIntrospectingColorDescription() throws {
        let src = try read("HoverButton.swift")
        for param in ["hoverFg: Color? = nil", "hoverBg: Color? = nil", "hoverBorder: Color? = nil"] {
            XCTAssertTrue(src.contains(param), "HoverButton must accept an explicit \(param) parameter (spec §J.21)")
        }
        XCTAssertFalse(stripComments(src).contains("description"),
                       "HoverButton must not introspect a Color's .description in actual code — that hack doesn't port (spec §J.21)")
    }

    /// spec §J.21/§L: "Drop scaleEffect/brightness/animation" — no swift-cross-ui
    /// equivalent exists, so re-copying any of them from the macOS original would fail
    /// to compile.
    func testHoverButtonDropsScaleEffectBrightnessAndAnimationModifiers() throws {
        let src = try read("HoverButton.swift")
        for banned in [".scaleEffect(", ".brightness(", ".animation("] {
            XCTAssertFalse(src.contains(banned),
                           "HoverButton.swift must not use '\(banned)' — no swift-cross-ui equivalent (spec §J.21/§L)")
        }
    }

    /// spec §J.21: hover state must actually drive the rendered colors and dispatch the
    /// action on tap — the two behaviors a "HoverButton" name promises.
    func testHoverButtonSwapsColorsOnHoverAndDispatchesActionOnTap() throws {
        let src = try read("HoverButton.swift")
        XCTAssertTrue(src.contains(".foregroundColor(isHovered ? hoverFg : fg)"),
                      "HoverButton must swap its foreground color based on isHovered (spec §J.21)")
        XCTAssertTrue(src.contains(".background(isHovered ? hoverBg : bg)"),
                      "HoverButton must swap its background color based on isHovered (spec §J.21)")
        XCTAssertTrue(src.contains(".onHover { isHovered = $0 }"),
                      "HoverButton must track hover state via .onHover (spec §J.21)")
        XCTAssertTrue(src.contains(".onTapGesture { action() }"),
                      "HoverButton must dispatch its action via .onTapGesture — swift-cross-ui's Button has no " +
                      "ViewBuilder label, so a real Button can't wrap this content (spec §0.3, §D.8)")
    }

    // MARK: - BrandButtons: ActionButton / BrandButton / ToggleButton (spec §J.22)

    /// spec §J.22: "Icons here are a single glyph Text in the brand color instead" — the
    /// macOS NSImage-rendered SVG icons must not be referenced at all.
    func testBrandButtonsUsesTextGlyphIconsNotNSImageRenderedSVGs() throws {
        let codeOnly = stripComments(try read("BrandButtons.swift"))
        for banned in ["NSImage", "Image(systemName:"] {
            XCTAssertFalse(codeOnly.contains(banned),
                           "BrandButtons.swift must not use '\(banned)' in actual code — brand icons are glyph " +
                           "Text, not rendered SVG/SF Symbols (spec §J.22)")
        }
        XCTAssertTrue(codeOnly.contains("let glyph: String"),
                      "both ActionButton and BrandButton must carry a `glyph: String` for their icon (spec §J.22)")
    }

    /// spec §J.22: brand-colored background is "the primary fidelity signal" for
    /// BrandButton — the accent must actually drive both idle and hovered background,
    /// not just tint the border.
    func testBrandButtonUsesAccentColorForBackgroundAndBorderBothIdleAndHovered() throws {
        let src = try read("BrandButtons.swift")
        guard let structBody = body(of: "struct BrandButton: View {", in: src, window: 1500) else {
            XCTFail("BrandButtons.swift is missing struct BrandButton")
            return
        }
        XCTAssertTrue(structBody.contains(".background(isHovered ? accent : accent.opacity(0.15))"),
                      "BrandButton must render its brand accent as the background, dimmed when idle (spec §J.22)")
        XCTAssertTrue(structBody.contains(".stroke(accent, style: StrokeStyle(width: 1))"),
                      "BrandButton must stroke its border in the brand accent color (spec §J.22)")
    }

    /// spec §E.10/§J.22: ToggleButton backs both the Viewport (Reset/Side-By-Side) and
    /// Theme (Dark/Light) pill controls — its active state must render identically to its
    /// hovered state (a common pill-toggle affordance), and inactive/unhovered must be
    /// visually distinct.
    func testToggleButtonRendersActiveStateSameAsHoveredState() throws {
        let src = try read("BrandButtons.swift")
        guard let structBody = body(of: "struct ToggleButton: View {", in: src, window: 900) else {
            XCTFail("BrandButtons.swift is missing struct ToggleButton")
            return
        }
        XCTAssertTrue(structBody.contains(".foregroundColor(isActive || isHovered ? .black : colors.accentGreen)"),
                      "ToggleButton's foreground must go black when active OR hovered, green otherwise (spec §E.10/§J.22)")
        XCTAssertTrue(structBody.contains(".background(isActive || isHovered ? colors.accentGreen : colors.accentGreen.opacity(0.2))"),
                      "ToggleButton's background must go solid green when active OR hovered (spec §E.10/§J.22)")
    }

    /// Every control in this family stands in for swift-cross-ui's Button, which (per
    /// §D.8's discovery) carries only a fixed String label — so none of them may
    /// literally declare `Button(` themselves, or a future edit assuming Button supports
    /// a ViewBuilder label here would silently fail to compile only once someone tries it.
    func testBrandButtonsDeclareNoRealButtonOnlyTapGestureSubstitutes() throws {
        let src = try read("BrandButtons.swift")
        XCTAssertFalse(src.contains("Button("),
                       "BrandButtons.swift must not declare a real Button( — swift-cross-ui's Button has no " +
                       "ViewBuilder label at 0.8.0 (spec §0.3, §D.8); every control here uses .onTapGesture instead")
        let tapGestureCount = src.components(separatedBy: ".onTapGesture { action() }").count - 1
        XCTAssertEqual(tapGestureCount, 3,
                       "expected all 3 controls (ActionButton, BrandButton, ToggleButton) to dispatch via " +
                       ".onTapGesture { action() }, got \(tapGestureCount)")
    }
}
