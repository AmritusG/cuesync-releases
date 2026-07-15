import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Platform-neutral file-picker API. Takes plain extension strings (no `UTType`) so
/// this compiles without `UniformTypeIdentifiers` on Windows. On macOS this wraps
/// `NSOpenPanel`/`NSSavePanel`; the swift-cross-ui backend wiring for other
/// platforms is the UI re-host ticket, so elsewhere these return `nil`.
enum FileDialogs {
    #if canImport(AppKit)
    @MainActor
    #endif
    static func openFile(title: String, extensions: [String]) -> URL? {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if !extensions.isEmpty { panel.allowedFileTypes = extensions }
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    @MainActor
    #endif
    static func saveFile(title: String, suggestedName: String, extension ext: String) -> URL? {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.allowedFileTypes = [ext]
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return nil
        #endif
    }
}
