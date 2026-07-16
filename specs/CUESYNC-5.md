# CUESYNC-5 — Re-host the UI on swift-cross-ui, step 1: dependency + app shell

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> Faithful port. Keep the Swift source and layout. The existing SwiftUI/AppKit presentation
> (`CueSync/CueSync/{App,Views,Theme,Utilities}`, built by `CueSync.xcodeproj`) **stays intact
> and untouched** as the macOS build. This ticket is the **first** of an incremental,
> one-screen-at-a-time re-host: it lands the `swift-cross-ui` dependency, establishes the
> `CUESYNC_CROSSUI` platform split, and gets **the app shell plus an intentionally empty
> ContentView** building on macOS **and** Windows. No CUE SYNC screen is ported in this
> ticket — `ProjectSectionView`, `BrowseSectionView`, `ConfigureSectionView`,
> `ExportSectionView`, the envelope canvas, and the menu commands are **later tickets**.
> Definition of Done: `swift build -c release` green on `macos-latest` **and**
> `windows-latest`, `swift test` still green on both, and `xcodebuild -scheme CueSync build`
> still green on macOS.

---

## 1. Problem

CUE SYNC's logic layer is already portable — `CUESYNC-4` landed a SwiftPM package whose
`CueSyncCore` target builds parsers, exporters, models and the `Support/` shim on Windows,
with the full test suite green on `windows-latest`. But the app a DJ actually runs is still
macOS-only: every screen lives in SwiftUI behind `#if canImport(AppKit)`, and the SwiftPM
executable target `CueSync` is a placeholder whose `UI/main.swift` does nothing but
`print("CueSync core loaded")`. There is a working engine on Windows and no window to put it
in. This ticket lays the foundation for the UI re-host without touching a single existing
screen: it adds `swift-cross-ui` as a pinned dependency, splits the presentation layer on a
`CUESYNC_CROSSUI` compile-time flag so the SwiftUI path keeps serving Apple untouched while a
new `UI/` path compiles everywhere else, and replaces the `print` stub with a real
application that opens a real, correctly-titled, correctly-sized window containing an empty
ContentView. The user-facing outcome is deliberately modest and deliberately verifiable: on
Windows, CUE SYNC opens a window for the first time; on macOS, nothing changes at all.

---

## 2. Plan

All paths are relative to the repo root. Existing sources live in `CueSync/CueSync/`.

### §0. Verify and pin the dependency — **blocking, do this first**

This planning pass had **no network access**, so every `swift-cross-ui` fact below is marked
**UNVERIFIED**. Do not carry an unverified claim into code. Before writing any manifest edit,
establish the following from the upstream repository itself
(`https://github.com/stackotter/swift-cross-ui`) — its README, its `Package.swift`, and
critically its own `.github/workflows/`, which is the best available evidence for whether a
GitHub-hosted Windows runner can build the Windows backend:

1. **The exact release tag** to pin. Record the tag **and** the resolved commit SHA. If the
   package has no tag suitable for pinning, pin `.revision("<full-40-char-sha>")` — never
   `branch:`, never an open-ended `from:` range. Pinning is a security requirement, not a
   style preference (§4).
2. **The product names** to depend on, and **which backend `DefaultBackend` selects per
   platform**. *Expected (UNVERIFIED): `SwiftCrossUI` + `DefaultBackend`; `DefaultBackend`
   resolves to `AppKitBackend` on macOS, `WinUIBackend` on Windows, `GtkBackend` on Linux.*
   Confirm before relying on it.
3. **The Windows prerequisites** for `WinUIBackend`. *Expected (UNVERIFIED): it may require
   the Windows App SDK / WinUI 3, `swift-winrt` projections, a NuGet restore step, and/or
   packaged-app (MSIX) or unpackaged bootstrapping to actually launch.* Whatever it needs
   becomes a step in `.github/workflows/swift-windows.yml` (§E). **This is the single largest
   risk in the ticket** — resolve it in §0, not after the manifest is written.
4. **The minimum Swift tools version and any `platforms:` floor** it imposes. Our manifest is
   `swift-tools-version:6.0` / `platforms: [.macOS(.v14)]`; CI installs Swift **6.1** on
   Windows and uses the preinstalled toolchain on macOS. If swift-cross-ui requires a higher
   floor, raise ours to match and say so in the PR.
5. **Windows ARM64 status** of the backend and its transitive dependencies (§5).

**Record the answers to 1–5 verbatim in the PR description.** If §0.3 turns out to be
unsatisfiable on `windows-latest` — i.e. the Windows backend genuinely cannot build on a
GitHub-hosted runner — **stop and report that finding**. Do not silently drop the Windows leg,
do not weaken the CI gate to `continue-on-error`, and do not substitute a headless/no-op
backend to make the build go green. A red Windows build reported honestly is the correct
outcome; a green build that proves nothing is not.

### §A. Manifest: dependency + the `CUESYNC_CROSSUI` split

6. `Package.swift` — add the pinned dependency from §0.1 to `dependencies:`.
7. `Package.swift` — rewrite the `CueSync` executable target to depend on `CueSyncCore` plus
   the §0.2 products, and to define the flag. Keep `path`/`exclude`/`sources` exactly as they
   are: `sources: ["UI"]` with `App`, `Views`, `Theme`, `Utilities`, `Resources`, `Models`,
   `Parsers`, `Exporters`, `Support` all excluded. Shape:

   ```swift
   .executableTarget(
       name: "CueSync",
       dependencies: [
           "CueSyncCore",
           .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
           .product(name: "DefaultBackend", package: "swift-cross-ui"),
       ],
       path: "CueSync/CueSync",
       exclude: [/* unchanged */],
       sources: ["UI"],
       swiftSettings: [.define("CUESYNC_CROSSUI")]
   )
   ```

   **Do not** add the flag or the dependency to `CueSyncCore` — the core stays UI-free and
   dependency-free, which is what keeps the test suite portable.
8. Commit **`Package.resolved`**. It is currently absent (the package has no dependencies);
   once one exists, the lockfile is the record of which commit was audited (§4). Remove
   `Package.resolved` from `.gitignore` if it is listed there.

**Flag semantics — state these in a comment in `Package.swift`:** `CUESYNC_CROSSUI` is
defined **only** by the SwiftPM build. The Xcode build never defines it. Therefore:

| Build | Flag | Presentation compiled | Screens |
|---|---|---|---|
| `xcodebuild -scheme CueSync` (macOS) | undefined | SwiftUI/AppKit — `App/`, `Views/`, `Theme/` | full, unchanged |
| `swift build` (macOS) | **defined** | swift-cross-ui `UI/` via AppKitBackend | empty shell |
| `swift build` (Windows/Linux) | **defined** | swift-cross-ui `UI/` via WinUI/Gtk backend | empty shell |

The two presentations already occupy disjoint directories and `CueSync.xcodeproj` contains
**no reference to `UI/`** (verified). So the flag is not what achieves the file split — the
target's `sources:`/`exclude:` already does. The flag's job is to make the split **explicit
and machine-checkable** (§D.15), and to guard the one case the directory split cannot: a file
compiled into both builds. Keep it honest — do not use `CUESYNC_CROSSUI` as a synonym for
"not Apple", because the macOS SwiftPM build is both.

### §B. The swift-cross-ui app shell (new, in `CueSync/CueSync/UI/`)

9. **Delete `CueSync/CueSync/UI/main.swift`.** This is required, not cosmetic: it is
   top-level code, and Swift rejects `@main` in a module containing a `main.swift`
   (*"'main' attribute cannot be used in a module that contains top-level code"*). Its
   `print("CueSync core loaded")` linkage proof is superseded by the app actually launching.
10. Add **`UI/CueSyncApp.swift`** — the swift-cross-ui entry point. Wrap the whole file in
    `#if CUESYNC_CROSSUI` / `#endif`. It declares the `@main` app, sets the window title
    **`CUE SYNC`** and the default size **1200×800** with a **1200×700 minimum**, matching
    `App/CueSyncApp.swift` exactly (`.defaultSize(width: 1200, height: 800)`,
    `.frame(minWidth: 1200, minHeight: 700)`), and renders `ContentView()`. Use the §0.2 API;
    the sketch below is **indicative, not verified** — conform to whatever the pinned version
    actually exposes:

    ```swift
    #if CUESYNC_CROSSUI
    import SwiftCrossUI
    import DefaultBackend

    @main
    struct CueSyncApp: App {
        var body: some Scene {
            WindowGroup("CUE SYNC") {
                ContentView()
            }
            .defaultSize(width: 1200, height: 800)
        }
    }
    #endif
    ```

    Naming: the type name `CueSyncApp` collides with the SwiftUI `CueSyncApp` in
    `App/CueSyncApp.swift` **only by name, never by compilation** — the two are never in the
    same module (`App/` is excluded from every SwiftPM target). Keeping the name identical is
    deliberate and aids the per-screen mapping. If the toolchain objects for any reason,
    rename the *file*, not the type.
11. Add **`UI/ContentView.swift`** — wrapped in `#if CUESYNC_CROSSUI`. **Intentionally
    empty** for this ticket: a single centered placeholder `Text("CUE SYNC")` is sufficient.
    Add a comment naming the later tickets' shape (Header → ScrollView{Project, Browse,
    Configure, Export} → Footer) so the next agent has the map. **Do not** port any section,
    the collapsible wrapper, the grid overlay, or the drag-to-reorder behavior here — that is
    gold-plating this ticket and pre-empting the incremental plan.
12. **No Apple imports in `UI/`.** No `AppKit`, `SwiftUI`, `CoreGraphics`,
    `UniformTypeIdentifiers`, `AVFoundation`, `Compression` — guarded or otherwise. The
    existing `PortComplianceTests.testNoSwiftPMSourceFileHasAnUnguardedAppleOnlyImport`
    already scans `UI/` for most of these; §D.16 closes the `SwiftUI` gap.
13. **Do not** make any `CueSyncCore` type `public` in this ticket. `UI/main.swift`'s comment
    flags that Models/Parsers/Exporters are `internal` and unreachable across the module
    boundary — that is a real blocker, but it only binds once a screen needs a model. An empty
    ContentView needs none. Widening the API surface belongs to the ticket that consumes it.

### §C. Leave the SwiftUI path alone

14. **Zero edits** to `App/`, `Views/`, `Theme/`, `Utilities/`, or `CueSync.xcodeproj`. Do not
    add `UI/` to the Xcode target. Do not "harmonize" the two ContentViews. `xcodebuild
    -scheme CueSync build` must stay green, and the diff for these paths must be empty.

### §D. Tests

15. **Fix the false-positive compliance test.**
    `PortComplianceTests.testPackageSwiftDeclaresSwiftCrossUIDependency` asserts only that
    `Package.swift` *contains the string* `swift-cross-ui` — and it **passes today**, on the
    strength of a code comment ("*The real swift-cross-ui presentation layer is re-hosted
    here…*"), with no dependency declared. As written it cannot tell a real pinned dependency
    from prose about one, so it would not catch this ticket failing. Tighten it to assert on
    the manifest's **structure**: a `.package(` entry naming `swift-cross-ui` pinned by
    `exact:`/`.exact(`/`revision:`, and the `CueSync` target depending on a `.product(` from
    that package. Reject `branch:` and `from:` explicitly.
16. Extend the banned-import scan (`testNoSwiftPMSourceFileHasAnUnguardedAppleOnlyImport`) to
    include **`SwiftUI`** in its `banned` list. It is currently absent, so a stray
    `import SwiftUI` in `UI/` would sail through the very test meant to keep Windows building.
17. Add a test asserting `Package.swift` defines **`CUESYNC_CROSSUI`** in `swiftSettings` for
    the `CueSync` target, and that **`Package.resolved` exists** and pins swift-cross-ui to a
    concrete revision SHA.
18. Add a test asserting **`UI/main.swift` no longer exists** and that `UI/CueSyncApp.swift`
    and `UI/ContentView.swift` do, each opening with a `#if CUESYNC_CROSSUI` guard.
19. All existing tests keep passing unchanged. Do not weaken, skip, or `XCTSkip` any of them.
    These structural tests are cheap proxies, not proof — the real gate is §E.

### §E. CI

20. `.github/workflows/swift-windows.yml` — add whatever Windows prerequisite steps §0.3
    established, **before** `swift build`. Keep both existing legs and both existing gates
    (macOS's plain `swift test`; the Windows XCTest-summary gate that tolerates the spurious
    swift-testing "0 tests" exit). Keep the `.build/release/` artifact upload.
21. Do **not** add a Linux leg in this ticket. `CueSyncCore` builds there and Gtk is the
    expected backend, but it is not this ticket's DoD and its Gtk prerequisites are a
    separate install story (§5).
22. **CI cannot verify the window opens** — the runners are headless and neither leg executes
    the binary. CI proves compilation and linkage only. The launch check is manual (§3), and
    the PR must not claim more than CI actually demonstrated.

---

## 3. Acceptance criteria

**Build (the real gate):**

- [ ] `swift build -c release` succeeds on **`macos-latest`**.
- [ ] `swift build -c release` succeeds on **`windows-latest`**, with the swift-cross-ui
      Windows backend actually compiled and linked — not stubbed, skipped, or made
      `continue-on-error`.
- [ ] `swift test` is green on **both** legs, with the same test count as before plus the new
      §D tests. No test weakened, skipped, or deleted.
- [ ] `xcodebuild -scheme CueSync build` still succeeds on macOS (SwiftUI path intact).
- [ ] `scripts/run-tests.sh` still passes on macOS.

**Manifest:**

- [ ] `Package.swift` depends on `swift-cross-ui` pinned to an **exact tag or a full 40-char
      revision SHA**. No `branch:`. No open-ended `from:`.
- [ ] `Package.resolved` is committed and pins swift-cross-ui (and every transitive
      dependency) to a concrete revision.
- [ ] The `CueSync` target defines `CUESYNC_CROSSUI` in `swiftSettings`; `CueSyncCore` does
      **not**, and gains no new dependency.
- [ ] The resolved dependency tree contains **no** package beyond swift-cross-ui and its own
      transitive closure, each one listed in the PR (§4).

**Source:**

- [ ] `CueSync/CueSync/UI/main.swift` is deleted.
- [ ] `UI/CueSyncApp.swift` and `UI/ContentView.swift` exist, each fully wrapped in
      `#if CUESYNC_CROSSUI`.
- [ ] No file under `UI/` imports `AppKit`, `SwiftUI`, `CoreGraphics`,
      `UniformTypeIdentifiers`, `AVFoundation`, or `Compression` — guarded or not.
- [ ] `git diff` touches **nothing** under `App/`, `Views/`, `Theme/`, `Utilities/`, or
      `CueSync.xcodeproj`.
- [ ] No `CueSyncCore` declaration changed from `internal` to `public`.
- [ ] No screen, section, collapsible wrapper, grid overlay, menu command, or envelope code
      ported. ContentView is empty by design.

**Behavior (manual — CI is headless and cannot check these):**

- [ ] `swift run CueSync` on macOS opens a window titled **CUE SYNC**, 1200×800, minimum
      1200×700, containing the empty ContentView; it does not crash, and closing it exits 0.
- [ ] The Windows launch check is **best-effort and explicitly reported**: if §0.3's
      prerequisites (Windows App SDK / MSIX / bootstrapping) mean the CI-built binary cannot
      be launched on a hosted runner, say so plainly in the PR rather than implying the window
      was seen. State exactly what was verified: *compiles and links on Windows*.

**Reporting:**

- [ ] The PR records the §0.1–§0.5 answers verbatim, including the pinned SHA and the Windows
      prerequisite findings.
- [ ] The PR states plainly that this is step 1 of N and that no screen is ported yet.

---

## 4. Threat model

This step adds no parsing, no I/O, and no user input — the empty ContentView has no attack
surface of its own. The entire risk of this ticket is **supply chain**, and it is not a small
one.

**Inputs crossing a trust boundary:**

- **The `swift-cross-ui` dependency and its full transitive closure — the primary trust
  boundary this ticket opens, and the reason §0.1 and §A.8 are non-negotiable.** Until now
  this repo had **zero** external Swift dependencies: `CSQLite` and `CZlib` were deliberately
  *vendored* as in-repo C source precisely so no third-party code is fetched at build time.
  This ticket ends that property. Every line of swift-cross-ui and of anything it pulls in
  (Gtk bindings, WinRT/`swift-winrt` projections, whatever §0 surfaces) compiles into CUE SYNC
  and runs with the user's full privileges — and, via SwiftPM plugins or `cSettings` build
  tooling, potentially on the *developer's* machine and in CI at build time. Mitigations, all
  mandatory: pin to an exact tag or revision SHA so the bytes are pinned rather than the
  label; commit `Package.resolved` so the audited commit is the one that builds; enumerate the
  resolved closure in the PR so a human sees what was actually added; and treat any unexpected
  transitive package as a finding to report, not a detail to wave through. A moving `branch:`
  pin would mean the code shipped to DJs is whatever upstream pushed most recently — that is
  the specific failure this forbids.
- **The `.github/workflows/swift-windows.yml` prerequisite steps (§E.20).** If §0.3 requires
  fetching a Windows App SDK, a NuGet package, or an installer, that fetch is a second supply
  chain entering CI. Pin those by version too — never `latest`. Prefer a pinned GitHub Action
  at a commit SHA or a versioned installer URL over an unpinned script piped to a shell.
- **Nothing else.** Rekordbox XML, ShowKontrol `.cue`, Serato ID3 GEOB blobs, Engine DJ
  SQLite databases and Resolume presets all remain untrusted input handled by `CueSyncCore` —
  but this ticket does not touch that code, does not change its guards, and does not newly
  expose it: the empty ContentView calls none of it. Their threat model is unchanged from
  CUESYNC-4.

**Secrets / credentials touched:** **none.** This ticket reads and writes no credential. The
Developer ID signing identity and the `amritus-notary` keychain profile used by `scripts/`
are **out of scope** — do not invoke, log, or modify them. `Package.resolved` and the manifest
must contain no token; if the pinned dependency ever needs authenticated fetch, that is a
finding to report, not a token to embed. Do not add secrets to the workflow.

**Values requiring a cryptographically secure primitive:** **none generated.** This ticket
introduces no key, nonce, token, session ID, or temp-file name — so there is no place for
`Data.random`/`arc4random`/`Int.random` and none may be introduced. The one integrity-critical
value it *consumes* is the **dependency's git revision SHA**, which is the cryptographic
primitive underwriting the pin: recording the exact SHA in `Package.resolved` is what makes
"the code we audited" and "the code we build" the same bytes, and it is why a tag alone is
weaker than a tag plus its resolved SHA. Should any later step need a temporary path, use
`FileManager`'s temp directory — never a hardcoded `/tmp`, never a hand-rolled random name.

---

## 5. Target platforms

| Platform | Status (this ticket's shell scope) | Notes |
|---|---|---|
| **macOS (arm64 + x86_64)** | ✅ Supported, two builds | Xcode/SwiftUI build unchanged and still the shipping app. The SwiftPM build additionally compiles the `UI/` shell via the expected AppKitBackend (**UNVERIFIED**, §0.2). Both must be green. |
| **Windows x64** | ✅ Primary target | SwiftPM + swift-cross-ui Windows backend, Swift 6.1 via `compnerd/gha-setup-swift`. **Gated on §0.3**: the backend's Windows App SDK / WinRT / packaging prerequisites are **UNVERIFIED** and are the ticket's main risk. DoD is compiles-and-links on `windows-latest`; launching is best-effort (§3). |
| **Windows ARM64** | ⚠️ **Not guaranteed — unverified, not CI-gated** | See the flagged dependency below. `CSQLite`/`CZlib` are pure C and fine. Do **not** claim ARM64 support without a green ARM64 build; no hosted ARM64 Windows runner is wired up. |
| **Linux (x64)** | ✅ Expected buildable, out of scope | `CueSyncCore` builds today; the shell would use the expected GtkBackend (**UNVERIFIED**), which adds a system Gtk install prerequisite. No CI leg in this ticket (§E.21). |

**Dependency flagged as lacking confirmed Windows-ARM64 support: `swift-cross-ui`'s Windows
(WinUI) backend and its transitive WinRT/Windows App SDK projections.** This is the only
dependency in the tree with an ARM64 question mark, and this ticket is precisely the one that
introduces it — CUESYNC-4 could truthfully call ARM64 clean only because it had no UI
dependency. Two distinct unknowns compound here and neither was verifiable during planning:
whether the Swift Windows/ARM64 toolchain is a supported configuration for this backend, and
whether the backend's own projections ship ARM64 binaries. Resolve both in §0.5 and report the
finding; if ARM64 is not supported upstream, **say so in the PR** rather than leaving the
platform table optimistic. `CSQLite` and `CZlib` remain portable C with **no** ARM64 gap.

**Cannot-reproduce-faithfully call-outs:** none applicable yet — this ticket ports no screen,
so there is no fidelity delta to declare. The open fidelity risks inherited from
`specs/CUESYNC-3.md` §D remain live and land with the tickets that port them: the
immediate-mode `Canvas` envelope editor, `.onHover` button animation, the
`NonSelectingTextField` focus nuance, drag-to-reorder panels, and `NSImage`-rendered
`BrandIcons` SVGs. One additional item surfaces here for the next ticket's benefit:
`Theme/ThemeColors.swift` is wrapped in `#if canImport(AppKit)` and sits in a directory
excluded from every SwiftPM target, so **the swift-cross-ui path currently has no theme
colors at all**. The empty ContentView does not need them; the first real screen will, and
porting `ThemeColors` is a prerequisite of that ticket, not this one.
