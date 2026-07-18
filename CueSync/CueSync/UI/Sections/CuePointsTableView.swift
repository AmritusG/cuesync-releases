#if CUESYNC_CROSSUI
import SwiftCrossUI
import CueSyncCore

// Re-host of Views/Sections/CuePointsTableView.swift onto swift-cross-ui (spec CUESYNC-7 §G.15).
// The AppKit original is off-limits (SwiftUI-only, excluded from this target) and read only
// as the behavioral reference.
//
// PORT: no `Table` on Gtk (§0 table) — this is a header row + `ScrollView`+`VStack`+`ForEach`,
// the same substitute established for the track/playlist lists (§F).
// PORT: no `LazyVStack` at 0.8.0 (§F) — a plain `VStack` is used inside the `ScrollView`.
// PORT: `ColorPicker` is Apple-only (§0 table, §L) — the color dot is a static swatch; editing
// a cue's color is deferred rather than reproduced with a hex `TextField`.
// PORT: the macOS row's tap-to-edit-name affordance (SF Symbol pencil glyph, strikethrough on
// disabled rows) has no portable equivalent (no SF Symbols, no `.strikethrough` at 0.8.0) — the
// Name column is a plain always-editable `TextField` instead, the same pattern already used for
// Project Name (§E) and the track search field (§F).
// PORT: `ScrollViewReader`/`scrollTo` is unconfirmed at 0.8.0 (spec §G.15) — verified absent
// from the pinned checkout, so auto-scroll-to-selected-row is dropped.
struct CuePointsTableView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TableHeader("ON", width: 36, colors: colors)
                TableHeader("", width: 28, colors: colors)
                TableHeader("NAME", flex: true, colors: colors)
                TableHeader("POSITION (S)", width: 85, colors: colors)
                TableHeader("X (0-100)", width: 70, colors: colors)
                TableHeader("Y (0-100)", width: 78, colors: colors)
                TableHeader("INTERPOLATION", width: 165, colors: colors)
            }
            .padding(.vertical, 6)
            .background(colors.tableHeaderBg)

            Rectangle().fill(colors.border).frame(height: 1)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(state.cuePoints.enumerated()), id: \.element.id) { index, _ in
                        CuePointRow(index: index)
                        Rectangle().fill(colors.border).frame(height: 1)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(colors.border, style: StrokeStyle(width: 1))
        }
        .cornerRadius(6)
    }
}

private struct TableHeader: View {
    let title: String
    var width: Double?
    var flex: Bool = false
    let colors: ThemeColors

    init(_ title: String, width: Double, colors: ThemeColors) {
        self.title = title
        self.width = width
        self.colors = colors
    }

    init(_ title: String, flex: Bool, colors: ThemeColors) {
        self.title = title
        self.flex = true
        self.colors = colors
    }

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(colors.textMuted)
            .frame(maxWidth: flex ? .infinity : nil, alignment: .leading)
            .frame(width: flex ? nil : width)
            .padding(.horizontal, 6)
    }
}

private struct CuePointRow: View {
    @Environment(AppState.self) private var state
    let index: Int

    private var cue: CuePoint {
        guard index < state.cuePoints.count else { return .makeDefault() }
        return state.cuePoints[index]
    }

    private var isSelected: Bool {
        state.selectedPointIndex == index
    }

    private var isStartOrEnd: Bool {
        index == 0 || index == state.cuePoints.count - 1
    }

    var body: some View {
        let colors = state.colors
        let posDisabled = !cue.enabled || state.lockXAxis || isStartOrEnd
        let yDisabled = !cue.enabled || state.lockYAxis

        HStack(spacing: 0) {
            Toggle("", isOn: Binding(
                get: { cue.enabled },
                set: { newVal in state.updateCuePoint(at: index) { $0.enabled = newVal } }
            ))
            .toggleStyle(.checkbox)
            .frame(width: 36)
            .padding(.horizontal, 6)

            Circle()
                .fill(Color(cssString: cue.color))
                .frame(width: 10, height: 10)
                .frame(width: 28)

            TextField("Name", text: Binding(
                get: { cue.name },
                set: { newVal in state.updateCuePoint(at: index) { $0.name = newVal } }
            ))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(cue.enabled ? colors.textPrimary : colors.textDisabled)
            .disabled(isStartOrEnd)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)

            StepperField(
                value: Binding(
                    get: { cue.start },
                    set: { newVal in state.updateCuePoint(at: index) { $0.start = newVal } }
                ),
                step: 0.001,
                min: 0,
                max: state.trackDuration,
                format: "%.3f",
                width: 85,
                disabled: posDisabled
            )
            .padding(.horizontal, 4)

            Text(String(format: "%.2f", state.trackDuration > 0 ? (cue.start / state.trackDuration) * 100 : 0))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(cue.enabled ? colors.accentGreen : colors.textDisabled)
                .frame(width: 70, alignment: .leading)
                .padding(.horizontal, 6)

            StepperField(
                value: Binding(
                    get: { cue.yValue },
                    set: { newVal in state.updateCuePoint(at: index) { $0.yValue = newVal } }
                ),
                step: 0.01,
                min: 0,
                max: 100,
                format: "%.2f",
                width: 74,
                disabled: yDisabled
            )
            .padding(.horizontal, 4)

            Picker(of: CurveType.all, selection: Binding<CurveType?>(
                get: { CurveType.all.first(where: { $0.id == cue.curve }) },
                set: { newVal in
                    guard let newVal else { return }
                    state.updateCuePoint(at: index) { $0.curve = newVal.id }
                }
            ))
            .pickerStyle(.menu)
            .frame(width: 165)
        }
        .padding(.vertical, 6)
        .background(
            isSelected ? colors.accentGreen.opacity(0.15) :
            (!cue.enabled ? colors.disabledRowBg : Color.clear)
        )
        .onTapGesture {
            if cue.enabled {
                state.selectedPointIndex = index
            }
        }
    }
}
#endif
