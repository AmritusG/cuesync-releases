#if CUESYNC_CROSSUI
import Foundation
import SwiftCrossUI
import GtkBackend

// Platform C library, for the ISO-C stdio redirect in `captureStartupDiagnostics()`
// below. On Windows `WinSDK` re-exports ucrt, which vends `stderr`/`freopen`/`setvbuf`
// (proven to compile on the Windows CI runner by swift-cross-ui's own
// `WinUIBackend/Console.swift`); `Darwin` vends the identical ISO-C symbols on macOS,
// so the redirect below type-checks here even though it only runs on Windows.
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(WinSDK)
    import WinSDK
#endif

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

    // CUESYNC-9 round 5 — capture the one datum that has been missing for four rounds.
    //
    // The Windows executable links /SUBSYSTEM:WINDOWS (Package.swift) so it opens no
    // console and its C `stderr` is discarded. GTK, GLib, Pango and GSK print all of
    // their diagnostics there — font-load failures, GL/renderer errors, layout-measure
    // criticals — so on the clean-PC probe box (which renders an empty, size-collapsed
    // window with dead input) none of the evidence that would tell rounds 1-4's three
    // rival suspects apart (main-loop starvation vs. a font/renderer runtime failure vs.
    // the exe never loading) ever survived to be read. Every prior round therefore had
    // to guess from source alone and shipped a fix it could neither confirm nor refute
    // — each produced a byte-identical probe. This redirects `stderr` to a log file next
    // to the executable the instant the process reaches Swift (`App.main()` runs this
    // `init()` before `_app.run()` starts GtkBackend's GLib main loop), so the box
    // retains that log. See specs/CUESYNC-9-findings.md §0.4 for the decision tree that
    // reads it. Windows-only: the shipping macOS app is App/CueSyncApp.swift (AppKit),
    // which never compiles this file (excluded in Package.swift).
    init() {
        #if os(Windows)
            Self.captureStartupDiagnostics()
        #endif
    }

    /// Redirects the process's C `stderr` to `CueSync-startup.log` next to the
    /// executable so GTK/GLib/Pango/GSK diagnostics are retained on a clean Windows
    /// box that runs the /SUBSYSTEM:WINDOWS (console-less) build.
    ///
    /// Best-effort and non-fatal: a null `freopen` result is ignored, because a
    /// missing log must never keep the app from starting. Uses only ISO-C
    /// `freopen`/`setvbuf`/`fputs` plus Foundation `URL`, so the exact shipped call is
    /// type-checked on macOS (`Darwin`) even though it is only invoked on Windows.
    private static func captureStartupDiagnostics() {
        let logPath = startupLogPath()
        logPath.withCString { cPath in
            _ = freopen(cPath, "w", stderr)
        }
        // Unbuffered: the failure under investigation is a hang / non-graceful exit,
        // which would otherwise lose a full stdio buffer's worth of the very
        // diagnostics we need. Pay a per-line write to guarantee nothing is lost.
        setvbuf(stderr, nil, _IONBF, 0)

        let banner = """
            === CUE SYNC — Windows startup diagnostics (CUESYNC-9) ===
            argv: \(CommandLine.arguments.joined(separator: " "))
            log: \(logPath)
            Reaching this line proves CueSync.exe itself launched (not the probe's \
            cmd.exe launcher). GSK_RENDERER is forced to 'cairo' by patch. GTK/GLib/\
            Pango/GSK output — if any — follows below; a clean run to a visible window \
            with these silent points at main-loop starvation, Pango/font lines at a \
            font-config failure, and GSK/GL lines at a renderer failure.
            ==========================================================

            """
        banner.withCString { _ = fputs($0, stderr) }
        fflush(stderr)
    }

    /// `CueSync-startup.log` next to the executable, falling back to the current
    /// working directory when argv[0] carries no directory component.
    private static func startupLogPath() -> String {
        let fileName = "CueSync-startup.log"
        if let arg0 = CommandLine.arguments.first, !arg0.isEmpty {
            let directory = URL(fileURLWithPath: arg0).deletingLastPathComponent()
            if !directory.path.isEmpty {
                return directory.appendingPathComponent(fileName).path
            }
        }
        return fileName
    }

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
