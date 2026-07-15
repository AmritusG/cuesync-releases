import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ConfigureSectionView: View {
    @Environment(AppState.self) private var state

    @State private var audioStatus: AudioLoadStatus = .idle
    @State private var audioFileName: String = ""
    @State private var audioError: String = ""
    @State private var newCueSec: String = "0"
    @State private var newCueMs: String = "0"

    enum AudioLoadStatus { case idle, loading, loaded, error }

    var body: some View {
        let colors = state.colors

        if state.cuePoints.isEmpty && state.selectedTrackId == nil {
            VStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 32))
                    .foregroundStyle(colors.textDisabled)
                Text("Select a track or create an envelope to configure cue points")
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
            VStack(spacing: 16) {
                // Selected track info bar
                trackInfoBar(colors)

                // Duration + Add Cue + Load Audio row.
                // .top aligns label baselines across every column; bare buttons get
                // an invisible label placeholder so they sit at the same y as the
                // controls under labelled columns.
                HStack(alignment: .top, spacing: 20) {
                    DurationInputView()

                    // Cue Position
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CUE POSITION")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(colors.textSecondary)
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                StepperIntField(text: $newCueSec, step: 1, min: 0, width: 65)
                                Text("sec")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(colors.textMuted)
                            }
                            HStack(spacing: 4) {
                                StepperIntField(text: $newCueMs, step: 1, min: 0, max: 999, width: 65)
                                Text("ms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(colors.textMuted)
                            }
                        }
                    }

                    // Add Cue Point — invisible label keeps it row-aligned
                    VStack(alignment: .leading, spacing: 4) {
                        invisibleLabel()
                        AddCueButton { addCueAtPosition() }
                            .environment(state)
                    }

                    OffsetToolInline(colors: colors)

                    // Load Audio File (only for track mode, not envelope mode)
                    if state.selectedTrackId != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            invisibleLabel()
                            audioLoadButton(colors)
                            if !audioError.isEmpty {
                                Text(audioError)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(colors.textMuted)
                                    .frame(maxWidth: 180)
                            }
                        }
                    }

                    Spacer()
                }

                // Envelope editor with header
                if state.cuePoints.count > 0 && state.trackDuration > 0 {
                    VStack(spacing: 0) {
                        // Envelope header bar
                        HStack(spacing: 12) {
                            Text("ENVELOPE PREVIEW")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(colors.accentGreen)

                            Spacer()

                            // Lock controls
                            HStack(spacing: 12) {
                                Toggle(isOn: Bindable(state).lockXAxis) {
                                    Text("🔒 Lock X")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(colors.textSecondary)
                                }
                                .toggleStyle(.checkbox)

                                Toggle(isOn: Bindable(state).lockYAxis) {
                                    Text("🔒 Lock Y")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(colors.textSecondary)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        EnvelopeCanvasView()
                            .frame(minHeight: 200)

                        HStack(spacing: 0) {
                            Text("Drag points to adjust Y • Uncheck cues below to exclude from envelope • ")
                                .foregroundStyle(colors.textDisabled)
                            let active = state.cuePoints.filter(\.enabled).count
                            Text("\(active)/\(state.cuePoints.count) enabled")
                                .foregroundStyle(colors.accentGreen)
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                    }
                    .background(colors.envelopeContainerBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(colors.envelopeContainerBorder, lineWidth: 1))
                }

                // Cue points table (full width, below envelope)
                if state.cuePoints.count > 0 {
                    CuePointsTableView()
                } else {
                    Text(state.selectedTrackId == nil ? "Add cue points using the fields above" : "No cue points found in this track")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(colors.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                        .background(colors.emptyStateBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .onKeyPress(.delete) {
                if state.canRemoveSelectedPoint { state.removeSelectedPoint() }
                return .handled
            }
            .onKeyPress(.deleteForward) {
                if state.canRemoveSelectedPoint { state.removeSelectedPoint() }
                return .handled
            }
        }
    }

    // MARK: - Toolbar helpers

    /// Invisible label-height spacer so bare-button columns line up with
    /// the labelled columns when the toolbar HStack uses .top alignment.
    @ViewBuilder
    private func invisibleLabel() -> some View {
        Text(" ")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1)
            .accessibilityHidden(true)
    }

    // MARK: - Track Info Bar

    @ViewBuilder
    private func trackInfoBar(_ colors: ThemeColors) -> some View {
        if let track = state.selectedTrack {
            HStack(spacing: 8) {
                Text(track.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(colors.textPrimary)
                Text("by \(track.artist.isEmpty ? "Unknown" : track.artist)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(colors.textSecondary)
                if !track.album.isEmpty {
                    Text("•").foregroundStyle(colors.textDisabled)
                    Text(track.album)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(colors.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(colors.accentGreen.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .leading) {
                Rectangle().fill(colors.accentGreen).frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        } else {
            HStack(spacing: 8) {
                Text(state.projectName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(colors.textPrimary)
                Text("Manual Envelope")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(colors.accentGold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(colors.accentGold.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(colors.accentGreen.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .leading) {
                Rectangle().fill(colors.accentGreen).frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    // MARK: - Load Audio Button

    @ViewBuilder
    private func audioLoadButton(_ colors: ThemeColors) -> some View {
        let (bg, border, fg): (Color, Color, Color) = {
            switch audioStatus {
            case .idle:    return (colors.buttonBg, colors.buttonBorder, colors.textPrimary)
            case .loading: return (Color.yellow.opacity(0.15), Color.yellow, Color.yellow)
            case .loaded:  return (colors.accentGreen.opacity(0.15), colors.accentGreen, colors.accentGreen)
            case .error:   return (Color.red.opacity(0.15), Color.red, Color.red)
            }
        }()

        Button { loadAudioFile() } label: {
            HStack(spacing: 6) {
                switch audioStatus {
                case .idle:
                    Image(systemName: "music.note").font(.system(size: 12))
                    Text("Load Audio File")
                case .loading:
                    Text("⏳ Analyzing...")
                case .loaded:
                    Text("✓ \(audioFileName)")
                case .error:
                    Text("⚠ Error - Try Again")
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(fg)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(audioStatus == .loading)
        .help("Supported formats: WAV, AIFF, MP3, FLAC, M4A")
    }

    // MARK: - Actions

    private func addCueAtPosition() {
        let sec = Double(newCueSec) ?? 0
        let ms = Double(newCueMs) ?? 0
        let time = sec + ms / 1000.0
        // Don't add if a cue already exists at this position
        let exists = state.cuePoints.contains { abs($0.start - time) < 0.001 }
        guard !exists else { return }
        state.addCuePoint(at: time)
    }

    private func loadAudioFile() {
        let audioTypes: [UTType] = [.wav, .aiff, .mp3].compactMap { $0 }
            + [UTType(filenameExtension: "flac"), UTType(filenameExtension: "m4a")].compactMap { $0 }

        guard let url = FileDialogs.openFile(title: "Load Audio File", types: audioTypes) else { return }

        audioStatus = .loading
        audioFileName = url.lastPathComponent
        audioError = ""

        // Use AVAudioFile to detect duration
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let audioFile = try AVAudioFile(forReading: url)
                let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

                DispatchQueue.main.async {
                    state.trackDuration = AppState.safeDuration(duration)
                    state.hasUnsavedChanges = true
                    audioStatus = .loaded
                }
            } catch {
                DispatchQueue.main.async {
                    audioStatus = .error
                    audioError = error.localizedDescription
                }
            }
        }
    }
}

private struct AddCueButton: View {
    @Environment(AppState.self) private var state
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let colors = state.colors
        Button(action: action) {
            HStack(spacing: 4) {
                Text("+").font(.system(size: 12, weight: .bold))
                Text("Add Cue Point")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isHovered ? .black : colors.accentGreen)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isHovered ? colors.accentGreen : colors.accentGreen.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(colors.accentGreen, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

/// Compact inline offset duplicate tool (sits in the same row as Add Cue)
private struct OffsetToolInline: View {
    @Environment(AppState.self) private var state
    let colors: ThemeColors
    @State private var offsetMs: String = "10"
    @State private var minusHovered = false
    @State private var plusHovered = false

    private var offset: Int { Int(offsetMs) ?? 10 }
    private var hasSelection: Bool { state.selectedPointIndex != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OFFSET DUPLICATE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(colors.textSecondary)
            HStack(spacing: 4) {
                // − button (same style as Add Cue Point)
                Button {
                    guard hasSelection else { return }
                    state.duplicateSelectedWithOffset(offsetMs: -offset)
                } label: {
                    HStack(spacing: 4) {
                        Text("−").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(minusHovered && hasSelection ? .black : colors.accentGreen)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(minusHovered && hasSelection ? colors.accentGreen : colors.accentGreen.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(colors.accentGreen, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .opacity(hasSelection ? 1 : 0.4)
                .onHover { minusHovered = $0 }
                .animation(.easeInOut(duration: 0.15), value: minusHovered)

                StepperIntField(text: $offsetMs, step: 1, min: 1, max: 5000, width: 55)

                Text("ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(colors.textMuted)

                // + button (same style as Add Cue Point)
                Button {
                    guard hasSelection else { return }
                    state.duplicateSelectedWithOffset(offsetMs: offset)
                } label: {
                    HStack(spacing: 4) {
                        Text("+").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(plusHovered && hasSelection ? .black : colors.accentGreen)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(plusHovered && hasSelection ? colors.accentGreen : colors.accentGreen.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(colors.accentGreen, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .opacity(hasSelection ? 1 : 0.4)
                .onHover { plusHovered = $0 }
                .animation(.easeInOut(duration: 0.15), value: plusHovered)
            }
        }
    }
}
