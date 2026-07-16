# CUESYNC-6 — Prove GtkBackend on Windows: backend switch, GTK 4 runtime bundling, DLL closure check

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> Faithful port. Keep the Swift source and layout. The existing SwiftUI/AppKit presentation
> (`CueSync/CueSync/{App,Views,Theme,Utilities}`, built by `CueSync.xcodeproj`) **stays intact
> and untouched** as the shipping macOS app. This ticket continues the incremental re-host
> started in `CUESYNC-5` and ports **no screen**: `UI/ContentView.swift` is explicitly left
> byte-for-byte alone. It changes exactly one thing about what CUE SYNC *is* — which
> swift-cross-ui backend the SwiftPM executable renders through — and then does the
> unglamorous work of proving that choice actually survives contact with Windows: install
> GTK 4 in CI, ship its DLLs next to the exe, and verify the binary's dependency closure
> resolves without reaching outside the bundle.
> Definition of Done: `swift build -c release` green on `macos-latest` **and**
> `windows-latest` with `GtkBackend` compiled and linked; the Windows artifact carries the
> GTK 4 runtime; a dependency check proves the artifact has no missing non-system DLL **and
> is itself proven non-vacuous**; the full test suite still green on both legs; and
> `xcodebuild -scheme CueSync build` still green on macOS.

---

## 1. Problem

`CUESYNC-5` landed the swift-cross-ui dependency and an app shell that compiles and links on
`windows-latest`, but it bought that green build with `DefaultBackend` — a product that
selects the platform backend for us and, on Windows, selects `WinUIBackend`. That leaves CUE
SYNC's Windows story resting on two things nobody has demonstrated: that the WinUI path is
the right one, and that a binary which *links* is a binary that *runs*. CI is headless and
never executes the exe, so "compiles and links on Windows" is the entire evidence base — and
a Windows GUI binary can link perfectly and still die on launch with a missing-DLL dialog
before a single line of our code runs. This ticket replaces the assumption with a
demonstration: it pins the executable to `GtkBackend` explicitly rather than accepting
whatever `DefaultBackend` picks, installs GTK 4 on the Windows CI job, bundles the GTK 4
runtime DLLs alongside `CueSync.exe` in the uploaded artifact, and adds a dependency-closure
check that fails the build if the exe references any non-system DLL the bundle does not
supply. The user-facing outcome is narrow and honest: nothing changes for the DJ running the
macOS app, and on Windows CUE SYNC goes from "a binary we believe would run" to "a binary
whose runtime dependencies are enumerated, bundled, and checked".

---

## 2. Plan

All paths are relative to the repo root. Existing sources live in `CueSync/CueSync/`.

### §0. Verify the backend and the GTK 4 toolchain story — **blocking, do this first**

This planning pass had **no network access** (`WebFetch`/`WebSearch`/`curl` all unavailable),
so every upstream claim below is marked **UNVERIFIED** and none may be carried into code
unchecked. `CUESYNC-5` §0 set the precedent and it holds here: resolve these *before* writing
a manifest edit, and record the answers verbatim in the PR.

Establish from the pinned dependency itself — `moreSwift/swift-cross-ui`, tag `0.8.0`,
revision `a6d206370812e3b9edba259d167e848892c5013d` (the resolved SHA already in
`Package.resolved`; read the code at **that** revision, not at `main`):

1. **That a `GtkBackend` product exists at the pinned revision**, and its exact product name.
   *Expected (UNVERIFIED): a `.library(name: "GtkBackend", ...)` alongside `AppKitBackend`,
   `WinUIBackend`, `Gtk3Backend`, `UIKitBackend`, `DefaultBackend`.* If `0.8.0` has no such
   product, **stop and report** — do not bump the pin to chase one. Changing the pinned
   revision is a re-audit of the whole closure (§4) and a separate decision.
2. **How an `App` selects a non-default backend** in this version. *Expected (UNVERIFIED):
   `import GtkBackend` plus an explicit `typealias Backend = GtkBackend` in the `App`
   conformance, because `DefaultBackend` supplies that associated type by default and
   removing the import removes the default.* Conform to whatever the pinned API actually
   exposes — the sketch in §B.6 is indicative, not verified.
3. **How `GtkBackend` locates GTK 4 at build time.** *Expected (UNVERIFIED): a
   `systemLibrary` target (`CGtk` or similar) with `pkgConfig: "gtk4"` and Homebrew/apt
   providers.* Two follow-ons matter more than the mechanism and must both be answered:
   **(a)** whether SwiftPM's `pkgConfig:` resolution actually functions on Windows, or
   whether the include/lib paths must be passed via `PKG_CONFIG_PATH` with `pkgconf` on
   `PATH`, or hand-fed as `-Xcc -I…` / `-Xlinker -L…`; and **(b)** whether swift-cross-ui
   runs any **build-time code generation** against the installed GTK headers (a `GtkCodeGen`
   executable or SwiftPM plugin), because that turns "GTK is installed" into "GTK is
   installed *and* a generator ran successfully" and is a much larger CI surface.
4. **Which GTK 4 Windows distribution to install — the ticket's central technical decision.**
   Swift on Windows targets the **MSVC ABI and the UCRT**. A GTK 4 build that does not match
   both is not usable, however green `pacman` looks. Evaluate at least these two and record
   the choice *and the rejected option's reason* in the PR:
   - **gvsbuild** — the GTK project's MSVC build system. Produces MSVC-ABI DLLs, `.lib`
     import libraries and `.pc` files, which is the ABI-correct match. Building from source
     in CI is far too slow (~1h+), so this means consuming a **pinned prebuilt release
     asset** from gvsbuild's GitHub Releases, verified by SHA-256 (§4).
   - **MSYS2 UCRT64** (`msys2/setup-msys2` + `pacman -S mingw-w64-ucrt-x86_64-gtk4`) —
     ships `pkgconf`, and the **UCRT64** environment matches MSVC's UCRT (the `MINGW64`
     environment does **not** — it links `msvcrt.dll` and is the wrong choice). GTK is plain
     C with a stable C ABI, so MSVC-linking against GCC-produced DLLs is *plausible*, but it
     hinges on usable import libraries (MSYS2 ships `.dll.a`, not `.lib`) and on the CRT
     match actually holding across the whole `glib`/`cairo`/`pango`/`gdk-pixbuf` stack.
     `pacman` is also **not pinnable by default** — it installs whatever is current, which
     §4 treats as a real finding, not a footnote.

   Pick on ABI correctness first and convenience second. If **neither** yields a
   `swift build -c release` that compiles and links `GtkBackend` on `windows-latest`, **stop
   and report that finding.** Do not weaken the Windows leg to `continue-on-error`, do not
   fall back to `DefaultBackend` while claiming GTK, and do not stub the backend. A red
   Windows build reported honestly is the correct outcome; a green build that proves nothing
   is not — this repo already carries two redteam tests written because earlier assertions
   were vacuously green (`AdversarialXcodeProjectIsolationTests`, and the §D.15 fix in
   `CUESYNC-5`), and that is the failure mode to avoid here.
5. **GTK 4 on macOS for the SwiftPM leg** — see §C.9, which is a consequence the ticket text
   does not mention and the Build Agent must not discover at CI time. Confirm `brew install
   gtk4` provides a `GtkBackend`-compatible GTK 4 and that swift-cross-ui's Gtk path builds
   on macOS at the pinned revision (**UNVERIFIED**).
6. **The dependency-checking tool.** The ticket names *"wldd/dependency_runner"*.
   *Expected (UNVERIFIED): `dependency_runner` is a Rust tool that emulates the Windows DLL
   search order and ships an ldd-like frontend named `wldd`.* Confirm the tool exists, what
   it is actually called, how it is installed, and how it is **pinned to a version**. If it
   cannot be pinned or does not exist as described, any tool meeting the §D.12 contract is
   acceptable — including a small first-party script over `dumpbin /dependents` — but say in
   the PR what was used and why.
7. **Windows ARM64 availability of the chosen GTK 4 distribution** (§5).

### §A. Manifest: switch the backend product

8. `Package.swift` — in the **`CueSync` executable target only**, replace the
   `.product(name: "DefaultBackend", package: "swift-cross-ui")` dependency with
   `.product(name: "GtkBackend", package: "swift-cross-ui")` (exact name per §0.1). Keep
   `SwiftCrossUI`. Change **nothing else**: the `.package(url:…, exact: "0.8.0")` pin, the
   resolved SHA, `path`/`exclude`/`sources`, and the `CUESYNC_CROSSUI` define all stay
   exactly as they are. Do **not** touch `CueSyncCore`, `CSQLite`, or `CZlib`.
9. **Expect `Package.resolved` to be unchanged, and treat any change as a finding.** SwiftPM
   resolves *package*-level dependencies from the dependency's manifest, largely
   independently of which *product* we consume, so swapping a product should not move a pin.
   If `Package.resolved` does change, that is exactly the "unexpected transitive package" §4
   requires be reported — audit it, do not regenerate and commit past it.
   `AdversarialSupplyChainTests.testResolvedClosureMatchesTheAuditedAllowlistExactly` asserts
   **set equality**, so it fails on packages *leaving* the closure too; if the swap prunes
   the Android/JNI subtree, update `Audit.resolvedClosure` deliberately and say so in the PR.

### §B. The app shell (`CueSync/CueSync/UI/`)

10. `UI/CueSyncApp.swift` — replace `import DefaultBackend` with `import GtkBackend` and add
    whatever backend selection §0.2 established. Keep the file's `#if CUESYNC_CROSSUI` wrap,
    the `@main struct CueSyncApp: App` name, the window title **`CUE SYNC`**, the
    `.defaultSize(width: 1200, height: 800)` and the `.frame(minWidth: 1200, minHeight: 700)`
    — all unchanged. Indicative only:

    ```swift
    #if CUESYNC_CROSSUI
    import SwiftCrossUI
    import GtkBackend

    @main
    struct CueSyncApp: App {
        typealias Backend = GtkBackend      // per §0.2 — conform to the pinned API
        var body: some Scene { /* unchanged */ }
    }
    #endif
    ```
11. **`UI/ContentView.swift` is not to be edited.** The ticket says so explicitly and the
    acceptance criteria enforce an empty diff for it. It stays the placeholder `Text("CUE
    SYNC")`. No screen, section, theme, or envelope work belongs in this ticket.
12. **No Apple imports in `UI/`**, unchanged from `CUESYNC-5` §B.12 — the existing banned-list
    scans in `PortComplianceTests` already enforce this and must keep passing.

### §C. CI: GTK 4 on both legs

13. `.github/workflows/swift-windows.yml`, **`windows-build` job** — add a GTK 4 install step
    per §0.4, **before** `swift build`, pinned per §4 (action by commit SHA; release asset by
    URL **and** SHA-256; `pacman` package by explicit version if that route wins). Export
    whatever `PKG_CONFIG_PATH` / `PATH` / include / lib environment §0.3 requires. Keep the
    VS dev environment step, the pinned `compnerd/gha-setup-swift`, and the `.build` cache.
    **Cache key:** the GTK install is now an input to the build — if GTK is unpacked anywhere
    inside `.build`, or if a changed GTK version could produce a stale hit against a key that
    only hashes `Package.resolved`, add the GTK version to the cache key. A stale cache that
    hides a broken GTK install is a silently-green build.
14. **`macos` job — add `brew install gtk4` (or the §0.5 equivalent).** *The ticket text asks
    only for "GTK4 install to the Windows CI job", but it also requires `swift build -c
    release` green **on macOS and Windows with GTK 4**, and those two statements conflict:*
    once the executable target depends unconditionally on `GtkBackend`, the macOS SwiftPM leg
    needs GTK 4 too or it goes red. Adding it to the macOS job is the resolution. Note in the
    PR that `brew install gtk4` is **not version-pinnable** in the ordinary way (§4).
15. **`windows-test` job — leave alone.** `CueSyncCoreTests` depends only on
    `CueSyncCore`/`CSQLite`/`CZlib` and never on the `CueSync` executable target, so it needs
    no GTK and must not grow a GTK install step; adding one would put a multi-minute install
    on the critical path of the job that exists to be the fast one. Keep the XCTest-summary
    gate exactly as it is.
16. Do **not** add a Linux leg (unchanged from `CUESYNC-5` §E.21), and do **not** add a
    Windows ARM64 leg — see §5.

### §D. Bundle the GTK 4 runtime and check the closure

17. **Bundle** — after `swift build -c release` in `windows-build`, copy the GTK 4 runtime
    DLLs next to `CueSync.exe` so the uploaded `cuesync-windows` artifact is self-contained.
    Copy from the §0.4 install prefix's `bin/`. This is not only GTK: it is the transitive
    runtime — `glib`, `gobject`, `gio`, `cairo`, `pango`, `harfbuzz`, `gdk-pixbuf`,
    `graphene`, `fribidi`, `libepoxy`, `png`/`jpeg`/`tiff`, `intl`, `zlib` and friends. Let
    the §D.18 check tell you what is actually required rather than curating the list by hand.
    Keep the existing `.build/release/` artifact upload; the DLLs land in that directory.
18. **The runs-clean check** — a step in `windows-build`, after the bundle step, using the
    §0.6 tool. Contract, in order of importance:
    - It resolves `CueSync.exe`'s **transitive** import closure using the real Windows DLL
      search order, rooted at the artifact directory.
    - It **fails the job** if any required DLL is unresolved, or resolves **outside** the
      artifact directory to anything that is not an OS-provided system DLL.
    - Its **system allowlist is narrow and written down**: `kernel32`/`user32`/`gdi32`/
      `advapi32`/`ole32`/`shell32`/`api-ms-win-*`/`ucrtbase` and the like. It must **not**
      be padded until the check passes. A permissive allowlist converts this check into
      exactly the vacuous-green assertion §0.4 warns about, and it is the single most likely
      way this ticket ships something worthless.
    - **The Swift runtime DLLs (`swiftCore.dll`, `Foundation.dll`, `dispatch.dll`,
      `BlocksRuntime.dll`, …) are redistributables, not system DLLs.** On the CI runner they
      resolve via the toolchain's `PATH`; on a DJ's machine they will not exist. Do **not**
      allowlist them into silence. Either bundle them alongside the GTK DLLs, or leave them
      genuinely out of scope for this ticket and **report the gap explicitly in the PR** as
      the next ticket's work. Choose one and say which — the forbidden third option is a
      broad allowlist that makes the gap invisible.
19. **Prove the check is not vacuous — a negative control, and a required deliverable.** A
    check that passes tells you nothing until you have watched it fail for the right reason.
    Add a CI step that deliberately removes one bundled GTK DLL, runs the checker, asserts it
    **fails**, then restores the DLL and re-runs to confirm it passes. Without this, "runs
    clean" is an unfalsified claim.
20. **State the check's real limit in the PR, and do not overclaim past it.** A static import
    scan reads the PE import table. It **cannot** see what GTK loads at runtime via
    `LoadLibrary`: GdkPixbuf image loaders, GIO modules, input-method and print backends,
    resolved through `loaders.cache` / `GIO_MODULE_DIR` / registry and env lookups. It also
    cannot see the **non-DLL** runtime assets GTK needs to start — `gschemas.compiled`, the
    icon theme cache, `settings.ini`. So a clean check means *"no missing statically-imported
    DLL"* and nothing more; it does **not** mean the app launches. CI is headless and still
    never executes the binary (`CUESYNC-5` §E.22 unchanged). Say precisely this in the PR.

### §E. Tests

21. Update `PortComplianceTests.testCueSyncTargetDependsOnASwiftCrossUIProduct`'s
    neighbourhood with a test that the `CueSync` target depends on the **`GtkBackend`**
    product specifically and **no longer** on `DefaultBackend`. Assert on the target block's
    structure, not on a substring of the whole manifest — a comment mentioning
    `DefaultBackend` (this spec's rationale will likely be quoted in one) must not be able to
    fail or pass it. That is the §D.15 lesson from `CUESYNC-5`, and it applies directly.
22. Add a test that `UI/CueSyncApp.swift` imports `GtkBackend` and does not import
    `DefaultBackend`, still inside its `#if CUESYNC_CROSSUI` guard.
23. Add a test that `UI/ContentView.swift` is unmodified in substance — it still declares
    `struct ContentView: View` with the placeholder body and imports no backend module.
24. **Do not weaken, skip, `XCTSkip`, or delete any existing test.** In particular do not
    "fix" `AdversarialSupplyChainTests.testResolvedClosureMatchesTheAuditedAllowlistExactly`
    by loosening set equality to `isSubset` — if it fires, §A.9 is the response.
25. **Test count.** The ticket says "all 179 tests intact". The working tree currently
    declares **203** `func test` methods across `Tests/CueSyncCoreTests/` (the redteam suite
    in commit `aa8e307` landed after that figure was written), so **179 is stale — do not
    treat it as a target to hit.** The binding requirement: the suite's passing count must
    not **decrease**, and no test may be removed or weakened. Record the actual count from
    the green run in the PR.

---

## 3. Acceptance criteria

**Build (the real gate):**

- [ ] `swift build -c release` succeeds on **`macos-latest`** with `GtkBackend` compiled and
      linked, using a GTK 4 installed by the workflow (§C.14).
- [ ] `swift build -c release` succeeds on **`windows-latest`** with `GtkBackend` actually
      compiled and linked — not stubbed, not skipped, not `continue-on-error`, and not
      silently still `DefaultBackend`.
- [ ] `swift test` green on **both** legs. Passing-test count **≥** the pre-change baseline
      (§E.25 — *not* 179). No test weakened, skipped, or deleted.
- [ ] `xcodebuild -scheme CueSync build` still succeeds on macOS (SwiftUI/AppKit path intact).
- [ ] `scripts/run-tests.sh` still passes on macOS.

**Manifest:**

- [ ] The `CueSync` target depends on the swift-cross-ui **`GtkBackend`** product and **not**
      on `DefaultBackend`.
- [ ] The swift-cross-ui pin is **still** `exact: "0.8.0"` / revision
      `a6d206370812e3b9edba259d167e848892c5013d`. No `branch:`, no `from:`, no version bump.
- [ ] `Package.resolved` is unchanged — or, if it changed, every added/removed package is
      audited and justified in the PR and `Audit.resolvedClosure` updated deliberately (§A.9).
- [ ] `CueSyncCore` gains no dependency and still does not define `CUESYNC_CROSSUI`.

**Source:**

- [ ] `UI/CueSyncApp.swift` imports `GtkBackend`, not `DefaultBackend`, still fully wrapped in
      `#if CUESYNC_CROSSUI`; title `CUE SYNC`, default size 1200×800, minimum 1200×700 all
      unchanged.
- [ ] **`git diff` for `UI/ContentView.swift` is empty.**
- [ ] `git diff` touches **nothing** under `App/`, `Views/`, `Theme/`, `Utilities/`, or
      `CueSync.xcodeproj`.
- [ ] No file under `UI/` imports `AppKit`, `SwiftUI`, `CoreGraphics`,
      `UniformTypeIdentifiers`, `AVFoundation`, or `Compression` — guarded or not.
- [ ] No `CueSyncCore` declaration changed from `internal` to `public`. No screen ported.

**Artifact and DLL closure:**

- [ ] The `cuesync-windows` artifact contains `CueSync.exe` **and** the GTK 4 runtime DLLs in
      the same directory.
- [ ] The dependency check runs in `windows-build` and **fails the job** on any unresolved
      DLL, or any non-system DLL resolved from outside the artifact directory.
- [ ] The system allowlist is explicit, narrow, and reviewable in the workflow — no wildcard
      that would swallow a real miss.
- [ ] **The negative control passes: removing one bundled GTK DLL makes the check fail, and
      restoring it makes the check pass again** (§D.19). A green check with no negative
      control does not satisfy this ticket.
- [ ] The Swift runtime DLLs are either bundled **or** named in the PR as a known, unfixed
      gap. They are not quietly allowlisted (§D.18).

**Reporting (the PR must not claim more than CI demonstrated):**

- [ ] The §0.1–§0.7 answers are recorded verbatim, including the §0.4 distribution choice and
      why the rejected option was rejected.
- [ ] The PR states that CI **never executes** the binary; that the check proves *no missing
      statically-imported DLL*, not that the app launches; and that GTK's runtime-loaded
      modules and non-DLL assets (§D.20) are outside what any static scan can see.
- [ ] The PR states that the macOS SwiftPM build now renders through GTK rather than AppKit
      (§5), and that the shipping Xcode app is unaffected.
- [ ] If §0.4 proved unsatisfiable, the PR reports that plainly instead of a green build.

---

## 4. Threat model

This ticket ports no screen and parses no file, so it adds **no new untrusted-input parsing**
of its own. Its risk is concentrated somewhere `CUESYNC-5`'s was not: `CUESYNC-5` added a
source dependency that SwiftPM compiles from a pinned commit, whereas this ticket adds a
**prebuilt binary runtime that we copy into the artifact a DJ downloads**, and it adds
**Windows DLL loading** as a live attack surface. Those are different problems and the second
is the more dangerous of the two.

**Inputs crossing a trust boundary:**

- **The GTK 4 Windows binary distribution (§0.4) — the primary new boundary.** These DLLs are
  not compiled from an audited source pin the way swift-cross-ui is; they are *someone else's
  compiled bytes*, shipped inside our artifact, running with the user's full privileges. The
  `.build/release/` upload becomes a redistribution channel. Mandatory: pin the exact source
  (release asset URL **and** its **SHA-256**, verified before extraction; or an explicit
  `pacman` package version). **`latest` is forbidden**, and an unpinned `pacman -S` — which is
  `pacman`'s default behaviour, so this must be handled, not assumed away — means the DLLs
  shipped to DJs are whatever the mirror served that morning. Record the exact versions in the
  PR. An unverified download piped into the artifact is the specific failure this forbids.
- **The Windows DLL search order — a real, classic attack surface that bundling only
  partially closes.** Placing DLLs next to the exe is a genuine mitigation (the application
  directory precedes `CWD` and `PATH` in the default search order), and it is why §D.17 exists.
  But it only protects the DLLs we actually bundle: **any** required non-system DLL we miss
  gets resolved from `PATH` or the working directory, which on a DJ's machine is an
  attacker-plantable location — a hijack that executes before `main`. This is precisely why
  §D.18's allowlist must stay narrow and why §D.19's negative control is mandatory: a
  vacuously-green check does not merely fail to add value, it actively certifies a DLL-planting
  hole as clean. Note honestly (§D.20) that a static import scan **cannot** cover GTK's
  `LoadLibrary`-time modules (GdkPixbuf loaders, GIO modules, IM/print backends) — those are
  the same hijack risk, unmeasured by this check, and must be named as such rather than
  implied covered.
- **GTK's own startup reads from disk and environment.** GTK 4 consults `gschemas.compiled`,
  `settings.ini`, icon and loader caches, and CSS themes, located via `XDG_DATA_DIRS`,
  `GSETTINGS_SCHEMA_DIR`, `GIO_MODULE_DIR`, `GTK_PATH` and similar. Every one is an input to
  our process resolved through an environment variable an attacker may influence. This ticket
  does not fix that; it must not silently introduce it either. Prefer resolving these from the
  bundle directory rather than inheriting ambient environment, and report whatever the §0.4
  route requires.
- **The CI install path is a second supply chain, entering at build time.** `msys2/setup-msys2`
  or any download step, plus the §0.6 checker, plus `brew install gtk4` on the macOS leg. Pin
  actions to commit SHAs (the workflow already does this consistently — match that standard).
  Never pipe an unpinned script to a shell. `brew install gtk4` resists pinning: flag it in the
  PR as a known weakness rather than pretending the macOS leg is reproducible.
- **Unchanged and untouched:** Rekordbox XML, ShowKontrol `.cue`, Serato ID3 GEOB blobs,
  Engine DJ SQLite databases, Resolume presets. All remain untrusted input handled by
  `CueSyncCore`. This ticket does not touch that code, change its guards, or newly expose it —
  `ContentView` is still empty and calls none of it. Their threat model is unchanged from
  `CUESYNC-4`.

**Secrets / credentials touched:** **none.** No credential is read, written, or logged. The
Developer ID signing identity and the `amritus-notary` keychain profile used by `scripts/` are
**out of scope** — do not invoke, log, or modify them. Add no secret to the workflow; the GTK
download and the checker are public artifacts requiring no authentication. If any step appears
to need an authenticated fetch, that is a finding to report, not a token to embed.

**Values requiring a cryptographically secure primitive:** **none generated.** This ticket
creates no key, nonce, token, session ID, or temp-file name, so `Data.random`/`arc4random`/
`Int.random` have no place here and none may be introduced. The integrity-critical values it
**consumes** are hashes, and they are the whole basis of trust in §4: the **SHA-256 of the GTK
4 binary bundle**, which is what makes "the runtime we audited" and "the runtime we ship to
DJs" the same bytes; the **git revision SHA** `a6d20637…` already pinning swift-cross-ui,
which must not move; and the **commit SHAs** pinning every GitHub Action. Verify the bundle
checksum **before** extraction, not after — checking a hash after unpacking an archive is
checking it after the untrusted bytes have already touched the filesystem. Should any step
need a temporary path, use `FileManager`'s temp directory (or the runner's `RUNNER_TEMP`) —
never a hardcoded `/tmp`, never `C:\Temp`, never a hand-rolled random name.

---

## 5. Target platforms

| Platform | Status (this ticket's scope) | Notes |
|---|---|---|
| **macOS (arm64 + x86_64)** | ✅ Supported, two builds, **one of them changes character** | The Xcode/SwiftUI/AppKit build is unchanged and is still the shipping app. The **SwiftPM** build now renders via `GtkBackend` instead of AppKitBackend, and consequently needs `brew install gtk4` in CI (§C.14) — a consequence the ticket text omits. Both builds must be green. |
| **Windows x64** | ✅ Primary target | SwiftPM + `GtkBackend`, Swift 6.1 via `compnerd/gha-setup-swift`. Gated on §0.4 (ABI/CRT match) and §0.3 (pkg-config on Windows). DoD is compiles, links, bundles, and passes the closure check; **launching is still unverified** — CI is headless (§D.20). |
| **Windows ARM64** | ⚠️ **Not supported by this ticket — and now flagged at the dependency level** | See the call-out below. No hosted ARM64 Windows runner is wired up; do not claim ARM64 support without a green ARM64 build. |
| **Linux (x64)** | ✅ Expected buildable, still out of scope | GTK is Linux's native path, so `GtkBackend` is the natural fit and `apt install libgtk-4-dev` is a well-trodden prerequisite. No CI leg in this ticket (§C.16). This ticket arguably improves Linux's odds; it does not verify them. |

**Dependency flagged as lacking Windows-ARM64 support: the GTK 4 Windows runtime itself
(§0.4), and by extension `GtkBackend`.** This is the ticket's ARM64 blocker and it is more
concrete than `CUESYNC-5`'s was. Both candidate distributions are x64-shaped:
**gvsbuild**'s published release assets are x64 and its ARM64 story is at best experimental
(**UNVERIFIED**), and **MSYS2**'s ARM64 environment (`CLANGARM64`) is a Clang/LLVM
environment whose GTK 4 package availability and completeness are unconfirmed
(**UNVERIFIED**) — and neither is MSVC-ABI ARM64, which is what a Swift ARM64 Windows build
would need. Note this replaces rather than removes `CUESYNC-5`'s flag: that spec flagged the
**WinUI** backend's WinRT projections as the ARM64 unknown; switching to `GtkBackend` swaps
that unknown for this one, and does not resolve it. Ironically WinUI, as a Microsoft-shipped
Windows framework, is the more likely of the two to have first-class ARM64 support — worth
recording in the PR as a known cost of the §0.1 choice. Answer §0.7 and report the finding
honestly; do not leave the platform table optimistic. `CSQLite` and `CZlib` remain portable C
with **no** ARM64 gap, and `CueSyncCore` — which is all the tests exercise — has no GTK
dependency at all.

**Cannot-reproduce-faithfully call-outs:** no *new* fidelity delta is introduced — this ticket
still ports no screen, so there is nothing to compare against `app.jsx` yet. But the §0.1
choice has a fidelity consequence the next tickets inherit and the PR should state: **on
macOS, the SwiftPM build now draws with GTK widgets rather than AppKit ones**, so that build
will not look or feel native on macOS. That is acceptable *here* precisely because the
shipping macOS app is the untouched Xcode/SwiftUI one and this build exists to prove the
Windows path — but if `GtkBackend` ever becomes the macOS path, that is a fidelity regression
against every screen in `specs/CUESYNC-3.md`, not a detail. The open fidelity risks inherited
from `CUESYNC-3` §D remain live and land with the tickets that port them: the immediate-mode
`Canvas` envelope editor, `.onHover` button animation, the `NonSelectingTextField` focus
nuance, drag-to-reorder panels, and `NSImage`-rendered `BrandIcons` SVGs. `CUESYNC-5`'s
hand-off item also still stands: `Theme/ThemeColors.swift` is `#if canImport(AppKit)`-wrapped
and excluded from every SwiftPM target, so the swift-cross-ui path still has **no theme colors
at all** — porting it is a prerequisite of the first real screen, not of this ticket.
