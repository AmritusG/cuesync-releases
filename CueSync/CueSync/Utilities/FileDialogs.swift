import AppKit
import UniformTypeIdentifiers

enum FileDialogs {
    static func openFile(title: String, types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveFile(title: String, suggestedName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }

    // Common file types
    static let xmlType = UTType.xml
    static let jsonType = UTType.json
    static let cueType = UTType(filenameExtension: "cue") ?? UTType.plainText
    static let cueprojType = UTType(filenameExtension: "cueproj") ?? UTType.json
}
