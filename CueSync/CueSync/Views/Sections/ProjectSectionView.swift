#if canImport(AppKit)
import SwiftUI
import UniformTypeIdentifiers

struct ProjectSectionView: View {
    @Environment(AppState.self) private var state

    @State private var showDurationModal = false
    @State private var pendingImportType: ImportType?
    @State private var pendingResolumeURL: URL?
    @State private var durationMinutes = "01"
    @State private var durationSeconds = "00"
    @State private var durationMs = "000"
    @State private var errorMessage: String?
    @State private var showError = false

    enum ImportType { case showkontrol, resolume }

    var body: some View {
        let colors = state.colors

        VStack(alignment: .leading, spacing: 12) {
            // Row 1: Project + Name + Create + Import Envelope + Import Cues (wraps on narrow windows)
            FlowLayout(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Project")
                    HStack(spacing: 8) {
                        ActionButton("New", colors: colors) {
                            state.confirmNewProject()
                        } icon: { NewIcon(size: 14, color: colors.textPrimary) }
                        ActionButton("Open", colors: colors) {
                            state.confirmAction { [self] in openProject() }
                        } icon: { OpenIcon(size: 14, color: colors.textPrimary) }
                        ActionButton("Save", colors: colors) {
                            saveProject()
                        } icon: { SaveIcon(size: 14, color: colors.textPrimary) }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Project Name")
                    NonSelectingTextField(text: Bindable(state).projectName, placeholder: "Project Name")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(colors.textPrimary)
                        .padding(8)
                        .background(colors.inputBg)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(colors.inputBorder, lineWidth: 1))
                        .frame(width: 155, height: 36)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Design from Scratch")
                    ImportButton("Create Envelope", bg: colors.accentGold, fg: colors.textPrimary, hoverFg: .black, action: {
                        state.createBlankEnvelope()
                    }) { CreateEnvelopeIcon(size: 16, color: colors.textPrimary) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Import Envelope")
                    ImportButton("Resolume", bg: colors.accentTeal, fg: colors.textPrimary, hoverFg: Color(red: 0.1, green: 0.23, blue: 0.21), action: {
                        importResolume()
                    }) { ResolumeIcon(size: 16, color: colors.textPrimary) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Import Cues")
                    HStack(spacing: 8) {
                        ImportButton("Rekordbox", bg: colors.isDark ? Color.white.opacity(0.5) : Color.black.opacity(0.5),
                                     fg: colors.textPrimary, hoverFg: .white, action: { importRekordbox() }) {
                            RekordboxIcon(size: 16, color: colors.textPrimary)
                        }
                        ImportButton("Serato", bg: colors.accentBlue, fg: colors.textPrimary, hoverFg: .white, action: { importSerato() }) {
                            SeratoIcon(size: 16, color: colors.textPrimary,
                                       bgColor: colors.isDark ? Color(red: 26/255, green: 26/255, blue: 46/255) : Color(red: 245/255, green: 245/255, blue: 247/255))
                        }
                        ImportButton("Engine DJ", bg: colors.accentMint, fg: colors.textPrimary, hoverFg: .black, action: { importEngineDJ() }) {
                            EngineDJIcon(size: 16, color: colors.textPrimary)
                        }
                        ShowKontrolImportButton(colors: colors) { importShowKontrol() }
                    }
                }
            }

            // Row 2: Viewport + Theme
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Viewport")
                    HStack(spacing: 6) {
                        ViewportButton(label: "Reset", colors: colors, isActive: !state.sideBySideMode) {
                            state.resetLayout()
                        }
                        ViewportButton(label: "Side-By-Side", colors: colors, isActive: state.sideBySideMode) {
                            state.sideBySideMode.toggle()
                            state.savePreferences()
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Theme")
                    HStack(spacing: 6) {
                        ThemeButton(label: "Dark", isActive: state.theme == .dark, colors: colors) {
                            state.theme = .dark
                            state.savePreferences()
                        }
                        ThemeButton(label: "Light", isActive: state.theme == .light, colors: colors) {
                            state.theme = .light
                            state.savePreferences()
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Import Settings")
                    HStack(spacing: 8) {
                        ThemeButton(label: "True", isActive: state.forceYZeroOnImport, colors: colors) {
                            state.forceYZeroOnImport = true
                            state.savePreferences()
                        }
                        ThemeButton(label: "False", isActive: !state.forceYZeroOnImport, colors: colors) {
                            state.forceYZeroOnImport = false
                            state.savePreferences()
                        }
                        Text("Click here to set Y=0 at importing Cue Points")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                }
            }

            // Track count at the bottom
            if !state.tracks.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(colors.accentGreen)
                    Text("\(state.tracks.count) tracks loaded")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(colors.accentGreen)
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .alert("Unsaved Changes", isPresented: Bindable(state).showUnsavedAlert) {
            Button("Discard", role: .destructive) {
                state.executePendingAction()
            }
            Button("Cancel", role: .cancel) {
                state.pendingAction = nil
            }
        } message: {
            Text("You have unsaved changes. Do you want to discard them?")
        }
        .sheet(isPresented: $showDurationModal) {
            DurationInputModal(
                minutes: $durationMinutes,
                seconds: $durationSeconds,
                milliseconds: $durationMs,
                onCancel: { showDurationModal = false },
                onConfirm: { confirmDurationImport() }
            )
            .environment(state)
        }
    }

    // MARK: - Import Actions

    private func importRekordbox() {
        guard let url = FileDialogs.openFile(title: "Import Rekordbox XML", types: [.xml]) else { return }
        do {
            try state.loadRekordbox(from: url)
        } catch {
            errorMessage = "Failed to parse Rekordbox XML: \(error.localizedDescription)"
            showError = true
        }
    }

    private func importSerato() {
        let audioTypes: [UTType] = [.mp3, .aiff, .wav].compactMap { $0 }
        let panel = NSOpenPanel()
        panel.title = "Import Serato Audio Files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = audioTypes
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        state.loadSerato(from: panel.urls)
        if state.tracks.isEmpty {
            errorMessage = "No Serato cue points found in the selected files."
            showError = true
        }
    }

    private func importEngineDJ() {
        let dbType = UTType(filenameExtension: "db") ?? UTType.database
        guard let url = FileDialogs.openFile(title: "Import Engine DJ Database", types: [dbType, .database]) else { return }
        do {
            try state.loadEngineDJ(from: url)
        } catch {
            errorMessage = "Failed to parse Engine DJ database: \(error.localizedDescription)"
            showError = true
        }
    }

    private func importShowKontrol() {
        let cueType = UTType(filenameExtension: "cue") ?? .plainText
        guard let url = FileDialogs.openFile(title: "Import ShowKontrol Cue", types: [cueType, .plainText]) else { return }
        do {
            let durationAutoDetected = try state.loadShowKontrol(from: url)
            if !durationAutoDetected {
                // No timing data in cues — ask user for duration
                pendingImportType = .showkontrol
                showDurationModal = true
            }
        } catch {
            errorMessage = "Failed to parse ShowKontrol file: \(error.localizedDescription)"
            showError = true
        }
    }

    private func importResolume() {
        guard let url = FileDialogs.openFile(title: "Import Resolume Envelope", types: [.xml]) else { return }
        pendingResolumeURL = url
        pendingImportType = .resolume
        showDurationModal = true
    }

    private func confirmDurationImport() {
        let min = Double(durationMinutes) ?? 0
        let sec = Double(durationSeconds) ?? 0
        let ms = Double(durationMs) ?? 0
        let totalSeconds = min * 60 + sec + ms / 1000.0

        if pendingImportType == .resolume, let url = pendingResolumeURL {
            do {
                try state.loadResolumeEnvelope(from: url, duration: totalSeconds)
            } catch {
                errorMessage = "Failed to parse Resolume envelope: \(error.localizedDescription)"
                showError = true
            }
        } else if pendingImportType == .showkontrol {
            state.trackDuration = AppState.safeDuration(totalSeconds)
        }

        showDurationModal = false
        pendingImportType = nil
        pendingResolumeURL = nil
    }

    private func openProject() {
        let cueprojType = UTType(filenameExtension: "cueproj") ?? .json
        guard let url = FileDialogs.openFile(title: "Open Project", types: [cueprojType, .json]) else { return }
        do {
            try state.loadProject(from: url)
        } catch {
            errorMessage = "Failed to open project: \(error.localizedDescription)"
            showError = true
        }
    }

    private func saveProject() {
        if let url = state.projectFileURL {
            do { try state.saveProject(to: url) } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
                showError = true
            }
        } else {
            let name = state.projectName.isEmpty ? "Untitled" : state.projectName
            let cueprojType = UTType(filenameExtension: "cueproj") ?? .json
            guard let url = FileDialogs.saveFile(title: "Save Project", suggestedName: "\(name).cueproj", type: cueprojType) else { return }
            do { try state.saveProject(to: url) } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
                showError = true
            }
        }
    }
}

// MARK: - Flow Layout (wrapping horizontal layout)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        // Use full proposed width so content left-aligns (not centered)
        let finalWidth = maxWidth.isFinite ? maxWidth : totalWidth
        return (CGSize(width: finalWidth, height: currentY + rowHeight), offsets)
    }
}

// MARK: - Subviews

private struct SectionLabel: View {
    let text: String
    @Environment(AppState.self) private var state

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(state.colors.textMuted)
    }
}

private struct ActionButton<Icon: View>: View {
    let label: String
    let colors: ThemeColors
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var isHovered = false

    init(_ label: String, colors: ThemeColors, action: @escaping () -> Void, @ViewBuilder icon: @escaping () -> Icon) {
        self.label = label
        self.colors = colors
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon()
                Text(label).font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .fixedSize()
            .foregroundStyle(colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(height: 36)
            .background(isHovered ? colors.buttonHoverBg : colors.buttonBg)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isHovered ? colors.buttonHoverBorder : colors.buttonBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

private struct ImportButton<Icon: View>: View {
    let label: String
    let accentColor: Color
    let textColor: Color
    let hoverTextColor: Color
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var isHovered = false

    init(_ label: String, bg: Color, fg: Color = .white, hoverFg: Color = .white, action: @escaping () -> Void, @ViewBuilder icon: @escaping () -> Icon) {
        self.label = label
        self.accentColor = bg
        self.textColor = fg
        self.hoverTextColor = hoverFg
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon()
                    .scaleEffect(isHovered ? 1.3 : 1.0)
                Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isHovered ? hoverTextColor : textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(height: 36)
            .background(isHovered ? accentColor : accentColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(accentColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }
}

private struct ViewportButton: View {
    let label: String
    let colors: ThemeColors
    var isActive: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isActive || isHovered ? .black : colors.accentGreen)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(isActive || isHovered ? colors.accentGreen : colors.accentGreen.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(colors.accentGreen, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

private struct ThemeButton: View {
    let label: String
    let isActive: Bool
    let colors: ThemeColors
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isActive || isHovered ? .black : colors.accentGreen)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(isActive || isHovered ? colors.accentGreen : colors.accentGreen.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(colors.accentGreen, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

/// ShowKontrol button with custom hover: icon turns white and spins 180°
private struct ShowKontrolImportButton: View {
    let colors: ThemeColors
    let action: () -> Void
    @State private var isHovered = false
    @State private var spinAngle: Double = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ShowKontrolIcon(size: 16, color: .white, useWhite: isHovered)
                    .rotationEffect(.degrees(spinAngle))
                Text("ShowKontrol")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isHovered ? .white : colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(height: 36)
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
