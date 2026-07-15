import Foundation
import XCTest
@testable import CueSyncCore

/// Structural checks tied directly to CUESYNC-3 acceptance criteria (specs/CUESYNC-3.md
/// §3) that aren't observable through the parser/exporter/model API surface — they
/// enforce build-manifest and source-guarding requirements a full app launch or a CI
/// matrix leg would otherwise be needed to catch. Deterministic and network-free: every
/// check reads files already checked into the repo, located via `#filePath` (never a
/// hardcoded absolute path) so it works unchanged on windows-latest / macos-latest.
final class PortComplianceTests: XCTestCase {
    /// Tests/CueSyncCoreTests/PortComplianceTests.swift -> Tests/CueSyncCoreTests -> Tests -> repo root
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let packageSwiftURL = repoRoot.appendingPathComponent("Package.swift")
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

    func testPackageSwiftDeclaresSwiftCrossUIDependency() throws {
        let manifest = try readPackageSwift()
        XCTAssertTrue(manifest.localizedCaseInsensitiveContains("swift-cross-ui") ||
                      manifest.contains("SwiftCrossUI"),
                      "Package.swift must depend on swift-cross-ui (spec §2.A.1) — the CueSync " +
                      "executable target cannot re-host the UI without it")
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
        let banned = ["AppKit", "AVFoundation", "Compression", "UniformTypeIdentifiers", "CoreGraphics"]
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

    // MARK: - Helpers

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
