import SwiftUI

struct DurationInputView: View {
    @Environment(AppState.self) private var state

    @State private var wholeSeconds: String = ""
    @State private var milliseconds: String = ""

    var body: some View {
        let colors = state.colors
        let isEnvelope = state.selectedTrackId == nil

        VStack(alignment: .leading, spacing: 4) {
            Text(isEnvelope ? "ENVELOPE LENGTH" : "TRACK DURATION")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(colors.textSecondary)

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    StepperIntField(text: $wholeSeconds, step: 1, min: 0, width: 65, onCommit: commitDuration)
                    Text("sec")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(colors.textMuted)
                }

                HStack(spacing: 4) {
                    StepperIntField(text: $milliseconds, step: 1, min: 0, max: 999, width: 65, onCommit: commitDuration)
                    Text("ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(colors.textMuted)
                }

                Text("= \(formatTime(state.trackDuration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colors.accentGreen)
            }
        }
        .onAppear { syncFromState() }
        .onChange(of: state.trackDuration) { _, _ in syncFromState() }
    }

    private func syncFromState() {
        let total = state.trackDuration
        let sec = Int(total)
        let ms = Int((total - Double(sec)) * 1000)
        wholeSeconds = "\(sec)"
        milliseconds = "\(ms)"
    }

    private func commitDuration() {
        let sec = Double(wholeSeconds) ?? 0
        let ms = Double(milliseconds) ?? 0
        let total = sec + ms / 1000.0
        if total > 0 {
            state.updateDurationWithScaling(total)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        let ms = Int((seconds - seconds.rounded(.down)) * 1000)
        if min > 0 {
            return String(format: "%d:%02d.%03d", min, sec, ms)
        }
        return String(format: "%d.%03d", Int(seconds), ms)
    }
}
