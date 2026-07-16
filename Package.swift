// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CueSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CueSyncCore", targets: ["CueSyncCore"]),
        .executable(name: "CueSync", targets: ["CueSync"]),
    ],
    dependencies: [
        // Pinned to the exact release tag v0.8.0, resolved commit
        // a6d206370812e3b9edba259d167e848892c5013d (spec CUESYNC-5 §0.1). `exact:`,
        // never `branch:`/`from:` — the bytes are pinned, not a moving label (§4).
        .package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.8.0"),
    ],
    targets: [
        // Vendored SQLite amalgamation (see Sources/CSQLite/README.md). Compiling it
        // directly removes any "install SQLite" prerequisite on Windows/Linux.
        .target(
            name: "CSQLite",
            path: "Sources/CSQLite",
            cSettings: [
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_DQS", to: "0"),
            ]
        ),
        // Vendored zlib source (see Sources/CZlib/README.md). Compiling it directly
        // removes any "install zlib" prerequisite on Windows/Linux/ARM.
        // include/zconf.h unconditionally defines Z_PREFIX, renaming every exported
        // symbol (deflate -> z_deflate, etc.) so this vendored copy can coexist in
        // the same binary as swift-cross-ui's own vendored zlib (pulled in
        // transitively via ImageFormats -> libpng) without a duplicate-symbol link
        // error — both link into the single CueSync executable (CUESYNC-5 §0).
        .target(
            name: "CZlib",
            path: "Sources/CZlib",
            exclude: ["gzclose.c", "gzlib.c", "gzread.c", "gzwrite.c"]
        ),
        // Business logic: parsers, exporters, models. Foundation-only except
        // EngineDJParser, which #if-guards its two Apple-only imports
        // (SQLite3, Compression) so this target still compiles elsewhere.
        .target(
            name: "CueSyncCore",
            dependencies: ["CSQLite", "CZlib"],
            path: "CueSync/CueSync",
            exclude: ["App", "Views", "Theme", "Utilities", "Resources", "UI"],
            sources: ["Models", "Parsers", "Exporters", "Support"]
        ),
        // swift-cross-ui app shell, re-hosted here screen-by-screen in later steps.
        // CUESYNC_CROSSUI is defined ONLY by this SwiftPM target, never by
        // CueSyncCore and never by the Xcode build — it exists to make the split
        // between the SwiftUI/AppKit presentation (App/, Views/, Theme/, built by
        // CueSync.xcodeproj, untouched) and this cross-platform presentation
        // (UI/, built by `swift build`) explicit and machine-checkable, since the
        // directory split alone can't guard a file that ends up compiled into both.
        .executableTarget(
            name: "CueSync",
            dependencies: [
                "CueSyncCore",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            path: "CueSync/CueSync",
            exclude: ["App", "Views", "Theme", "Utilities", "Resources", "Models", "Parsers", "Exporters", "Support"],
            sources: ["UI"],
            swiftSettings: [.define("CUESYNC_CROSSUI")]
        ),
        // Ports CueSync/Tests/CueSyncTests.swift (custom-runner suite) into XCTest so
        // `swift test` exercises Models/Parsers/Exporters on windows-latest + macos-latest
        // (spec item E.27). The old standalone runner (scripts/run-tests.sh) is unchanged.
        // Depends on CSQLite/CZlib directly (not just transitively via CueSyncCore) so
        // fixture-building code can import them for in-process SQLite/raw-DEFLATE test data.
        .testTarget(
            name: "CueSyncCoreTests",
            dependencies: ["CueSyncCore", "CSQLite", "CZlib"],
            path: "Tests/CueSyncCoreTests",
            resources: [.copy("Fixtures/Samples")]
        ),
    ]
)
