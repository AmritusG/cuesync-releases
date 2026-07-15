import SwiftUI

struct CuePointsTableView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let colors = state.colors

        VStack(spacing: 0) {
            // Header
            HStack(spacing: 0) {
                TableHeader("ON", width: 36)
                TableHeader("", width: 32)
                TableHeader("NAME", flex: true)
                TableHeader("POSITION (S)", width: 85)
                TableHeader("X (0-100)", width: 70)
                TableHeader("Y (0-100)", width: 70)
                TableHeader("INTERPOLATION", width: 165)
            }
            .padding(.vertical, 6)
            .background(colors.tableHeaderBg)

            // Rows
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(state.cuePoints.enumerated()), id: \.element.id) { index, cue in
                            CuePointRow(index: index)
                                .id(cue.id)
                            Rectangle().fill(colors.border).frame(height: 1)
                        }
                    }
                }
                .onChange(of: state.selectedPointIndex) { _, newIdx in
                    if let idx = newIdx, idx < state.cuePoints.count {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(state.cuePoints[idx].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(colors.border, lineWidth: 1)
        )
    }
}

private struct TableHeader: View {
    let title: String
    var width: CGFloat?
    var flex: Bool = false

    @Environment(AppState.self) private var state

    init(_ title: String, width: CGFloat) {
        self.title = title
        self.width = width
    }

    init(_ title: String, flex: Bool) {
        self.title = title
        self.flex = true
    }

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(state.colors.textMuted)
            .frame(maxWidth: flex ? .infinity : nil, alignment: .leading)
            .frame(width: flex ? nil : width)
            .padding(.horizontal, 6)
    }
}

private struct CuePointRow: View {
    @Environment(AppState.self) private var state
    let index: Int

    @State private var editingName = false
    @State private var tempName = ""
    @State private var showColorPicker = false
    @State private var pickedColor = Color.green

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
            // Enable checkbox
            Toggle("", isOn: Binding(
                get: { cue.enabled },
                set: { newVal in state.updateCuePoint(at: index) { $0.enabled = newVal } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 36)
            .padding(.horizontal, 6)

            // Color dot — click to change color
            Circle()
                .fill(Color(cssString: cue.color))
                .frame(width: 10, height: 10)
                .shadow(color: Color(cssString: cue.color).opacity(cue.enabled ? 0.6 : 0), radius: 3)
                .opacity(cue.enabled ? 1 : 0.3)
                .frame(width: 32)
                .contentShape(Circle().scale(2.5))
                .onTapGesture {
                    pickedColor = Color(cssString: cue.color)
                    showColorPicker = true
                }
                .popover(isPresented: $showColorPicker) {
                    VStack(spacing: 12) {
                        Text("CUE COLOR")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        ColorPicker("", selection: $pickedColor, supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 200, height: 150)
                        Button("Apply") {
                            if let hex = pickedColor.hexString {
                                state.updateCuePoint(at: index) { $0.color = hex }
                            }
                            showColorPicker = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 30/255, green: 215/255, blue: 96/255))
                    }
                    .padding(16)
                }

            // Name — click to edit (except Start/End)
            Group {
                if editingName {
                    TextField("Name", text: $tempName, onCommit: {
                        state.updateCuePoint(at: index) { $0.name = tempName }
                        editingName = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(colors.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(colors.inputBg)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(colors.accentGreen, lineWidth: 1))
                    .onExitCommand { editingName = false }
                } else {
                    HStack(spacing: 4) {
                        Text(cue.name.isEmpty ? "Cue \(index + 1)" : cue.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(cue.enabled ? colors.textPrimary : colors.textDisabled)
                            .strikethrough(!cue.enabled, color: colors.textDisabled)
                            .opacity(cue.enabled ? 1 : 0.4)
                            .lineLimit(1)
                        if !isStartOrEnd && cue.enabled {
                            Image(systemName: "pencil")
                                .font(.system(size: 8))
                                .foregroundStyle(colors.textMuted)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isStartOrEnd ? Color.clear : colors.inputBg.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isStartOrEnd ? Color.clear : colors.inputBorder.opacity(0.5), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isStartOrEnd else { return }
                        tempName = cue.name
                        editingName = true
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)

            // Position — disabled for start/end and when lockX
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
            .help(isStartOrEnd ? "Start/End position is fixed" : "")
            .padding(.horizontal, 4)

            // X Value (normalized 0-100, read-only)
            Text(String(format: "%.2f", state.trackDuration > 0 ? (cue.start / state.trackDuration) * 100 : 0))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(cue.enabled ? colors.accentGreen : colors.textDisabled)
                .frame(width: 70, alignment: .leading)
                .padding(.horizontal, 6)

            // Y Value — disabled when lockY
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

            // Curve dropdown
            Picker("", selection: Binding(
                get: { cue.curve },
                set: { newVal in state.updateCuePoint(at: index) { $0.curve = newVal } }
            )) {
                ForEach(CurveType.all) { curve in
                    Text(curve.name)
                        .tag(curve.id)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 9, design: .monospaced))
            .frame(width: 165)
        }
        .padding(.vertical, 6)
        .background(
            isSelected ? colors.accentGreen.opacity(0.15) :
            (!cue.enabled ? colors.disabledRowBg : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if cue.enabled {
                state.selectedPointIndex = index
            }
        }
    }
}
