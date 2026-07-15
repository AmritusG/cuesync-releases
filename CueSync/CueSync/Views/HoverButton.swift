import SwiftUI

/// A button style that provides hover state tracking for custom hover effects.
struct HoverableButtonStyle: ButtonStyle {
    let hoverBg: Color
    let hoverFg: Color?
    let hoverBorder: Color?

    func makeBody(configuration: Configuration) -> some View {
        HoverableButtonBody(
            configuration: configuration,
            hoverBg: hoverBg,
            hoverFg: hoverFg,
            hoverBorder: hoverBorder
        )
    }
}

private struct HoverableButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let hoverBg: Color
    let hoverFg: Color?
    let hoverBorder: Color?
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .brightness(isHovered ? 0.05 : 0)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

/// Generic hover modifier that applies background/foreground changes on hover.
struct HoverEffect: ViewModifier {
    let hoverBg: Color?
    let hoverFg: Color?
    let hoverBorder: Color?
    let scaleOnHover: Bool
    @State private var isHovered = false

    init(hoverBg: Color? = nil, hoverFg: Color? = nil, hoverBorder: Color? = nil, scale: Bool = true) {
        self.hoverBg = hoverBg
        self.hoverFg = hoverFg
        self.hoverBorder = hoverBorder
        self.scaleOnHover = scale
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && scaleOnHover ? 1.02 : 1.0)
            .brightness(isHovered ? 0.1 : 0)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
    }
}

extension View {
    func hoverEffect(bg: Color? = nil, fg: Color? = nil, border: Color? = nil, scale: Bool = true) -> some View {
        modifier(HoverEffect(hoverBg: bg, hoverFg: fg, hoverBorder: border, scale: scale))
    }
}

/// A button with proper hover highlighting matching the Electron app.
/// On hover: background brightens, slight scale up.
struct HoverButton: View {
    let label: String
    let icon: String?
    let fg: Color
    let bg: Color
    let border: Color
    let action: () -> Void

    @State private var isHovered = false

    init(_ label: String, icon: String? = nil, fg: Color, bg: Color, border: Color, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.fg = fg
        self.bg = bg
        self.border = border
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 12))
                }
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isHovered ? hoverFg : fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered ? hoverBg : bg)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isHovered ? hoverBorder : border, lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var hoverBg: Color {
        // For green buttons, fill solid green. For others, brighten.
        if bg.description.contains("green") || border.description.contains("green") {
            return Color(red: 30/255, green: 215/255, blue: 96/255)
        }
        return bg.opacity(1.5) // brighten
    }

    private var hoverFg: Color {
        if bg.description.contains("green") || border.description.contains("green") {
            return .black
        }
        return .white
    }

    private var hoverBorder: Color {
        border
    }
}
