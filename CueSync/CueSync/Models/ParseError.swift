import Foundation

// Shim for the SwiftPM `CueSyncCore` target: `ParseError` normally lives in
// App/AppState.swift, but App/ depends on SwiftUI and isn't part of this
// target's sources. This file isn't referenced by the Xcode project, so the
// two definitions never collide in the legacy macOS build. Mirrors the same
// shim already used by Tests/main.swift.
enum ParseError: LocalizedError {
    case invalidFormat(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return msg
        case .noData: return "No data found in file"
        }
    }
}
