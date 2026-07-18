#if CUESYNC_CROSSUI
import SwiftCrossUI

// Re-host of Views/FooterView.swift onto swift-cross-ui (spec CUESYNC-7 §C.7). Mirrors the
// exact footer strings/glyphs; the AppKit original is off-limits and read only as reference.
struct FooterView: View {
    @Environment(AppState.self) var state

    var body: some View {
        let colors = state.colors

        HStack(spacing: 4) {
            Text("Built for VJs")
                .foregroundColor(colors.textMuted)
            Text("\u{2022}")
                .foregroundColor(colors.accentGreen)
            Text("Rekordbox")
                .foregroundColor(colors.textMuted)
            Text("\u{2022}")
                .foregroundColor(colors.accentGreen)
            Text("Serato")
                .foregroundColor(colors.textMuted)
            Text("\u{2022}")
                .foregroundColor(colors.accentGreen)
            Text("Engine DJ")
                .foregroundColor(colors.textMuted)
            Text("\u{2022}")
                .foregroundColor(colors.accentGreen)
            Text("ShowKontrol")
                .foregroundColor(colors.textMuted)
            Text("\u{2192}")
                .foregroundColor(colors.accentGreen)
            Text("Resolume")
                .foregroundColor(colors.textMuted)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(colors.sectionBG)
        .overlay(alignment: .top) {
            Rectangle().fill(colors.border).frame(height: 1)
        }
    }
}
#endif
