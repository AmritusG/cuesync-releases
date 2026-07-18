#if CUESYNC_CROSSUI
import SwiftCrossUI
import CueSyncCore

// Re-hosts the AppKit `Color(cssString:)` init (Theme/ThemeColors.swift's
// `NSColor.fromCSSString` extension) onto SwiftCrossUI.Color, delegating the actual
// parsing to `CueSyncCore.Hex` so the accent-green fallback and clamping behavior stay
// identical and unit-testable (spec CUESYNC-7 §B.5).
extension Color {
    init(cssString: String) {
        let rgb = Hex.parseCSSColor(cssString)
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
#endif
