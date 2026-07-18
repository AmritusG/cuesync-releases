#if CUESYNC_CROSSUI
import SwiftCrossUI

// Re-host of Views/HeaderView.swift onto swift-cross-ui (spec CUESYNC-7 §C.6). Mirrors the
// logo, tagline, project name, and version badge exactly; the AppKit original is off-limits
// (SwiftUI-only) and read only as the behavioral reference.
struct HeaderView: View {
    @Environment(AppState.self) var state

    var body: some View {
        let colors = state.colors

        HStack(spacing: 12) {
            // Logo
            HStack(spacing: 6) {
                Text("\u{25C8}")  // ◈ character
                    .font(.system(size: 18))
                    .foregroundColor(colors.accentGreen)
                Text("CUE")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(colors.textPrimary)
                Text("SYNC")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(colors.accentGreen)
            }

            // Tagline - matches Electron: "Rekordbox • Serato • Engine DJ • ShowKontrol → Resolume"
            // PORT: `.tracking(0.5)` letter-spacing has no swift-cross-ui equivalent; dropped.
            HStack(spacing: 4) {
                Text("Rekordbox")
                    .foregroundColor(colors.textMuted)
                Text("\u{2022}")
                    .foregroundColor(colors.accentGreen.opacity(0.5))
                Text("Serato")
                    .foregroundColor(colors.textMuted)
                Text("\u{2022}")
                    .foregroundColor(colors.accentGreen.opacity(0.5))
                Text("Engine DJ")
                    .foregroundColor(colors.textMuted)
                Text("\u{2022}")
                    .foregroundColor(colors.accentGreen.opacity(0.5))
                Text("ShowKontrol")
                    .foregroundColor(colors.textMuted)
                Text("\u{2192}")
                    .foregroundColor(colors.accentGreen)
                Text("Resolume")
                    .foregroundColor(colors.textMuted)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))

            Spacer()

            // Project name: "{name} •" when unsaved (bullet not asterisk)
            Text(state.projectName + (state.hasUnsavedChanges ? " \u{2022}" : ""))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(colors.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .trailing)

            // Version badge
            Text("v1.0.0")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(colors.accentGreen)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(colors.accentGreen.opacity(0.15))
                        .stroke(colors.accentGreen.opacity(0.3), style: StrokeStyle(width: 1))
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
#endif
