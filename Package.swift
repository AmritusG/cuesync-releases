// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CueSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CueSyncCore", targets: ["CueSyncCore"]),
        .executable(name: "CueSync", targets: ["CueSync"]),
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
        // Placeholder executable shell. The real swift-cross-ui presentation
        // layer is re-hosted here screen-by-screen in later steps.
        .executableTarget(
            name: "CueSync",
            dependencies: ["CueSyncCore"],
            path: "CueSync/CueSync",
            exclude: ["App", "Views", "Theme", "Utilities", "Resources", "Models", "Parsers", "Exporters", "Support"],
            sources: ["UI"]
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
