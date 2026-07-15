#if canImport(AppKit)
import SwiftUI
import UniformTypeIdentifiers

struct ExportSectionView: View {
    @Environment(AppState.self) private var state
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        let colors = state.colors

        Group {
        if state.cuePoints.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 32))
                    .foregroundStyle(colors.textDisabled)
                Text("Select a track or create an envelope to generate output")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colors.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(colors.emptyStateBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(colors.emptyStateBorder, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
        } else {
            VStack(spacing: 12) {
                // Single row: Preset Name + Save XML + Save ShowKontrol Cue
                HStack(spacing: 16) {
                    // Preset name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PRESET NAME")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(colors.textSecondary)
                        TextField("Preset Name", text: Bindable(state).presetName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(colors.textPrimary)
                            .padding(8)
                            .background(colors.inputBg)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(colors.inputBorder, lineWidth: 1)
                            )
                            .frame(minWidth: 240, maxWidth: 360)
                    }

                    // Save XML button — fully functional
                    ExportButton(
                        label: "Save XML", icon: "bolt.fill",
                        fg: colors.accentGreen, bg: colors.accentGreen.opacity(0.2),
                        hoverBg: colors.accentGreen, hoverFg: .black,
                        border: colors.accentGreen
                    ) { exportXML() }

                    // Save ShowKontrol button — fully functional
                    ShowKontrolExportButton(colors: colors) { exportShowKontrol() }

                    Spacer()
                }
            }
        }
        } // end Group
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func exportXML() {
        let xml = state.xmlPreview
        guard !xml.isEmpty else {
            errorMessage = "No envelope data to export. Add cue points first."
            showError = true
            return
        }
        let name = state.presetName.isEmpty ? "envelope" : state.presetName
        guard let url = FileDialogs.saveFile(title: "Export Resolume XML", suggestedName: "\(name).xml", type: .xml) else { return }
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Failed to export: \(error.localizedDescription)"
            showError = true
        }
    }

    private func exportShowKontrol() {
        guard let data = ShowKontrolExporter.generate(cuePoints: state.cuePoints) else {
            errorMessage = "No cue points to export."
            showError = true
            return
        }
        let name = state.presetName.isEmpty ? "cues" : state.presetName
        let cueType = UTType(filenameExtension: "cue") ?? .plainText
        guard let url = FileDialogs.saveFile(title: "Export ShowKontrol Cue", suggestedName: "\(name).cue", type: cueType) else { return }
        do {
            try data.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Failed to export: \(error.localizedDescription)"
            showError = true
        }
    }
}

private struct ExportButton: View {
    let label: String
    let icon: String
    let fg: Color
    let bg: Color
    let hoverBg: Color
    let hoverFg: Color
    let border: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .scaleEffect(isHovered ? 1.2 : 1.0)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isHovered ? hoverFg : fg)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isHovered ? hoverBg : bg)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }
}

private struct ShowKontrolExportButton: View {
    @Environment(AppState.self) private var state
    let colors: ThemeColors
    let action: () -> Void
    @State private var isHovered = false
    @State private var spinAngle: Double = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ShowKontrolIcon(size: 14, color: colors.textPrimary, useWhite: isHovered)
                    .rotationEffect(.degrees(spinAngle))
                Text("Save ShowKontrol Cue")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isHovered ? .white : colors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isHovered ? colors.accentPink : colors.accentPink.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(colors.accentPink, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                withAnimation(.easeInOut(duration: 0.5)) {
                    spinAngle += 180
                }
            }
        }
    }
}
#endif
