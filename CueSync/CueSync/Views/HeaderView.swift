import SwiftUI

struct HeaderView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        HStack(spacing: 12) {
            // Logo
            HStack(spacing: 6) {
                Text("\u{25C8}")  // ◈ character
                    .font(.system(size: 18))
                    .foregroundStyle(colors.accentGreen)
                Text("CUE")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(colors.textPrimary)
                Text("SYNC")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(colors.accentGreen)
            }

            // Tagline - matches Electron: "Rekordbox • Serato • Engine DJ • ShowKontrol → Resolume"
            HStack(spacing: 4) {
                Text("Rekordbox")
                    .foregroundStyle(colors.textMuted)
                Text("\u{2022}")
                    .foregroundStyle(colors.accentGreen.opacity(0.5))
                Text("Serato")
                    .foregroundStyle(colors.textMuted)
                Text("\u{2022}")
                    .foregroundStyle(colors.accentGreen.opacity(0.5))
                Text("Engine DJ")
                    .foregroundStyle(colors.textMuted)
                Text("\u{2022}")
                    .foregroundStyle(colors.accentGreen.opacity(0.5))
                Text("ShowKontrol")
                    .foregroundStyle(colors.textMuted)
                Text("\u{2192}")
                    .foregroundStyle(colors.accentGreen)
                Text("Resolume")
                    .foregroundStyle(colors.textMuted)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.5)

            Spacer()

            // Project name: "{name} •" when unsaved (bullet not asterisk)
            Text(state.projectName + (state.hasUnsavedChanges ? " \u{2022}" : ""))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(colors.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .trailing)

            // Version badge
            Text("v1.0.0")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(colors.accentGreen)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(colors.accentGreen.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(colors.accentGreen.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            // Gradient background: linear-gradient(180deg, rgba(30,215,96,0.08) 0%, transparent 100%)
            LinearGradient(
                colors: [colors.accentGreen.opacity(0.08), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            // Gradient bottom border: rgba(30, 215, 96, 0.2)
            Rectangle()
                .fill(colors.accentGreen.opacity(0.2))
                .frame(height: 1)
        }
    }
}
