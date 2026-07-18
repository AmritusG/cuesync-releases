import Foundation

/// Pure-Swift hex/CSS color parsing — no `NSColor` dependency, so it compiles and
/// runs identically on every platform. Mirrors `ThemeColors`' `NSColor.fromCSSString`
/// parsing rules; the UI layer will re-host that extension on top of this once the
/// presentation layer moves to swift-cross-ui.
public enum Hex {
    /// Clamps a parsed component to a finite value in the valid 0...1 range.
    /// `Double("nan")`, `Double("inf")`, and overflowing literals like `1e400`
    /// all parse successfully in Swift, so any component derived from untrusted
    /// input must be sanitized before it reaches the renderer — an `Int(NaN/Inf)`
    /// conversion downstream would trap. nan/-inf → 0, +inf → 1.
    private static func sanitize(_ value: Double) -> Double {
        guard value.isFinite else { return value > 0 ? 1.0 : 0.0 }
        return min(max(value, 0.0), 1.0)
    }

    /// Parses `#rgb` or `#rrggbb` (leading `#` optional) into 0...1 RGB components.
    /// Returns `nil` for anything else.
    static func parseHexColor(_ string: String) -> (r: Double, g: Double, b: Double)? {
        var hex = string.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        let r = (value >> 16) & 0xFF
        let g = (value >> 8) & 0xFF
        let b = value & 0xFF
        // Hex can never be non-finite, but route through sanitize for one code path.
        return (sanitize(Double(r) / 255.0), sanitize(Double(g) / 255.0), sanitize(Double(b) / 255.0))
    }

    /// Parses `rgb(r, g, b)` (0...255 components) into 0...1 RGB. Returns `nil` for
    /// anything else. Non-finite inputs (`nan`, `inf`, overflowing literals) are
    /// clamped to a finite value — never surfaced to the caller.
    static func parseRGBFunction(_ string: String) -> (r: Double, g: Double, b: Double)? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("rgb("), s.hasSuffix(")") else { return nil }
        let inner = s.dropFirst(4).dropLast(1)
        let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        return (sanitize(parts[0] / 255.0), sanitize(parts[1] / 255.0), sanitize(parts[2] / 255.0))
    }

    /// Parses any CSS color string CueSync uses (`#rgb`, `#rrggbb`, `rgb(r,g,b)`),
    /// falling back to the app's accent green when the string is unrecognized —
    /// matches the existing `NSColor.fromCSSString` fallback behavior. The returned
    /// components are always finite. `public`: this is the function the swift-cross-ui
    /// `Color(cssString:)` re-host (`UI/Theme/ColorParsing.swift`) calls (CUESYNC-7 §B.5).
    public static func parseCSSColor(_ string: String) -> (r: Double, g: Double, b: Double) {
        if let rgb = parseRGBFunction(string) { return rgb }
        if let hex = parseHexColor(string) { return hex }
        return (30.0 / 255.0, 215.0 / 255.0, 96.0 / 255.0)
    }
}
