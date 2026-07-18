#if CUESYNC_CROSSUI
import Foundation
import SwiftCrossUI

// Re-host of Views/Sections/StepperField.swift onto swift-cross-ui (spec CUESYNC-7 §J.20).
// swift-cross-ui's Button carries only a fixed String label — no ViewBuilder content — so
// the up/down chevrons use a plain Text("\u{25B2}")/Text("\u{25BC}") with `.onTapGesture`
// standing in for the AppKit original's `Button { } label: { Image(systemName:) }`, the same
// substitute CollapsibleSection's header row established (§D.8). SF Symbols are unavailable,
// so the arrows are the source's `chevron.up`/`chevron.down` reproduced as glyphs (§J.20).
// Numeric parsing, clamping, the isFinite guard, and overflow-safe Int handling are preserved
// verbatim from the AppKit original (§4: "a hostile file cannot produce NaN geometry").
struct StepperField: View {
    @Binding var value: Double
    var step: Double = 1
    var min: Double = 0
    var max: Double = .infinity
    var format: String = "%.3f"
    var width: Double = 70
    var disabled: Bool = false
    var onCommit: (() -> Void)?

    @State private var text: String = ""
    @State private var isEditing = false

    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        HStack(spacing: 0) {
            TextField("", text: $text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(disabled ? colors.textDisabled : colors.textPrimary)
                .multilineTextAlignment(.center)
                .disabled(disabled)
                .frame(maxWidth: .infinity)
                .onSubmit {
                    commitText()
                    onCommit?()
                }
                .onChange(of: value) {
                    if !isEditing { syncFromValue() }
                }

            if !disabled {
                VStack(spacing: 0) {
                    Text("\u{25B2}")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(colors.textSecondary)
                        .frame(width: 16, height: 12)
                        .onTapGesture { adjustValue(by: step) }

                    Rectangle()
                        .fill(colors.stepperDivider)
                        .frame(height: 0.5)

                    Text("\u{25BC}")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(colors.textSecondary)
                        .frame(width: 16, height: 12)
                        .onTapGesture { adjustValue(by: -step) }
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
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(disabled ? colors.border : colors.inputBorder, style: StrokeStyle(width: 1))
        }
        .cornerRadius(4)
        // PORT: no View-level `.opacity()` at 0.8.0 (only Color.opacity) — the disabled
        // look relies on textDisabled/border color alone, not a dimmed whole-view overlay.
        .onAppear { syncFromValue() }
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
    var width: Double = 65
    var disabled: Bool = false
    var onCommit: (() -> Void)?

    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        HStack(spacing: 0) {
            TextField("0", text: $text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(disabled ? colors.textDisabled : colors.textPrimary)
                .multilineTextAlignment(.center)
                .disabled(disabled)
                .frame(maxWidth: .infinity)
                .onSubmit {
                    clampText()
                    onCommit?()
                }

            if !disabled {
                VStack(spacing: 0) {
                    Text("\u{25B2}")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(colors.textSecondary)
                        .frame(width: 16, height: 13)
                        .onTapGesture { adjust(by: step) }

                    Rectangle()
                        .fill(colors.stepperDivider)
                        .frame(height: 0.5)

                    Text("\u{25BC}")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(colors.textSecondary)
                        .frame(width: 16, height: 13)
                        .onTapGesture { adjust(by: -step) }
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
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(disabled ? colors.border : colors.inputBorder, style: StrokeStyle(width: 1))
        }
        .cornerRadius(4)
        // PORT: no View-level `.opacity()` at 0.8.0 (only Color.opacity) — see StepperField above.
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
#endif
