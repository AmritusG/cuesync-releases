#if canImport(AppKit)
import SwiftUI

struct FooterView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        HStack(spacing: 4) {
            Text("Built for VJs")
                .foregroundStyle(colors.textMuted)
            Text("\u{2022}")
                .foregroundStyle(colors.accentGreen)
            Text("Rekordbox")
                .foregroundStyle(colors.textMuted)
            Text("\u{2022}")
                .foregroundStyle(colors.accentGreen)
            Text("Serato")
                .foregroundStyle(colors.textMuted)
            Text("\u{2022}")
                .foregroundStyle(colors.accentGreen)
            Text("Engine DJ")
                .foregroundStyle(colors.textMuted)
            Text("\u{2022}")
                .foregroundStyle(colors.accentGreen)
            Text("ShowKontrol")
                .foregroundStyle(colors.textMuted)
            Text("\u{2192}")
                .foregroundStyle(colors.accentGreen)
            Text("Resolume")
                .foregroundStyle(colors.textMuted)
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
