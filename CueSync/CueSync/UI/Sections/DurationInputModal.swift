#if CUESYNC_CROSSUI
import SwiftCrossUI

// Re-host of Views/Sections/DurationInputModal.swift as swift-cross-ui `Sheet`
// content (spec CUESYNC-7 §I.19). The caller (Project section) presents this via
// `.sheet(isPresented:content:)`; this view is just the sheet's body, so it needs
// no `.environment(state)` re-injection — swift-cross-ui's sheet environment is
// derived from the presenting view's environment (unlike the macOS SwiftUI
// original, which re-injects explicitly).
// PORT: `.shadow` has no swift-cross-ui equivalent and is dropped (§L).
struct DurationInputModal: View {
    @Environment(AppState.self) private var state
    @Binding var minutes: String
    @Binding var seconds: String
    @Binding var milliseconds: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let colors = state.colors

        VStack(spacing: 20) {
            Text("Set Track Duration")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(colors.textPrimary)

            Text("This import format doesn't include duration.\nPlease enter the track duration:")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(colors.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                durationField(placeholder: "01", text: $minutes, unit: "min", colors: colors)
                Text(":")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(colors.textSecondary)
                durationField(placeholder: "00", text: $seconds, unit: "sec", colors: colors)
                Text(":")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(colors.textSecondary)
                durationField(placeholder: "000", text: $milliseconds, unit: "ms", colors: colors)
            }

            HStack(spacing: 12) {
                Text("Cancel")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(colors.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.white.opacity(0.2), style: StrokeStyle(width: 1))
                    }
                    .cornerRadius(5)
                    .onTapGesture { onCancel() }

                Text("Import")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(colors.accentGreen)
                    .cornerRadius(5)
                    .onTapGesture { onConfirm() }
            }
        }
        .padding(30)
        .background(colors.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(colors.border, style: StrokeStyle(width: 1))
        }
        .cornerRadius(12)
        .frame(width: 400)
    }

    private func durationField(placeholder: String, text: Binding<String>, unit: String, colors: ThemeColors) -> some View {
        VStack(spacing: 4) {
            TextField(placeholder, text: text)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundColor(colors.textPrimary)
                .multilineTextAlignment(.center)
                .frame(width: 60)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.4))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), style: StrokeStyle(width: 1))
                }
                .cornerRadius(6)
            Text(unit)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(colors.textMuted)
        }
    }
}
#endif
