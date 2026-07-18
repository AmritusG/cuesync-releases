# CUESYNC-8 — the UI renders; make it INTERACTIVE

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.** · **Base branch:** `adw/CUESYNC-7`

> Scope note. The full swift-cross-ui UI re-host already landed (Header/Footer, all four sections,
> `CollapsibleSection`, controls, `AppState`, `CueSyncApp`, built by `swift build` against GtkBackend
> on `windows-latest`/`macos-latest`). The GTE on the clean PC (2026-07-18) reports: **"Everything is
> visible, but I cannot click anything."** Rendering layer: done. Event layer: dead. This ticket makes
> the already-rendered UI **respond** — with **no screen, wording, layout, or app-code redesign**, and
> **no CI/adversarial-suite regression**. The fix is at the toolkit boundary (swift-cross-ui/GtkBackend),
> not in the screens.

---

## 1. Problem

CueSync's Windows/swift-cross-ui port draws the whole UI correctly but no control reacts to input:
buttons don't fire, sections don't collapse/expand, playlist and track rows don't select, stepper arrows
don't step, the modal and envelope preview don't respond. The rendering path works; the event path is
dead. Root cause lives at the toolkit boundary, not in the app: the port implements **every primary
affordance** (all import/action/toggle/export buttons, the `CollapsibleSection` header, list rows,
`StepperField` arrows, the duration-modal actions) as a plain view carrying `.onTapGesture` / `.onHover`
— never a real `SwiftCrossUI.Button` — because 0.8.0's `Button` takes only a fixed `String` label and
can't wrap a glyph+label. At the pinned **swift-cross-ui v0.8.0** (`exact: "0.8.0"`, commit
`a6d206370812e3b9edba259d167e848892c5013d`), GtkBackend does not deliver those tap/hover events to those
widgets — and/or the decorative border `.overlay { RoundedRectangle().stroke(...) }` that wraps nearly
every control sits above the tap target and intercepts the event. The controls that DO use real GTK
widgets — `TextField` (GtkEntry), `Picker` (GtkDropDown), `Toggle` (GtkCheckButton), the menu `Button`s,
`.sheet`/`.alert` — still work, which is why typing into a field works while "clicking" appears totally
dead. The user-facing outcome of this ticket: on the clean PC every control that renders also responds —
buttons click, sections collapse/expand, rows select, fields accept input, steppers step — with the app's
screens, wording, and layout byte-for-byte unchanged, and the whole existing test/CI suite still green.

## 2. Plan

The whole app-level `CueSync/CueSync/UI/` tree stays as-is unless a step says otherwise — **keeping the
`.onTapGesture` structure is deliberate** (the existing source-pinning tests assert it; see step 4). The
pinned dependency is **never edited in place**: any change to swift-cross-ui is a checked-in, reviewable
patch applied to the *resolved checkout* by `git apply`, exactly like the existing gulong/gsize
`-replace` step in `.github/workflows/swift-windows.yml`. Verify first, fix one suspect, at the root.

1. **Reproduce and isolate the dead layer (verify before touching anything).** On the **ci-local**
   Windows gate, build/run a minimal probe (a temporary screen behind a debug flag, or a throwaway
   `@main` in a scratch target — do not commit it to the shipping app) containing exactly: (a) a real
   `Button("probe") { … }`, (b) a `Text("probe").onTapGesture { … }`, (c) a `Text("probe").onHover { … }`,
   each flipping a visible state. On the clean PC, record which fire. Expected from the audit below: the
   real `Button` fires (menu New/Undo/Redo already prove GtkButton `clicked` is wired); `.onTapGesture` /
   `.onHover` do not. This isolates the gap to the gesture/hover path (not the GTK main loop, not layout).

2. **Read the pinned GtkBackend source and name the exact gap.** *(The pinned source could not be audited
   during planning — the planning environment has no access to `github.com`/`raw.githubusercontent.com`
   and no resolved checkout, so the exact modifier→`AppBackend`→GtkBackend symbol chain is deliberately
   left to be read on-box rather than guessed. Do not assume; read it.)* After `swift package resolve`,
   inspect `.build/checkouts/swift-cross-ui`:
   - the `onTapGesture` / `onHover` modifier definitions under `Sources/SwiftCrossUI`,
   - the `AppBackend` protocol method(s) they call,
   - GtkBackend's conformance under `Sources/GtkBackend`,
   - the Gtk widget wrappers under `Sources/Gtk` (`GtkGestureClick`, `GtkEventControllerMotion`,
     `GtkButton`'s `clicked`).
   Decide which of two roots holds:
   - **(H1) missing wiring** — the modifier's backend hook is unimplemented / a default no-op, so the
     callback is stored but never invoked; or
   - **(H2) overlay interception** — the hook is implemented but attached to a widget GTK never targets
     because a decorative sibling layer (the `.overlay` border, or the base container's `can-target`)
     sits above it and swallows the click.
   Write the finding — with `file:line` citations — to `specs/CUESYNC-8-findings.md`, mirroring
   `specs/CUESYNC-6-findings.md`.

3. **Fix at the root via the established workflow-patch mechanism.** Author a checked-in patch under
   `patches/` (e.g. `patches/swift-cross-ui-0.8.0-gtk-interactivity.patch`) whose content depends on
   step 2:
   - **(H1):** implement the tap/hover backend hook in GtkBackend by attaching a `GtkGestureClick`
     (and, for hover, a `GtkEventControllerMotion`) to the widget the modifier targets, invoking the
     stored Swift callback on `pressed`/`released` (and `enter`/`leave`). Use GTK's own event-controller
     API — no new dependency, no network, no dynamic loading.
   - **(H2):** make a decorative overlay/background child that carries no interactive handler be created
     with `can-target = false` (GTK's equivalent of `allowsHitTesting(false)`), so taps fall through to
     the base widget's gesture — the same protection the macOS original already gives `GridOverlay`
     (`Views/ContentView.swift:187`, `.allowsHitTesting(false)`).
   Apply it with a new **`git apply`** workflow step in `.github/workflows/swift-windows.yml`, on **all
   three legs that compile GtkBackend** (`macos`, `windows-build`, `windows-test`), placed **after**
   `swift package resolve` / the swift-java symlink repair and **before** `swift build` / `swift test`.
   The step must: clear the read-only flag first on Windows (dependency sources check out read-only —
   the reason the gulong step does `Set-ItemProperty -Name IsReadOnly -Value $false`); be **idempotent**
   (guard with `git apply --reverse --check` so a second run is a no-op); and be pinned to the v0.8.0 tag
   in a comment naming the audited commit. Add `scripts/patch-swift-cross-ui.sh` (invoked by the dev /
   ci-local loop) applying the same patch locally so the build agent can iterate without GitHub CI.

4. **Do NOT convert `.onTapGesture` controls to real `Button`s.** The existing source-pinning tests
   (`Tests/CueSyncCoreTests/CrossUIControlsTests.swift`, `CrossUIChromeTests.swift`) assert
   `.onTapGesture` presence and forbid a literal `Button(` in these controls (e.g.
   `testBrandButtonsDeclareNoRealButtonOnlyTapGestureSubstitutes`,
   `testCollapsibleSectionHeaderTapTogglesCollapsedSectionsAndSavesPreferences`), and a `String`-only
   `Button` can't reproduce the glyph+label brand buttons faithfully. The patch makes the existing app
   code start working **unchanged** — that is what keeps the suite green (no regression) and the port
   faithful.

5. **Envelope canvas interactivity — honor if the primitive exists, else document.** The DoD lists "the
   envelope canvas responds to drags." `UI/Sections/EnvelopeCanvasView.swift` currently drops all pointer
   editing on the claim that 0.8.0 has "no `DragGesture`, no pointer location on tap." Re-verify against
   the resolved checkout (step 2): **if** 0.8.0 exposes a tap/drag location or a `DragGesture` usable on
   GtkBackend, wire click-to-select / drag-to-move on the canvas points (keeping the toolbar + cue table
   editor intact). **If it genuinely does not exist** even after the gesture patch, record it as an
   explicit **cannot-reproduce-faithfully** callout in the findings doc and the PR — the toolbar/table
   stay the complete editor — rather than inventing the `GtkFixed`/absolute-positioning path the port
   forbids. Do not add `GtkFixed` or absolute positioning.

6. **Tests — source/workflow-structural, matching the harness.** The CrossUI/`UI` files compile only
   under `#if CUESYNC_CROSSUI`, which `CueSyncCoreTests` does not define, so tests pin **source/workflow
   text**, not live GTK behavior. Add to `Tests/CueSyncCoreTests/`:
   - a workflow test (mirror `CUESYNC6WindowsGtkWorkflowTests`) asserting the gesture patch step is
     present on `macos` + `windows-build` + `windows-test`, runs after resolve and before build/test,
     clears the Windows read-only flag, is idempotent-guarded, and names the pinned v0.8.0 commit;
   - a test asserting the checked-in `patches/*.patch` exists and targets the audited GtkBackend/Gtk
     file(s) named in step 2;
   - if step 3 took the **H2** path, a guard that no decorative `.overlay`/background under `UI/` is
     created interactive (asserted at whatever layer the patch/app expresses hit-test-transparency).
   Keep the existing `CrossUIControlsTests`/`CrossUIChromeTests` green. All tests are network-free and
   `#filePath`-relative, and the suite's `func test…` count must not drop below the audited baseline
   (`CUESYNC6WindowsGtkWorkflowTests.testMethodCountAcrossTheSuiteHasNotDroppedBelowTheAuditedBaseline`).

7. **Land the lesson in `agents/uiux.md`** (create the file; `agents/` does not yet exist). State the
   generalized rule the root cause proves, plus the concrete CueSync instance, so no future port repeats
   it — e.g.: *On swift-cross-ui/GTK, decorative layers (backgrounds, overlays, borders) must be
   hit-test-transparent (`can-target = false`, the GTK analogue of SwiftUI's `allowsHitTesting(false)`),
   and any affordance that must receive input needs a mechanism the target backend actually delivers
   events for — a real `Button`, or a gesture controller the backend wires. A view that only renders is
   not a control; verify tap/hover delivery on the real backend, never assume a modifier that compiles is
   also live.*

## 3. Acceptance criteria

**Interactivity — GTE on the clean PC (Amrit clicks):**
- Every button fires its action: New / Open / Save; Create Envelope; Resolume, Rekordbox, Serato, Engine
  DJ, ShowKontrol imports; Reset / Side-By-Side; Dark / Light; True / False; + Add Cue Point; offset −/+;
  Load Audio; Remove; Save XML; Save ShowKontrol Cue.
- Section headers collapse/expand, the ▶/▼ glyph flips, and the state persists across relaunch
  (`state.collapsedSections` + `savePreferences()`).
- Playlist rows select, folder rows expand/collapse, track rows select and show their hover highlight.
- Stepper ▲/▼ arrows change the value; every `TextField` accepts typed input; the sort and interpolation
  `Picker`s change selection; the ON / Lock X / Lock Y checkboxes toggle.
- The duration modal's Cancel/Import respond; the unsaved-changes alert's Discard/Cancel respond.
- Envelope canvas: per step 5 — either click-to-select / drag-to-move responds, **or** the callout is
  documented and the table/toolbar editor is confirmed fully functional.

**No-regression / structural — CI + tests:**
- `swift · macos-latest`, `windows-latest (build)`, `windows-latest (test)` stay green; the adversarial
  suite stays green; the AppKit-free `UI/` grep guard stays green.
- The gesture patch step exists on all three GtkBackend-compiling legs, is idempotent, clears the Windows
  read-only flag, runs after resolve and before build/test, and is pinned to the v0.8.0 commit.
- swift-cross-ui stays pinned `exact: "0.8.0"` (Package.swift and Package.resolved unchanged); the
  dependency is patched at the checkout, never forked or re-pinned.
- No file under `UI/` gains an `import AppKit` or an NS-prefixed symbol; no `GtkFixed`/absolute-position
  API is introduced anywhere.
- `agents/uiux.md` exists and states the hit-test/interactivity lesson with the concrete CueSync instance.
- The suite's `func test…` count does not drop below the audited baseline.

## 4. Threat model

- **Inputs crossing a trust boundary.** This ticket wires events; it adds no new parser. But making
  controls live means value-handling paths that were previously unreachable on Windows now actually run,
  so their existing guards matter *more*: (a) `StepperField.commitText()`'s `parsed.isFinite` check must
  stay — a hand-typed `nan`/`inf` in a cue **position** or **Y** field must never reach `cue.start` /
  `cue.yValue` and then the envelope `Path`/curve math (`CrossUIControlsTests` pins this; do not weaken
  it); (b) `TextTools.slugify()` on any name that becomes an export filename stays the sanitiser at that
  boundary (unchanged from CUESYNC-7). Values still originate from untrusted files (Rekordbox XML, Serato
  GEOB, Engine DJ SQLite, ShowKontrol/Resolume) and user text.
- **The patched dependency is a supply-chain surface.** The fix modifies bytes of a pinned, audited
  dependency at build time — it must be a **checked-in, reviewable `.patch` applied by `git apply` to the
  exact pinned commit**, never an unpinned `sed`/`-replace` against a moving target, so "the code we
  audited" and "the code we build" stay identical. The patch adds only gesture / hit-test wiring using
  GTK's own event-controller APIs: no network call, no new dependency, no dynamic code load. The pin stays
  `exact: "0.8.0"`; `Package.resolved` is untouched. (The DLL-closure/negative-control checks in the
  Windows job continue to gate what ships.)
- **Secrets / credentials touched:** **none.** No token, key, password, or signing material is read,
  logged, or written. The Developer-ID cert and the `amritus-notary` keychain profile used by `scripts/`
  are out of scope — do not invoke or modify them. No secret is added to the workflow.
- **Values requiring a cryptographically secure primitive:** **none introduced or required.** This ticket
  generates no key, nonce, token, session id, or temp-file name — so there is no place for
  `Date`/counter/seedable RNG, and none may be added in the patch, the probe, or the scripts. (CUESYNC-7's
  `generateToken()` CSPRNG requirement is unrelated and untouched.)
- **No hardcoded paths / separators / line endings.** The patch-application script and any probe operate
  on the resolved checkout path derived at runtime (via `git apply` from the package root), never a
  hardcoded `/tmp` or `C:\…`; tests locate files via `#filePath`. ShowKontrol's `\r`-only line ending and
  every exporter are untouched.

## 5. Target platforms

- **Windows x64** — **primary target**; the clean-PC GTE runs here. GtkBackend + gvsbuild GTK 4, Swift
  6.3.3. The gesture patch is what makes it interactive. Iteration goes through the ci-local Windows gate;
  GitHub CI once at the end.
- **macOS 14+** — two builds: the shipping Xcode/SwiftUI app (`App/`, `Views/` — untouched, natively
  interactive) and the SwiftPM GtkBackend build on CI, which compiles GtkBackend too and therefore needs
  the same patch to build and behave identically (Homebrew `gtk4`).
- **Windows ARM64** — ⚠️ **not CI-gated, not guaranteed.** swift-cross-ui's GTK/WinRT transitive closure
  carries the same unverified-ARM64 status flagged since CUESYNC-5; the gesture patch is architecture-
  neutral GTK code and adds **no new** ARM64 gap, but ARM64 must not be claimed without a green ARM64
  build (no hosted ARM64 Windows runner is wired). Flag honestly in the PR.
- **Linux x64** — same source + same patch build with system GTK 4; **no CI leg is added** — the workflow
  must keep exactly zero Linux/ARM64 matrix legs
  (`CUESYNC6WindowsGtkWorkflowTests.testNoLinuxOrWindowsArm64RunnerIsAddedToTheMatrix` enforces this).
- **Dependency lacking confirmed Windows-ARM64 support:** `swift-cross-ui` (GtkBackend + its GTK/WinRT
  closure) — unchanged from prior tickets. **No new dependency is added by this ticket.**
