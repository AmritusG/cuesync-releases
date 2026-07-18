#if CUESYNC_CROSSUI
import SwiftCrossUI

// Re-host of Views/HoverButton.swift onto swift-cross-ui (spec CUESYNC-7 §J.21). swift-cross-ui's
// `Button` carries only a fixed String label (no ViewBuilder content, discovered while
// re-hosting CollapsibleSection, §D.8), so this is a `Text`-based tappable row — the same
// `.onTapGesture` substitute used throughout `UI/` — rather than a real `Button`. The AppKit
// original picks its hover colors by string-matching `Color.description.contains("green")`;
// that hack has no equivalent here (`Color` exposes no such introspection) and doesn't port,
// so callers pass explicit `hoverFg`/`hoverBg`/`hoverBorder` instead (spec §J.21).
// PORT: `scaleEffect`/`brightness`/`.easeInOut` animation on hover are dropped — no
// swift-cross-ui equivalent (spec §L).
struct HoverButton: View {
    let label: String
    let fg: Color
    let bg: Color
    let border: Color
    let hoverFg: Color
    let hoverBg: Color
    let hoverBorder: Color
    let action: () -> Void

    @State private var isHovered = false

    init(
        _ label: String,
        fg: Color,
        bg: Color,
        border: Color,
        hoverFg: Color? = nil,
        hoverBg: Color? = nil,
        hoverBorder: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.fg = fg
        self.bg = bg
        self.border = border
        self.hoverFg = hoverFg ?? fg
        self.hoverBg = hoverBg ?? bg
        self.hoverBorder = hoverBorder ?? border
        self.action = action
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(isHovered ? hoverFg : fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered ? hoverBg : bg)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isHovered ? hoverBorder : border, style: StrokeStyle(width: 1))
            }
            .cornerRadius(5)
            .onHover { isHovered = $0 }
            .onTapGesture { action() }
    }
}
#endif
