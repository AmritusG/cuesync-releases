import Foundation

/// Pure-Swift hex/CSS color parsing — no `NSColor` dependency, so it compiles and
/// runs identically on every platform. Mirrors `ThemeColors`' `NSColor.fromCSSString`
/// parsing rules; the UI layer will re-host that extension on top of this once the
/// presentation layer moves to swift-cross-ui.
enum Hex {
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
        return (Double(r) / 255.0, Double(g) / 255.0, Double(b) / 255.0)
    }

    /// Parses `rgb(r, g, b)` (0...255 components) into 0...1 RGB. Returns `nil` for
    /// anything else.
    static func parseRGBFunction(_ string: String) -> (r: Double, g: Double, b: Double)? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("rgb("), s.hasSuffix(")") else { return nil }
        let inner = s.dropFirst(4).dropLast(1)
        let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        return (parts[0] / 255.0, parts[1] / 255.0, parts[2] / 255.0)
    }

    /// Parses any CSS color string CueSync uses (`#rgb`, `#rrggbb`, `rgb(r,g,b)`),
    /// falling back to the app's accent green when the string is unrecognized —
    /// matches the existing `NSColor.fromCSSString` fallback behavior.
    static func parseCSSColor(_ string: String) -> (r: Double, g: Double, b: Double) {
        if let rgb = parseRGBFunction(string) { return rgb }
        if let hex = parseHexColor(string) { return hex }
        return (30.0 / 255.0, 215.0 / 255.0, 96.0 / 255.0)
    }
}
