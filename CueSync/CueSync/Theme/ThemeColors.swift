import SwiftUI

enum AppTheme: String, Codable, CaseIterable {
    case dark, light
}

struct ThemeColors {
    let background: Color
    let sectionBG: Color
    let surface: Color
    let accentGreen: Color
    let accentPink: Color
    let accentGold: Color
    let accentTeal: Color
    let accentBlue: Color
    let accentMint: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let textDisabled: Color
    let border: Color
    let borderAccent: Color

    static let dark = ThemeColors(
        background:    Color(red: 10/255, green: 10/255, blue: 15/255),
        sectionBG:     Color(red: 20/255, green: 20/255, blue: 30/255),
        surface:       Color(red: 26/255, green: 26/255, blue: 46/255),
        accentGreen:   Color(red: 30/255, green: 215/255, blue: 96/255),
        accentPink:    Color(red: 239/255, green: 40/255, blue: 138/255),
        accentGold:    Color(red: 255/255, green: 215/255, blue: 0/255),
        accentTeal:    Color(red: 93/255, green: 228/255, blue: 199/255),
        accentBlue:    Color(red: 0/255, green: 104/255, blue: 169/255),
        accentMint:    Color(red: 91/255, green: 210/255, blue: 159/255),
        textPrimary:   Color(red: 224/255, green: 224/255, blue: 232/255),
        textSecondary: Color(red: 136/255, green: 136/255, blue: 136/255),
        textMuted:     Color(red: 102/255, green: 102/255, blue: 102/255),
        textDisabled:  Color(red: 85/255, green: 85/255, blue: 85/255),
        border:        Color.white.opacity(0.08),
        borderAccent:  Color(red: 30/255, green: 215/255, blue: 96/255).opacity(0.2),
        isDark:        true
    )

    static let light = ThemeColors(
        background:    Color(red: 245/255, green: 245/255, blue: 247/255),
        sectionBG:     Color.white,
        surface:       Color.white,
        accentGreen:   Color(red: 29/255, green: 185/255, blue: 84/255),
        accentPink:    Color(red: 239/255, green: 40/255, blue: 138/255),
        accentGold:    Color(red: 255/255, green: 215/255, blue: 0/255),
        accentTeal:    Color(red: 93/255, green: 228/255, blue: 199/255),
        accentBlue:    Color(red: 0/255, green: 104/255, blue: 169/255),
        accentMint:    Color(red: 91/255, green: 210/255, blue: 159/255),
        textPrimary:   Color(red: 29/255, green: 29/255, blue: 31/255),
        textSecondary: Color(red: 134/255, green: 134/255, blue: 139/255),
        textMuted:     Color(red: 153/255, green: 153/255, blue: 153/255),
        textDisabled:  Color(red: 170/255, green: 170/255, blue: 170/255),
        border:        Color.black.opacity(0.08),
        borderAccent:  Color(red: 29/255, green: 185/255, blue: 84/255).opacity(0.2),
        isDark:        false
    )

    // MARK: - Theme-aware contextual colors

    let isDark: Bool

    var inputBg: Color {
        isDark ? Color.black.opacity(0.4) : Color.white.opacity(0.9)
    }
    var inputBorder: Color {
        isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.12)
    }
    var buttonBg: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)
    }
    var buttonBorder: Color {
        isDark ? Color.white.opacity(0.2) : Color.black.opacity(0.12)
    }
    var buttonHoverBg: Color {
        isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.08)
    }
    var buttonHoverBorder: Color {
        isDark ? Color.white.opacity(0.4) : Color.black.opacity(0.2)
    }
    var emptyStateBg: Color {
        isDark ? Color.black.opacity(0.15) : Color.black.opacity(0.04)
    }
    var emptyStateBorder: Color {
        isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)
    }
    var cardBg: Color {
        isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)
    }
    var cardBorder: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }
    var sectionShadow: Color {
        isDark ? Color.clear : Color.black.opacity(0.04)
    }
    var canvasBg: Color {
        isDark ? Color.black.opacity(0.4) : Color.black.opacity(0.03)
    }
    var envelopeContainerBg: Color {
        isDark ? Color.black.opacity(0.3) : Color.black.opacity(0.02)
    }
    var envelopeContainerBorder: Color {
        isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)
    }
    var tableHeaderBg: Color {
        isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)
    }
    var stepperDivider: Color {
        isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)
    }
    var stepperArrowBg: Color {
        isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)
    }
    var disabledRowBg: Color {
        isDark ? Color.black.opacity(0.2) : Color.black.opacity(0.03)
    }
    var countBadgeBg: Color {
        isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)
    }
    var footerBg: Color {
        isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)
    }
    var gridColor: Color {
        isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.06)
    }
    var pillBg: Color {
        isDark ? Color.black.opacity(0.75) : Color.black.opacity(0.7)
    }

    static func colors(for theme: AppTheme) -> ThemeColors {
        switch theme {
        case .dark: return .dark
        case .light: return .light
        }
    }
}

// MARK: - NSColor helpers for parsing color strings

import AppKit

extension NSColor {
    static func fromCSSString(_ css: String) -> NSColor {
        let s = css.trimmingCharacters(in: .whitespaces)
        // Handle rgb(r, g, b)
        if s.hasPrefix("rgb(") {
            let inner = s.dropFirst(4).dropLast(1)
            let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count >= 3 {
                return NSColor(red: parts[0]/255, green: parts[1]/255, blue: parts[2]/255, alpha: 1)
            }
        }
        // Handle #hex
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 {
                hex = hex.map { "\($0)\($0)" }.joined()
            }
            if hex.count == 6, let val = UInt64(hex, radix: 16) {
                return NSColor(
                    red: CGFloat((val >> 16) & 0xFF) / 255,
                    green: CGFloat((val >> 8) & 0xFF) / 255,
                    blue: CGFloat(val & 0xFF) / 255,
                    alpha: 1
                )
            }
        }
        return NSColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1) // fallback accent green
    }
}

extension Color {
    init(cssString: String) {
        self.init(nsColor: NSColor.fromCSSString(cssString))
    }
}
