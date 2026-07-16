#if CUESYNC_CROSSUI
import SwiftCrossUI
import DefaultBackend

// swift-cross-ui entry point. Mirrors App/CueSyncApp.swift's window title and
// sizing exactly (spec CUESYNC-5 §B.10); the SwiftUI/AppKit app of the same
// name lives in App/ and is never compiled into this target (excluded in
// Package.swift), so the two never collide at build time.
@main
struct CueSyncApp: App {
    var body: some Scene {
        WindowGroup("CUE SYNC") {
            ContentView()
                .frame(minWidth: 1200, minHeight: 700)
        }
        .defaultSize(width: 1200, height: 800)
    }
}
#endif
