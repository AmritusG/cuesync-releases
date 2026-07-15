# CUESYNC-4 — Complete the Windows support layer (faithful native port)

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> Faithful port. Keep the Swift source and layout, keep the macOS Xcode build and the
> existing `scripts/run-tests.sh` harness working, and change only what Windows requires.
> This ticket finishes the cross-platform **logic/support layer** that a prior port
> (`adw/CUESYNC-3`) scaffolded but left stubbed: `EngineDJParser` still throws *"Engine DJ
> import is not yet supported on this platform"* on non-Apple, with TODOs to *"switch to
> the vendored CSQLite/CZlib target."* The UI re-host onto swift-cross-ui is a **separate
> ticket and out of scope here** — this ticket's Definition of Done is `swift test` going
> **129/129 green** on macOS and Windows.

---

## 1. Problem

CUE SYNC's parsers, exporters and models (`CueSync/CueSync/{Models,Parsers,Exporters}`)
are UI-independent and already compile with plain `swiftc` on macOS, but two dependencies
are Apple-only — `import SQLite3` (system module) and `import Compression`
(`compression_decode_buffer`) in `EngineDJParser` — so the same code cannot build or be
tested on Windows, and `XMLParser` (used by the Rekordbox/Resolume parsers) lives in a
different module off-Darwin. As a result the SwiftPM build that CI runs
(`.github/workflows/swift-windows.yml`: `swift build -c release` + `swift test` on
`windows-latest` **and** `macos-latest`) has no `Package.swift` to build and the Windows leg
cannot run the suite. This ticket delivers a SwiftPM package that vendors SQLite and zlib as
portable C targets, adds a small cross-platform **Support** layer so the logic compiles
identically on every platform, and fixes a Resolume-exporter defect where control bytes in a
(untrusted) preset name produce XML the app's own parser rejects — so that DJs on Windows get
byte-for-byte identical Engine DJ / Rekordbox / Serato / ShowKontrol / Resolume import-export
behavior, verified by the full 129-test suite passing on both macOS and Windows.

---

## 2. Plan

All paths are under the repo root. Existing Swift sources live in `CueSync/CueSync/`. The
existing `CueSync.xcodeproj` and its SwiftUI views are **left untouched** as the macOS build;
`scripts/run-tests.sh` (the standalone `swiftc` + `sqlite3`-CLI macOS harness) stays working.
The port adds a SwiftPM build that reuses the logic files unchanged except for the guarded
imports below.

### A. SwiftPM package + vendored C targets

1. Add **`Package.swift`** at the repo root (this is where CI runs `swift build` / `swift
   test`). `swift-tools-version:6.0`, `platforms: [.macOS(.v14)]`. Products: a `CueSyncCore`
   library. Targets: `CSQLite`, `CZlib`, `CueSyncCore`, and the `CueSyncCoreTests` test
   target (step E). Pin any external dependency to an exact tag/revision.
2. Add vendored C target **`Sources/CSQLite/`** — the SQLite **amalgamation**
   (`sqlite3.c` + `include/sqlite3.h` + `include/module.modulemap` declaring `module CSQLite
   { header "sqlite3.h"; export * }`). Vendoring (not a `systemLibrary`) removes any "install
   SQLite" prerequisite on Windows and compiles on every arch. Record the exact SQLite
   version in a short `Sources/CSQLite/README`/header comment. Recommended `cSettings`:
   `SQLITE_THREADSAFE=1`, `SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_DQS=0` (defensive defaults);
   full read/write is required because the test target creates fixture DBs (step E).
3. Add vendored C target **`Sources/CZlib/`** — zlib C source (at minimum the inflate side:
   `inflate.c inftrees.c inffast.c adler32.c crc32.c zutil.c` + all zlib headers; vendor the
   full zlib for simplicity so `deflate` is available to the parity test in step E) with
   `include/module.modulemap` declaring `module CZlib { header "zlib.h"; export * }`. Same
   rationale: no system-zlib prerequisite on Windows/ARM. Record the exact zlib version.
4. Declare target **`CueSyncCore`** with `path: "CueSync/CueSync"`,
   `sources: ["Models", "Parsers", "Exporters", "Support"]`,
   `exclude: ["App", "Views", "Theme", "Utilities", "Resources"]` (never compile SwiftUI),
   and `dependencies: ["CSQLite", "CZlib"]`. `Support/` is new (step C). Do **not** add a
   macOS `.linkedLibrary("sqlite3")` — Engine DJ now resolves SQLite through the guarded
   import + vendored `CSQLite` on every platform.

### B. Make the logic layer cross-platform (guard the Apple-only APIs)

5. `Parsers/EngineDJParser.swift` — wrap the SQLite import so the identical `sqlite3_*` call
   sites resolve everywhere:
   ```swift
   #if canImport(SQLite3)
   import SQLite3      // Apple system module (macOS Xcode + SwiftPM)
   #else
   import CSQLite      // vendored amalgamation (Windows/Linux)
   #endif
   ```
   Remove the CUESYNC-3 stub that threw *"not yet supported on this platform"* and the
   `#if canImport(SQLite3)` gate around the function bodies, so the real SQLite code path
   compiles and runs on Windows via `CSQLite`. No SQL changes — queries are already
   parameterised and the DB is opened `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`.
6. `Parsers/EngineDJParser.swift` — delete its direct `import Compression` and
   `compression_decode_buffer` usage; route decompression through `Support/Zlib.swift`
   (step C) via a single call such as `Zlib.inflate(compressed, cap: …)`. This keeps
   `EngineDJParser` free of any Apple-only import. Behavior (returned bytes, graceful nil on
   bad input) must be identical to the current Apple path.
7. `Parsers/RekordboxParser.swift` **and** `Parsers/ResolumeParser.swift` — `XMLParser`
   lives in `Foundation` on Darwin but in `FoundationXML` off-Darwin. Add at the top of each:
   ```swift
   #if canImport(FoundationXML)
   import FoundationXML
   #endif
   ```
   (`NSObject`/`XMLParserDelegate` remain available.) No parsing-logic changes; external
   entity resolution stays off (Foundation default) — see Threat model.
8. Confirm `Models/`, `Exporters/ShowKontrolExporter.swift`, `Parsers/SeratoParser.swift`,
   `Parsers/ShowKontrolParser.swift` are Foundation-only (verified: the only non-portable API
   in the core is `XMLParser`, handled in step 7). No changes beyond compiling under the new
   package.

### C. New cross-platform `CueSync/CueSync/Support/` layer — the 6 files

Every file must compile in `CueSyncCore` on macOS **and** Windows and contain **no unguarded**
`AppKit`/`AVFoundation`/`Compression`/`UniformTypeIdentifiers`/`CoreGraphics` import (each such
import, if present, sits inside `#if canImport(<module>)`).

9. **`Support/SQLite.swift`** — SQLite glue shared by `CueSyncCore`. Guarded import
   (`#if canImport(SQLite3) import SQLite3 #else import CSQLite #endif`) plus a single safe
   `SQLITE_TRANSIENT` destructor constant
   (`let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)`) so the
   fragile `unsafeBitCast` is defined once. Optional thin helpers (e.g. `columnText`) may move
   here; keep behavior identical.
10. **`Support/Zlib.swift`** — cross-platform raw-DEFLATE inflate used by `EngineDJParser`.
    ```swift
    #if canImport(Compression)
    import Compression
    #else
    import CZlib
    #endif
    enum Zlib { static func inflate(_ src: Data, cap: Int) -> Data? { … } }
    ```
    On Apple keep `compression_decode_buffer(…, COMPRESSION_ZLIB)` (raw DEFLATE); elsewhere use
    zlib initialised with **`inflateInit2(&strm, -15)`** (negative windowBits = raw DEFLATE,
    matching Apple's semantics), driving `inflate` in a bounded loop. **Hard-cap** the output at
    `cap` (see Threat model) on both paths; abort if exceeded. Return `nil` on any zlib error.
11. **`Support/Hex.swift`** — pure-Swift hex/CSS `#rrggbb`(/`#rgb`) → `(r,g,b)` Double parsing
    with integer math, no `NSColor`. Used by the UI layer later; must exist and compile now.
12. **`Support/AudioDuration.swift`** — pure-Swift WAV/AIFF header duration parsing (bounded
    reads, see Threat model), returning seconds or `nil`. On Apple, keep an AVFoundation path
    for mp3/m4a behind `#if canImport(AVFoundation) import AVFoundation #endif`; elsewhere
    return `nil` (UI falls back to the manual duration modal). No unguarded Apple import.
13. **`Support/Preferences.swift`** — cross-platform key/value preferences over `UserDefaults`
    (Foundation, works on Windows) with a JSON-file fallback stored under
    `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, …)` —
    never a hardcoded path. Foundation-only.
14. **`Support/FileDialogs.swift`** — platform-neutral file-picker API
    (`openFile(title:extensions:) -> URL?`, `saveFile(title:suggestedName:extension:) -> URL?`)
    taking **extension strings** (no `UTType`, so no `UniformTypeIdentifiers` on Windows). On
    macOS implement with `NSOpenPanel`/`NSSavePanel` behind `#if canImport(AppKit) import
    AppKit #endif`; elsewhere return `nil` (the swift-cross-ui backend wiring is the UI
    ticket). Guard-clean.

### D. Fix the Resolume exporter control-char round-trip

15. `Exporters/ResolumeExporter.swift` — the preset name is untrusted (it can come from a
    hostile `.cueproj` or an imported track title). `escapeXml(_:)` escapes the five XML
    metacharacters but not the C0 control bytes (NUL/backspace/bell/…) that **XML 1.0 forbids
    outright and cannot even be represented as character references**, so a control-laced name
    produces a document `ResolumeParser.parse` (and Resolume) reject. Before escaping the five
    entities, **strip every scalar outside the XML 1.0 `Char` set** — keep only U+0009, U+000A,
    U+000D, U+0020–U+D7FF, U+E000–U+FFFD, U+10000–U+10FFFF; drop the rest. Apply this to the
    preset name (the only untrusted text placed into the XML). Legal Unicode names (accents,
    emoji) must be preserved byte-for-byte so they still round-trip exactly; only illegal
    control scalars are removed. Numeric coordinate/curve output is unchanged (already finite,
    plain-decimal, ≤6 dp, curve clamped to 1…23).

### E. Tests, fixtures, CI

16. Add the SwiftPM XCTest target **`Tests/CueSyncCoreTests/`** (`@testable import
    CueSyncCore`) that `swift test` runs on `windows-latest` and `macos-latest`. It ports the
    existing standalone behavioral coverage from `CueSync/Tests/CueSyncTests.swift` (the
    custom-runner suite) **1:1 in behavior** — every Models/Parsers/Exporters/fuzz assertion —
    grouped into per-area files (Models, Rekordbox, ShowKontrol, Resolume, Serato, EngineDJ),
    plus an **Adversarial** file (XXE-not-resolved, entity-bomb-bounded, raw-NUL-throws,
    decompression-bomb-bounded, out-of-range coordinates) and a **PortCompliance** file. The
    total suite is **129 tests** and must be **all-green**. The `scripts/run-tests.sh` macOS
    harness stays as a second, independent runner.
17. **`Tests/CueSyncCoreTests/PortComplianceTests.swift`** — structural checks (deterministic,
    network-free, files located via `#filePath`, never absolute paths) that assert: `Package.swift`
    declares a **`CSQLite`** target and a **`CZlib`** target; `EngineDJParser`'s `import SQLite3`
    and `import Compression` (if present) are inside `#if canImport(...)`; **no** SwiftPM source
    file under `Models/Parsers/Exporters/Support/UI` has an unguarded
    `AppKit`/`AVFoundation`/`Compression`/`UniformTypeIdentifiers`/`CoreGraphics` import; and
    `Support/{FileDialogs,Preferences,AudioDuration,Hex}.swift` each exist.
18. **Fixtures are generated in-process and portable.** Build the Engine DJ SQLite fixtures
    (`engine-good`, `engine-no-perf`, `engine-empty`, `engine-badblob`, `engine-corrupt`) via
    the SQLite C API through the **same guarded import** (`#if canImport(SQLite3) … #else
    import CSQLite`) with parameterised inserts — **not** the `sqlite3` CLI (absent on Windows).
    Bundle the `samples/` files needed by tests as SwiftPM resources (`.copy("Fixtures/Samples")`
    on the test target; read via `Bundle.module`). Use `FileManager.default.temporaryDirectory`
    for all scratch files — **never** `/tmp` and never the hardcoded
    `/Users/amritrosell/.../samples` path in the old `Tests/main.swift`.
19. Add a **zlib parity/round-trip** unit test: `deflate` a known byte buffer with raw DEFLATE
    (`deflateInit2(..., -15, ...)` via `CZlib`) then `Zlib.inflate` it and assert equality (and,
    on Apple, that the Compression path yields identical bytes). This directly exercises the new
    inflate implementation independent of a real Engine blob.
20. Keep `.github/workflows/swift-windows.yml` as-is (matrix `windows-latest` + `macos-latest`,
    `swift build -c release` then `swift test`, artifact `.build/release/`). No new prerequisite
    steps are needed because `CSQLite`/`CZlib` are vendored C (no system packages).
21. **Do not** break the macOS Xcode build: the guarded imports (`#if canImport(SQLite3)` →
    `SQLite3`, `#if canImport(Compression)` in `Support/Zlib.swift`, `#if canImport(FoundationXML)`
    no-op on Darwin) all resolve to the existing Apple modules under Xcode, so
    `CueSync.xcodeproj` still builds and `scripts/run-tests.sh` still passes.

> **swift-cross-ui note (scope boundary):** the UI re-host is a separate ticket. If the shared
> `PortComplianceTests` retains a check that `Package.swift` references `swift-cross-ui`, satisfy
> it by declaring the dependency (pinned) in the manifest for the forthcoming UI target **without**
> wiring it into any target this ticket builds (an unused, declared dependency resolves but is not
> compiled, so `swift test` stays green without building a UI backend). Do not add a swift-cross-ui
> executable target in this ticket.

---

## 3. Acceptance criteria

*(each bullet is a checkable statement; the suite that verifies them is `swift test`, 129 tests)*

- `swift build -c release` succeeds at the repo root on **macos-latest** and **windows-latest**.
- `swift test` runs **129 tests and reports 0 failures / 0 crashes** on both CI legs.
- `Package.swift` declares a vendored **`CSQLite`** C target and a vendored **`CZlib`** C target;
  neither the package nor CI requires a system SQLite or system zlib install.
- `Support/` contains exactly the six new files **`FileDialogs.swift`, `Preferences.swift`,
  `AudioDuration.swift`, `Hex.swift`, `SQLite.swift`, `Zlib.swift`**, all compiled into
  `CueSyncCore` and each free of any **unguarded** AppKit/AVFoundation/Compression/
  UniformTypeIdentifiers/CoreGraphics import.
- In `EngineDJParser.swift`, `import SQLite3` and `import Compression` (if present) each sit
  inside a `#if canImport(...)` block; the parser has no other unguarded Apple-only import.
- Engine DJ import works on Windows via `CSQLite`: `EngineDJParser.parse(databaseURL:)` on
  `engine-good` returns 2 tracks (title used as name, empty title falls back to filename, key
  code 1 → "C"); a missing DB, a DB missing `PerformanceData`, an empty `Track` table, and a
  non-SQLite file each **throw** (no crash); a garbage/oversized `quickCues` blob returns the
  track **with no cues** (no crash).
- `Support/Zlib.inflate` decompresses a raw-DEFLATE (`windowBits = -15`) buffer to bytes
  **identical** to Apple's `COMPRESSION_ZLIB` for the same input, honors the output **cap**
  (returns `nil` / aborts past the cap), and returns `nil` on corrupt input.
- **Resolume control-char round-trip:** `ResolumeExporter.generate(...)` with a preset name
  containing `\u{0000}\u{0008}\u{0007}` still produces non-empty XML, and
  `ResolumeParser.parse(xml:)` of that output **does not throw**; a legal Unicode preset name
  still round-trips **exactly** (`parsed.presetName == name`).
- Resolume export is otherwise unchanged: no `nan`/`inf` coordinate tokens, plain decimal with
  ≤6 dp (no scientific notation), curves clamped to `1…23`, and arrival-curve/position
  round-trip through export→parse→convert preserved.
- **ShowKontrol `.cue`** export uses `\r`-only separators and contains **no `\n`** byte on any
  platform (assert on raw bytes); names have commas/newlines stripped.
- **Parser/exporter parity:** parsing each `samples/` fixture (Rekordbox XML, Resolume envelope,
  ShowKontrol `.cue`, `.cueproj`) yields models whose serialization is **byte-identical** on
  macOS and Windows.
- **Adversarial inputs are contained:** a Rekordbox XXE external-entity reference never leaks
  file contents into a track name; a nested internal-entity ("billion laughs") document stays
  bounded and does not hang; a raw NUL byte inside XML makes the parser **throw**, not crash;
  all fuzz/truncation cases keep cues finite, non-negative, curve ∈ `1…23`.
- Tests use only `FileManager` temp dirs and bundled resources — **no** `/tmp`, no hardcoded
  absolute path, no `sqlite3` CLI shell-out; Engine DJ fixtures are built in-process.
- The macOS **Xcode** build (`CueSync.xcodeproj`) still builds unchanged, and
  `scripts/run-tests.sh` still passes (macOS path preserved).

---

## 4. Threat model

**Trust boundary — every imported file is untrusted external input.** All parsing fails closed
(throw / return empty-or-nil), never crashes, never reads out of bounds.

- **Rekordbox / Resolume XML, `.cueproj` JSON, ShowKontrol `.cue`:** parse defensively — XML via
  Foundation `XMLParser`/`FoundationXML` (external-entity resolution stays **off**, the
  Foundation default; keep it off so a `SYSTEM` entity cannot exfiltrate a local file into a
  track name), JSON via `Codable` with tolerant defaults. A raw control byte (e.g. NUL) inside
  XML must make the parser throw, not crash. Nested internal-entity expansion must stay bounded.
- **Serato audio files** (`SeratoParser` — manual GEOB/ID3/RIFF/AIFF byte-offset parsing): every
  indexed read must stay behind an explicit bounds guard (`readBigEndianFloat64` /
  `readBigEndianUInt32` must not index past `count`). Preserve all existing bounds checks;
  malformed/truncated input returns empty/nil.
- **Engine DJ SQLite DB** (untrusted file): open **read-only**
  (`SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`, already set); all queries stay **parameterised**
  (already the case) — no string-built SQL. `CSQLite` is compiled with `SQLITE_OMIT_LOAD_EXTENSION`
  so a hostile DB cannot load a native extension.
- **Engine DJ zlib blob — decompression-bomb risk (primary new attack surface):** the uncompressed
  size is read from the **first 4 bytes of the untrusted blob**. Do **not** trust it unbounded.
  Keep the existing `< 1_000_000` sanity gate **and** pass a hard output **cap** into
  `Support/Zlib.inflate`; the inflate loop must abort once output exceeds the cap on **both** the
  Apple (`compression_decode_buffer` fixed destination) and vendored-zlib (`inflate`) paths.
- **Audio duration header parsing:** bound every read; an unknown/oversized WAV/AIFF header field
  → give up gracefully and defer to the manual duration modal (return `nil`).

**File output / path handling:** never hardcode `/tmp`, path separators, or `UTType`s — use
Foundation `URL`/`FileManager` throughout; exports write atomically
(`write(to:atomically:true)`); scratch/fixtures use `FileManager.temporaryDirectory` /
`.applicationSupportDirectory`. **ShowKontrol `.cue` line endings are `\r`-only and
format-significant** — emit exact bytes; assert on raw bytes that no platform newline translation
introduces `\n`.

**Secrets / credentials:** **none.** The app has no network, accounts, or tokens; the Gumroad
licensing code is already removed. No credential or secret crosses any boundary.

**Cryptographically secure primitives:** **none required.** The only "unique" value is the
Resolume envelope `uniqueId` (a millisecond timestamp) used solely to distinguish presets inside
Resolume — it is not a security token and needs no CSPRNG. No password, key, nonce, salt or session
value exists. (If unpredictable IDs are ever needed, use `SystemRandomNumberGenerator`, not a
timestamp — out of scope here.) Test fuzzing uses a **deterministic** `XorShift64` seed on purpose;
this is not a security primitive and must stay deterministic for reproducibility.

---

## 5. Target platforms

| Platform | Status (this ticket's core+tests scope) | Notes |
|----------|------------------------------------------|-------|
| **macOS (arm64 + x86_64)** | ✅ Supported | Existing `CueSync.xcodeproj` SwiftUI build stays; the SwiftPM `CueSyncCore` + tests build via the guarded imports resolving to Apple `SQLite3`/`Compression`/`Foundation`. `scripts/run-tests.sh` still passes. |
| **Windows x64** | ✅ Primary target | SwiftPM + vendored `CSQLite` + `CZlib` (no system-lib prereqs). `XMLParser` via `FoundationXML`. Verified on the `windows-latest` CI leg (`swift build -c release` + `swift test`). |
| **Windows ARM64** | ✅ Buildable in this scope | `CSQLite` and `CZlib` are **pure C** and compile on ARM64; `CueSyncCore` + tests have **no UI dependency** in this ticket, so there is no ARM64 gap here. (Not CI-gated unless an ARM64 runner is added.) |
| **Linux (x64)** | ✅ Buildable (not a ticket requirement) | `CueSyncCore` is Foundation + `FoundationXML` + vendored C. Include a CI leg only if capacity allows. |

**Dependency lacking Windows-ARM64 support:** **none within this ticket's scope.** `CSQLite`
(sqlite3 amalgamation) and `CZlib` (zlib) are portable C with no ARM64 gap. The one dependency
that *is* an ARM64 (and general Windows-backend) risk — **swift-cross-ui**'s WinUI/Windows App SDK
backend for the UI re-host — is **out of scope here** and deferred to the UI ticket; this ticket
deliberately does not build it, so it cannot block the `swift test` DoD on any platform.
