#if CUESYNC_CROSSUI
import SwiftCrossUI

// Re-hosts the small button variants embedded in Views/Sections/ProjectSectionView.swift
// (ActionButton, ImportButton, ViewportButton/ThemeButton) onto swift-cross-ui
// (spec CUESYNC-7 §J.22). swift-cross-ui's `Button` carries only a fixed String
// label — no ViewBuilder content (confirmed while re-hosting CollapsibleSection,
// §D.8) — so every variant here is the same Text + `.onTapGesture` substitute
// HoverButton (§J.21) established, not a real `Button`.
//
// PORT: the macOS `ImportButton`s render brand SVG icons (`Views/BrandIcons.swift`,
// `NSImage`-rendered, Apple-only) with a hover scale/rotate animation. Icons here
// are a single glyph `Text` in the brand color instead — the inline SVG XML the
// macOS file carries is portable *data* a later ticket can rasterize (spec §J.22,
// §L: pixel-accurate brand icons are a known fidelity delta, not a blocker).
// Hover scale/rotate animation has no swift-cross-ui equivalent and is dropped.

/// New / Open / Save — neutral background, glyph + label (macOS `ActionButton`).
struct ActionButton: View {
    let label: String
    let glyph: String
    let colors: ThemeColors
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(glyph).font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(label).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundColor(colors.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 36)
        .background(isHovered ? colors.buttonHoverBg : colors.buttonBg)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(isHovered ? colors.buttonHoverBorder : colors.buttonBorder, style: StrokeStyle(width: 1))
        }
        .cornerRadius(5)
        .onHover { isHovered = $0 }
        .onTapGesture { action() }
    }
}

/// Create Envelope / Resolume / Rekordbox / Serato / Engine DJ / ShowKontrol —
/// brand-colored background, glyph + label (macOS `ImportButton`; spec §J.22's
/// "brand color + label" is the primary fidelity signal, not the icon art).
struct BrandButton: View {
    let label: String
    let glyph: String
    let accent: Color
    let fg: Color
    let hoverFg: Color
    let action: () -> Void

    @State private var isHovered = false

    init(
        _ label: String,
        glyph: String,
        accent: Color,
        fg: Color = .white,
        hoverFg: Color = .white,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.glyph = glyph
        self.accent = accent
        self.fg = fg
        self.hoverFg = hoverFg
        self.action = action
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(glyph).font(.system(size: 13, weight: .bold, design: .monospaced))
            Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(isHovered ? hoverFg : fg)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 36)
        .background(isHovered ? accent : accent.opacity(0.15))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(accent, style: StrokeStyle(width: 1))
        }
        .cornerRadius(5)
        .onHover { isHovered = $0 }
        .onTapGesture { action() }
    }
}

/// Reset / Side-By-Side / Dark / Light / True / False — pill toggle button
/// (macOS `ViewportButton` and `ThemeButton` share this exact style, so one
/// type covers both call sites).
struct ToggleButton: View {
    let label: String
    let isActive: Bool
    let colors: ThemeColors
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(isActive || isHovered ? .black : colors.accentGreen)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isActive || isHovered ? colors.accentGreen : colors.accentGreen.opacity(0.2))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(colors.accentGreen, style: StrokeStyle(width: 1))
            }
            .cornerRadius(5)
            .onHover { isHovered = $0 }
            .onTapGesture { action() }
    }
}
#endif
