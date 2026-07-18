#if CUESYNC_CROSSUI
import SwiftCrossUI
import Foundation
import CueSyncCore

// Re-host of Views/Sections/ExportSectionView.swift onto swift-cross-ui (spec CUESYNC-7 §H).
// The AppKit original is off-limits (SwiftUI-only) and read only as the behavioral reference.
// PORT: SF Symbols, the spin/scale hover animation, and the XML preview panel are dropped —
// no equivalents at 0.8.0 (spec §L); the two buttons are the brand-colored `BrandButton`
// established in §J.22 instead of the macOS custom `ExportButton`/`ShowKontrolExportButton`.
struct ExportSectionView: View {
    @Environment(AppState.self) private var state
    @Environment(\.chooseFileSaveDestination) private var chooseFileSaveDestination

    @State private var errorMessage: String?

    var body: some View {
        let colors = state.colors

        VStack {
            if state.cuePoints.isEmpty {
                VStack(spacing: 12) {
                    Text("\u{1F4E4}")
                        .font(.system(size: 28))
                    Text("Select a track or create an envelope to generate output")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(colors.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(colors.emptyStateBg)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(colors.emptyStateBorder, style: StrokeStyle(width: 1))
                }
                .cornerRadius(8)
            } else {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PRESET NAME")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(colors.textSecondary)
                        TextField("Preset Name", text: state.$presetName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colors.textPrimary)
                            .padding(8)
                            .background(colors.inputBg)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(colors.inputBorder, style: StrokeStyle(width: 1))
                            }
                            .cornerRadius(5)
                            .frame(width: 240, height: 36)
                    }

                    BrandButton(
                        "Save XML", glyph: "\u{26A1}",
                        accent: colors.accentGreen, fg: colors.textPrimary, hoverFg: .black
                    ) { exportXML() }

                    BrandButton(
                        "Save ShowKontrol Cue", glyph: "\u{25B8}",
                        accent: colors.accentPink, fg: colors.textPrimary, hoverFg: .white
                    ) { exportShowKontrol() }

                    Spacer()
                }
            }
        }
        .alert($errorMessage) {
            Button("OK") {}
        }
    }

    // MARK: - Export Actions

    private func exportXML() {
        let xml = state.xmlPreview
        guard !xml.isEmpty else {
            errorMessage = "No envelope data to export. Add cue points first."
            return
        }
        let name = TextTools.slugify(state.presetName, fallback: "envelope")
        Task {
            guard let url = await chooseFileSaveDestination(
                title: "Export Resolume XML",
                defaultFileName: "\(name).xml"
            ) else { return }
            do {
                try xml.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "Failed to export: \(error.localizedDescription)"
            }
        }
    }

    private func exportShowKontrol() {
        guard let data = ShowKontrolExporter.generate(cuePoints: state.cuePoints) else {
            errorMessage = "No cue points to export."
            return
        }
        let name = TextTools.slugify(state.presetName, fallback: "cues")
        Task {
            guard let url = await chooseFileSaveDestination(
                title: "Export ShowKontrol Cue",
                defaultFileName: "\(name).cue"
            ) else { return }
            do {
                try data.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "Failed to export: \(error.localizedDescription)"
            }
        }
    }
}
#endif
