#if canImport(AppKit)
import SwiftUI

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
                .foregroundStyle(colors.textPrimary)

            Text("This import format doesn't include duration.\nPlease enter the track duration:")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(colors.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                VStack(spacing: 4) {
                    TextField("01", text: $minutes)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(width: 60)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                    Text("min")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(colors.textMuted)
                }

                Text(":")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(colors.textSecondary)

                VStack(spacing: 4) {
                    TextField("00", text: $seconds)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(width: 60)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                    Text("sec")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(colors.textMuted)
                }

                Text(":")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(colors.textSecondary)

                VStack(spacing: 4) {
                    TextField("000", text: $milliseconds)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundStyle(colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(width: 60)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                    Text("ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(colors.textMuted)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(colors.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                    .buttonStyle(.plain)

                Button("Import") { onConfirm() }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(colors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .buttonStyle(.plain)
            }
        }
        .padding(30)
        .background(colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        .frame(width: 400)
    }
}
#endif
