import SwiftUI

@main
struct CueSyncApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 1200, minHeight: 700)
                .onAppear {
                    appState.loadPreferences()
                }
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { appState.confirmNewProject() }
                    .keyboardShortcut("n")
                Button("Open Project...") { openProject() }
                    .keyboardShortcut("o")
                Button("Save Project") { saveProject() }
                    .keyboardShortcut("s")
                Button("Save Project As...") { saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export Resolume XML...") { exportXML() }
                    .keyboardShortcut("e")
                Button("Export ShowKontrol .cue...") { exportShowKontrol() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { appState.undo() }
                    .keyboardShortcut("z")
                Button("Redo") { appState.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Envelope") {
                Button("Add Cue Point") {
                    appState.addCuePoint(at: appState.trackDuration / 2)
                }
                .keyboardShortcut("d")
                Button("Delete Selected Point") {
                    appState.removeSelectedPoint()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!appState.canRemoveSelectedPoint)
            }
        }
    }

    private func openProject() {
        guard let url = FileDialogs.openFile(
            title: "Open Project",
            types: [FileDialogs.cueprojType]
        ) else { return }
        do {
            try appState.loadProject(from: url)
        } catch {
            showError("Failed to open project: \(error.localizedDescription)")
        }
    }

    private func saveProject() {
        if let url = appState.projectFileURL {
            do { try appState.saveProject(to: url) }
            catch { showError("Failed to save: \(error.localizedDescription)") }
        } else {
            saveProjectAs()
        }
    }

    private func saveProjectAs() {
        let name = appState.projectName.isEmpty ? "Untitled" : appState.projectName
        guard let url = FileDialogs.saveFile(
            title: "Save Project",
            suggestedName: "\(name).cueproj",
            type: FileDialogs.cueprojType
        ) else { return }
        do { try appState.saveProject(to: url) }
        catch { showError("Failed to save: \(error.localizedDescription)") }
    }

    private func exportXML() {
        let xml = appState.xmlPreview
        guard !xml.isEmpty else {
            showError("No envelope data to export. Add cue points first.")
            return
        }
        let name = appState.presetName.isEmpty ? "envelope" : appState.presetName
        guard let url = FileDialogs.saveFile(
            title: "Export Resolume XML",
            suggestedName: "\(name).xml",
            type: FileDialogs.xmlType
        ) else { return }
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError("Failed to export: \(error.localizedDescription)")
        }
    }

    private func exportShowKontrol() {
        guard let cueData = ShowKontrolExporter.generate(cuePoints: appState.cuePoints) else {
            showError("No cue points to export.")
            return
        }
        let name = appState.presetName.isEmpty ? "cues" : appState.presetName
        guard let url = FileDialogs.saveFile(
            title: "Export ShowKontrol Cue",
            suggestedName: "\(name).cue",
            type: FileDialogs.cueType
        ) else { return }
        do {
            try cueData.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError("Failed to export: \(error.localizedDescription)")
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
