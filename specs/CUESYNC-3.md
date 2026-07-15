# CUESYNC-3 — Port CUE SYNC to Windows x64 (faithful native port)

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> Faithful port: keep the Swift source and project layout, reproduce every screen
> and user flow 1:1, and change only what Windows requires. The business logic
> (`Models/`, `Parsers/`, `Exporters/`) is already UI-independent — it compiles today
> with plain `swiftc` against Foundation + SQLite3 + Compression (see
> `scripts/run-tests.sh`). The UI layer is re-hosted from Apple SwiftUI/AppKit onto
> **swift-cross-ui** so one codebase builds on Windows *and* macOS/Linux via SwiftPM.

---

## 1. Problem

CUE SYNC is a native macOS SwiftUI app (Xcode-only) that converts DJ cue points
(Rekordbox, Serato, Engine DJ, ShowKontrol, Resolume) into Resolume Arena envelope
automation and ShowKontrol cues. Windows DJs/VJs cannot run it at all. This ticket
delivers a **faithful Windows x64 native build** of the same app — identical four-panel
workflow (Project → Browse → Configure → Export), identical import/export formats,
identical wording and dark/light theming — built with SwiftPM (Windows has no Xcode)
and a cross-platform UI framework, so the exact same product runs on Windows while the
existing macOS build is preserved.

---

## 2. Plan

All paths below are under the repo root. Existing Swift sources live in
`CueSync/CueSync/`; the existing `CueSync.xcodeproj` and its SwiftUI views are **left
untouched** as the legacy macOS build. The port adds a SwiftPM build that reuses the
logic files and introduces a new swift-cross-ui presentation layer.

### A. SwiftPM package + cross-platform build skeleton

1. Add `Package.swift` at the **repo root** (CI at `.github/workflows/swift-windows.yml`
   runs `swift build -c release` / `swift test` there). Declare `swift-tools-version:6.0`,
   `platforms: [.macOS(.v14)]`, products: a `CueSyncCore` library and a `CueSync`
   executable. Dependencies: `swift-cross-ui` (stackotter), plus the two vendored C
   targets below. Pin every dependency to an exact tag/revision.
2. Add vendored C target `Sources/CSQLite/` — the SQLite **amalgamation**
   (`sqlite3.c` + `sqlite3.h` + module map). Vendoring (not a `systemLibrary`) removes
   any "install SQLite" prerequisite on Windows and compiles on every arch.
3. Add vendored C target `Sources/CZlib/` — zlib source (`inflate`/`inftrees`/`adler32`/
   `crc32`/`zutil`/`inffast` + headers + module map). Same rationale: no system-zlib
   dependency on Windows/ARM.
4. Define `CueSyncCore` target with `path: "CueSync/CueSync"`,
   `sources: ["Models", "Parsers", "Exporters", "Support"]`, and dependencies
   `["CSQLite", "CZlib"]`. (`Support/` is new, created below.)
5. Define `CueSync` executable target with `path: "CueSync/CueSync"`,
   `sources: ["UI"]` (the new swift-cross-ui layer, created below), dependency
   `["CueSyncCore", .product(name: "SwiftCrossUI", ...), .product(name: "DefaultBackend", ...)]`.
   Exclude the legacy `App/`, `Views/`, `Theme/`, `Utilities/`, `Resources/` from SwiftPM
   targets so the Xcode build keeps them and SwiftPM never compiles SwiftUI.

### B. Make the logic layer cross-platform (guard the 2 Apple-only APIs)

6. `Parsers/EngineDJParser.swift` — replace Apple `Compression` with vendored zlib:
   wrap the import as `#if canImport(Compression) import Compression #endif`, and in
   `zlibDecompress(_:expectedSize:)` branch: on Apple keep `compression_decode_buffer`
   / `COMPRESSION_ZLIB`; elsewhere call zlib `inflate` initialised with
   **`inflateInit2(&strm, -15)`** (raw DEFLATE, negative windowBits) — this matches
   Apple's raw-DEFLATE semantics exactly. Keep the existing `expectedSize` handling but
   **hard-cap** the output buffer (see Threat model). Behaviour and returned bytes must
   be identical on both paths.
7. `Parsers/EngineDJParser.swift` — change `import SQLite3` to `import CSQLite` (or an
   umbrella `import CueSyncSQLite`) so the same `sqlite3_*` symbols resolve on Windows.
   Guard with `#if canImport(SQLite3)` / `#else import CSQLite` if keeping the macOS
   Xcode build on the system module. No SQL/logic changes — queries already parameterised.
8. `Parsers/EngineDJParser.swift` — keep `homeDirectoryForCurrentUser` (works on Windows,
   returns the user profile) for `defaultDatabaseURL`; the `Music/Engine Library/Database2/m.db`
   relative path is unchanged. Users pick the DB via the file dialog regardless, so no
   platform branch is required here.
9. Confirm `Models/`, `Exporters/`, and the rest of `Parsers/` are Foundation-only
   (they are) — no changes beyond compiling under the new target.

### C. Platform-abstracted glue (new `CueSync/CueSync/Support/`, in `CueSyncCore`)

10. `Support/FileDialogs.swift` — define a platform-neutral `FileDialogs` API
    (`openFile(title:extensions:) -> URL?`, `saveFile(title:suggestedName:extension:) -> URL?`)
    using swift-cross-ui's dialog API / backend-native pickers. Replace the AppKit
    `NSOpenPanel`/`NSSavePanel` implementation; move the old one behind
    `#if canImport(AppKit)` only if still needed by the Xcode build. Take **extension
    strings**, not `UTType`, so no `UniformTypeIdentifiers` dependency on Windows.
11. `Support/Preferences.swift` — abstract the six preference keys currently read/written
    via `UserDefaults` in `AppState` (`theme`, `sectionOrder`, `collapsedSections`,
    `sideBySideMode`, `forceYZeroOnImport`, `sectionColumns`). Use `UserDefaults` where it
    works; provide a JSON-file fallback stored under
    `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, …)`
    (never a hardcoded path). Keep `AppState.loadPreferences()/savePreferences()` signatures.
12. `Support/AudioDuration.swift` — replace `AVAudioFile` (AVFoundation) duration
    detection. On Apple keep AVFoundation behind `#if canImport(AVFoundation)`. Elsewhere:
    parse WAV/AIFF headers in pure Swift for an exact duration; for mp3/flac/m4a (no
    bundled decoder) return `nil` and have the UI fall back to the existing **manual
    duration modal** (`DurationInputModal`). Clamp all results with `AppState.safeDuration`.
13. `Support/Hex.swift` — move the CSS/hex → RGB parsing out of `ThemeColors`/`BrandIcons`
    (currently `NSColor.fromCSSString` / `Color.hexString`) into pure-Swift integer math
    with no `NSColor`. Returns `(r,g,b)` doubles the UI layer maps to a swift-cross-ui color.

### D. Re-host the UI on swift-cross-ui (new `CueSync/CueSync/UI/`)

Reproduce each screen 1:1. Same controls, labels, wording, order, colors, dark/light.
Per-screen re-hosting map (SwiftUI/AppKit → swift-cross-ui):

14. `UI/CueSyncApp.swift` — `SwiftUI.App`/`WindowGroup`/`.commands` → swift-cross-ui `App`
    + `WindowGroup` + menu/commands builder. Recreate every menu item and shortcut:
    New ⌘/Ctrl-N, Open ⌘/Ctrl-O, Save ⌘/Ctrl-S, Save As ⇧⌘/Ctrl-Shift-S, Export XML
    ⌘/Ctrl-E, Export .cue ⇧⌘/Ctrl-Shift-E, Undo/Redo, Envelope ▸ Add Cue Point (⌘/Ctrl-D),
    Delete Selected Point. `NSAlert` error dialog → swift-cross-ui alert.
15. `UI/ContentView.swift` — `VStack{Header, ScrollView{sections}, Footer}` + background
    grid + single/side-by-side column layout. Replace `NSEvent.addLocalMonitorForEvents`
    drag-cleanup and `.dropDestination` section reordering (see §D risk item 24).
16. `UI/HeaderView.swift` (logo + `v1.0.0` badge), `UI/FooterView.swift` → HStack/Text/Image.
17. `UI/CollapsibleSection.swift` — collapsible wrapper w/ step number, title, icon,
    optional trailing/count badge, collapse toggle, drag handle. Map to a
    VStack + header row + show/hide body.
18. `UI/HoverButton.swift` — buttons with `.onHover` animation → swift-cross-ui `Button`;
    hover state where the backend supports it (graceful loss otherwise).
19. `UI/Sections/ProjectSectionView.swift` — import buttons (Rekordbox / Serato / Engine DJ /
    ShowKontrol / Resolume) + New/Open/Save project controls; wire to `CueSyncCore` parsers
    and `FileDialogs`.
20. `UI/Sections/BrowseSectionView.swift` — track list + playlist/folder tree, selection.
21. `UI/Sections/ConfigureSectionView.swift` — hosts the envelope canvas, the cue table,
    duration input, "Load Audio File", and the active-points badge.
22. `UI/Sections/CuePointsTableView.swift` — editable table (ON toggle, curve swatch, NAME,
    POSITION(S), X, Y, INTERPOLATION dropdown). Already built from `HStack`/`VStack`
    (not SwiftUI `Table`) → direct stack translation. `NonSelectingTextField`
    (`NSViewRepresentable`) → plain swift-cross-ui `TextField` (see risk item 25).
23. `UI/Sections/DurationInputModal.swift` + `DurationInputView.swift` + `StepperField.swift`
    → swift-cross-ui modal/sheet + numeric stepper.
24. `UI/Sections/EnvelopeCanvasView.swift` — **highest-fidelity-risk screen.** SwiftUI
    `Canvas`/`GraphicsContext` (grid, axis labels, curve, gradient fill, draggable points)
    + `DragGesture`. Reproduce with swift-cross-ui's drawing/path surface; if the chosen
    backend lacks an immediate-mode canvas, implement a backend drawing view. Keep the
    envelope math (curve interpolation, point hit-testing, coordinate mapping) in
    `CueSyncCore` so it is platform-independent and unit-testable. Also covers the
    `GridOverlay` `Canvas` in `ContentView`.
25. `UI/BrandIcons.swift` — SVG icons are rendered today via `NSImage(data:)` (macOS-only).
    Replace with **build-time pre-rasterized PNG@1x/2x assets** (one per icon, per needed
    tint) bundled as SwiftPM resources, OR a cross-platform SVG rasterizer. No `NSImage`.
26. `UI/ThemeColors.swift` — the pure-SwiftUI `Color` definitions map directly to
    swift-cross-ui colors; strip the `import AppKit` / `NSColor` extension (moved to
    `Support/Hex.swift`).

### E. Tests + CI

27. Port the existing standalone suite (`CueSync/Tests/CueSyncTests.swift`, driven by
    `Tests/main.swift`'s custom runner) into an XCTest (or swift-testing) target
    `CueSyncCoreTests` so `swift test` runs it unchanged-in-behavior on Windows and macOS.
    Keep every existing parser/exporter/fuzz assertion; add the cases in §3.
28. Generate SQLite/binary fixtures in-process (Swift), not via the `sqlite3` CLI, so the
    test target is self-contained on Windows. Use `FileManager`'s temp directory
    (`.itemReplacementDirectory` / `url(for:.itemReplacementDirectory,…)`), never `/tmp`.
29. Keep `.github/workflows/swift-windows.yml` (matrix: `windows-latest`, `macos-latest`).
    Add whatever Windows prerequisite steps swift-cross-ui's Windows backend needs (see
    Target platforms). Artifact = `.build/release/`.

---

## 3. Acceptance criteria

- `swift build -c release` succeeds at the repo root on **windows-latest** and
  **macos-latest** CI legs (both matrix jobs green).
- `swift test` runs the ported `CueSyncCoreTests` and passes on both CI legs.
- The Windows executable launches and shows all four panels — **PROJECT**,
  **BROWSE & SELECT TRACK**, **CONFIGURE CUE POINTS**, **EXPORT** — with the same
  controls, labels, wording, step numbers, and dark theme as macOS.
- End-to-end on Windows: import `samples/sample-rekordbox.xml` → a track appears in
  Browse → selecting it populates Configure with cue points → Export Resolume XML and
  Export ShowKontrol .cue both write files.
- **Parser parity:** parsing each `samples/` fixture (Rekordbox XML, Resolume envelope,
  ShowKontrol .cue, `.cueproj`) yields models whose serialization is byte-identical on
  Windows and macOS.
- **Engine DJ:** the vendored-zlib `inflate` path returns byte-identical output to
  Apple's `COMPRESSION_ZLIB` for the same blob fixture; a corrupt/oversized blob returns
  the track with no cues (no crash), matching existing behavior.
- SQLite reads a real Engine DJ `m.db` via the vendored `CSQLite` on Windows.
- **Export parity:** Resolume XML output is byte-identical cross-platform;
  ShowKontrol `.cue` output uses `\r`-only line separators and contains **no `\n`**
  byte on any platform (assert on raw bytes).
- The Windows `CueSync` target links **no** AppKit/AVFoundation/Compression symbols
  (all Apple-only APIs are `#if`-guarded); a `grep`/nm check finds none.
- Preferences (theme, section order, collapsed sections, side-by-side, force-Y-zero,
  section columns) persist across a quit/relaunch on Windows.
- Menu items and their shortcuts exist on Windows (Ctrl-based equivalents of the macOS ⌘
  shortcuts) and invoke the same actions.
- Loading a WAV/AIFF on Windows auto-fills track duration; loading mp3/flac/m4a falls
  back to the manual duration modal (no crash, no wrong value).
- The existing macOS Xcode build (`CueSync.xcodeproj`) still builds and behaves as before
  (logic files compile under the new `#if` guards).
- Any screen that cannot be reproduced 1:1 on the Windows backend is listed in the PR
  with the concrete visual/interaction delta (see risks §D 18/24/25).

---

## 4. Threat model

**Trust boundary — all imported files are untrusted external input:**

- Rekordbox XML, ShowKontrol `.cue`, Resolume envelope XML, `.cueproj` JSON: parse
  defensively. XML via Foundation `XMLParser`; JSON via `Codable` (reject malformed).
- **Serato audio files** (`SeratoParser`, 748 lines of manual binary GEOB/ID3/RIFF/AIFF
  offset parsing): every offset read must stay behind an explicit bounds guard. The
  parser already guards most reads (e.g. `guard pos + Int(payloadLength) <= stream.count`);
  the port must **preserve all bounds checks** and add one to any raw indexed reader that
  lacks it (`readBigEndianFloat64`/`readBigEndianUInt32` must not index past `count`).
  Malformed input must fail closed (return empty/nil), never crash or read OOB.
- **Engine DJ SQLite DB** (untrusted file): open **read-only** (`SQLITE_OPEN_READONLY`,
  already set); all queries stay parameterised (already the case) — no string-built SQL.
- **Engine DJ zlib blob — decompression-bomb risk:** the uncompressed size is read from
  the **first 4 bytes of the untrusted blob**. Do **not** trust it unbounded. Clamp the
  allocation to a hard maximum (e.g. a few MB, sized to plausible cue data) and cap
  `inflate` output; abort decompression if it exceeds the cap. This applies to both the
  Apple and vendored-zlib paths.
- **Audio files** for duration: header parsing must bound all reads; unknown/oversized
  header fields → give up gracefully and defer to the manual duration modal.

**File output / path handling:**

- Never hardcode `/tmp`, path separators, or `UTType`s. Use Foundation `URL`/`FileManager`
  for all paths; atomic writes for exports (`write(to:atomically:true)`); temp files via
  `url(for:.itemReplacementDirectory,…)` / `NSTemporaryDirectory()`.
- **ShowKontrol `.cue` line endings are `\r`-only and format-significant** — write the
  exact bytes and ensure no platform newline translation turns them into `\r\n`. Verify on
  raw bytes in a test.

**Secrets / credentials:** none. The app has no network, no accounts, no tokens; the
Gumroad licensing code is already removed. No credential or secret crosses any boundary.

**Cryptographically secure primitives:** **none required.** The only "unique" value is the
Resolume envelope `uniqueId` (a timestamp) used purely to distinguish presets in Resolume —
it is not a security token and needs no CSPRNG. No password, key, nonce, or session value
exists in this app. If a future need for unpredictable IDs arises, use `secrets`-equivalent
(`SystemRandomNumberGenerator`), not the current timestamp — but that is out of scope here.

---

## 5. Target platforms

| Platform | Status | Notes |
|----------|--------|-------|
| **macOS (arm64 + x86_64)** | ✅ Supported | Existing `CueSync.xcodeproj` SwiftUI build stays; the SwiftPM/swift-cross-ui build also runs via the AppKit backend. Logic files compile under `#if canImport(Compression/AVFoundation/AppKit)` guards. |
| **Windows x64** | ✅ Primary target | SwiftPM + swift-cross-ui Windows backend. Vendored `CSQLite` + `CZlib` (no system-lib prereqs). Verified on the `windows-latest` CI leg. |
| **Windows ARM64** | ⚠️ Not guaranteed | Vendored C deps (sqlite3, zlib — pure C) compile fine on ARM64. **The gap is the UI backend + toolchain:** swift-cross-ui's Windows backend (WinUI / Windows App SDK + WinRT projections) and the Swift Windows/ARM64 toolchain are not a validated configuration. Flag as best-effort; do not claim ARM64 support without a green ARM64 build. |
| **Linux (x64)** | ✅ Buildable (not a ticket requirement) | `CueSyncCore` is Foundation + vendored C; swift-cross-ui Gtk backend renders the UI. Include only if CI capacity allows. |

**Dependency flagged for Windows-ARM64:** `swift-cross-ui`'s **Windows (WinUI) backend**
and its Windows App SDK / C++-WinRT projection prerequisites — untested on ARM64, and a
possible extra install step even on x64 CI (may require adding a Windows App SDK setup step
to `swift-windows.yml`). `CSQLite` and `CZlib` (vendored C) have **no** ARM64 gap.

**Cannot-reproduce-faithfully call-outs (must appear in the PR):** (1) the SwiftUI
immediate-mode `Canvas` envelope editor (§D 24) — fidelity depends on swift-cross-ui's
drawing surface; (2) `.onHover` button animations (§D 18); (3) the `NonSelectingTextField`
"don't select-all on focus" AppKit nuance (§D 22); (4) drag-to-reorder panels via
`.dropDestination` (§D 15/24) — may become explicit reorder controls if the backend lacks
drag-drop. Each ships as the closest faithful equivalent with the delta documented.
