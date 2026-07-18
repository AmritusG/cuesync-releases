#if CUESYNC_CROSSUI
import SwiftCrossUI
import GtkBackend

// swift-cross-ui entry point. Mirrors App/CueSyncApp.swift's window title and
// sizing exactly (spec CUESYNC-5 §B.10); the SwiftUI/AppKit app of the same
// name lives in App/ and is never compiled into this target (excluded in
// Package.swift), so the two never collide at build time.
//
// Pinned explicitly to GtkBackend (spec CUESYNC-6 §0.1/§0.2/§B.10) rather than
// DefaultBackend, which resolves to WinUIBackend on Windows — an untested backend
// swap this ticket replaces with a demonstrated one. `typealias Backend` is
// redundant with the `extension App { typealias Backend = GtkBackend }` that
// GtkBackend itself provides (verified at the pinned revision), but is kept
// explicit rather than relying on that implicit default.
//
// Re-hosts App/CueSyncApp.swift's state creation, preference loading, and menu
// commands onto swift-cross-ui (spec CUESYNC-7 §K).
// PORT: Open/Save/Export are not on the menu — `PresentSingleFileOpenDialogAction`/
// `PresentFileSaveDialogAction` (§J.23) carry a `window` captured from a View's
// `@Environment`, so they're only callable from inside a View, not from a Scene's
// command closures. Those actions stay fully wired on the Project/Export section
// buttons (§E/§H); only the dialog-free actions (New/Undo/Redo) are on the menu.
// PORT: no keyboard-shortcut modifier exists in this swift-cross-ui checkout
// (verified: no such API in Sources/SwiftCrossUI) — menu items have no key-binding here.
@main
struct CueSyncApp: App {
    typealias Backend = GtkBackend

    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("CUE SYNC") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1200, minHeight: 700)
                .task { state.loadPreferences() }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandMenu("File") {
                Button("New Project") { state.confirmNewProject() }
            }
            CommandMenu("Edit") {
                Button("Undo") { state.undo() }
                Button("Redo") { state.redo() }
            }
        }
    }
}
#endif
