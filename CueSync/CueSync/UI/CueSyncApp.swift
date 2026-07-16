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
@main
struct CueSyncApp: App {
    typealias Backend = GtkBackend

    var body: some Scene {
        WindowGroup("CUE SYNC") {
            ContentView()
                .frame(minWidth: 1200, minHeight: 700)
        }
        .defaultSize(width: 1200, height: 800)
    }
}
#endif
