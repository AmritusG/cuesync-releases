import SwiftUI

/// A numeric text field with up/down stepper arrows, matching the Electron app's `<input type="number">`.
struct StepperField: View {
    @Binding var value: Double
    var step: Double = 1
    var min: Double = 0
    var max: Double = .infinity
    var format: String = "%.3f"
    var width: CGFloat = 70
    var disabled: Bool = false
    var onCommit: (() -> Void)?

    @State private var text: String = ""
    @State private var isEditing = false

    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        HStack(spacing: 0) {
            // Text input
            TextField("", text: $text, onCommit: {
                commitText()
                onCommit?()
            })
            .textFieldStyle(.plain)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(disabled ? colors.textDisabled : colors.textPrimary)
            .multilineTextAlignment(.center)
            .disabled(disabled)
            .frame(maxWidth: .infinity)
            .onAppear { syncFromValue() }
            .onChange(of: value) { _, _ in
                if !isEditing { syncFromValue() }
            }

            // Up/down arrows
            if !disabled {
                VStack(spacing: 0) {
                    Button {
                        adjustValue(by: step)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(colors.textSecondary)
                            .frame(width: 16, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(colors.stepperDivider)
                        .frame(height: 0.5)

                    Button {
                        adjustValue(by: -step)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(colors.textSecondary)
                            .frame(width: 16, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(colors.stepperArrowBg)
                .overlay(alignment: .leading) {
                    Rectangle().fill(colors.stepperDivider).frame(width: 0.5)
                }
            }
        }
        .frame(width: width)
        .padding(.vertical, 5)
        .padding(.leading, 6)
        .background(colors.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(disabled ? colors.border : colors.inputBorder, lineWidth: 1)
        )
        .opacity(disabled ? 0.4 : 1)
    }

    private func syncFromValue() {
        text = String(format: format, value)
    }

    private func commitText() {
        // Double("nan"/"inf") parse successfully; min/max do NOT sanitize them, so guard
        // isFinite or a non-finite value would land in cue.start / cue.yValue.
        if let parsed = Double(text), parsed.isFinite {
            value = Swift.min(Swift.max(parsed, min), max)
        }
        syncFromValue()
    }

    private func adjustValue(by delta: Double) {
        let newVal = Swift.min(Swift.max(value + delta, min), max)
        value = newVal
        syncFromValue()
        onCommit?()
    }
}

/// Integer variant for simpler cases (duration sec/ms fields)
struct StepperIntField: View {
    @Binding var text: String
    var step: Int = 1
    var min: Int = 0
    var max: Int = Int.max
    var width: CGFloat = 65
    var disabled: Bool = false
    var onCommit: (() -> Void)?

    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        HStack(spacing: 0) {
            TextField("0", text: $text, onCommit: {
                clampText()
                onCommit?()
            })
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(disabled ? colors.textDisabled : colors.textPrimary)
            .multilineTextAlignment(.center)
            .disabled(disabled)
            .frame(maxWidth: .infinity)

            if !disabled {
                VStack(spacing: 0) {
                    Button {
                        adjust(by: step)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(colors.textSecondary)
                            .frame(width: 16, height: 13)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(colors.stepperDivider)
                        .frame(height: 0.5)

                    Button {
                        adjust(by: -step)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(colors.textSecondary)
                            .frame(width: 16, height: 13)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(colors.stepperArrowBg)
                .overlay(alignment: .leading) {
                    Rectangle().fill(colors.stepperDivider).frame(width: 0.5)
                }
            }
        }
        .frame(width: width)
        .padding(.vertical, 5)
        .padding(.leading, 8)
        .background(colors.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(disabled ? colors.border : colors.inputBorder, lineWidth: 1)
        )
        .opacity(disabled ? 0.4 : 1)
    }

    private func clampText() {
        let val = Int(text) ?? 0
        let clamped = Swift.min(Swift.max(val, min), max)
        text = "\(clamped)"
    }

    private func adjust(by delta: Int) {
        let val = Int(text) ?? 0
        // addingReportingOverflow avoids a trap when val is at Int.max/Int.min.
        let (sum, overflow) = val.addingReportingOverflow(delta)
        let raw = overflow ? (delta > 0 ? max : min) : sum
        let newVal = Swift.min(Swift.max(raw, min), max)
        text = "\(newVal)"
        onCommit?()
    }
}
