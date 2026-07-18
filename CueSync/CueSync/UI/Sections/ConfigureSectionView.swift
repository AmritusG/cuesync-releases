#if CUESYNC_CROSSUI
import SwiftCrossUI
import CueSyncCore

// Re-host of Views/Sections/ConfigureSectionView.swift onto swift-cross-ui (spec CUESYNC-7
// §G.17). The AppKit original is off-limits (SwiftUI-only, excluded from this target) and
// read only as the behavioral reference.
//
// PORT: Load Audio uses `CueSyncCore.AudioDuration` (pure-Swift WAV/AIFF header probing)
// instead of `AVAudioFile` — mp3/m4a/flac duration detection, which macOS gets from
// AVFoundation, is unavailable here; those formats fall back to the manual duration fields
// (spec §G.17, §0 table).
// PORT: `.onKeyPress(.delete)` deletion is optional per spec §G.17 — a Remove button is used
// instead since 0.8.0 key-press handling for this case is unconfirmed.
struct ConfigureSectionView: View {
    @Environment(AppState.self) private var state
    @Environment(\.chooseFile) private var chooseFile

    @State private var audioStatus: AudioLoadStatus = .idle
    @State private var audioFileName: String = ""
    @State private var audioError: String = ""
    @State private var newCueSec: String = "0"
    @State private var newCueMs: String = "0"
    @State private var offsetMs: String = "10"

    enum AudioLoadStatus { case idle, loading, loaded, error }

    var body: some View {
        let colors = state.colors

        if state.cuePoints.isEmpty && state.selectedTrackId == nil {
            VStack(spacing: 12) {
                Text("\u{1F3B5}")
                    .font(.system(size: 28))
                Text("Select a track or create an envelope to configure cue points")
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
            VStack(spacing: 16) {
                trackInfoBar(colors)

                HStack(alignment: .top, spacing: 20) {
                    DurationInputView()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("CUE POSITION")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(colors.textSecondary)
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                StepperIntField(text: $newCueSec, step: 1, min: 0, width: 65)
                                Text("sec")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(colors.textMuted)
                            }
                            HStack(spacing: 4) {
                                StepperIntField(text: $newCueMs, step: 1, min: 0, max: 999, width: 65)
                                Text("ms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(colors.textMuted)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        invisibleLabel()
                        HoverButton(
                            "+ Add Cue Point",
                            fg: colors.accentGreen, bg: colors.accentGreen.opacity(0.2), border: colors.accentGreen,
                            hoverFg: .black, hoverBg: colors.accentGreen
                        ) {
                            addCueAtPosition()
                        }
                    }

                    offsetTool(colors)

                    if state.selectedTrackId != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            invisibleLabel()
                            audioLoadButton(colors)
                            if !audioError.isEmpty {
                                Text(audioError)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(colors.textMuted)
                                    .frame(maxWidth: 180)
                            }
                        }
                    }

                    Spacer()
                }

                if state.cuePoints.count > 0 && state.trackDuration > 0 {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("ENVELOPE PREVIEW")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(colors.accentGreen)

                            Spacer()

                            HStack(spacing: 12) {
                                Toggle("\u{1F512} Lock X", isOn: state.$lockXAxis)
                                    .toggleStyle(.checkbox)
                                Toggle("\u{1F512} Lock Y", isOn: state.$lockYAxis)
                                    .toggleStyle(.checkbox)
                            }
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(colors.textSecondary)

                            HoverButton(
                                "Remove",
                                fg: colors.textSecondary, bg: colors.buttonBg, border: colors.buttonBorder,
                                hoverFg: colors.textPrimary, hoverBg: colors.buttonHoverBg,
                                hoverBorder: colors.buttonHoverBorder
                            ) {
                                if state.canRemoveSelectedPoint { state.removeSelectedPoint() }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        EnvelopeCanvasView()
                            .frame(minHeight: 200)

                        HStack(spacing: 0) {
                            let active = state.cuePoints.filter(\.enabled).count
                            Text("\(active)/\(state.cuePoints.count) enabled")
                                .foregroundColor(colors.accentGreen)
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                    }
                    .background(colors.envelopeContainerBg)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(colors.envelopeContainerBorder, style: StrokeStyle(width: 1))
                    }
                    .cornerRadius(6)
                }

                if state.cuePoints.count > 0 {
                    CuePointsTableView()
                } else {
                    Text(state.selectedTrackId == nil ? "Add cue points using the fields above" : "No cue points found in this track")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(colors.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                        .background(colors.emptyStateBg)
                        .cornerRadius(6)
                }
            }
        }
    }

    @ViewBuilder
    private func invisibleLabel() -> some View {
        Text(" ")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
    }

    @ViewBuilder
    private func trackInfoBar(_ colors: ThemeColors) -> some View {
        HStack(spacing: 8) {
            if let track = state.selectedTrack {
                Text(track.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(colors.textPrimary)
                Text("by \(track.artist.isEmpty ? "Unknown" : track.artist)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(colors.textSecondary)
                if !track.album.isEmpty {
                    Text("\u{2022}").foregroundColor(colors.textDisabled)
                    Text(track.album)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(colors.textSecondary)
                }
            } else {
                Text(state.projectName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(colors.textPrimary)
                Text("Manual Envelope")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(colors.accentGold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(colors.accentGold.opacity(0.2))
                    .cornerRadius(4)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(colors.accentGreen.opacity(0.1))
        .cornerRadius(5)
    }

    @ViewBuilder
    private func offsetTool(_ colors: ThemeColors) -> some View {
        let offset = Int(offsetMs) ?? 10
        let hasSelection = state.selectedPointIndex != nil

        VStack(alignment: .leading, spacing: 4) {
            Text("OFFSET DUPLICATE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(colors.textSecondary)
            HStack(spacing: 4) {
                HoverButton(
                    "\u{2212}",
                    fg: colors.accentGreen, bg: colors.accentGreen.opacity(0.2), border: colors.accentGreen,
                    hoverFg: .black, hoverBg: colors.accentGreen
                ) {
                    guard hasSelection else { return }
                    state.duplicateSelectedWithOffset(offsetMs: -offset)
                }

                StepperIntField(text: $offsetMs, step: 1, min: 1, max: 5000, width: 55)

                Text("ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(colors.textMuted)

                HoverButton(
                    "+",
                    fg: colors.accentGreen, bg: colors.accentGreen.opacity(0.2), border: colors.accentGreen,
                    hoverFg: .black, hoverBg: colors.accentGreen
                ) {
                    guard hasSelection else { return }
                    state.duplicateSelectedWithOffset(offsetMs: offset)
                }
            }
        }
    }

    @ViewBuilder
    private func audioLoadButton(_ colors: ThemeColors) -> some View {
        let (bg, border, fg): (Color, Color, Color) = {
            switch audioStatus {
            case .idle: return (colors.buttonBg, colors.buttonBorder, colors.textPrimary)
            case .loading: return (Color.yellow.opacity(0.15), Color.yellow, Color.yellow)
            case .loaded: return (colors.accentGreen.opacity(0.15), colors.accentGreen, colors.accentGreen)
            case .error: return (Color.red.opacity(0.15), Color.red, Color.red)
            }
        }()

        let label: String = {
            switch audioStatus {
            case .idle: return "Load Audio File"
            case .loading: return "\u{23F3} Analyzing..."
            case .loaded: return "\u{2713} \(audioFileName)"
            case .error: return "\u{26A0} Error - Try Again"
            }
        }()

        HoverButton(label, fg: fg, bg: bg, border: border) {
            loadAudioFile()
        }
    }

    // MARK: - Actions

    private func addCueAtPosition() {
        let sec = Double(newCueSec) ?? 0
        let ms = Double(newCueMs) ?? 0
        let time = sec + ms / 1000.0
        let exists = state.cuePoints.contains { abs($0.start - time) < 0.001 }
        guard !exists else { return }
        state.addCuePoint(at: time)
    }

    private func loadAudioFile() {
        audioStatus = .loading
        audioError = ""
        Task {
            guard let url = await chooseFile(title: "Load Audio File") else {
                audioStatus = .idle
                return
            }
            if let duration = AudioDuration.duration(of: url) {
                state.trackDuration = AppState.safeDuration(duration)
                state.hasUnsavedChanges = true
                audioFileName = url.lastPathComponent
                audioStatus = .loaded
            } else {
                audioStatus = .error
                audioError = "Could not read duration from this file."
            }
        }
    }
}
#endif
