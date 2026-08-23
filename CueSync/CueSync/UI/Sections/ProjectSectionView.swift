#if CUESYNC_CROSSUI
import SwiftCrossUI
import Foundation
import CueSyncCore

// Re-host of Views/Sections/ProjectSectionView.swift onto swift-cross-ui (spec
// CUESYNC-7 §E). Import/open/save actions delegate to the re-hosted `AppState`
// (`UI/State/AppState.swift`) exactly like macOS.
//
// PORT: the SwiftUI `Layout`/`FlowLayout` macOS uses to wrap the button row on
// narrow windows has no swift-cross-ui equivalent (§0 table), so row 1 below is
// a fixed, non-wrapping `HStack` (spec §E.10).
// PORT: `PresentSingleFileOpenDialogAction` (`@Environment(\.chooseFile)`) is
// single-file-only at 0.8.0 — verified against the pinned checkout, there is no
// multi-select `FileOpenDialogs` action. The macOS Serato import uses a
// multi-select `NSOpenPanel`; here it imports one audio file per pick instead of
// many at once (spec §E.11 asks for "the multi-select variant of chooseFile",
// which does not exist to use).
// PORT: `chooseFile`/`chooseFileSaveDestination` don't expose a content-type/
// extension filter to callers at 0.8.0 (`FileDialogOptions.allowedContentTypes`
// is always `[]` from these actions) — the dialog shows all files, unfiltered by
// extension, unlike the macOS `UTType`-filtered panels.
// PORT: swift-cross-ui's `.alert` has no `message:` body (SwiftUI-only) — the
// error text is the alert's title instead. `AlertAction` has no `role:`, so
// "Discard" isn't visually distinguished from "Cancel" in the unsaved-changes
// alert (spec §E.12).
struct ProjectSectionView: View {
    @Environment(AppState.self) private var state
    @Environment(\.chooseFile) private var chooseFile
    @Environment(\.chooseFileSaveDestination) private var chooseFileSaveDestination

    @State private var showDurationModal = false
    @State private var pendingImportType: ImportType?
    @State private var pendingResolumeURL: URL?
    @State private var durationMinutes = "01"
    @State private var durationSeconds = "00"
    @State private var durationMs = "000"
    @State private var errorMessage: String?

    enum ImportType { case showkontrol, resolume }

    var body: some View {
        let colors = state.colors

        VStack(alignment: .leading, spacing: 12) {
            // Row 1: Project + Name + Create + Import Envelope + Import Cues (no wrap, see PORT note above)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Project", colors: colors)
                    HStack(spacing: 8) {
                        ActionButton(label: "New", glyph: "+", colors: colors) {
                            state.confirmNewProject()
                        }
                        ActionButton(label: "Open", glyph: "\u{25B8}", colors: colors) {
                            state.confirmAction { openProject() }
                        }
                        ActionButton(label: "Save", glyph: "\u{2193}", colors: colors) {
                            saveProject()
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Project Name", colors: colors)
                    TextField("Project Name", text: state.$projectName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(colors.textPrimary)
                        .padding(8)
                        .background(colors.inputBg)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(colors.inputBorder, style: StrokeStyle(width: 1))
                        }
                        .cornerRadius(5)
                        .frame(width: 155, height: 36)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Design from Scratch", colors: colors)
                    BrandButton(
                        "Create Envelope", glyph: "\u{2726}",
                        accent: colors.accentGold, fg: colors.textPrimary, hoverFg: .black
                    ) {
                        state.createBlankEnvelope()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Import Envelope", colors: colors)
                    BrandButton(
                        "Resolume", glyph: "\u{25B2}",
                        accent: colors.accentTeal, fg: colors.textPrimary,
                        hoverFg: Color(red: 0.1, green: 0.23, blue: 0.21)
                    ) {
                        importResolume()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Import Cues", colors: colors)
                    HStack(spacing: 8) {
                        BrandButton(
                            "Rekordbox", glyph: "\u{25CF}",
                            accent: colors.isDark ? Color.white.opacity(0.5) : Color.black.opacity(0.5),
                            fg: colors.textPrimary, hoverFg: .white
                        ) {
                            importRekordbox()
                        }
                        BrandButton(
                            "Serato", glyph: "\u{25C6}",
                            accent: colors.accentBlue, fg: colors.textPrimary, hoverFg: .white
                        ) {
                            importSerato()
                        }
                        BrandButton(
                            "Engine DJ", glyph: "\u{25A0}",
                            accent: colors.accentMint, fg: colors.textPrimary, hoverFg: .black
                        ) {
                            importEngineDJ()
                        }
                        BrandButton(
                            "ShowKontrol", glyph: "\u{25B8}",
                            accent: colors.accentPink, fg: colors.textPrimary, hoverFg: .white
                        ) {
                            importShowKontrol()
                        }
                    }
                }
            }

            // Row 2: Viewport + Theme + Import Settings
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Viewport", colors: colors)
                    HStack(spacing: 6) {
                        ToggleButton(label: "Reset", isActive: !state.sideBySideMode, colors: colors) {
                            state.resetLayout()
                        }
                        ToggleButton(label: "Side-By-Side", isActive: state.sideBySideMode, colors: colors) {
                            state.sideBySideMode.toggle()
                            state.savePreferences()
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Theme", colors: colors)
                    HStack(spacing: 6) {
                        ToggleButton(label: "Dark", isActive: state.theme == .dark, colors: colors) {
                            state.theme = .dark
                            state.savePreferences()
                        }
                        ToggleButton(label: "Light", isActive: state.theme == .light, colors: colors) {
                            state.theme = .light
                            state.savePreferences()
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Import Settings", colors: colors)
                    HStack(spacing: 8) {
                        ToggleButton(label: "True", isActive: state.forceYZeroOnImport, colors: colors) {
                            state.forceYZeroOnImport = true
                            state.savePreferences()
                        }
                        ToggleButton(label: "False", isActive: !state.forceYZeroOnImport, colors: colors) {
                            state.forceYZeroOnImport = false
                            state.savePreferences()
                        }
                        Text("Click here to set Y=0 at importing Cue Points")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(colors.textMuted)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                }
            }

            if !state.tracks.isEmpty {
                HStack(spacing: 4) {
                    Text("\u{2713}")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(colors.accentGreen)
                    Text("\(state.tracks.count) tracks loaded")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(colors.accentGreen)
                }
            }
        }
        .alert($errorMessage) {
            Button("OK") {}
        }
        .alert("Unsaved Changes", isPresented: state.$showUnsavedAlert) {
            Button("Discard") { state.executePendingAction() }
            Button("Cancel") { state.pendingAction = nil }
        }
        .sheet(isPresented: $showDurationModal) {
            DurationInputModal(
                minutes: $durationMinutes,
                seconds: $durationSeconds,
                milliseconds: $durationMs,
                onCancel: { showDurationModal = false },
                onConfirm: { confirmDurationImport() }
            )
        }
    }

    // MARK: - Import Actions

    private func importRekordbox() {
        Task {
            guard let url = await chooseFile(title: "Import Rekordbox XML") else { return }
            do {
                try state.loadRekordbox(from: url)
            } catch {
                errorMessage = "Failed to parse Rekordbox XML: \(error.localizedDescription)"
            }
        }
    }

    private func importSerato() {
        Task {
            guard let url = await chooseFile(title: "Import Serato Audio File") else { return }
            state.loadSerato(from: [url])
            if state.tracks.isEmpty {
                errorMessage = "No Serato cue points found in the selected file."
            }
        }
    }

    private func importEngineDJ() {
        Task {
            guard let url = await chooseFile(title: "Import Engine DJ Database") else { return }
            do {
                try state.loadEngineDJ(from: url)
            } catch {
                errorMessage = "Failed to parse Engine DJ database: \(error.localizedDescription)"
            }
        }
    }

    private func importShowKontrol() {
        Task {
            guard let url = await chooseFile(title: "Import ShowKontrol Cue") else { return }
            do {
                let durationAutoDetected = try state.loadShowKontrol(from: url)
                if !durationAutoDetected {
                    // No timing data in cues — ask user for duration
                    pendingImportType = .showkontrol
                    showDurationModal = true
                }
            } catch {
                errorMessage = "Failed to parse ShowKontrol file: \(error.localizedDescription)"
            }
        }
    }

    private func importResolume() {
        Task {
            guard let url = await chooseFile(title: "Import Resolume Envelope") else { return }
            pendingResolumeURL = url
            pendingImportType = .resolume
            showDurationModal = true
        }
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
            }
        } else if pendingImportType == .showkontrol {
            state.trackDuration = AppState.safeDuration(totalSeconds)
        }

        showDurationModal = false
        pendingImportType = nil
        pendingResolumeURL = nil
    }

    private func openProject() {
        Task {
            guard let url = await chooseFile(title: "Open Project") else { return }
            do {
                try state.loadProject(from: url)
            } catch {
                errorMessage = "Failed to open project: \(error.localizedDescription)"
            }
        }
    }

    private func saveProject() {
        if let url = state.projectFileURL {
            do {
                try state.saveProject(to: url)
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        } else {
            Task {
                let name = TextTools.slugify(state.projectName, fallback: "untitled")
                guard let url = await chooseFileSaveDestination(
                    title: "Save Project",
                    defaultFileName: "\(name).cueproj"
                ) else { return }
                do {
                    try state.saveProject(to: url)
                } catch {
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Subviews

private struct SectionLabel: View {
    let text: String
    let colors: ThemeColors

    init(_ text: String, colors: ThemeColors) {
        self.text = text
        self.colors = colors
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            // Column captions are single-line headings; without this a squeezed
            // width proposal hyphen-wraps them into nonsense ("IM-PO-RT EN…").
            // They are short, so holding their ideal width costs little.
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(colors.textMuted)
    }
}
#endif
