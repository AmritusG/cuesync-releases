# CUESYNC-7 — Port the FULL Cue Sync UI onto swift-cross-ui (Windows)

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> Faithful port. The Swift source, project structure, and every screen stay. The existing
> SwiftUI/AppKit presentation (`CueSync/CueSync/{App,Views,Theme,Utilities}`, built by
> `CueSync.xcodeproj`) **stays intact and untouched** as the macOS build. This ticket is the
> main body of the incremental re-host that CUESYNC-5/6/6b–6e set up: it replaces the
> intentionally-empty `UI/ContentView.swift` (`Text("CUE SYNC")`) with the real four-section
> UI — Header, Project, Browse & Select Track, Configure Cue Points, Export, Footer — as
> `#if CUESYNC_CROSSUI` widgets under `UI/`, mirroring the macOS view tree and STYLES.md, and
> suppresses the stray console window. **CI proves compile + tests + ship; it CANNOT prove the
> UI looks right.** The authoritative fidelity verdict is Amrit launching the build on the
> clean Windows PC (the GTE pass). This spec is written so a Build Agent can drive Windows +
> macOS CI to green; visual fidelity is explicitly UNVERIFIED until the GTE check.

---

## 0. Verify-first — **blocking, do this before writing any UI code**

Three premises in the ticket body are wrong or incomplete against the branch you are on. Confirm
each yourself in one pass; the plan below depends on the corrected facts, not the ticket's.

1. **"AppState is shared (not AppKit-gated)" — FALSE.** `CueSync/CueSync/App/AppState.swift`
   begins `#if canImport(AppKit)` and imports `SwiftUI` + `Combine`; it is `@Observable`
   (Swift's Observation module). It is **excluded** from *both* SwiftPM targets
   (`Package.swift`: `App` is in the `exclude:` list of `CueSyncCore` and of the `CueSync`
   executable). So on Windows, `AppState` **does not compile and is not linked today**.
   *(Verify: `Package.swift` lines 52–79; `AppState.swift` line 1.)*
2. **The entire `Views/` tree, `Theme/ThemeColors.swift`, `Views/BrandIcons.swift`, and
   `Utilities/FileDialogs.swift` are all `#if canImport(AppKit)`-gated and excluded** — the
   Windows UI layer is empty, not partial. The genuinely cross-platform, already-shared layer
   is **`CueSyncCore`** (`Models`, `Parsers`, `Exporters`, `Support`), which the 179+ tests
   already exercise on `windows-latest`. `Support/FileDialogs.swift` (string-extension API,
   `#else → nil` seam) and `Support/AudioDuration.swift` (pure-Swift WAV/AIFF probing,
   `#if canImport(AVFoundation)` fallback) are the two neutral seams already built for this
   ticket. *(Verify by reading each file's first line.)*
3. **swift-cross-ui is a SwiftUI-*like* subset, not a drop-in** (pin: `moreSwift/swift-cross-ui`
   `exact 0.8.0`, revision `a6d206370812e3b9edba259d167e848892c5013d`, `SwiftCrossUI` +
   `GtkBackend`). Confirm these API facts from the resolved checkout before relying on them —
   they drive every translation decision (a sibling worktree resolved the source at
   `.build/checkouts/swift-cross-ui/`; the CUESYNC-7 worktree has no `.build/` yet, so run
   `swift package resolve` first, or read the pinned bytes from the sibling checkout):

   | swift-cross-ui 0.8.0 (GtkBackend) | Status | Consequence for this port |
   |---|---|---|
   | `View`/`some View`, `@State`, `@Binding`, `@Environment` | ✅ own wrappers | Structural layout ports ~1:1 |
   | Swift `@Observable` (Observation) | ❌ not the mechanism | Re-host state as SwiftCrossUI `ObservableObject` + `@Published` / `@ObservableObject` macro |
   | `@Environment(Model.self)` app-wide injection | ✅ (model must be `ObservableObject`) | Inject the re-hosted state exactly like the macOS `@Environment(AppState.self)` |
   | VStack/HStack/ZStack/ScrollView/ForEach/Spacer | ✅ | **spacing/padding are `Int`, not CGFloat**; `ForEach` must pass `id:` |
   | `Text/Button/TextField/Toggle/Slider/Picker/Menu` | ✅ | `Picker` is **dropdown-only** on Gtk (other styles `fatalError`) |
   | `Color` (RGBA `Double` init, `.black/.white/.gray`, `.background(Color)`, gradients) | ✅ | Re-host theme with these; keep exact hex values |
   | `.font/.foregroundColor/.padding/.frame/.cornerRadius/.background` | ✅ | Note `.foregroundColor`, **not** `.foregroundStyle` |
   | `.border`, `.overlay`, `.foregroundStyle` | ❌ | Borders/overlays via a stroked `Rectangle`/`RoundedRectangle` inside a `ZStack` |
   | `Path`/`Shape` (Rectangle, RoundedRectangle, Ellipse, Circle, Capsule) rendered on a Cairo `DrawingArea` | ✅ | The envelope curve/grid/points are drawn with `Path` (moveTo/lineTo/cubicCurve/arc/circle, `StrokeStyle`, fill rule) |
   | `Canvas`/`GraphicsContext` (immediate mode) | ❌ | Do **not** plan on `Canvas { ctx in }` |
   | `onTapGesture` (no location), `onHover` (Bool) | ✅ | Tap gives **no coordinate**; hover is a bool |
   | `DragGesture`, pointer position, hit-testing | ❌ | **Canvas drag-to-edit is not portable at 0.8.0** — see §G |
   | Sheets, Alerts, file open/save (`@Environment(\.chooseFile)` + save action), popover menus, `Scene.commands`/`CommandMenu` | ✅ | Duration modal, error alerts, import/export dialogs, menu bar all map |
   | Clipboard | ❌ | N/A — the current Swift `ExportSectionView` has no clipboard action anyway |
   | `Table` on Gtk | ❌ commented out | The cue table uses `List` or `ScrollView`+`VStack`+`ForEach` |
   | SwiftUI `Layout` protocol (`FlowLayout`) | ❌ | Wrapping button rows become fixed HStack/VStack groups |
   | SF Symbols `Image(systemName:)`, `NSImage`-rendered SVG (`BrandIcons`) | ❌ | Icons re-hosted as brand-colored buttons with labels + simple `Path`/text glyphs |

4. **Re-establish the test baseline `N` empirically** — run `swift test -c release`
   (`CueSyncCoreTests`) and record the count. Do **not** trust the ticket's "179"; CUESYNC-6d
   established the real number (~245). `N` is the floor for §3.

5. **Confirm the console-window fix surface.** CI builds via `swift build -c release` →
   `.build/release/CueSync.exe`, then bundles GTK4 DLLs next to it, then runs the `wldd`
   closure check (`.github/workflows/swift-windows.yml`). The console window is suppressed by
   linking the exe for the Windows GUI subsystem — a `Package.swift` linker setting, **not** a
   workflow change. `Package.swift` is not an AppKit-gated file and is in scope to edit.

6. **Correction found while implementing §B (not one of premises 1–3, but the same category —
   a plan-level assumption that's false on this branch): `CueSyncCore`'s Models/Parsers/
   Exporters/Support types are all `internal` (Swift's default), not `public`.** SwiftPM module
   boundaries mean `internal` is invisible outside its own target — unlike the Xcode build,
   where `App/AppState.swift` compiles directly alongside these files in one module. A plain
   `import CueSyncCore` from the `CueSync` (swift-cross-ui) executable target therefore cannot
   see `Track`, `CuePoint`, `Project`, `RekordboxParser`, etc. at all — confirmed empirically:
   `UI/State/AppState.swift` failed to compile with "cannot find 'Track' in scope" etc. until
   the exact symbols §B.3 requires (`Track`, `Playlist`, `CuePoint` + its memberwise `init`,
   `Project` + a hand-written public memberwise `init` alongside its existing `init(from:)`,
   `ParseError` — already `internal`-shimmed for the same cross-target reason, just not yet
   `public` — `RekordboxParser`/`ShowKontrolParser`/`SeratoParser`/`EngineDJParser`/
   `ResolumeParser` + `ResolumeExporter`/`ShowKontrolExporter`, and `Hex.parseCSSColor`) were
   marked `public`. This **replaces** §3's "`CueSyncCore/Support/` (parser only)" scope note —
   the actual footprint is `Models/`, `Parsers/`, `Exporters/`, and `Support/Hex.swift`, every
   edit additive (`internal` → `public`, plus one hand-written `Project` init; no behavior
   changed). It also **replaces** the pre-existing `PortComplianceTests
   .testNoPublicDeclarationExistsInCueSyncCoreScopedSources` (added by CUESYNC-6 §B.13, whose
   own failure message said "widening the surface belongs to the ticket that consumes it" —
   this ticket) with `testCueSyncCorePublicSurfaceMatchesTheDocumentedAllowlist`, an explicit
   allowlist of the exact lines this ticket exposes, so an *unintended* future widening still
   fails the build.

7. **Ticket-body scope item — "Add a `text_tools` module with `slugify()` and a secure
   `generate_token()` helper" — REJECTED as out of scope for this faithful port; do not build
   it.** Recorded here (rather than silently dropped) so the decision is explicit and auditable:
   - **Language / idiom mismatch.** `text_tools` / `slugify` / `generate_token` are Python-shaped
     names; this is a Swift app and the strategy is *faithful-native* — "a Swift app stays Swift;
     do not rewrite in another language." There is no Python target to add a module to, and
     inventing a Swift module to satisfy the phrasing would be building to the wording, not the need.
   - **Not required by the platform.** The faithful-port mandate is "only change what the target
     platform requires; keep all non-UI code intact." Windows needs the UI re-host (§A–§M) and
     nothing else; a slug/token helper is new, unrequested behavior, i.e. gold-plating.
   - **No caller.** The app constructs no filenames from untrusted names — exports go to a
     user-chosen path via the save dialog (§H, §J.23) — and already mints identifiers with `UUID()`
     where *uniqueness*, not unpredictability, is the requirement. `slugify()`/`generate_token()`
     would be dead code with no call site anywhere in the macOS reference or the port.
   - **Contradicts the reasoned security stance.** §4 deliberately concludes **no cryptographically
     secure primitive is required or introduced** by this ticket, and warns a "secure token" must
     not be presented as a security control here. Adding a `generate_token()` "secure helper" would
     manufacture exactly the false security signal §4 rules out.
   - **If a real need surfaces later** (e.g. a Windows-safe *default* export filename derived from
     the preset name — a legitimate cross-platform concern, since `< > : " / \\ | ? *`, trailing
     dots/spaces, and reserved device names like `CON`/`NUL`/`COM1` are illegal on Windows), it
     belongs in its own ticket with a stated use case, implemented in Swift under
     `CueSyncCore/Support/` (`Foundation`/`pathlib`-equivalent APIs, never a hardcoded separator),
     using `SystemRandomNumberGenerator` (Swift's cross-platform CSPRNG) **only** where
     unpredictability is genuinely required — not merged into this UI-port ticket.

If any of premises 1–3 is false on your branch, stop and report — the plan assumes the
corrected facts. (Premises 1–3 all held; §0.6 documents a 4th correction found once implementation
started; §0.7 records a ticket-body scope item deliberately rejected as out of scope.)

---

## 1. Problem

On a clean Windows PC, CUE SYNC now launches (CUESYNC-5/6/6b–6e landed the swift-cross-ui
dependency, the `GtkBackend`, the self-contained GTK4 bundle, and green Windows + macOS CI) but
the window is empty save a placeholder `Text("CUE SYNC")` and a stray console/debug window opens
beside it. The whole UI — header, the four workflow sections (Project, Browse & Select Track,
Configure Cue Points, Export), and footer — lives in SwiftUI behind `#if canImport(AppKit)` and
compiles to nothing off Apple; even `AppState` and `ThemeColors` are AppKit-gated and excluded
from the Windows build. So the engine runs on Windows with no usable interface. This ticket
ports the real UI: it re-hosts every screen as `#if CUESYNC_CROSSUI` widgets under `UI/`,
mirroring the macOS view tree, labels, order, and STYLES.md palette; re-hosts the observable
state and theme onto swift-cross-ui's own `ObservableObject`/`Color` (the AppKit originals are
off-limits and use Apple-only observation) while reusing the shared `CueSyncCore` for all
parsing, exporting, and models; renders the envelope as a `Path`-drawn visualization bound to
state (with editing through the cue table, since 0.8.0 exposes no drag/pointer API); replaces
absolute placement with real layout containers so the `gtk_widget_measure()` warning from issue
#1 disappears; and links the executable for the Windows GUI subsystem so no terminal opens. The
user-facing outcome: a DJ on Windows opens CUE SYNC and sees the actual four-step app — not a
blank window and not a console — bound to the same engine the Mac app uses. What "looks right"
is confirmed by Amrit on the clean PC, not by CI.

---

## 2. Plan

All paths relative to repo root; existing sources live in `CueSync/CueSync/`. Every new file is
`#if CUESYNC_CROSSUI … #endif` and lives under `CueSync/CueSync/UI/` (the executable target's
`sources: ["UI"]` globs subdirectories, so **no `Package.swift` file listing is needed** for new
UI files). Do **not** edit any `#if canImport(AppKit)` file — read them only as the behavioral
reference. Push after each section compiles so CI stays green incrementally (§M).

### §A. Manifest: suppress the console window (the only `Package.swift` change)

1. Add `linkerSettings` to the `CueSync` executable target that link it for the Windows GUI
   subsystem, guarded to Windows so macOS/Linux are unaffected:
   ```swift
   linkerSettings: [
       .unsafeFlags(
           ["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
           .when(platforms: [.windows])
       )
   ]
   ```
   `/SUBSYSTEM:WINDOWS` stops the console from opening; `/ENTRY:mainCRTStartup` keeps Swift's
   C-runtime `main` entry (without it, `/SUBSYSTEM:WINDOWS` makes link.exe look for `WinMain`
   and fail). **Verify on CI** — this is a Windows-linker behavior unobservable locally; if the
   flag pair doesn't link, iterate against the actual `Build (release)` log, not from memory.
2. Change nothing else in `Package.swift` — not the pin, not the excludes, not `CueSyncCore`.
   Do not add per-file `sources`; the `UI` directory glob already covers new subfolders.

### §B. Re-host the shared foundation under `UI/` (state + theme + color parsing)

The macOS `AppState` and `ThemeColors` are AppKit-gated, excluded, and off-limits; and
swift-cross-ui does not use Swift's `@Observable`. So re-host them, reusing `CueSyncCore` for all
logic — this is a genuine platform requirement (the same reason the views are re-hosted), not a
gold-plated fork. Keep method names, signatures, and behavior identical to the macOS originals so
the two never diverge in meaning.

3. **`UI/State/AppState.swift`** — a SwiftCrossUI `ObservableObject` (use the `@ObservableObject`
   macro or `@Published` on every stored var) mirroring `App/AppState.swift`'s property and
   method surface: project fields, library (`tracks`/`playlists`), browse (`selectedPlaylistId`,
   `searchQuery`, `sortBy`, `expandedFolders`), envelope (`cuePoints`, `trackDuration`,
   `presetName`, `selectedPointIndex`, `lockXAxis`/`lockYAxis`, `forceYZeroOnImport`), UI state
   (`theme`, `collapsedSections`, `sectionOrder`, `sideBySideMode`, `sectionColumns`),
   unsaved-changes dialog fields, and the full undo/redo stack. Port the methods **verbatim in
   behavior** — `selectTrack`, `createBlankEnvelope`, `addCuePoint`, `duplicateSelectedWithOffset`,
   `removeSelectedPoint`, `updateCuePoint(at:)`, `updateCuePointSilently(at:)`, `pushUndoSnapshot`,
   the `load*` importers, `saveProject`/`loadProject`, `updateDurationWithScaling`, `newProject`,
   `confirm*`/`executePendingAction`, `ensureStartAndEndPoints`, `safeDuration`, `filteredTracks`,
   `xmlPreview`, preferences load/save — delegating to the shared `RekordboxParser`,
   `SeratoParser`, `EngineDJParser`, `ShowKontrolParser`, `ResolumeParser`, `ResolumeExporter`,
   `ShowKontrolExporter`, `Project`, `CuePoint`, `AudioDuration`, and `CurveType` in `CueSyncCore`.
   **Preserve every input-sanitization guard** — `CuePoint.sanitized()`, `AppState.safeDuration`,
   `ensureStartAndEndPoints`, the finite/clamp checks — so a hostile file cannot produce NaN
   geometry on Windows any more than on macOS (§4).
   - `import Combine` is not available on Windows — do not carry it over. Preferences use
     `Foundation.UserDefaults` (cross-platform); keep the same keys.
     `// PORT:` note where a macOS-only detail (e.g. `ISO8601DateFormatter`) needs a Foundation
     equivalent — verify it exists on the Windows toolchain before relying on it.
4. **`UI/Theme/ThemeColors.swift`** — re-host `AppTheme` and `ThemeColors` with SwiftCrossUI
   `Color`, using the **exact** STYLES.md hex values (dark default: Background `#0a0a0f`, Section
   BG `#14141e`, Surface `#1a1a2e`, Accent Green `#1ed760`, Pink `#ef288a`, Gold `#ffd700`, Teal
   `#5de4c7`, Blue `#0068a9`, Mint `#5bd29f`, and the text/border tokens; light theme per the
   table). Reproduce the computed contextual colors (`inputBg`, `buttonBg`, `canvasBg`,
   `gridColor`, `tableHeaderBg`, `stepperDivider`, …) with the same `isDark ? … : …` logic. Do
   **not** carry the `NSColor.fromCSSString` extension.
5. **`UI/Theme/ColorParsing.swift`** — a pure-Swift `#hex` / 3-digit-hex / `rgb(r,g,b)` → `Color`
   parser replacing `Color(cssString:)` (used by the canvas and cue table for per-cue colors).
   Reuse `Support/Hex.swift` if it already decodes hex; keep the same accent-green fallback for
   malformed input. **This parser is pure and testable** — place its hex/rgb→`(r,g,b)` core in
   `CueSyncCore/Support/` so `CueSyncCoreTests` can unit-test it (the `Color` wrapper stays in
   `UI/`), and add tests for `#1ed760`, `#abc`, `rgb(30, 215, 96)`, and a malformed string.

### §C. Header + Footer

6. **`UI/HeaderView.swift`** — mirror `Views/HeaderView.swift`: `HStack` with the logo (◈ / `CUE`
   white / `SYNC` accent-green via three `Text`), the tagline `Text` (exact string + `•`/`→`
   glyphs from the source — do not invent), `Spacer()`, project-name `Text` (bound to
   `state.projectName`, dim), and the version badge (`Text` in a rounded, accent-tinted box —
   built as a `ZStack` of a `RoundedRectangle` background/stroke behind the `Text`, since
   `.overlay`/`.border` are absent). Bind the unsaved indicator to `state.hasUnsavedChanges`.
   `// PORT:` for `LinearGradient` header background (use flat `sectionBG` if gradient proves
   fiddly) and `.tracking` letter-spacing (drop if unsupported).
7. **`UI/FooterView.swift`** — mirror `Views/FooterView.swift`: full-width `HStack` of the exact
   footer strings/glyphs on `colors.footerBg`, with the top hairline as a thin `Rectangle` in a
   `ZStack`.

### §D. Section container + collapsible wrapper + grid background

8. **`UI/CollapsibleSection.swift`** — a generic wrapper mirroring `Views/CollapsibleSection.swift`
   minus the drag-reorder: `VStack(spacing: 0)` of a header `Button` (toggles membership in
   `state.collapsedSections`) containing the step-number badge (accent-green rounded box + number
   `Text`), the uppercase title, an optional `trailing` view, and a ▶/▼ collapse glyph `Text`;
   below it, when expanded, a hairline `Rectangle` divider and the padded content. Section frame:
   `colors.sectionBG` background, `cornerRadius(10)`, and a stroked-`RoundedRectangle` "border" in
   a `ZStack` (no `.border`). **Omit** `.draggable`/`.dropDestination` reordering and the
   hover/opacity/animation — `// PORT:` note; section order stays the fixed logical order.
9. **`UI/ContentView.swift`** — replace the placeholder body with the real shape:
   `VStack(spacing: 0) { HeaderView(); ScrollView { … sections … }; FooterView() }` on
   `colors.background`. Sections render in `state.sectionOrder` (default `project, browse,
   configure, export`) each wrapped in `CollapsibleSection` with step numbers 1–4 and the
   Configure trailing "`active/total points active`" label. Support `state.sideBySideMode` as an
   `HStack` of two `VStack` columns (button-toggled in Project; **not** drag) or single-column
   otherwise. The subtle green `GridOverlay` becomes a `Path`-drawn grid on a `DrawingArea` behind
   the content in a `ZStack` at ~3% opacity, or **`// PORT:`-deferred** if it complicates layout —
   it is cosmetic and must not reintroduce fixed positioning. **Use only VStack/HStack/ZStack +
   `.frame`; never `GtkFixed`/absolute coordinates** (that is the measure-warning cause the DoD
   forbids).

### §E. Project section (`UI/Sections/ProjectSectionView.swift`)

10. Mirror `Views/Sections/ProjectSectionView.swift`, replacing the SwiftUI `Layout`/`FlowLayout`
    with fixed HStack/VStack groups (`// PORT:` for wrapping): the labelled column groups —
    **Project** (New/Open/Save buttons), **Project Name** (`TextField` bound to
    `state.projectName`), **Design from Scratch** (Create Envelope, gold), **Import Envelope**
    (Resolume, teal), **Import Cues** (Rekordbox / Serato / Engine DJ / ShowKontrol) — then the
    **Viewport** (Reset, Side-By-Side toggle → `state.sideBySideMode` + `savePreferences`),
    **Theme** (Dark/Light → `state.theme`), and **Import Settings** (`forceYZeroOnImport`
    True/False) rows, and the "✓ N tracks loaded" indicator.
11. Import/open/save wiring uses swift-cross-ui's file dialog actions (§J), calling the re-hosted
    `state.loadRekordbox/loadSerato/loadEngineDJ/loadShowKontrol/loadResolumeEnvelope/loadProject/
    saveProject`. ShowKontrol and Resolume imports (no embedded duration) present the Duration
    modal (§I) before committing, exactly as macOS does. Serato is multi-select (the macOS code
    uses a raw `NSOpenPanel`); use the multi-select variant of `chooseFile`.
12. Error and unsaved-changes flows use `Alert` (§0 table). Keep the destructive/cancel
    semantics of `confirmNewProject`/`confirmAction`/`executePendingAction`.

### §F. Browse & Select Track section (`UI/Sections/BrowseSectionView.swift`)

13. Mirror `Views/Sections/BrowseSectionView.swift`: empty-state message when `tracks.isEmpty`;
    otherwise an `HStack` of the **playlist sidebar** (a `ScrollView`+`VStack`: "All Tracks" row
    then a recursive `ForEach` over `state.playlists` with folder expand/collapse driven by
    `state.expandedFolders`, depth indentation via leading padding, and count badges) and the
    **track list** (search `TextField` bound to `state.searchQuery`; Sort `Picker` `.menu` bound
    to `state.sortBy` over `SortField.allCases`; a `ScrollView`+`ForEach` over
    `state.filteredTracks` of track rows showing name / artist•album / bpm•key•cues / duration;
    "Showing X of Y" footer). Row tap → selection (`state.selectedPlaylistId`,
    `state.selectTrack`). Hover highlight via `onHover` bool. Replace SF-Symbol chevrons/emoji
    with the source's emoji glyphs (portable) or simple text markers.

### §G. Configure Cue Points section — the hard part

14. **`UI/Sections/EnvelopeCanvasView.swift`** — render the envelope as a **read-only `Path`
    visualization** bound to state (there is no `Canvas` and, critically, **no drag/pointer API**
    at 0.8.0). Give the drawing a fixed intrinsic frame (`.frame(minHeight: 200)` /
    `.aspectRatio` — a measured widget, not `GtkFixed`) on `colors.canvasBg`. Reproduce the macOS
    drawing math from `Views/Sections/EnvelopeCanvasView.swift`: the same margins/graph rect, the
    10×4 grid, the axis labels, the fill area under the curve, the per-segment eased curve
    (`CurveType.evaluate(curve, t:)`, keyed off the destination point), and the point circles
    (normal / selected-larger / disabled-gray) with per-cue color via §5's parser and the Y-value
    / curve-name labels. Coordinate mapping (`ptX`/`ptY`) is identical. **Guard `duration > 0`
    and clamp all normalized values to `[0,1]`** so no non-finite coordinate reaches Cairo (§4).
    - **Deferred (`// PORT:` + flag for GTE punch-list):** click-to-add, click-to-select, and
      drag-to-move on the canvas — all require pointer coordinates 0.8.0 does not expose, and
      overlaying tappable handles at pixel offsets would demand the forbidden absolute
      positioning. All point creation/selection/editing therefore routes through the toolbar and
      cue table (below), which is already a complete editor in the macOS app. Note this is the
      single largest fidelity delta and the most likely follow-up-ticket item.
15. **`UI/Sections/CuePointsTableView.swift`** — mirror `Views/Sections/CuePointsTableView.swift`
    using `List` or `ScrollView`+`VStack`+`ForEach(cuePoints, id: \.id)` (no `Table` on Gtk):
    header row of column labels, then per-cue rows with an **enable** `Toggle` (checkbox style),
    a **color** dot (`Circle().fill` via §5 parser; the `ColorPicker` popover is Apple-only —
    `// PORT:` to a simple hex `TextField` or defer color editing), an **editable name**
    `TextField`, **Position** and **Y** `StepperField`s (§J) writing through
    `state.updateCuePoint(at:)`, a read-only **X** `Text`, and an **Interpolation** `Picker`
    `.menu` over `CurveType.all`. **Row tap selects** (`state.selectedPointIndex`) — this is the
    canvas's selection substitute. `ScrollViewReader`/`scrollTo` is unconfirmed at 0.8.0 —
    `// PORT:` if absent.
16. **`UI/Sections/DurationInputView.swift`** — mirror the inline duration editor: label
    (ENVELOPE LENGTH / TRACK DURATION per `selectedTrackId`), sec + ms `StepperIntField`s, and
    the "= N.NNNs" total, writing through `state.updateDurationWithScaling`.
17. **`UI/Sections/ConfigureSectionView.swift`** — assemble: the track-info bar, the toolbar
    (`DurationInputView`, Cue Position steppers, Add Cue button → `state.addCuePoint`, the offset
    tool → `state.duplicateSelectedWithOffset`, optional Load-Audio using `AudioDuration` from
    `CueSyncCore` instead of AVFoundation), the Lock X / Lock Y `Toggle`s (checkbox style) bound
    to `state.lockXAxis`/`lockYAxis`, the `EnvelopeCanvasView`, and the `CuePointsTableView`.
    Delete-selected via a Remove button (`.onKeyPress(.delete)` is `// PORT:`-optional).

### §H. Export section (`UI/Sections/ExportSectionView.swift`)

18. Mirror `Views/Sections/ExportSectionView.swift`: empty-state when no cues; otherwise the
    Preset-name `TextField` (bound to `state.presetName`), a **Save XML** button, and a **Save
    ShowKontrol .cue** button. Wire both to the save-file dialog (§J) writing
    `state.xmlPreview` / `ShowKontrolExporter.generate(cuePoints:)` via
    `String.write(to:atomically:encoding:)` (Foundation, portable). The macOS Swift source has
    **no clipboard action**, so none is added (clipboard is unavailable at 0.8.0 anyway).
    Optionally show the XML preview `Text` (read-only, monospaced) as in STYLES.md.

### §I. Duration modal (`UI/Sections/DurationInputModal.swift`)

19. Mirror `Views/Sections/DurationInputModal.swift` as **Sheet** content (swift-cross-ui sheets
    exist): title, instruction, min/sec/ms `TextField`s, Cancel + Import buttons calling the
    `onCancel`/`onConfirm` closures passed from Project (§E). Present via the sheet API rather
    than SwiftUI `.sheet`.

### §J. Custom controls + file dialogs

20. **`UI/Controls/StepperField.swift`** — re-host `StepperField` (Double) and `StepperIntField`
    (String) as a `TextField` + up/down `Button`s in an `HStack`, keeping the numeric parsing,
    clamping, `isFinite` guard, and overflow-safe Int handling from
    `Views/Sections/StepperField.swift`. Chevron glyphs → simple `Text("▲")`/`Text("▼")`.
21. **`UI/Controls/HoverButton.swift`** — a plain `Button` whose background/foreground swap on the
    `onHover` bool (the string-`Color.description`-`.contains("green")` hack in the macOS file
    does not port; pass explicit colors). Drop `scaleEffect`/`brightness`/animation (`// PORT:`).
22. **`UI/Controls/BrandButtons.swift`** — reproduce the import buttons by **brand color + label**
    (the primary fidelity signal per STYLES.md's Import-Buttons table) with a simple `Path`- or
    text-glyph icon. The `NSImage`-rendered SVGs are Apple-only; the inline SVG XML strings are
    portable *data* a later ticket can rasterize — `// PORT:` note; do not block this ticket on
    pixel-accurate brand icons.
23. **`UI/Support/FileDialogsCrossUI.swift`** (or inline at call sites) — a thin helper over
    swift-cross-ui's `@Environment(\.chooseFile)` (async, multi-select variant for Serato) and the
    save-destination action, returning `URL`s handed straight to the `CueSyncCore` parsers/
    exporters. Build filter options from plain extension strings (no `UTType`, which is
    Apple-only). Leave `Support/FileDialogs.swift` as-is; the CrossUI views use this helper.

### §K. App wiring + menu commands

24. **`UI/CueSyncApp.swift`** — keep the `WindowGroup("CUE SYNC")` title and 1200×800 default
    (per the ticket, already correct). Create the re-hosted `AppState` once (e.g.
    `@State private var state = AppState()`), call `state.loadPreferences()` at launch, and
    inject it with `.environment(state)` so every view reads `@Environment(AppState.self)`.
25. Add menu commands via `Scene.commands`/`CommandMenu` where GtkBackend supports them: New/Open/
    Save/Export/Undo/Redo. Keyboard shortcuts "where the toolkit allows" — `// PORT:` any that
    Gtk cannot bind. Do **not** import AppKit for this.

### §L. Consolidated deferral list (leave a `// PORT:` at each site — never drop silently)

Envelope canvas drag/click-to-add/select · section drag-reorder · SVG/SF-Symbol pixel-accurate
icons · `ColorPicker` popover · animations/`scaleEffect`/`brightness`/`.shadow`/`.tracking` ·
`LinearGradient` section/header backgrounds (approximate with flat color) · `ScrollViewReader`
auto-scroll · `.help` tooltips · `.onKeyPress` deletion. Each is a known fidelity delta for
Amrit's GTE punch-list, not a silent reduction.

### §M. CI, tests, and the self-contained bundle

26. **Keep both legs green at every push.** After each section compiles, push and read the run.
    Windows `Build (release)` + `Test`, macOS `swift build -c release` + `Test`, and
    `xcodebuild -scheme CueSync build` must all stay green. The GtkBackend build already works on
    Windows (that was CUESYNC-6/6e's result); do not disturb the swift-java symlink repair, the
    gvsbuild GTK4 acquisition + SHA gate, the DLL bundling step, or the `wldd` closure check +
    negative control.
27. **Do not regress tests.** `swift test -c release` count stays `≥ N` (§0.4); no test is added
    to pass, deleted, skipped, `XCTSkip`-ed, commented out, or weakened. Add the §5 color-parser
    unit tests to `CueSyncCoreTests` (pure logic in `CueSyncCore/Support/`).
28. **Guard the platform split.** No file under `UI/` may `import AppKit`, `import SwiftUI`,
    `import UniformTypeIdentifiers`, `import AVFoundation`, or `import Combine`, or reference an
    `NS`-prefixed AppKit symbol — a machine-checkable proxy for "all Windows UI is
    `CUESYNC_CROSSUI` and toolkit-correct." Recommend a lightweight `grep` guard step in the
    Windows workflow (fails the job on a match); if adding a workflow step is deemed out of scope,
    at minimum verify it by hand before each push.

---

## 3. Acceptance criteria

**Machine-checkable (these become the CI gate / tests):**

- `swift build -c release` is green on `windows-latest` **and** `macos-latest`.
- `xcodebuild -scheme CueSync build` is green on macOS (the SwiftUI/AppKit product is untouched).
- `swift test -c release` (`CueSyncCoreTests`) is green with count `≥ N` (§0.4); no test is
  removed, skipped, or weakened. New pure color-parser tests (`#1ed760`, `#abc`,
  `rgb(30, 215, 96)`, malformed → accent-green fallback) pass.
- `UI/ContentView.swift`'s body is the real `VStack { HeaderView; ScrollView{sections}; FooterView }`
  tree — it no longer resolves to a bare `Text("CUE SYNC")`.
- Four section views (`ProjectSectionView`, `BrowseSectionView`, `ConfigureSectionView`,
  `ExportSectionView`) plus `HeaderView`, `FooterView`, `CollapsibleSection`,
  `EnvelopeCanvasView`, `CuePointsTableView`, `DurationInputView`, `DurationInputModal`, and the
  re-hosted `AppState` + `ThemeColors` exist under `UI/`, all `#if CUESYNC_CROSSUI`, all bound to
  the re-hosted `AppState`.
- No file under `UI/` imports `AppKit`/`SwiftUI`/`UniformTypeIdentifiers`/`AVFoundation`/`Combine`
  or references an `NS`-prefixed AppKit symbol (§M.28 grep).
- `Package.swift` carries `/SUBSYSTEM:WINDOWS` + `/ENTRY:mainCRTStartup` on the `CueSync`
  executable target under `.when(platforms: [.windows])`, and no other manifest change (no pin,
  exclude, or `CueSyncCore` edit).
- No AppKit-gated file (`App/`, `Views/`, `Theme/`, `Utilities/`) is modified — `git diff`
  touches only files under `UI/`, `Package.swift`, `CueSyncCore`'s `Models/`, `Parsers/`,
  `Exporters/`, and `Support/Hex.swift` (widening `internal` → `public` only — see §0.6 — plus
  `PortComplianceTests.swift`'s allowlist update for the same reason), the spec, and
  (optionally) the workflow guard step.
- The GTK4 DLL bundling step and the `wldd` closure check + its negative control still pass on
  `windows-build`.
- No swift-cross-ui `fatalError` path is invoked (e.g. only `Picker` `.menu` is used; no `Table`
  on Gtk; no unsupported `PickerStyle`).

**GTE-visual — UNVERIFIED by CI, requires Amrit's clean-PC pass (state so in the handoff):**

- Header, the four sections, and footer render as real widgets matching the macOS structure,
  order, labels, and the STYLES.md palette/spacing.
- The envelope curve, grid, fill, and points render from state and update as the table/steppers
  edit cue points.
- **No stray console/debug window** opens beside the app (the `/SUBSYSTEM:WINDOWS` result).
- **No `gtk_widget_measure()` warning** (issue #1) — proper layout containers, no `GtkFixed`.
- The self-contained bundle still runs on a clean Windows PC.
- The handoff explicitly flags the §L deferrals (canvas drag-edit foremost) as the follow-up
  punch-list.

---

## 4. Threat model

This is a UI re-host; it adds a Windows presentation and file-dialog wiring around **already-
shared, already-hardened** `CueSyncCore` parsers/exporters. No network, no server, no IPC, no
new file format.

**Inputs crossing a trust boundary**

| Input | Boundary | Control |
|---|---|---|
| User-selected import files — Rekordbox `.xml`, ShowKontrol `.cue`, Resolume `.xml`, Serato audio (`.mp3/.wav/.aiff/.flac/.m4a`), Engine DJ `.db` (SQLite), and `.cueproj` JSON | Windows file chooser → `CueSyncCore` parsers | Parsing is unchanged shared code already exercised by the ~245 tests on Windows and hardened against hostile input (bounded chunk reads in `AudioDuration`, `SeratoParser`, SQLite via vendored amalgamation, `finiteOrNil`, XML/JSON decoding). This ticket adds **no new parsing** — only the dialog→parser wiring. |
| A hand-edited / malicious `.cueproj` or import file carrying negative/huge/NaN cue values or a bad duration | file → re-hosted `AppState` → `Path`/Cairo geometry | The re-host **must** keep every macOS guard: `CuePoint.sanitized()` on load/edit, `AppState.safeDuration` clamping duration finite/positive/Int-safe, `ensureStartAndEndPoints`, and the canvas's `duration > 0` guard + `[0,1]` clamp on normalized coordinates. A non-finite value must never reach Cairo (it would draw garbage or trap a downstream `Int(...)`). Dropping any clamp during the re-host is the one real regression risk here — call it out and verify. |
| The `/SUBSYSTEM:WINDOWS` + `/ENTRY:mainCRTStartup` linker flags | build time only | Static, no runtime input; affects only how the exe is linked on Windows. Guarded `.when(platforms: [.windows])` so macOS/Linux are untouched. |

**Secrets / credentials:** none. No API keys, tokens, keychain, `secrets.*`, or auth. No
environment is read or logged. Nothing is sent anywhere — file writes go only to the user-chosen
save path.

**Cryptographically secure primitives:** none required and none introduced. The re-hosted
`AppState` mints cue-point IDs with `UUID()` (Foundation) — these are **local identifiers, not
security tokens**; uniqueness, not unpredictability, is the requirement, so no CSPRNG is needed
and none must be presented as a security control. No nonces, hashes, or randomness are added by
this ticket. (The existing `wldd` download's SHA-256 gate in CI is unrelated and untouched.) This
is also why the ticket-body "secure `generate_token()` helper" was rejected in §0.7: introducing a
"secure token" with no unpredictability requirement and no caller would fabricate a security signal
this app does not have. Should a future ticket genuinely need unpredictability, use Swift's
cross-platform CSPRNG (`SystemRandomNumberGenerator`), not a timestamp or `Int.random` seed.

**Portability:** no `/tmp`, path separator, or line-ending literal is hardcoded in new code —
paths come from swift-cross-ui's file dialogs as `URL`s and are handled with Foundation `URL`/
`String(contentsOf:)`/`write(to:)`. The ShowKontrol `\r` line ending is a **file-format**
requirement living in `CueSyncCore`'s exporter (unchanged), not a path/OS assumption. Spacing
values must be `Int` (swift-cross-ui), not CGFloat.

---

## 5. Target platforms

| Platform | Status after this ticket | Notes |
|---|---|---|
| **macOS** (arm64 / x64) | ✅ Shipping, unaffected | The SwiftUI/AppKit app built by `CueSync.xcodeproj` remains the macOS product and is not touched (all `#if canImport(AppKit)` files read-only). `swift build -c release` and `xcodebuild -scheme CueSync build` stay green; the new `UI/` code is `#if CUESYNC_CROSSUI` and not compiled by Xcode. |
| **Windows x64** | ✅ The platform this ticket delivers | The real four-section UI renders via `SwiftCrossUI` + `GtkBackend` on the gvsbuild GTK4 (x64) runtime, console suppressed via `/SUBSYSTEM:WINDOWS`, self-contained bundle intact. **Envelope drag-editing is the known fidelity gap** (0.8.0 exposes no drag/pointer API) — editing is via the cue table; flagged for the GTE punch-list. |
| **Windows ARM64** | ➖ Not supported; **no new gap introduced here** | Blocked by the pre-existing gvsbuild-GTK4-is-x64-only narrowing (CUESYNC-6d) and the absence of a hosted GitHub Actions Windows-ARM64 runner. `SwiftCrossUI`/`GtkBackend` and all new UI code are architecture-neutral Swift; only the bundled GTK4 runtime is x64. This ticket adds no ARM64-specific limitation — it would work the moment an ARM64 GTK4 runtime and runner exist. |
| **Linux** | ➖ Not targeted | `GtkBackend` makes Linux the most plausible future target (it is Gtk's native home), and the new `#if CUESYNC_CROSSUI` UI would largely compile there, but no Linux CI leg exists and this ticket adds none. |

**Dependency lacking Windows-ARM64 support:** the **gvsbuild GTK4 runtime** (x64-only, per
CUESYNC-6d) — the same pre-existing constraint, not a new one. swift-cross-ui `GtkBackend` itself
is architecture-neutral.
</content>
</invoke>
