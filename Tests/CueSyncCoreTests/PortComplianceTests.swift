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
