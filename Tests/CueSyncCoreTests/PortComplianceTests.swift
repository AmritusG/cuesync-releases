import Foundation
import XCTest
@testable import CueSyncCore

/// Structural checks tied directly to CUESYNC-3 (specs/CUESYNC-3.md §3) and CUESYNC-5
/// (specs/CUESYNC-5.md §3) acceptance criteria that aren't observable through the
/// parser/exporter/model API surface — they enforce build-manifest and source-guarding
/// requirements a full app launch or a CI matrix leg would otherwise be needed to catch.
/// Deterministic and network-free: every check reads files already checked into the
/// repo, located via `#filePath` (never a hardcoded absolute path) so it works unchanged
/// on windows-latest / macos-latest.
final class PortComplianceTests: XCTestCase {
    /// Tests/CueSyncCoreTests/PortComplianceTests.swift -> Tests/CueSyncCoreTests -> Tests -> repo root
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let packageSwiftURL = repoRoot.appendingPathComponent("Package.swift")
    private static let packageResolvedURL = repoRoot.appendingPathComponent("Package.resolved")
    private static let sourceRoot = repoRoot.appendingPathComponent("CueSync/CueSync")

    private func readPackageSwift() throws -> String {
        try String(contentsOf: Self.packageSwiftURL, encoding: .utf8)
    }

    // MARK: - A. SwiftPM package + cross-platform build skeleton (spec §2.A)

    func testPackageSwiftDeclaresVendoredCSQLiteTarget() throws {
        let manifest = try readPackageSwift()
        XCTAssertTrue(manifest.contains("CSQLite"),
                      "Package.swift must declare a vendored CSQLite C target (spec §2.A.2) so " +
                      "Engine DJ import works on Windows without a system SQLite prerequisite")
    }

    func testPackageSwiftDeclaresVendoredCZlibTarget() throws {
        let manifest = try readPackageSwift()
        XCTAssertTrue(manifest.contains("CZlib"),
                      "Package.swift must declare a vendored CZlib C target (spec §2.A.3) so " +
                      "Engine DJ quickCues decompression works on Windows without system zlib")
    }

    /// Tightened per CUESYNC-5 §D.15: the old version of this test passed on the strength
    /// of a code *comment* mentioning "swift-cross-ui", with no dependency actually
    /// declared — it could not tell a real pinned dependency from prose about one. This
    /// asserts on the manifest's structure instead: a `.package(` entry naming
    /// swift-cross-ui, pinned by `exact:`/`.exact(`/`revision:` and never `branch:` or an
    /// open-ended `from:` (spec §4 threat model — a moving pin means CUE SYNC ships
    /// whatever upstream pushed most recently).
    func testPackageSwiftPinsSwiftCrossUIToAnExactTagOrRevision() throws {
        let manifest = try readPackageSwift()
        guard let dependencyLine = manifest.components(separatedBy: "\n").first(where: {
            $0.contains(".package(") && $0.contains("swift-cross-ui")
        }) else {
            XCTFail("Package.swift must declare a .package(...) entry naming swift-cross-ui (spec §A.6)")
            return
        }
        XCTAssertTrue(
            dependencyLine.contains("exact:") || dependencyLine.contains(".exact(") ||
            dependencyLine.contains("revision:"),
            "swift-cross-ui must be pinned with exact:/.exact(/revision:, got: \(dependencyLine)"
        )
        XCTAssertFalse(dependencyLine.contains("branch:"),
                       "swift-cross-ui must never be pinned to a branch: \(dependencyLine)")
        XCTAssertFalse(dependencyLine.contains("from:"),
                       "swift-cross-ui must never use an open-ended from: range: \(dependencyLine)")
    }

    /// spec §A.7: the CueSync executable target must depend on a `.product(...)` sourced
    /// from the swift-cross-ui package — not just have the package listed in `dependencies:`.
    func testCueSyncTargetDependsOnASwiftCrossUIProduct() throws {
        let manifest = try readPackageSwift()
        guard let cueSyncBlock = targetBlock(named: "CueSync", in: manifest) else {
            XCTFail("could not locate the CueSync target block in Package.swift")
            return
        }
        XCTAssertTrue(
            cueSyncBlock.range(of: #"\.product\(\s*name:\s*"[^"]+",\s*package:\s*"swift-cross-ui"\s*\)"#,
                               options: .regularExpression) != nil,
            "the CueSync target must depend on at least one .product(..., package: \"swift-cross-ui\")"
        )
    }

    /// spec CUESYNC-6 §A.8/§E.21: the CueSync target must depend on the swift-cross-ui
    /// **GtkBackend** product specifically, and no longer on DefaultBackend. Asserts on the
    /// target block's structure (via `targetBlock`), not a substring of the whole manifest,
    /// so a comment elsewhere mentioning "DefaultBackend" (this spec's own rationale
    /// quotes it) can't accidentally satisfy or fail this — the CUESYNC-5 §D.15 lesson.
    func testCueSyncTargetDependsOnGtkBackendAndNotDefaultBackend() throws {
        let manifest = try readPackageSwift()
        guard let cueSyncBlock = targetBlock(named: "CueSync", in: manifest) else {
            XCTFail("could not locate the CueSync target block in Package.swift")
            return
        }
        XCTAssertTrue(
            cueSyncBlock.range(of: #"\.product\(\s*name:\s*"GtkBackend",\s*package:\s*"swift-cross-ui"\s*\)"#,
                               options: .regularExpression) != nil,
            "the CueSync target must depend on .product(name: \"GtkBackend\", package: \"swift-cross-ui\") (spec CUESYNC-6 §A.8)"
        )
        XCTAssertTrue(
            cueSyncBlock.range(of: #"\.product\(\s*name:\s*"DefaultBackend",\s*package:\s*"swift-cross-ui"\s*\)"#,
                               options: .regularExpression) == nil,
            "the CueSync target must no longer depend on DefaultBackend (spec CUESYNC-6 §A.8)"
        )
    }

    /// spec acceptance criteria (§3, Manifest): `CUESYNC_CROSSUI` is defined in
    /// `swiftSettings` for the `CueSync` target only — `CueSyncCore` stays UI-free and
    /// gains no new dependency (spec §A, flag semantics table).
    func testPackageSwiftDefinesCUESYNCCROSSUIOnlyForTheCueSyncTarget() throws {
        let manifest = try readPackageSwift()
        guard let cueSyncBlock = targetBlock(named: "CueSync", in: manifest) else {
            XCTFail("could not locate the CueSync target block in Package.swift")
            return
        }
        XCTAssertTrue(cueSyncBlock.contains(#".define("CUESYNC_CROSSUI")"#),
                      "the CueSync target must define CUESYNC_CROSSUI in swiftSettings")

        guard let coreBlock = targetBlock(named: "CueSyncCore", in: manifest) else {
            XCTFail("could not locate the CueSyncCore target block in Package.swift")
            return
        }
        XCTAssertFalse(coreBlock.contains("CUESYNC_CROSSUI"),
                       "CueSyncCore must never define CUESYNC_CROSSUI — it stays UI-free")
        XCTAssertFalse(coreBlock.contains("swift-cross-ui"),
                       "CueSyncCore must gain no dependency on swift-cross-ui")
    }

    /// spec §A.8 / §3 Manifest: once a real dependency exists, `Package.resolved` is the
    /// record of exactly which commit was audited — it must be committed and must pin
    /// swift-cross-ui to a concrete (not symbolic) revision.
    func testPackageResolvedExistsAndPinsSwiftCrossUIToAFullRevisionSHA() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.packageResolvedURL.path),
                      "Package.resolved must be committed now that swift-cross-ui is a dependency")
        let data = try Data(contentsOf: Self.packageResolvedURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pins = (json?["pins"] as? [[String: Any]])
            ?? ((json?["object"] as? [String: Any])?["pins"] as? [[String: Any]])
            ?? []
        let swiftCrossUIPin = pins.first {
            let identity = ($0["identity"] as? String) ?? ($0["package"] as? String) ?? ""
            return identity.localizedCaseInsensitiveContains("swift-cross-ui")
        }
        guard let pin = swiftCrossUIPin, let state = pin["state"] as? [String: Any],
              let revision = state["revision"] as? String else {
            XCTFail("Package.resolved must contain a swift-cross-ui pin with a resolved revision")
            return
        }
        XCTAssertEqual(revision.count, 40, "swift-cross-ui revision must be a full 40-char SHA, got \(revision)")
        XCTAssertTrue(revision.allSatisfy(\.isHexDigit), "swift-cross-ui revision must be hex: \(revision)")
    }

    // MARK: - A2. Windows GUI subsystem linker flags (spec CUESYNC-7 §A) — no coverage existed yet

    /// spec CUESYNC-7 §3: "Package.swift carries /SUBSYSTEM:WINDOWS + /ENTRY:mainCRTStartup
    /// on the CueSync executable target ... and no other manifest change." Scoped to the
    /// CueSync target block (not a whole-manifest substring search) so a comment elsewhere
    /// mentioning the flags can't satisfy this by accident — same pattern as the existing
    /// GtkBackend/DefaultBackend check above.
    func testCueSyncTargetLinksWindowsGUISubsystemAndCRTEntryPointScopedToWindows() throws {
        let manifest = try readPackageSwift()
        guard let cueSyncBlock = targetBlock(named: "CueSync", in: manifest) else {
            XCTFail("could not locate the CueSync target block in Package.swift")
            return
        }
        let collapsed = cueSyncBlock.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        XCTAssertTrue(
            collapsed.contains(#"["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]"#),
            "CueSync executable target must link /SUBSYSTEM:WINDOWS (suppresses the console window) and " +
            "/ENTRY:mainCRTStartup (keeps Swift's C-runtime entry point) — spec §A.1"
        )
        XCTAssertTrue(
            collapsed.contains(
                #"["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"], .when(platforms: [.windows])"#
            ),
            "the Windows GUI-subsystem linker flags must be scoped via .when(platforms: [.windows]) so the " +
            "MSVC-specific /SUBSYSTEM//ENTRY syntax never reaches the macOS/Linux linker (spec §A.1)"
        )
    }

    /// spec §3: "no other manifest change (no pin, exclude, or CueSyncCore edit)." Pins the
    /// exact CueSyncCore/CueSync `exclude:`/`sources:` arrays this ticket must leave
    /// untouched, so an accidental widening of either target's source footprint — e.g. a
    /// stray edit that lets CueSyncCore start compiling `UI/`, or lists new files
    /// individually instead of relying on the `UI` directory glob (spec §2: "no
    /// Package.swift file listing is needed for new UI files") — fails loudly instead of
    /// silently changing what each SwiftPM target builds.
    func testTargetExcludeAndSourceListsAreUnchangedByThisTicket() throws {
        let manifest = try readPackageSwift()
        guard let coreBlock = targetBlock(named: "CueSyncCore", in: manifest) else {
            XCTFail("could not locate the CueSyncCore target block in Package.swift")
            return
        }
        XCTAssertTrue(coreBlock.contains(#"exclude: ["App", "Views", "Theme", "Utilities", "Resources", "UI"]"#),
                      "CueSyncCore's exclude list must stay exactly as it was before CUESYNC-7 (spec §3)")
        XCTAssertTrue(coreBlock.contains(#"sources: ["Models", "Parsers", "Exporters", "Support"]"#),
                      "CueSyncCore's sources list must stay exactly as it was before CUESYNC-7 (spec §3)")

        guard let cueSyncBlock = targetBlock(named: "CueSync", in: manifest) else {
            XCTFail("could not locate the CueSync target block in Package.swift")
            return
        }
        XCTAssertTrue(cueSyncBlock.contains(
            #"exclude: ["App", "Views", "Theme", "Utilities", "Resources", "Models", "Parsers", "Exporters", "Support"]"#),
                      "CueSync's exclude list must stay exactly as it was before CUESYNC-7 (spec §3)")
        XCTAssertTrue(cueSyncBlock.contains(#"sources: ["UI"]"#),
                      "CueSync's sources list must stay exactly [\"UI\"] — every new screen lives under UI/ and " +
                      "is picked up by the existing directory glob, no per-file Package.swift listing (spec §2)")
    }

    /// spec §3: "no other manifest change (no pin ...)" — the swift-cross-ui pin must stay
    /// exactly 0.8.0, not bumped as an incidental side effect of this ticket's edits.
    func testSwiftCrossUIPinIsStillExactlyVersion0_8_0() throws {
        let manifest = try readPackageSwift()
        XCTAssertTrue(manifest.contains(#".package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.8.0")"#),
                      "swift-cross-ui must stay pinned to exact: \"0.8.0\" — CUESYNC-7 §3 forbids a pin change")
    }

    // MARK: - B. Cross-platform logic layer: the 2 Apple-only APIs must be #if-guarded (spec §2.B)

    func testEngineDJParserGuardsSQLite3Import() throws {
        let path = Self.sourceRoot.appendingPathComponent("Parsers/EngineDJParser.swift")
        let src = try String(contentsOf: path, encoding: .utf8)
        assertImportIsGuarded(src, module: "SQLite3", file: "Parsers/EngineDJParser.swift")
    }

    func testEngineDJParserGuardsCompressionImport() throws {
        let path = Self.sourceRoot.appendingPathComponent("Parsers/EngineDJParser.swift")
        let src = try String(contentsOf: path, encoding: .utf8)
        assertImportIsGuarded(src, module: "Compression", file: "Parsers/EngineDJParser.swift")
    }

    /// No file compiled into the cross-platform `CueSyncCore`/`CueSync` SwiftPM targets may
    /// import AppKit/AVFoundation/Compression/UniformTypeIdentifiers unguarded — that would
    /// fail to link on Windows. This is the closest unit-testable proxy for the acceptance
    /// criterion's `grep`/`nm` link check (spec §3: "links no AppKit/AVFoundation/Compression
    /// symbols"), run against every source file that actually ships in those targets today.
    func testNoSwiftPMSourceFileHasAnUnguardedAppleOnlyImport() throws {
        // SwiftUI (CUESYNC-5 §D.16): a stray `import SwiftUI` in UI/ would sail through
        // an otherwise-identical scan that omitted it, defeating the whole point of
        // keeping the swift-cross-ui shell buildable on Windows.
        let banned = ["AppKit", "AVFoundation", "Compression", "UniformTypeIdentifiers", "CoreGraphics", "SwiftUI"]
        // Directories currently wired into CueSyncCore/CueSync sources in Package.swift.
        // Support/ and UI/ are included pre-emptively: they must stay guarded as they grow.
        let dirs = ["Models", "Parsers", "Exporters", "Support", "UI"]
        var checked = 0
        for dir in dirs {
            let dirURL = Self.sourceRoot.appendingPathComponent(dir)
            guard let files = swiftFiles(under: dirURL) else { continue }
            for file in files {
                let src = try String(contentsOf: file, encoding: .utf8)
                checked += 1
                for module in banned {
                    assertImportIsGuarded(src, module: module,
                                          file: file.path.replacingOccurrences(of: Self.sourceRoot.path + "/", with: ""))
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "expected to scan at least the Models/Parsers/Exporters sources")
    }

    // MARK: - C. Platform-abstracted glue (spec §2.C) — Support/ layer

    func testSupportLayerFileDialogsExists() {
        assertSourceFileExists("Support/FileDialogs.swift",
                               "spec §2.C.10: platform-neutral FileDialogs API to replace NSOpenPanel/NSSavePanel")
    }

    func testSupportLayerPreferencesExists() {
        assertSourceFileExists("Support/Preferences.swift",
                               "spec §2.C.11: cross-platform Preferences abstraction over UserDefaults")
    }

    func testSupportLayerAudioDurationExists() {
        assertSourceFileExists("Support/AudioDuration.swift",
                               "spec §2.C.12: pure-Swift WAV/AIFF duration parsing to replace AVAudioFile")
    }

    func testSupportLayerHexExists() {
        assertSourceFileExists("Support/Hex.swift",
                               "spec §2.C.13: pure-Swift hex/CSS color parsing to replace NSColor.fromCSSString")
    }

    func testSupportLayerSQLiteExists() {
        assertSourceFileExists("Support/SQLite.swift",
                               "spec §2.C.9: shared SQLite glue (guarded import + SQLITE_TRANSIENT) for CueSyncCore")
    }

    func testSupportLayerZlibExists() {
        assertSourceFileExists("Support/Zlib.swift",
                               "spec §2.C.10: cross-platform raw-DEFLATE inflate used by EngineDJParser")
    }

    /// Spec §3: "Support/ contains exactly the six new files" — not five, not seven.
    /// A stray file left behind (or a rename that silently orphans an old name) would
    /// slip past the individual existence checks above.
    func testSupportDirectoryContainsExactlyTheSixSpecifiedFiles() throws {
        let expected: Set<String> = [
            "FileDialogs.swift", "Preferences.swift", "AudioDuration.swift",
            "Hex.swift", "SQLite.swift", "Zlib.swift",
        ]
        let dir = Self.sourceRoot.appendingPathComponent("Support")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let swiftFiles = Set(names.filter { $0.hasSuffix(".swift") })
        XCTAssertEqual(swiftFiles, expected,
                       "Support/ must contain exactly the six files the spec names (spec §3), got \(swiftFiles.sorted())")
    }

    // MARK: - D. swift-cross-ui app shell (spec §B, §D.18)

    /// spec §B.9/§3: `UI/main.swift` is top-level code, and Swift rejects `@main` in a
    /// module containing top-level code — it must be gone, replaced by the two files
    /// below, each still guarded so the SwiftPM-only presentation never leaks anywhere
    /// `CUESYNC_CROSSUI` isn't defined.
    func testUIMainSwiftIsDeletedAndCrossUIShellFilesExistGuarded() throws {
        let uiDir = Self.sourceRoot.appendingPathComponent("UI")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: uiDir.appendingPathComponent("main.swift").path),
            "UI/main.swift must be deleted (spec §B.9) — top-level code conflicts with @main"
        )
        for fileName in ["CueSyncApp.swift", "ContentView.swift"] {
            let url = uiDir.appendingPathComponent(fileName)
            guard let src = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("UI/\(fileName) does not exist (spec §B)")
                continue
            }
            let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(trimmed.hasPrefix("#if CUESYNC_CROSSUI"),
                          "UI/\(fileName) must open with #if CUESYNC_CROSSUI (spec §3 acceptance criteria)")
        }
    }

    /// spec §3 Source: "each fully wrapped in `#if CUESYNC_CROSSUI`" — stronger than just
    /// opening with the guard (the prefix check above): the file must also *close* with
    /// `#endif`, so no declaration in it can ever compile outside the flag. Uses
    /// `.whitespacesAndNewlines` (covers CR, LF, and CRLF alike) so this holds regardless
    /// of which line-ending convention a Windows checkout produces.
    func testUIShellFilesAreFullyWrappedEndToEndInCUESYNCCROSSUIGuard() throws {
        let uiDir = Self.sourceRoot.appendingPathComponent("UI")
        for fileName in ["CueSyncApp.swift", "ContentView.swift"] {
            let url = uiDir.appendingPathComponent(fileName)
            guard let src = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("UI/\(fileName) does not exist (spec §B)")
                continue
            }
            let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(trimmed.hasSuffix("#endif"),
                          "UI/\(fileName) must close with #endif so nothing in it compiles outside CUESYNC_CROSSUI")
        }
    }

    /// spec §3 Source: "`UI/` contains exactly `CueSyncApp.swift` and `ContentView.swift`" —
    /// this ticket is step 1 of an incremental re-host and explicitly forbids porting any
    /// screen yet (spec §B.11), so a stray extra file under `UI/` would itself be scope
    /// creep. Mirrors the existing `Support/` exact-file-count pattern.
    func testUIDirectoryContainsExactlyTheTwoShellFiles() throws {
        let expected: Set<String> = ["CueSyncApp.swift", "ContentView.swift"]
        let dir = Self.sourceRoot.appendingPathComponent("UI")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let swiftFiles = Set(names.filter { $0.hasSuffix(".swift") })
        XCTAssertEqual(swiftFiles, expected,
                       "UI/ must contain exactly the two shell files this ticket adds (spec §B), got \(swiftFiles.sorted())")
    }

    /// spec §3 Source: "No file under `UI/` imports AppKit, SwiftUI, CoreGraphics,
    /// UniformTypeIdentifiers, AVFoundation, or Compression — guarded or not." This is
    /// strictly stronger than `testNoSwiftPMSourceFileHasAnUnguardedAppleOnlyImport`, which
    /// only requires those imports to be *guarded* elsewhere in the tree — inside `UI/`
    /// even a `#if canImport(AppKit)`-guarded import is banned outright, because the
    /// swift-cross-ui shell must never gain an Apple-only code path at all. Normalizes
    /// CRLF to LF before scanning so a Windows checkout with `core.autocrlf` doesn't dodge
    /// the check by leaving a trailing `\r` on every line.
    func testNoFileUnderUIImportsBannedAppleFrameworksEvenIfGuarded() throws {
        // Combine added by CUESYNC-7 §B.3: not Apple-exclusive in principle, but unavailable
        // on the Windows Swift toolchain and explicitly called out as forbidden to carry
        // over from App/AppState.swift's `import Combine` when re-hosting onto
        // SwiftCrossUI.ObservableObject.
        let banned = ["AppKit", "SwiftUI", "CoreGraphics", "UniformTypeIdentifiers", "AVFoundation", "Compression", "Combine"]
        let uiDir = Self.sourceRoot.appendingPathComponent("UI")
        guard let files = swiftFiles(under: uiDir), !files.isEmpty else {
            XCTFail("expected to find .swift files under UI/")
            return
        }
        for file in files {
            let src = try String(contentsOf: file, encoding: .utf8)
            let lines = src.replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
            for module in banned {
                let hit = lines.contains { $0.trimmingCharacters(in: .whitespaces) == "import \(module)" }
                XCTAssertFalse(hit, "UI/\(file.lastPathComponent) must never import \(module), guarded or not (spec §3)")
            }
        }
    }

    /// spec §B.10/§3 Behavior: the swift-cross-ui window must mirror `App/CueSyncApp.swift`
    /// exactly — title **CUE SYNC**, default size **1200×800**, minimum **1200×700**. CI is
    /// headless and can't launch the window (spec §E.22), so this structural check on the
    /// literal source values is the closest automated proxy to that manual acceptance check.
    func testUICueSyncAppDeclaresTheSpecifiedWindowTitleAndSizing() throws {
        let url = Self.sourceRoot.appendingPathComponent("UI/CueSyncApp.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("\"CUE SYNC\""), "UI/CueSyncApp.swift must title the window exactly \"CUE SYNC\"")
        XCTAssertTrue(src.contains("width: 1200") && src.contains("height: 800"),
                      "UI/CueSyncApp.swift must set the default size to 1200x800 (spec §B.10)")
        XCTAssertTrue(src.contains("minWidth: 1200") && src.contains("minHeight: 700"),
                      "UI/CueSyncApp.swift must set the minimum size to 1200x700 (spec §B.10)")
    }

    /// spec §1/§B: this ticket is step 1 of an incremental re-host — "No CUE SYNC screen is
    /// ported in this ticket ... the menu commands are later tickets." A `.commands` scene
    /// modifier (the swift-cross-ui/SwiftUI equivalent of `App/CueSyncApp.swift`'s
    /// `CommandGroup`/`CommandMenu` block) would be exactly that kind of premature port.
    func testUICueSyncAppDeclaresNoMenuCommandsYet() throws {
        let url = Self.sourceRoot.appendingPathComponent("UI/CueSyncApp.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        for forbidden in [".commands", "CommandGroup", "CommandMenu"] {
            XCTAssertFalse(src.contains(forbidden),
                           "UI/CueSyncApp.swift must not declare menu commands yet (\(forbidden) found) — spec §1/§B")
        }
    }

    /// spec §3 Source: "No screen, section, collapsible wrapper, grid overlay, menu
    /// command, or envelope code ported. ContentView is empty by design." Scans for every
    /// concrete section/screen type name that exists in the SwiftUI presentation
    /// (`Views/Sections/*.swift`, `Views/CollapsibleSection.swift`, etc.) to catch a
    /// premature port of any of them into the swift-cross-ui shell.
    func testUIContentViewPortsNoScreenSectionOrChrome() throws {
        let forbidden = [
            "ProjectSectionView", "BrowseSectionView", "ConfigureSectionView", "ExportSectionView",
            "CollapsibleSection", "EnvelopeCanvasView", "CuePointsTableView", "DurationInputView",
            "DurationInputModal", "StepperField", "HeaderView", "FooterView", "HoverButton", "BrandIcons",
        ]
        let url = Self.sourceRoot.appendingPathComponent("UI/ContentView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        for name in forbidden {
            XCTAssertFalse(src.contains(name),
                           "UI/ContentView.swift must not reference \(name) yet — this ticket's ContentView is empty by design (spec §B.11)")
        }
    }

    /// spec CUESYNC-6 §B.10/§E.22: `UI/CueSyncApp.swift` must import GtkBackend and must
    /// not import DefaultBackend, still inside its `#if CUESYNC_CROSSUI` guard. Checks
    /// whole-line imports (not a substring match) so a comment mentioning "DefaultBackend"
    /// — this spec's own rationale for the swap quotes it — can't trip either assertion.
    func testUICueSyncAppImportsGtkBackendNotDefaultBackend() throws {
        let url = Self.sourceRoot.appendingPathComponent("UI/CueSyncApp.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasPrefix("#if CUESYNC_CROSSUI"),
                      "UI/CueSyncApp.swift must stay fully wrapped in #if CUESYNC_CROSSUI (spec §3)")
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains("import GtkBackend"),
                      "UI/CueSyncApp.swift must import GtkBackend (spec CUESYNC-6 §B.10)")
        XCTAssertFalse(lines.contains("import DefaultBackend"),
                       "UI/CueSyncApp.swift must no longer import DefaultBackend (spec CUESYNC-6 §B.10)")
    }

    /// spec CUESYNC-6 §B.11/§E.23: `UI/ContentView.swift` is explicitly left byte-for-byte
    /// alone by this ticket — it still declares the empty placeholder `View` and imports no
    /// backend module (only `SwiftCrossUI`, which is backend-agnostic).
    func testUIContentViewUnmodifiedAndImportsNoBackendModule() throws {
        let url = Self.sourceRoot.appendingPathComponent("UI/ContentView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("struct ContentView: View"),
                      "UI/ContentView.swift must still declare struct ContentView: View (spec CUESYNC-6 §B.11)")
        XCTAssertTrue(src.contains(#"Text("CUE SYNC")"#),
                      "UI/ContentView.swift must still hold only the placeholder body (spec CUESYNC-6 §B.11)")
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for backend in ["GtkBackend", "DefaultBackend", "WinUIBackend", "AppKitBackend", "Gtk3Backend"] {
            XCTAssertFalse(lines.contains("import \(backend)"),
                           "UI/ContentView.swift must import no backend module, found import \(backend) (spec CUESYNC-6 §B.11)")
        }
    }

    /// spec CUESYNC-6 §B.13 froze CueSyncCore at fully-internal because CUESYNC-6 didn't
    /// yet need to consume it from `UI/` — its own rationale said so explicitly: "widening
    /// the surface belongs to the ticket that consumes it." CUESYNC-7 *is* that ticket:
    /// `UI/State/AppState.swift` (spec §B.3) must call the shared parsers/exporters/models
    /// directly, which is impossible across the `CueSyncCore` / `CueSync` SwiftPM module
    /// boundary without `public` (internal, the default, is invisible outside its own
    /// target — unlike the Xcode build, where App/AppState.swift compiles alongside these
    /// files directly). So the blanket "no public" check is retired in favor of an
    /// allowlist of the *exact* trimmed lines this ticket intentionally exposes — anything
    /// public that isn't on the list still fails, so an accidental/unrelated widening is
    /// still caught. Scans with the same word-boundary regex as before (not a plain
    /// substring check) so an identifier merely containing "public" can't produce a hit.
    func testCueSyncCorePublicSurfaceMatchesTheDocumentedAllowlist() throws {
        let allowedByFile: [String: Set<String>] = [
            "CuePoint.swift": [
                "public struct CuePoint: Identifiable, Codable, Equatable {",
                "public var id: String",
                "public var start: Double          // Time position in seconds",
                "public var name: String",
                "public var color: String          // CSS color string e.g. \"rgb(255, 0, 0)\" or \"#ff0000\"",
                "public var yValue: Double         // 0-100",
                "public var curve: Int             // 1-23",
                "public var enabled: Bool",
                "public init(id: String, start: Double, name: String, color: String, yValue: Double, curve: Int, enabled: Bool) {",
                "public func normalizedX(duration: Double) -> Double {",
                "public var normalizedY: Double {",
                "public func sanitized() -> CuePoint {",
            ],
            "ParseError.swift": [
                "public enum ParseError: LocalizedError {",
                "public var errorDescription: String? {",
            ],
            "Playlist.swift": [
                "public struct Playlist: Identifiable, Codable, Equatable {",
                "public var id: String",
                "public var name: String",
                "public var type: PlaylistType",
                "public var trackIds: [String]",
                "public var children: [Playlist]",
                "public enum PlaylistType: String, Codable {",
                "public var isFolder: Bool { type == .folder }",
                "public func totalTrackCount() -> Int {",
            ],
            "Project.swift": [
                "public struct Project: Codable {",
                "public var version: String = \"3.0\"",
                "public var name: String = \"Untitled Project\"",
                "public var savedAt: String?",
                "public var tracks: [Track] = []",
                "public var playlists: [Playlist] = []",
                "public var selectedTrackId: String?",
                "public var cuePoints: [CuePoint] = []",
                "public var trackDuration: Double = 60.0",
                "public var presetName: String = \"New Envelope\"",
                "public init(",
                "public init(from decoder: Decoder) throws {",
            ],
            "Track.swift": [
                "public struct Track: Identifiable, Codable, Equatable {",
                "public var id: String",
                "public var name: String",
                "public var artist: String",
                "public var album: String",
                "public var genre: String",
                "public var totalTime: Int             // Duration in seconds",
                "public var bpm: Double",
                "public var tonality: String",
                "public var location: String           // File path",
                "public var cuePoints: [CuePoint]",
                "public var formattedDuration: String {",
                "public var cueCount: Int { cuePoints.count }",
            ],
            "EngineDJParser.swift": [
                "public enum EngineDJParser {",
            ],
            "RekordboxParser.swift": [
                "public struct RekordboxResult {",
                "public let tracks: [Track]",
                "public let playlists: [Playlist]",
                "public enum RekordboxParser {",
            ],
            "ResolumeParser.swift": [
                "public struct ResolumePoint {",
                "public struct ResolumeParseResult {",
                "public let presetName: String",
                "public let points: [ResolumePoint]",
                "public enum ResolumeParser {",
            ],
            "SeratoParser.swift": [
                "public struct SeratoResult {",
                "public let tracks: [Track]",
                "public enum SeratoParser {",
            ],
            "ShowKontrolParser.swift": [
                "public struct ShowKontrolResult {",
                "public let cuePoints: [CuePoint]",
                "public let suggestedDurationMs: Double?",
                "public let durationFromCues: Bool  // true if duration was derived from cue timing data",
                "public enum ShowKontrolParser {",
            ],
            "ResolumeExporter.swift": [
                "public enum ResolumeExporter {",
            ],
            "ShowKontrolExporter.swift": [
                "public enum ShowKontrolExporter {",
            ],
            "Hex.swift": [
                "public enum Hex {",
            ],
        ]
        // Every allowlisted line above also carries its own `public static func`/`public
        // static var` sibling (e.g. `public static func parse(...)`) that this narrower
        // regex — deliberately unchanged from the original check — doesn't match, because
        // "static" sits between "public" and the keyword list. Those are exactly the entry
        // points spec §B.3 requires (`RekordboxParser.parse`, `CuePoint.makeDefault`,
        // `ResolumeParser.convertToCuePoints`, `ResolumeExporter.generate`,
        // `ShowKontrolExporter.generate`, `Hex.parseCSSColor`, `EngineDJParser.parse`, …).
        let dirs = ["Models", "Parsers", "Exporters", "Support"]
        let pattern = #"(^|[^A-Za-z0-9_])public\s+(class|struct|enum|protocol|func|var|let|init|extension|typealias)\b"#
        var checked = 0
        for dir in dirs {
            let dirURL = Self.sourceRoot.appendingPathComponent(dir)
            guard let files = swiftFiles(under: dirURL) else { continue }
            for file in files {
                let src = try String(contentsOf: file, encoding: .utf8)
                checked += 1
                let allowed = allowedByFile[file.lastPathComponent] ?? []
                for line in src.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.range(of: pattern, options: .regularExpression) != nil else { continue }
                    XCTAssertTrue(allowed.contains(trimmed),
                                  "\(file.lastPathComponent) declares a public API not on the CUESYNC-7 §B.3 allowlist: " +
                                  "'\(trimmed)' — either it's an unintended widening, or the allowlist needs updating")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "expected to scan at least the Models/Parsers/Exporters/Support sources")
    }

    /// spec §3 Manifest: "The resolved dependency tree contains no package beyond
    /// swift-cross-ui and its own transitive closure" — the direct-dependency half of that
    /// guarantee is that `Package.swift` itself never grows a second, unaudited
    /// `.package(...)` entry alongside swift-cross-ui (spec §4: "any unexpected transitive
    /// package [is] a finding to report, not a detail to wave through").
    func testPackageSwiftDeclaresExactlyOneDirectPackageDependency() throws {
        let manifest = try readPackageSwift()
        let count = manifest.components(separatedBy: ".package(").count - 1
        XCTAssertEqual(count, 1,
                       "Package.swift must declare exactly one .package(...) entry (swift-cross-ui) — " +
                       "got \(count). An extra direct dependency is an unaudited supply-chain addition (spec §4)")
    }

    /// spec §3 Manifest / §4 threat model: "commit Package.resolved so the audited commit
    /// is the one that builds" applies to swift-cross-ui's *entire* transitive closure, not
    /// just the top-level pin already checked by
    /// `testPackageResolvedExistsAndPinsSwiftCrossUIToAFullRevisionSHA`. A branch-tracking
    /// or otherwise symbolic pin on any transitive dependency would reintroduce the exact
    /// "moving pin" risk §4 forbids, just one hop further down the tree.
    func testPackageResolvedPinsEveryTransitiveDependencyToAFullRevisionSHA() throws {
        let data = try Data(contentsOf: Self.packageResolvedURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pins = (json?["pins"] as? [[String: Any]])
            ?? ((json?["object"] as? [String: Any])?["pins"] as? [[String: Any]])
            ?? []
        XCTAssertGreaterThan(pins.count, 0, "Package.resolved must contain at least the swift-cross-ui pin")
        for pin in pins {
            let identity = (pin["identity"] as? String) ?? (pin["package"] as? String) ?? "<unknown>"
            guard let state = pin["state"] as? [String: Any], let revision = state["revision"] as? String else {
                XCTFail("pin \(identity) in Package.resolved has no resolved revision")
                continue
            }
            XCTAssertEqual(revision.count, 40, "pin \(identity) must resolve to a full 40-char SHA, got \(revision)")
            XCTAssertTrue(revision.allSatisfy(\.isHexDigit), "pin \(identity) revision must be hex: \(revision)")
        }
    }

    /// spec §3 Source: "Zero edits to App/, Views/, Theme/, Utilities/, or
    /// CueSync.xcodeproj ... Do not add UI/ to the Xcode target." A `git diff` check isn't
    /// reliable inside a deterministic, network-free unit test (CI checkouts may be
    /// shallow), but this is directly verifiable from the committed project file itself:
    /// it must contain no group or file reference naming the `UI/` directory or either of
    /// its two shell files, since the spec requires the SwiftUI build to stay completely
    /// unaware the swift-cross-ui shell exists.
    func testXcodeProjectDoesNotReferenceTheCrossUIShell() throws {
        let pbxprojURL = Self.repoRoot.appendingPathComponent("CueSync/CueSync.xcodeproj/project.pbxproj")
        let contents = try String(contentsOf: pbxprojURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("UI/"),
                       "CueSync.xcodeproj must not reference the UI/ directory (spec §C.14)")
        for path in ["path = CueSyncApp.swift", "path = ContentView.swift"] {
            // Both file names are legitimately reused by App/CueSyncApp.swift and
            // Views/ContentView.swift (the SwiftUI originals) — those references are
            // expected and unrelated to this check, which only guards against a *second*,
            // UI/-directory group being added. The absence-of-"UI/"-substring assertion
            // above is what actually enforces the ticket's requirement; this loop is a
            // sanity check that both expected SwiftUI references still resolve at all.
            XCTAssertTrue(contents.contains(path), "expected the pre-existing SwiftUI \(path) reference to remain")
        }
    }

    // MARK: - Helpers

    /// Extracts the full `.target(...)`/`.executableTarget(...)`/`.testTarget(...)` call
    /// text for the target named `targetName`, via balanced-paren scanning from the
    /// nearest preceding target-call keyword through to its matching close paren. Used to
    /// scope assertions (e.g. "CueSyncCore must never mention CUESYNC_CROSSUI") to a
    /// single target instead of the whole manifest, so an unrelated target mentioning the
    /// same substring elsewhere can't produce a false pass.
    private func targetBlock(named targetName: String, in manifest: String) -> String? {
        // `products:` entries also contain the substring "targets: [" (e.g.
        // `targets: ["CueSync"]`) before the real `targets:` array does, so anchor on
        // the LAST occurrence — the real array is declared once, after `products:` and
        // `dependencies:`, and no individual target's own definition repeats the phrase.
        let targetsArrayStart = manifest.range(of: "targets: [", options: .backwards)?.upperBound
            ?? manifest.startIndex
        guard let nameRange = manifest.range(of: "name: \"\(targetName)\"",
                                             range: targetsArrayStart..<manifest.endIndex) else { return nil }
        let searchRange = targetsArrayStart..<nameRange.lowerBound
        let openers = [".target(", ".executableTarget(", ".testTarget("]
        let opener = openers
            .compactMap { manifest.range(of: $0, options: .backwards, range: searchRange) }
            .max { $0.lowerBound < $1.lowerBound }
        guard let opener else { return nil }

        var depth = 0
        var idx = manifest.index(before: opener.upperBound) // the "(" itself
        while idx < manifest.endIndex {
            let c = manifest[idx]
            if c == "(" { depth += 1 } else if c == ")" {
                depth -= 1
                if depth == 0 { return String(manifest[opener.lowerBound...idx]) }
            }
            idx = manifest.index(after: idx)
        }
        return nil
    }

    private func assertSourceFileExists(_ relativePath: String, _ reason: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let url = Self.sourceRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "\(relativePath) does not exist yet (\(reason))", file: file, line: line)
    }

    private func swiftFiles(under dir: URL) -> [URL]? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Verifies every occurrence of `import <module>` in `source` sits inside an
    /// `#if canImport(<module>)` conditional-compilation block (tracked via a simple
    /// directive-nesting stack — sufficient for this codebase's straight-line `#if/#else/
    /// #endif` usage, without needing a full Swift parser).
    private func assertImportIsGuarded(_ source: String, module: String, file: String,
                                       xctFile: StaticString = #filePath, xctLine: UInt = #line) {
        var stack: [String] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if") {
                stack.append(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("#elseif") {
                if !stack.isEmpty { stack[stack.count - 1] = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
            } else if line == "import \(module)" {
                let guarded = stack.contains { $0.contains("canImport(\(module))") }
                XCTAssertTrue(guarded, "\(file): `import \(module)` must be inside `#if canImport(\(module))`",
                              file: xctFile, line: xctLine)
            }
        }
    }
}
