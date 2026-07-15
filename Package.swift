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
        // Business logic: parsers, exporters, models. Foundation-only except
        // EngineDJParser, which #if-guards its two Apple-only imports
        // (SQLite3, Compression) so this target still compiles elsewhere.
        .target(
            name: "CueSyncCore",
            path: "CueSync/CueSync",
            exclude: ["App", "Views", "Theme", "Utilities", "Resources", "UI"],
            sources: ["Models", "Parsers", "Exporters"],
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS]))
            ]
        ),
        // Placeholder executable shell. The real swift-cross-ui presentation
        // layer is re-hosted here screen-by-screen in later steps.
        .executableTarget(
            name: "CueSync",
            dependencies: ["CueSyncCore"],
            path: "CueSync/CueSync",
            exclude: ["App", "Views", "Theme", "Utilities", "Resources", "Models", "Parsers", "Exporters"],
            sources: ["UI"]
        ),
    ]
)
