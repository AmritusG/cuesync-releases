# CUESYNC-9 — input is DEAD end-to-end; fix it at the ROOT, machine-verified

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.** · **Base branch:** `adw/CUESYNC-8` (keep all of 7+8's work)

> Scope note. The full swift-cross-ui re-host (CUESYNC-5/6/7) and CUESYNC-8's app-layer
> hit-test fix (`can-target = false` on decorative `Shape` widgets,
> `patches/swift-cross-ui-0.8.0-gtk-interactivity.patch`) already landed and stay. Yet the GTE on
> the clean PC (2026-07-19, **second consecutive time**, identical to CUESYNC-7): **"program opens,
> nothing can be clicked."** Every pipeline gate was green both times. The conclusion the ticket
> draws is decisive: the failure is **NOT** app-level hit-testing — CUESYNC-8 fixed overlays/
> z-order/gesture picking at the app layer and **changed nothing observable**, so the real defect
> lives **below** the widget tree, at the toolkit/window/main-loop boundary. This ticket finds that
> defect against a **machine that clicks** (the click-probe gate), fixes it at the root via the
> established dependency-patch mechanism, and proves it with the same probe — **no screen, wording,
> layout, or app-code redesign; no CI/adversarial-suite regression; the CUESYNC-8 interactivity
> patch preserved.**

---

## 1. Problem

CueSync's Windows/swift-cross-ui port draws the whole UI correctly but **not one pixel of input is
delivered anywhere** — buttons don't fire, sections don't collapse, rows don't select, steppers
don't step, and (unlike CUESYNC-8's source-read assumption) even `TextField`s and scrollbars are
inert. The rendering path works; the event path is dead **window-wide**, which is the classic
signature of a GTK window that paints but never dispatches input — a broken/absent event-source ↔
Win32 message-pump integration, a root surface created without input, or an invisible grab — none
of which the app-layer CUESYNC-8 fix could touch. The user-facing outcome of this ticket: on the
clean PC every control that renders also **responds** — buttons click, sections collapse/expand,
rows select, text fields accept typed input, steppers step — with the app's screens, wording, and
layout byte-for-byte unchanged, the CUESYNC-8 interactivity work intact, and the whole existing
test/CI suite still green. The fix is proven by a machine, not a theory: the click-probe gate must
turn GREEN (a synthesized click on the window's own GTK-drawn close button kills the process, and a
center-click changes pixels).

## 2. Plan

The pinned dependency is **never edited in place**: every change to swift-cross-ui is a checked-in,
reviewable `.patch` applied to the *resolved checkout* by `git apply`, exactly like the existing
gulong/gsize `-replace` step and the CUESYNC-8 interactivity `git apply` step in
`.github/workflows/swift-windows.yml`. Verify first, fix **one** suspect, at the root, and let the
probe decide. Steps are atomic and land under `CueSync/`, `patches/`, `scripts/`, `.github/`,
`agents/`, `specs/`, `Tests/`.

1. **Consume the FIRST red probe round before touching any code.** The click-probe gate launches the
   real built `CueSync.exe` on the build box, synthesizes a REAL mouse click on the window's own
   GTK-drawn (client-side-decoration) close button and demands the process die, then clicks the
   window center and diffs before/after screenshots; evidence lands in `.factory/probe/`. Read that
   first red round's screenshots + findings and **classify the failure into exactly one fork** at the
   top of `specs/CUESYNC-9-findings.md`:
   - **Fork W (window-level input dead):** the close-button click does **not** kill the process AND
     the center click does **not** change pixels → no pointer input reaches *any* widget → the defect
     is at the window/surface/main-loop layer (suspects 1–3 below). This matches "the whole window is
     inert including scrollbars and text fields."
   - **Fork D (widget-level dispatch dead):** the close-button click **does** kill the process but the
     center click changes nothing → window chrome receives input, the app's own view-tree does not →
     the defect is in event propagation into the app widgets.
   Do not change anything until this classification is written down — it selects which suspect leads.

2. **Audit the pinned source on the box — read it, do not guess.** (The planning environment has no
   `github.com` access and no resolved checkout, exactly as in CUESYNC-8 §2; the audit is deliberately
   left to be read on-box.) Run `swift package resolve`, apply the existing CUESYNC-8 interactivity
   patch first (so you audit the same bytes the box builds), then read `.build/checkouts/swift-cross-ui`
   confirmed at commit `a6d206370812e3b9edba259d167e848892c5013d`. Produce `file:line` citations for:
   - **the main-loop / app-run path:** `Sources/GtkBackend/GtkBackend.swift` (`runMainLoop`/`run`, any
     manual `g_main_context` iteration, any `DispatchQueue.main`/scheduler shim) and
     `Sources/Gtk/Application.swift` (`run()` → `g_application_run`, the `activate` handler). A GLib
     main loop that renders frames but never drains the GDK/Win32 event source is the textbook cause of
     "paints but no input."
   - **the root window / surface:** `Sources/Gtk/Widgets/ApplicationWindow.swift` / `Window.swift`
     (`present()`, `setChild`, and the root container's `can-target` / `can-focus` / input-region /
     focus state) and the backend's `createWindow` / `setChild` / `show`.
   - **event-controller attachment & propagation phase** for tap/hover (`createTapGestureTarget`,
     `createHoverTarget`, `GestureClick`, `EventControllerMotion`) — whether the target widget is
     focusable/targetable and whether the phase actually delivers.
   - **any Windows-specific display/backend init** (`GDK_BACKEND`, `setenv`, gdk-win32).
   Then, because the box has network, **search upstream** swift-cross-ui issues / PRs / commits dated
   **after** tag `v0.8.0` for Windows input / unresponsive / message-pump / gdk-win32 / event-dispatch
   fixes. If upstream already fixed it, a minimal backport of that fix (pinned to `v0.8.0`) is the
   candidate — never a re-pin to a moving label.

3. **Name ONE root cause matching evidence + source; write the finding.** In
   `specs/CUESYNC-9-findings.md` (mirror `specs/CUESYNC-8-findings.md`'s structure and rigor): state
   the fork from step 1, the exact defect with `file:line` citations, *why* it produces "paints but no
   input," and which of the three ranked suspects it is —
   **(1)** upstream GtkBackend input wiring / GLib-loop ↔ Win32-pump integration (prime suspect: the
   whole window is inert, and the app-layer fix changed nothing);
   **(2)** a modal / invisible grab (zero-opacity surface or active GTK grab swallowing every event
   before widget dispatch);
   **(3)** window-level flags (root surface created without input region, or `can-focus`/`can-target`
   off at the root).
   Rule out the other two with evidence, not vibes.

4. **Fix at the root via the established dependency-patch mechanism — one suspect, minimal, documented.**
   Author a **new** checked-in patch `patches/swift-cross-ui-0.8.0-windows-input.patch` (name the slug
   for the root cause actually found) — kept **separate** from the CUESYNC-8 interactivity patch so each
   patch documents exactly one root cause and CUESYNC-8's tests stay green. It must be a real `git apply`
   unified diff against the pinned commit, touching only the file(s) named in step 3, using GTK/GLib's
   own APIs — **no new dependency, no network, no dynamic load, no `sed`/`-replace`.** Add a `git apply`
   step named **"Patch swift-cross-ui Windows input dispatch"** (keep the name in sync with the tests and
   all three legs) to **all three GtkBackend-compiling legs** (`macos`, `windows-build`, `windows-test`),
   placed **after** `swift package resolve` / the swift-java symlink repair / the existing patch steps and
   **before** `swift build` / `swift test`. The step must: clear the Windows read-only flag first on
   **exactly** the file(s) it patches (`Set-ItemProperty … -Name IsReadOnly -Value $false`, same rationale
   as the gulong/gsize step); be **idempotent** (`git apply --reverse --check` guard); and be pinned in a
   comment naming commit `a6d206370812e3b9edba259d167e848892c5013d`. Extend
   `scripts/patch-swift-cross-ui.sh` to apply this patch too (idempotent, fail-fast). **Do not touch or
   regress** the CUESYNC-8 interactivity patch or its `can-target` hunk.
   *Contingency:* if the audit proves the root is a GTK-runtime/init **config** defect rather than an
   upstream **source** bug (e.g. a display/input-init call the app shell must make, or an env the launch
   must set), apply the minimal, documented equivalent at the app-shell layer instead — still one suspect,
   still evidence-driven, still using the framework's own API, and still **never** introducing GtkFixed /
   absolute positioning.

5. **Iterate against the probe gate; revert non-movers.** Rebuild and re-run the click-probe gate. GREEN =
   the synthesized close-click **kills the process** AND the center click **changes pixels**. Apply **one
   suspect per round**: if a round's fix does not move the probe, **revert that hunk** before trying the
   next suspect — never stack speculative patches. If the close-click starts killing but in-app controls
   stay inert (a Fork W → Fork D transition), record it in the round notes and continue on the
   widget-dispatch suspect.

6. **Envelope-canvas drag — re-verify, don't invent.** Once input is live, re-check the resolved checkout
   for a pointer-location / `DragGesture` primitive at 0.8.0. Per CUESYNC-8 findings §2.4 none exists, so
   the DoD's "envelope canvas drags" stays **cannot-reproduce-faithfully**: keep the toolbar + `CuePointsTableView`
   as the complete editor and keep the callout in `EnvelopeCanvasView.swift`/findings accurate; **do NOT add
   GtkFixed or absolute positioning.** Only if the input fix genuinely surfaces a usable location-aware
   primitive, wire click-to-select / drag-to-move on the canvas points.

7. **Land the lesson.** Append a **new** section to `agents/uiux.md` (distinct from the existing
   `can-target` section): the generalized window/main-loop input-death rule the root cause proves — *a GTK
   window that paints but dispatches no input means the event-source/main-loop integration or the root
   surface's input flags, not widget hit-testing; before touching app widgets, verify with a real
   synthesized click on the window's own chrome (close button) whether ANY input is delivered.* Ground it in
   the concrete CueSync instance with the `file:line` root cause and the fix. Document the fix in the new
   patch header and the dev script per the dependency-patch convention.

8. **Tests — source/workflow-structural, mirroring the harness.** The `UI/` files compile only under
   `#if CUESYNC_CROSSUI` (which `CueSyncCoreTests` does not define), so `swift test` pins **source/workflow
   text**, not live GTK behavior — the click-probe gate and the GTE are what prove live behavior. Add to
   `Tests/CueSyncCoreTests/` (mirror `CUESYNC8GtkInteractivityWorkflowTests`):
   - the new input-patch step exists on `macos` + `windows-build` + `windows-test`, runs after resolve and
     before build/test, is idempotent-guarded, clears the Windows read-only flag on **exactly** its patched
     file(s), and names the pinned `v0.8.0` commit;
   - the new `patches/*.patch` exists, is a real unified diff (not `sed`/`-replace`), and targets the
     file(s) named in `specs/CUESYNC-9-findings.md`;
   - `scripts/patch-swift-cross-ui.sh` applies the new patch too (executable code, idempotent, fail-fast);
   - a **no-regression** guard that the CUESYNC-8 interactivity patch is unchanged (still targets exactly
     `Widget.swift` + `GtkBackend.swift`, `can-target` hunk intact) and all `CUESYNC8…` tests stay green;
   - `specs/CUESYNC-9-findings.md` exists and cites the root cause.
   Keep the existing `CrossUI*`/adversarial/`CUESYNC6*`/`CUESYNC8*` suites green. All tests are
   network-free and `#filePath`-relative; the suite's `func test…` count must **not** drop below the audited
   baseline (`CUESYNC6WindowsGtkWorkflowTests.testMethodCountAcrossTheSuiteHasNotDroppedBelowTheAuditedBaseline`).

## 3. Acceptance criteria

**Machine-verified — the click-probe gate on the box (the DoD's ground truth):**
- The click-probe gate is **GREEN**: the synthesized click on the window's own GTK-drawn close button
  kills the `CueSync.exe` process, **and** the window-center click changes pixels (before/after
  screenshot diff is non-empty). Evidence retained in `.factory/probe/`.

**Interactivity — GTE on the clean PC (Amrit clicks):**
- Every button fires: New / Open / Save; Create Envelope; Resolume, Rekordbox, Serato, Engine DJ,
  ShowKontrol imports; Reset / Side-By-Side; Dark / Light; True / False; + Add Cue Point; offset −/+;
  Load Audio; Remove; Save XML; Save ShowKontrol Cue.
- Section headers collapse/expand, the ▶/▼ glyph flips, and state persists across relaunch
  (`state.collapsedSections` + `savePreferences()`).
- Playlist rows select, folder rows expand/collapse, track rows select and show their hover highlight.
- Stepper ▲/▼ arrows change the value; **every `TextField` accepts typed input**; the sort and
  interpolation `Picker`s change selection; the ON / Lock X / Lock Y checkboxes toggle.
- The duration modal's Cancel/Import respond; the unsaved-changes alert's Discard/Cancel respond.
- Envelope canvas: per step 6 — either click-to-select / drag-to-move responds (only if 0.8.0 exposes
  the primitive), **or** the cannot-reproduce-faithfully callout stays documented and the toolbar/table
  editor is confirmed fully functional.

**Root-cause & fix mechanism — structural:**
- `specs/CUESYNC-9-findings.md` exists, classifies the failure as Fork W or Fork D from the first red
  probe round, and names one root cause with `file:line` citations, ruling out the other suspects.
- A new checked-in `patches/swift-cross-ui-0.8.0-windows-input.patch` (slug named for the actual root
  cause) exists, is a **real unified diff** (`diff --git` hunks, never `sed`/`-replace`), targets only
  the file(s) named in the findings, and uses GTK/GLib's own APIs — no new dependency, no network, no
  dynamic load.
- The new `git apply` step exists on **all three** GtkBackend-compiling legs (`macos`, `windows-build`,
  `windows-test`), runs **after** resolve/existing patches and **before** build/test, is idempotent
  (`git apply --reverse --check`), clears the Windows read-only flag on **exactly** its patched file(s),
  and names the pinned `v0.8.0` commit `a6d206370812e3b9edba259d167e848892c5013d`.
- `scripts/patch-swift-cross-ui.sh` applies the new patch too, in executable code, idempotently and
  fail-fast.

**No-regression / invariants:**
- `swift · macos-latest`, `windows-latest (build)`, `windows-latest (test)` stay green; the adversarial
  suite stays green; the AppKit-free `UI/` grep guard stays green.
- The **CUESYNC-8 interactivity patch is unchanged** — still targets exactly `Sources/Gtk/Widgets/Widget.swift`
  + `Sources/GtkBackend/GtkBackend.swift`, `can-target`/`canTarget = false` hunk intact — and every
  `CUESYNC8GtkInteractivityWorkflowTests` case stays green.
- swift-cross-ui stays pinned `exact: "0.8.0"` (Package.swift and Package.resolved **unchanged**); the
  dependency is patched at the checkout, never forked or re-pinned.
- No file under `UI/` gains an `import AppKit` or an NS-prefixed symbol; **no `GtkFixed`/absolute-position
  API** is introduced anywhere (patch or app code).
- `agents/uiux.md` gains a new section stating the window/main-loop input-death lesson grounded in the
  concrete CueSync instance (in addition to the existing `can-target` section, which stays).
- The suite's `func test…` count does not drop below the audited baseline; **no Linux or Windows-ARM64
  runner is added** to the matrix
  (`CUESYNC6WindowsGtkWorkflowTests.testNoLinuxOrWindowsArm64RunnerIsAddedToTheMatrix`).

## 4. Threat model

- **Inputs crossing a trust boundary.** This ticket wires window/global input; it adds **no new parser**.
  But making the *whole* UI live means value-handling paths that were previously unreachable on Windows now
  actually run, so their existing guards matter *more*: (a) `StepperField.commitText()`'s `parsed.isFinite`
  check must stay — a hand-typed `nan`/`inf` in a cue **position** or **Y** field must never reach
  `cue.start` / `cue.yValue` and then the envelope `Path`/curve math (`CrossUIControlsTests` pins this; do
  not weaken it); (b) `TextTools.slugify()` on any name that becomes an export filename stays the sanitiser
  at that boundary (unchanged from CUESYNC-7). Values still originate from untrusted files (Rekordbox XML,
  Serato GEOB, Engine DJ SQLite, ShowKontrol/Resolume) and user text.
- **The patched dependency is a supply-chain surface.** The fix modifies bytes of a pinned, audited
  dependency at build time — it must be a **checked-in, reviewable `.patch` applied by `git apply` to the
  exact pinned commit** (`a6d2063…`), never an unpinned `sed`/`-replace` against a moving target, so "the
  code we audited" and "the code we build" stay identical. The patch adds only window/main-loop/input
  wiring using GTK/GLib's own APIs: no network call, no new dependency, no dynamic code load. The pin stays
  `exact: "0.8.0"`; `Package.resolved` is untouched. (The DLL-closure / negative-control checks in the
  Windows job continue to gate what ships.) The click-probe gate runs the built `CueSync.exe` on a
  build-box VM and drives synthetic input — it must not be given any secret and must write only to
  `.factory/probe/`.
- **Secrets / credentials touched:** **none.** No token, key, password, or signing material is read,
  logged, or written. The Developer-ID cert and the `amritus-notary` keychain profile used by `scripts/`
  are out of scope — do not invoke or modify them. No secret is added to the workflow or the probe harness.
- **Values requiring a cryptographically secure primitive:** **none introduced or required.** This ticket
  generates no key, nonce, token, session id, or temp-file name — so there is no place for
  `Date`/counter/seedable RNG, and none may be added in the patch, the probe-consuming code, or the
  scripts. (CUESYNC-7's `generateToken()` CSPRNG requirement is unrelated and untouched.)
- **No hardcoded paths / separators / line endings.** The patch-application script and any probe-evidence
  reading operate on paths derived at runtime (the resolved checkout via `git apply` from the package root;
  `.factory/probe/` relative to the repo), never a hardcoded `/tmp` or `C:\…`; tests locate files via
  `#filePath`. ShowKontrol's `\r`-only line ending and every exporter are untouched.

## 5. Target platforms

- **Windows x64** — **primary target**; the clean-PC GTE and the click-probe gate both run here. GtkBackend
  + gvsbuild GTK 4, Swift 6.3.3. The input-death is a Windows-runtime failure; the fix is what makes the
  window interactive. Iteration goes through the click-probe gate on the build box; GitHub CI once at the end.
- **macOS 14+** — two builds: the shipping Xcode/SwiftUI app (`App/`, `Views/` — untouched, natively
  interactive) and the SwiftPM GtkBackend build on CI, which compiles GtkBackend and therefore needs the
  same patch to build (Homebrew `gtk4`). The patch must be OS/architecture-neutral GTK/GLib code that keeps
  the macOS GtkBackend build green; the macOS SwiftUI app is unaffected.
- **Windows ARM64** — ⚠️ **not CI-gated, not guaranteed.** swift-cross-ui's GTK/WinRT transitive closure
  carries the same unverified-ARM64 status flagged since CUESYNC-5; the input patch is architecture-neutral
  GTK/GLib code and adds **no new** ARM64 gap, but ARM64 must not be claimed without a green ARM64 build (no
  hosted ARM64 Windows runner is wired). Flag honestly in the PR.
- **Linux x64** — same source + same patch builds with system GTK 4; **no CI leg is added** — the workflow
  must keep exactly zero Linux/ARM64 matrix legs
  (`CUESYNC6WindowsGtkWorkflowTests.testNoLinuxOrWindowsArm64RunnerIsAddedToTheMatrix` enforces this).
- **Dependency lacking confirmed Windows-ARM64 support:** `swift-cross-ui` (GtkBackend + its GTK/WinRT
  closure) — unchanged from prior tickets. **No new dependency is added by this ticket.**
