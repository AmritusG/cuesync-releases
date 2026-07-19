# CUESYNC-9 §§1–3 findings — window/main-loop input death

## §0.5 — ROUND 6 (2026-07-19, this session): round 5's measurement was RIGHT but delivered to a dead channel — route it back, don't guess again

> This is the sixth CUESYNC-9 round. It ships **no** new swift-cross-ui input patch. Round 5's
> premise was correct — *stop guessing, capture CueSync.exe's own stderr* — but it made one wrong
> assumption that silently defeated it: it wrote `CueSync-startup.log` **next to the executable**
> (argv[0] dir → `<repo>/.build/release/`), assuming "the box / gate owner will retrieve it." The
> click-probe gate does **not** retrieve arbitrary files: it returns **only**
> `.factory/probe/before.png` and `.factory/probe/after.png` (confirmed — those two files are the
> entire `.factory/probe/` payload, and `.factory/` is gitignored so nothing else is even tracked).
> So the log round 6 was told to read (§0.4: "Do NOT author round 6 until it is read") **never came
> back**. The decisive datum was captured on the box and then thrown away at the delivery layer.

**Round 6's whole job: fix the delivery so the datum actually returns — through the two channels
that verifiably come back.** No cause is guessed; the instrument is simply pointed at a channel that
works. Two coordinated changes, both measurement-only:

1. **App-shell (`CueSync/CueSync/UI/CueSyncApp.swift`, `startupLogPath()`): write the log where the
   gate already harvests.** The Windows exe ships *inside* the repo build tree
   (`<repo>/.build/release/CueSync.exe`), two levels below `.factory/probe/`. So instead of writing
   next-to-exe (buried in `.build/`, never returned), walk up from argv[0] to the enclosing **repo
   root** — the first ancestor carrying **`Package.swift`** (committed, always present on box and
   CI) — and write `CueSync-startup.log` into `<repo>/.factory/probe/`, **beside** before.png/
   after.png, creating that dir if the gate has not yet (do not gamble on it pre-existing at process
   start). A shipped end-user install has no `Package.swift` ancestor → falls back to next-to-exe
   then CWD, so the `.factory/probe` routing is scoped to exactly the box/CI checkouts where the gate
   reads it. This is the load-bearing change: it puts the log in the one directory the gate is known
   to return.
2. **CI (`.github/workflows/swift-windows.yml`, `windows-build`, new step "Capture CueSync.exe
   startup diagnostics"): launch the exe and echo the log to a channel I can read.** Between the
   Swift-DLL bundling and the artifact upload (adjacency invariant preserved — bundling still runs
   after the closure check and before upload), launch the self-contained exe under a hard 25 s
   timeout, kill it, then `Get-Content` the log to the CI console (so it is readable via
   `gh run view`) and copy it + a best-effort runner screenshot into the uploaded artifact. The
   GitHub `windows-latest` runner is itself a **GPU-less, headless-ish Windows VM** — the same
   constraint round 4 pinned the RDP box's GL failure on — so it exercises the forced
   `GSK_RENDERER=cairo` path and may reproduce the empty-render/dead-input failure directly, handing
   me the app's own `Pango`/`GSK`/`GDK` stderr. The step **always exits 0**; it is an instrument, not
   a gate.

**Upstream re-verified this round (not trusted from a prior round's note).** `moreSwift/swift-cross-ui`
**v0.8.0 is still the latest tag** (checked live via the GitHub API against both `moreSwift` and the
`stackotter` origin — no v0.9). `main` carries **17** commits past the tag; reading every subject
line, **none** touches GtkBackend Windows input, the main loop, the message pump, or gdk-win32 — so
§0's "no fix to backport" holds, now re-confirmed rather than assumed. A sharper signal fell out of
that read: **every** post-v0.8.0 Windows commit targets **WinUIBackend** (`sheets`, `openExternalURL`,
`stdout fix before App.init`, `multiple alerts`) — i.e. upstream actively maintains its *native*
Windows backend and leaves **GtkBackend-on-Windows input unmaintained**. That is context for whoever
owns the ticket after the log is read: if the log proves GtkBackend's win32 event integration is
structurally broken in this pinned build, the durable fix may be a backend decision, not a patchable
one-liner — but that is out of scope for this round and this agent's lane, and is flagged, not acted on.

**Why NOT another input patch this round (the discipline the pattern demands).** Rounds 1–5 each
shipped one fix reasoned from source alone and each returned a **byte-identical** probe (md5s across
rounds: `d3a753ec…` → `e165fe8e…` → `dc6d8369…` → `262857fe…` → `926fa17a…` — the desktop behind the
window changes, the black window + dead input never does). Shipping a sixth blind input patch now —
even the well-motivated one §0.4 names (round 2's priority hack does not stop
`RunLoop.main.limitDate(forMode: .default)` from still `PeekMessage(NULL, …, PM_REMOVE)`-draining the
win32 queue every tick; a non-`.default`-mode pump would) — would repeat the exact failure: an
unverifiable change producing another byte-identical probe and teaching nothing. The lesson stands:
**when every blind fix returns an identical probe, ship the measurement, not guess N+1.** Round 5 had
the right instrument and the wrong wire; round 6 fixes the wire. The three existing patches
(interactivity, windows-input, gsk-renderer) and round 5's stderr redirect are **retained unchanged**
— each still independently revertable.

**The round-7 decision tree — now that the log will actually arrive** (read `<repo>/.factory/probe/
CueSync-startup.log` from the box's returned evidence, and/or the `windows-build` job's "Capture
CueSync.exe startup diagnostics" console output / `cuesync-windows` artifact):
- **No log at all** (banner absent from both channels) → CueSync.exe never reached Swift `App.init()`
  — a packaging/loader failure (missing DLL, bad entry point), not a window bug. Fix the launch path.
- **Banner present, then `Pango-*`/`fontconfig`/`couldn't load font`** → **(B-fonts)**: text measures
  to 0, layout collapses. Bundle fonts + point Pango/fontconfig at them (app-shell). Note this is only
  partially consistent with the pixels — the probe shows **no** accent-colour fills either, which a
  fonts-only failure would leave visible — so weigh it against (A).
- **Banner present, then `Gsk`/`GSK`/GL/`renderer` lines** → **(B-renderer)**: cairo not actually in
  effect / a paint failure. Confirm/force the software renderer earlier.
- **Banner present, log otherwise clean, window empty + dead** → **(A) starvation confirmed**: fix the
  `GtkBackend` run loop so `RunLoop.main` stops draining the win32 queue — a **non-`.default`-mode
  pump** (a run-loop mode with no Windows message-queue mask) that services `DispatchQueue.main`
  without `PeekMessage(NULL)`, replacing round 2's priority hack. Now targetable against evidence.
- **CI runner renders the UI fine but the RDP box does not** → the failure is **box-display/RDP-input
  specific**, not a code defect the GtkBackend patch can reach — hand the runner/probe-harness owner
  the display/input-injection path.

**One-suspect discipline (spec step 5).** Round 6's "suspect" is not a cause — it is the corrected
delivery of round 5's measurement. It touches two files (the app-shell log path; a new, always-green
CI diagnostic step), adds **no** swift-cross-ui patch, no dependency, no network, no dynamic load, and
no `GtkFixed`/absolute positioning. The app screens, wording, and layout are byte-for-byte unchanged
(the change is the log *path*, invisible to the UI). It hands round 7 the datum ten rounds have lacked.

## §0.4 — ROUND 5 (2026-07-19, this session): stop guessing — capture CueSync.exe's own stderr, the one datum every prior round named decisive and deferred

> This is the fifth CUESYNC-9 round, and it deliberately BREAKS the pattern of rounds 1–4: each
> shipped a single Windows-only source/config fix reasoned from source alone, and each produced a
> **byte-identical** `before.png`/`after.png` because nobody on a macOS box could see *why* the box
> fails. Round 5 ships **no** new blind swift-cross-ui patch. It ships the instrument — the exact
> datum §0, §0.1, §0.2 and §0.3 each ended by naming as the decisive next step and then punting:
> **`CueSync.exe`'s own `stderr`**, suppressed because the app links `/SUBSYSTEM:WINDOWS` (no console).

**What the current gate feedback actually tells us (progress, then the real remaining fork).** The
gate now reports "a REAL mouse click on the window's own **(GTK-drawn) close button** did not
terminate the app … renders, ignores the mouse," with `changed_ratio=0` on the centre click. That a
*GTK-drawn* window with a close button is now on screen means **round 4's `GSK_RENDERER=cairo` fix
moved the needle**: the "no window / only the `cmd.exe` launcher" state of §0.3 is gone — a real
CueSync GTK window now paints. The current `.factory/probe/before.png`/`after.png` (byte-identical)
show that window: a near-black (`≈RGB(12,12,12)`, CueSync's `#0a0a0f` background) content area with
**only a vertical scrollbar**, **undersized** (desktop icons visible below/right, well under the
`.frame(minWidth: 1200, minHeight: 700)` in `CueSync/CueSync/UI/CueSyncApp.swift`). So two symptoms
coexist: (i) the window **renders essentially empty / layout-collapsed**, and (ii) **input is dead**.

**Why this is not closeable by another input-only patch.** Symptom (i) — an empty, size-collapsed
render — is **not** a signature pure input-starvation can produce: if the only defect were the
run-loop stealing the Win32 queue (rounds 1–2's suspect (1)), the **full** UI would paint and then
freeze, not render blank. Rounds 1–2 already shipped the priority/floor fix for suspect (1) and the
probe did not move. So at least one of the remaining causes is a **runtime layout/paint** failure
that a run-loop patch cannot touch, and the two live suspects need **different** fixes:
- **(A) main-loop starvation** → a `GtkBackend` run-loop fix (stop `RunLoop.main` draining the Win32
  queue GDK owns; round 2's GLib-priority attempt was too weak / did not move it).
- **(B) a runtime layout/paint collapse** → app-shell/launch config: Pango/fontconfig finding no
  usable font (every text widget measures to 0 → tree collapses → empty, sub-min window), or a DPI/
  scale query returning a degenerate value over the remote session, or the cairo renderer still not
  actually selected. None of these is a swift-cross-ui source bug.

The **only** cheap, on-box datum that separates (A) from (B) — GTK/GLib/Pango/GSK all print their
diagnostics to `stderr` — has never been captured, because the shipped exe has no console.

**Round-5 change (one file, app-shell, NOT a swift-cross-ui patch).**
`CueSync/CueSync/UI/CueSyncApp.swift` gains an `init()` that, `#if os(Windows)`, redirects the
process `stderr` to `CueSync-startup.log` **next to the executable** (argv[0] dir; CWD fallback),
unbuffered, and writes a banner (argv + a "CueSync.exe itself launched" marker). `App.main()` runs
this `init()` **before** `_app.run()` starts GtkBackend's GLib main loop, so GTK's first realize/
paint — and every warning it emits — lands in the log. GTK/GLib **WARNING/CRITICAL** go to `stderr`
by default (no `G_MESSAGES_DEBUG` needed), so the payload is captured without extra env.

**How the compile-safety objection that deferred this for 4 rounds is discharged.** Rounds 2–4 each
refused to add this because "Windows-only C interop this macOS box cannot compile-check." Round 5
uses **only** ISO-C `freopen`/`setvbuf`/`fputs` plus Foundation `URL`/`CommandLine` — whose
signatures are **type-checked on macOS via `Darwin`** (the redirect body is compiled on every
platform; only its *call site* is `#if os(Windows)`). The one Windows-specific unknown — whether the
`stderr` symbol exists in Swift's Windows module — is settled **from proven-on-CI code**, not guessed:
swift-cross-ui's own `Sources/WinUIBackend/Console.swift` (compiled on the windows-latest runner)
calls `freopen_s(&fp, "CONOUT$", "w", stderr)`, so `stderr` is available under `import WinSDK`.
**Verified in this environment:** `swift build -c release --product CueSync` links CueSync with all
three checked-in patches applied (interactivity + windows-input + gsk-renderer); the CI macOS
grep-guard (no forbidden imports / no NS-prefixed symbols under `UI/`) passes on the edited file. No
NS-prefixed symbol is used (path built with `URL`, not `NSString`).

**The decision tree to read from `CueSync-startup.log` after the next probe (this ENDS the guessing).**
> **Box / gate owner: retrieve `CueSync-startup.log` from the CueSync.exe directory after the next
> probe run and attach it. Do NOT author round 6 until it is read.** Then:
- **No log file, or a log with no banner** → `CueSync.exe` never reached Swift: the probe is
  screenshotting/clicking the **launcher**, not the app (revives §0.2's premise), OR the exe crashes
  pre-`init`. Cause is packaging/launch, not the window — hand the runner owner the launch path.
- **Banner present, then `Pango-*`/`fontconfig`/`couldn't load font` lines** → **(B-fonts)**: text
  measures to 0, layout collapses. Fix = bundle fonts + point Pango/fontconfig at them (app-shell).
- **Banner present, then `Gsk`/`GSK`/GL/`renderer` errors** → **(B-renderer)**: cairo not actually in
  effect / another paint failure. Fix = confirm/force the software renderer earlier.
- **Banner present, log otherwise clean, window visible-but-empty + dead** → **(A) starvation
  confirmed**: the real fix is a `GtkBackend` run loop that stops `RunLoop.main` consuming the Win32
  queue (replace round 2's priority hack with a non-`.default`-mode pump, or equivalent) — now
  targetable against evidence instead of blind.

**One-suspect discipline (spec step 5).** Round 5 changes exactly one file (`CueSyncApp.swift`),
touches **no** swift-cross-ui source, adds no dependency, no network, no dynamic load, and no
`GtkFixed`/absolute positioning. The three prior patches (interactivity, windows-input, gsk-renderer)
are **retained unchanged** — each remains independently revertable. This round's "suspect" is not a
cause at all; it is the measurement that will let round 6 name the cause with certainty.

## §0.3 — ROUND 4 (2026-07-19, this session): the window never paints because GTK's GL renderer can't run over the remote desktop

> This is the fourth CUESYNC-9 round. It KEEPS round 3's decisive machine-read — the current
> `.factory/probe/before.png`/`after.png` (md5 `262857fe294219dbc12d475a49979484`, byte-identical,
> captured 14:44 AFTER round 3's DLL-bundling commit `a29d490`) are STILL a `C:\WINDOWS\SYSTEM32\cmd.exe`
> launcher console with **no CueSync window anywhere on screen** — but it CORRECTS round 3's mechanism.
> Classification is unchanged: **Fork W** (window-level: no window ⇒ close-click can't kill, centre click
> can't change pixels). This is the spec step-4 **CONTINGENCY** path (a GTK-runtime/init **config** defect —
> "an env the launch must set" — fixed with the framework's own API, NOT an upstream source bug), applied
> as the checked-in `patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch`.

**Why round 3's "missing Swift runtime DLLs" mechanism is not (or no longer) the whole story.** Round 3
read the same cmd.exe-only probe and blamed the Windows loader failing to start `CueSync.exe` because the
Swift runtime DLLs weren't bundled. But the `windows-build` job **already bundles the GTK 4 runtime DLLs**
("Bundle GTK 4 runtime DLLs next to CueSync.exe", pre-existing) **and** round 3 added the Swift runtime DLL
bundling, with a `wldd` closure check + negative control asserting the artifact is self-contained. Yet the
**post-round-3** probe is byte-for-byte the same failure. Two readings survive, and the decisive tell is in
the pixels: a clean-PC exe that fails to *load* a missing DLL raises a hard Windows **error dialog**
("The code execution cannot proceed because X.dll was not found") — there is **no such dialog** in
`after.png`, only the launcher console. That points away from a load-time DLL failure and toward the exe
**loading and running but never presenting a window** — a GTK **runtime** failure, not a packaging one.

**Root cause (the remote-desktop tell).** The clean-PC probe box is driven over **remote desktop** — its
own desktop in `.factory/probe/after.png` shows a **RustDesk** shortcut (and TeamViewer, Configure USB
Network Gate: this is a remote-controlled machine). GTK 4's default GSK renderer on Windows is the
**GPU/OpenGL-backed `ngl`/`gl` renderer**, which must create an OpenGL context on the window's surface.
Over an RDP / RustDesk / headless remote session the GL surface the remote host exposes **cannot back a
`GskGLRenderer`**: context creation fails, no `GskRenderer` realizes for the surface, and the window never
paints or presents. The process stays alive (so a close-click on the launcher doesn't end "the app"),
`gtk_window_present` is a no-op paint-wise, and the probe sees only the launcher console — the exact
three-symptom signature the gate reports. This is a **config** defect (`GtkBackend.runMainLoop`,
`Sources/GtkBackend/GtkBackend.swift:118` at pinned commit `a6d206370812e3b9edba259d167e848892c5013d`, right
before `gtkApp.run`), not a swift-cross-ui source bug and not a hit-testing bug.

**Fix.** Force GTK's pure-software **Cairo** renderer by setting `GSK_RENDERER=cairo` via GLib's own
`g_setenv` at the top of `runMainLoop`, before `gtkApp.run` (`g_application_run` → activate → window
realize → first `GskRenderer`). Cairo needs no GPU/GL context and always succeeds, so the window reliably
appears in a remote session. `#if os(Windows)`-guarded; Linux/macOS keep their working default renderers,
and CueSync's macOS build uses the native AppKit/SwiftUI app (not GtkBackend) so the shipping mac app is
untouched. **Compile/link verified on macOS**: `swift build -c release` links CueSync with the hunk
temporarily un-guarded — `g_setenv` resolves via `CGtk` (already imported by GtkBackend), so the
symbol/signature are sound. This is the compile-safety gap the round-3 findings flagged for the deferred
round 4; using GLib's `g_setenv` (not the Windows-only `ucrt` `_putenv_s`) closes it, because `g_setenv`
compiles on every platform.

**One-suspect discipline (spec step 5).** GSK-renderer failure is round 4's single suspect. The round-2
input patch and round-3 DLL bundling are **retained** (they are different, independently-correct concerns:
main-loop hygiene, and a self-contained artifact) and kept in **separate** patches/steps so any non-mover
can be reverted alone. Round 4 changes exactly one file in the dependency (`GtkBackend.swift`,
`runMainLoop`) via one new patch; it does not touch the other two patches, adds no dependency/network/
dynamic-load, and introduces no GtkFixed/absolute positioning.

**What this round can and cannot prove from macOS.** It proves the fix compiles/links and that all three
patches apply cleanly in sequence and idempotently. It **cannot** prove the window now appears on the remote
box — that needs the on-box probe re-capture (a CueSync-titled window replacing the cmd.exe console) or the
GTE clicking on the box. **If round 4 still shows only the launcher console**, the remaining discriminators,
in order: (a) the probe is not running the CI artifact at all (then the whole packaging+renderer chain is
moot and the harness launch path is the real blocker — hand the runner owner the launch/`-NoProfile`
fix); (b) the exe genuinely fails to load a DLL (then a Windows error dialog should be visible — look for
it, and widen the bundle); (c) a non-render window-presentation failure. The single missing datum remains
**CueSync.exe's own stderr on the box** (still detached by `/SUBSYSTEM:WINDOWS`); the lowest-risk round 5,
iff needed, is the app-shell `freopen` stderr→log deferred since round 2.

## §0.2 — ROUND 3 (2026-07-19, this session): the probe was clicking the LAUNCHER, not CueSync

> This is the third CUESYNC-9 fix round, and it OVERTURNS the shared premise of rounds 1–2 (and of
> the spec's Problem statement): that the Windows window "draws the whole UI correctly but input is
> dead," or "renders essentially empty." A closer machine read of the current probe capture shows
> that premise is **false**. The classification bucket is still **Fork W** (window-level input dead
> — the close-button click does not kill the process and the center click changes zero pixels), but
> the *mechanism* is not input dispatch, an empty render, or main-loop starvation. **CueSync's own
> window never appears at all.** Rounds 1–2's `patches/swift-cross-ui-0.8.0-windows-input.patch`
> targeted a phantom "empty render"; it is retained (it is harmless and fixes a real main-loop
> busy-spin that will matter *once the app launches* — see below), but it is NOT and never could be
> the probe-mover.

**The decisive new datum: the window in the probe is a `cmd.exe` console, not CueSync.**
The current `.factory/probe/before.png` / `after.png` (md5 `dc6d8369000a858bc5d1aa9fc5ffe8a0`, still
byte-identical to each other, captured after round 2's commit `a3516e7`) has a **title bar that
reads `C:\WINDOWS\SYSTEM32\cmd.exe`** with the cmd.exe console icon, a pure-black console buffer,
and a Windows **console** scrollbar (cmd.exe's default 80×300 screen buffer is taller than its
window, so it always draws a vertical scrollbar). This is the GTE/probe harness's **launcher
terminal**, not CueSync's window — CueSync's `WindowGroup` is titled `CUE SYNC`
(`CueSync/CueSync/UI/CueSyncApp.swift:33`), never `cmd.exe`. §0's earlier scan of the same-class
image (zero accent/text pixels, "only a scroll-bar," undersized, "desktop visible below/right")
was correct about the pixels but **mis-attributed** them: the flat-black area with a scrollbar is
an **empty console**, and there is **no 1200×800 CueSync window anywhere in the full-screen
capture**. "Renders empty" (§0/§0.1) was reading an empty cmd.exe console as CueSync rendering
nothing. A window that never appears cannot be clicked, cannot receive a close event, and cannot
change center pixels — the exact three symptoms the gate reported.

**Root cause (suspect (1) re-scoped from "input wiring" to "the exe never loads"; CI-confirmed).**
CueSync.exe is linked `/SUBSYSTEM:WINDOWS` + `/ENTRY:mainCRTStartup` (`Package.swift:83-88`), so it
opens **no console of its own** — the cmd.exe is external, the box's launcher. Its transitive import
closure includes the **Swift runtime DLLs** (`swiftCore.dll`, `Foundation.dll`, `dispatch.dll`,
`swiftCRT.dll`, `BlocksRuntime.dll`, the ICU data DLLs, …). The Windows job's **own "Verify DLL
closure" step proves these are unbundled**: it resolves every one of them from the **Swift toolchain
root on the runner's PATH** (its `$isFromSwiftToolchain` branch — CI-observed run 29580303796:
`swiftCRT.dll => C:\Users\runneradmin\...\Swift\Runtimes\6.3.3\usr\bin\swiftCRT.dll`), never from the
`.build\release` artifact. The GTE runs on a **clean PC with no Swift toolchain**, so the Windows
loader cannot find `swiftCore.dll` et al. and **fails to start CueSync.exe before `main` runs** — no
GDK init, no `gtk_window_present`, no window. This is a **packaging** defect, not a swift-cross-ui
source defect, and it fully explains a clean-PC "program opens [the launcher], nothing can be
clicked [there is nothing to click]" across CUESYNC-7/8/9. The swift-cross-ui show/present path
itself is correct (`GtkBackend.swift:286-291` → `Window.show()` / `gtk_window_present`,
`Application.swift:81-92` creates+presents exactly one `ApplicationWindow`) — it just never runs.

**Round-3 fix (`.github/workflows/swift-windows.yml`, `windows-build` job — a `git apply`-free
packaging fix, spec step-4 contingency: "a GTK-runtime/init config defect … apply the minimal
equivalent at the app-shell/launch layer").** A new **"Bundle Swift runtime DLLs next to
CueSync.exe (self-contained artifact)"** step, placed AFTER the closure check + its negative control
(both stay green, unchanged, gating the pre-bundle artifact) and BEFORE the upload. It re-uses
`wldd`'s own resolved closure — copying **exactly** the dependencies it resolves from the Swift
toolchain root into the artifact directory, nothing hardcoded — then re-walks CueSync.exe and
**asserts no dependency resolves from the toolchain root anymore** (on-box machine-verification that
the exe is now self-contained). No swift-cross-ui bytes change; `Package.swift`/`Package.resolved`
untouched; the CUESYNC-8 interactivity patch and the round-2 input patch untouched.

**Why the round-2 input patch stays (and is honestly not the mover).** Its priority + 8 ms floor fix
a genuine 0 ms busy-reschedule (100 % CPU) in `mainRunLoopTicklingLoop` and preserve PR #141's
`@MainActor`/`DispatchQueue.main` servicing that `.task { state.loadPreferences() }` depends on —
real main-loop hygiene that matters the moment the exe actually launches and the tickler starts
running. It is retained rather than reverted because it is harmless and correct on its own terms;
§0.1's "the fix the drain should have been" framing is superseded here only as to *what moves the
probe*, not as to the patch's local correctness. (Spec step 5's "revert non-movers" is about not
*stacking speculative fixes for the same symptom*; this is a different, now-correctly-identified
symptom, so the round-2 hunk is left as standalone main-loop hygiene, not stacked as a second guess
at input death.)

**If round 3 still does not move the probe — the pre-scoped round-4 datum.** Bundling is a no-op iff
the gate does **not** run the CI artifact but instead builds/runs on a Swift-equipped box (then the
Swift DLLs already resolve and the window would already appear — pushing the cause to **(B)** a
GTK-runtime/display defect: the GSK GL renderer failing on a headless/RDP box, or Pango/fontconfig
finding no fonts). The clean discriminator remains **CueSync.exe's own stderr on the box**, still
uncaptured because `/SUBSYSTEM:WINDOWS` detaches it. Round 4, iff this misses: an **app-shell**
change at process start on Windows — `freopen` the CRT `stderr`/`stdout` to a log next to
`.factory/probe/*.png`, and set `GSK_RENDERER=cairo` before GDK init. It is deliberately **not**
bundled here: it is Windows-only C interop this macOS box cannot compile-check, and a mistyped
module import would turn the currently-green Windows CI *red* — strictly worse than this round's
fully compile-safe, CI-only packaging change. One suspect per round (spec step 5): the missing
runtime DLLs are round 3's single, CI-confirmed suspect.

## §0.1 — ROUND 2 (2026-07-19, this session): the fix the drain should have been

> This is the second CUESYNC-9 fix round. Round 1 (the GLib-drain `windows-input.patch`)
> named the right suspect — **suspect (1)**, the run-loop tickler contending with GDK for the
> one Win32 message queue — but shipped a mechanism too weak to move the probe. This section
> records the current probe evidence, sharpens the mechanism, and REPLACES the round-1 fix
> (per spec step 5: revert non-movers, do not stack). It does not re-open the fork; suspect (1)
> stands, now with a stronger, GLib-priority-based fix.

**Current probe evidence (this round).** `.factory/probe/before.png` and `after.png` are again
**byte-identical** (`md5 = e165fe8e6e532e41d92d1dcbcf602c3d` for both) — the synthesized
close-button click did **not** kill the process and the window-center click changed **zero**
pixels. The image itself matches §0's earlier scan exactly: the CueSync window is a near-black
content area with **only a scroll-bar** drawn (up/down arrows + a thumb near the top), **no**
header, buttons, sections, labels, or accent colours, and it is **undersized** — the Windows
desktop and its icons are visible below/right of it, where the window failed to fill the
requested 1200×800. This is **Fork W** (window-level input dead) confirmed by a machine, with a
**rendering+layout-collapse** signature, exactly as §0 first established. Round 1's fix was in
the checkout when this was captured, so the GLib-drain alone is a confirmed **non-mover**.

**Why the close-button click NOT killing the process points at starvation, not a bare renderer
failure.** If the *only* defect were the GSK GL renderer failing on a headless/RDP build box
(so the UI is merely unpainted), GDK would still be draining the win32 queue and a click on the
CSD close button's location would still terminate the app even with the button invisible. It
does not. Input is dead *together with* the render — the signature of GDK being **starved of the
one thread message queue entirely**, which drives BOTH its win32 event delivery AND its
frame-clock repaint/relayout. One cause, both symptoms.

**The sharpened mechanism (why round 1 was too weak, in GLib terms).** The tickler is scheduled
via `g_timeout_add_full` at **`G_PRIORITY_DEFAULT` (0)** — the *same* priority as GDK's own win32
event source (`GDK_PRIORITY_EVENTS == G_PRIORITY_DEFAULT == 0`) and *above* nothing. Worse, it
busy-reschedules at **0 ms** whenever `RunLoop.main.limitDate` returns a past/now date (there is
almost always a ready libdispatch item), so it wakes the GLib main context on *every* iteration.
Each wake runs a CoreFoundation Windows run-loop pass that `PeekMessage(NULL, …, PM_REMOVE)` +
`DispatchMessage`es the queue — stealing messages GDK's equal-priority source would otherwise
translate into `GdkEvent`s, and denying GDK's redraw source (`GDK_PRIORITY_REDRAW == 120`) the
turns it needs to paint. Round 1's one-shot `g_main_context_iteration` drain gave GDK a head
start *within* a single tick, but could not overcome a same-priority competitor that then runs
`limitDate` and immediately re-arms at 0 ms — a one-shot drain against a continuous racer.

**Round-2 fix (`patches/swift-cross-ui-0.8.0-windows-input.patch`, rewritten — same file, same
one target `Sources/GtkBackend/GtkBackend.swift`, still `#if os(Windows)` only, still GLib's own
APIs).** Three coordinated hunks that make GDK structurally win the queue instead of racing for
it:
1. **Priority.** Schedule the tickler at `G_PRIORITY_DEFAULT_IDLE` (200) — *below* both
   `GDK_PRIORITY_EVENTS` (0) and `GDK_PRIORITY_REDRAW` (120). GLib's dispatcher only runs sources
   at or above the highest-priority *ready* source in each iteration (`g_main_context_prepare`
   returns that max priority; `dispatch` skips everything lower), so in **any** iteration where
   GDK has a pending input message or a queued repaint, the tickler is **skipped** and GDK — not
   Foundation's `PeekMessage`/`DispatchMessage` — owns the queue that frame. This is the
   load-bearing change and the direct implementation of §0's Option (A) ("stop `RunLoop.main`
   from consuming the Win32 input queue GDK owns").
2. **Floor.** Clamp the reschedule to ≥ 8 ms so the tickler can never busy-loop at 0 ms and wake
   the context every iteration (removes both the 100% CPU and the wake-storm amplifier §0 named).
3. **Drain (retained).** Keep the round-1 `while g_main_context_iteration(nil, 0) != 0 {}`
   before the `limitDate` pass — now redundant belt-and-suspenders, harmless, and it keeps the
   patch's GLib-own-API contract explicit. `@MainActor`/`DispatchQueue.main` servicing (upstream
   PR #141, which CueSync's `.task { state.loadPreferences() }` depends on) is preserved: the
   tickler still runs, just below GDK and off the 0 ms path. Linux/macOS are byte-identical to
   upstream (the `#else` branches; macOS never runs the tickler at all).

**Verification available from this environment (macOS): compile + logic only.** The patched
`GtkBackend.swift` was built on macOS with the Windows-guarded hunks temporarily un-guarded to
prove they compile (`g_main_context_iteration`, the `CInt` priority, the floor all compile), then
built again with both checked-in patches applied (whole `CueSync` executable links, exit 0). The
priority semantics above are GLib ABI, stable across GTK4. What this box **cannot** produce is the
live Windows behaviour — that is the click-probe gate's and the GTE's job.

**If round 2 still does not move the probe — the ONE datum to capture next, and why it was not
forced this round.** The remaining discriminator between (A) starvation (this fix's target) and
(B) a gvsbuild GTK-runtime config defect (GSK GL renderer failing on the headless box → force
`GSK_RENDERER=cairo`; or Pango/fontconfig finding no fonts) is still `CueSync.exe`'s **stderr**
on the box, which no round has captured because the app ships `/SUBSYSTEM:WINDOWS` (no console)
and the external probe harness does not redirect it. The clean next step is an **app-shell**
change (spec step-4 contingency, not a source patch): at process start on Windows, `freopen` the
CRT `stderr`/`stdout` to a log file next to the probe evidence so GTK/GLib/Pango/GSK diagnostics
are retained, and — if that log shows GSK/GL errors — set `GSK_RENDERER=cairo`. It was **not**
bundled into this round deliberately: it is Windows-only C interop this macOS box cannot
compile-check, and a mis-typed `import`/module name would fail the Windows CI *compile* (a
regression worse than the current red), whereas this round's fix is fully compile-verified. Per
spec step 5 (one suspect per round) the priority fix is round 2's single suspect; the
stderr-capture + `GSK_RENDERER` is the pre-scoped, de-risked round 3 **iff** this misses.

## §0 — CORRECTED DIAGNOSIS (2026-07-19, from the FIRST live probe evidence + a local macOS reproduction)

> This section supersedes the framing of §1–§3 below. §1–§3 remain as the record of the
> input-**dispatch** audit, but that audit targeted a **secondary** symptom. The first real
> `.factory/probe/` evidence + a local macOS run of the same GtkBackend target prove the
> **primary** failure is that the Windows window renders **empty**, not merely inert.

**What the live probe actually shows (hard pixel facts, not theory).**
`.factory/probe/before.png` and `after.png` (captured 2026-07-19T13:23, 1228×854) are
**byte-identical** (`md5 = d3a753ec27608c1e53502aaabf610bb8` for both; `cmp` = identical).
The synthesized close-button click did **not** kill the process and the center click changed
**zero** pixels → **Fork W confirmed by a machine** (the classification in §1 was previously
drawn only from the GTE's verbal report; now it is machine-confirmed).

But the decisive new fact is *what* is on screen: a full-image scan of `before.png` finds the
window content is a **uniform flat `RGB(12,12,12)` fill** plus only ~790 white pixels (the
scroll-bar). **Zero** colored or text pixels anywhere — none of CueSync's accent colors
(`#1ed760` green, `#ef288a` pink, gold, teal), no "CUE SYNC" header, no buttons, no labels, no
section borders. The window is also only ~955×484, **below** the requested `1200×800`. So the
Windows window is **rendering essentially nothing** and its layout has **collapsed** — this is
**not** "the whole UI draws correctly but input is dead" (the premise §1 inherited from the GTE
and from every CUESYNC-7/8 round). "Program opens, nothing can be clicked" was literally true:
there is almost nothing drawn to click.

**Local macOS reproduction rules out the app view-tree as the cause.** The `CueSync` executable
target (`.define("CUESYNC_CROSSUI")`, pinned to `GtkBackend`) was built and **run on macOS**
against Homebrew GTK 4.22.4 with the **pristine** (unpatched) checkout. It renders the **full,
correct UI** at the requested `1200×832`: the `◈ CUE SYNC` header, every PROJECT control
(Create Envelope, Resolume/Rekordbox/Serato/Engine DJ/ShowKontrol, Reset/Side-By-Side,
Dark/Light, True/False), both empty-state sections, the footer, and all accent colors. (Screenshot
retained during the session.) **Therefore the CueSync view tree, its swift-cross-ui layout, and
GtkBackend's rendering are all correct** — an app-layout or hit-testing bug would fail on macOS
too. The defect is **Windows-runtime-specific**, at exactly the layer §1 suspected (below the
widget tree) but with a **rendering+layout** signature, not merely input.

**Experiment — the tickler mechanism is not inherently destructive.** Forcing
`mainRunLoopTicklingLoop()` to run on macOS as well (removing the `#if !os(macOS)` guard at
`GtkBackend.swift:151`, rebuild+run) left the macOS render **fully intact**. So the tickler's
*logic* does not break rendering; the destructive factor is **win32-specific** — `RunLoop.main`
is unconditionally bound to the thread's Win32 message queue (`QS_ALLINPUT`, see §2.5), which it
is **not** on macOS.

**Upstream has no fix to backport.** `moreSwift/swift-cross-ui` `v0.8.0` (`a6d2063`) is the
**latest tag**; `main` has only 17 commits since, and **none** touch Windows input, the main
loop, the message pump, or `GtkBackend`'s run path (the two GtkBackend commits are Gtk3 sheet
support + an SPI rename). A re-pin/backport is therefore **not** available.

**Corrected root cause (suspect (1), CONFIRMED and SEVERE — total starvation, not occasional theft).**
On Windows, `g_application_run`'s GLib loop and the `mainRunLoopTicklingLoop`'s `RunLoop.main`
pass are two consumers of the **one** thread-global Win32 message queue. GDK's win32 backend
drives **both** input **and** its frame-clock / relayout / redraw from that queue. The empty,
size-collapsed window + dead close button together are the signature of GDK being **starved of
the queue entirely** — after the initial partial paint it processes neither input **nor** any
further layout/redraw. The starvation amplifier is concrete: `mainRunLoopTicklingLoop`
reschedules with `nextDelay = max(min(Int(timeIntervalSinceNow*1000), 50), 0)`
(`GtkBackend.swift:164-166`) → whenever `limitDate` returns a nil/past date (there is always a
ready libdispatch item or timer), `nextDelay == 0` → `g_timeout_add_full(0, 0, …)`
(`GtkBackend.swift:500`) → the RunLoop pump runs **continuously** at `G_PRIORITY_DEFAULT`,
monopolizing the queue GDK needs.

**Why the shipped `windows-input.patch` (GLib-drain) does not and cannot fix this.** (a) It only
reorders *input* drainage — it does nothing for the empty-render half of the failure, which is
the primary symptom. (b) Even for input, draining GDK's context **once** before each tick cannot
overcome a RunLoop pump that then runs and busy-reschedules at 0 ms; the drain is a one-shot head
start against a continuous competitor. This is consistent with the byte-identical probe (a
non-mover, if the probe built the patched binary) **and** with the deeper truth that an
input-only patch was aimed at the wrong symptom.

**The remaining fork the box (not this macOS environment) must close before step-5 patching.**
Two Windows-runtime causes both fit "empty + collapsed + dead," and they need **different** fixes:
- **(A) main-loop starvation** (above) → fix in `mainRunLoopTicklingLoop`: stop the 0 ms
  busy-reschedule (enforce a frame-paced floor) and/or stop `RunLoop.main` from consuming the
  Win32 input queue GDK owns — a `patches/swift-cross-ui-0.8.0-windows-input.patch` rewrite for
  the **same** suspect (1), replacing the drain, not stacked on it.
- **(B) a gvsbuild GTK-runtime config defect** — e.g. Pango/fontconfig finding no fonts (every
  text widget measures to 0 → whole tree collapses → empty, sub-min window) or the GSK GL
  renderer failing on the headless/RDP build box (nothing composites). This is the spec step-4
  **contingency** (an app-shell/launch fix: bundle fonts + set `FONTCONFIG_FILE`/`FONTCONFIG_PATH`,
  or force `GSK_RENDERER=cairo`), **not** a swift-cross-ui source patch.

**Decisive next datum (cheap, on-box, currently missing).** The probe must capture
`CueSync.exe`'s **stderr/stdout** to a file when it launches it, and retain it next to
`.factory/probe/*.png`. GTK/GLib/Pango/GSK print their diagnostics there and will immediately
separate (A) from (B): font/fontconfig or `Pango-WARNING` lines ⇒ (B-fonts); `GSK`/GL/renderer
errors ⇒ (B-renderer); a clean log ⇒ (A-starvation). Two 2-minute on-box launch experiments pin
it outright: `set GSK_RENDERER=cairo & CueSync.exe` (if it now renders → renderer) and inspecting
whether any bundled `fonts/` + `fonts.conf` reach the exe (if absent → fonts). **This macOS
environment cannot produce that datum** (no win32 message queue, native Homebrew fonts/renderer),
which is exactly why every prior round — reasoning from source alone — mis-scoped the failure as
input-dispatch. Do **not** author the next patch until this log is read.

---

*(Original §1–§3 below — the input-dispatch audit, retained as record; note its "renders the
whole UI correctly" premise is falsified by §0.)*


Recorded per spec step 1/3 ("Do not change anything until this classification is written
down"). Verified by running `swift package resolve` against this repo's pinned `Package.swift`
(`exact: "0.8.0"`), applying the existing CUESYNC-8 interactivity patch first (so the audit
reads the same bytes the box builds), and reading `.build/checkouts/swift-cross-ui`, confirmed
at `HEAD` == tag `v0.8.0`, commit `a6d206370812e3b9edba259d167e848892c5013d`
(`git log -1 --format=%H` inside the checkout). All file:line citations below are relative to
that checkout unless stated otherwise.

## §1 — Fork classification

The spec's own problem statement is the first red round's evidence for this ticket: the clean-PC
GTE (2026-07-19, second consecutive time, identical to CUESYNC-7) reports "program opens, nothing
can be clicked" — **including scrollbars and `TextField`s**, not just the compound controls
CUESYNC-8's `can-target` fix targeted. CUESYNC-8's fix is a blanket, non-context-specific change
(every `Shape`-backed widget, everywhere, unconditionally gets `can-target = false` — findings
CUESYNC-8 §2.3) and it **changed nothing observable** on the second GTE round. A fix that
covers every decorative overlay in the app and still leaves literally nothing clickable rules out
"one more decorative sibling was missed" — the defect cannot be at the widget-picking layer
CUESYNC-8 already fixed exhaustively.

This is **Fork W**: no pointer input reaches *any* widget, matching "the whole window is inert
including scrollbars and text fields" verbatim from the spec's own fork definition. (This repo has
no live click-probe-gate run of its own yet — see the "Scope of this audit" note below — so the
classification here is drawn from the GTE description already in the ticket and confirmed against
source, not from a fresh `.factory/probe/` screenshot pair. The next iteration against the real
probe gate is what turns this from "best available evidence" into machine-verified.)

## §2 — Audit: the main-loop / app-run path

### §2.1 — `runMainLoop` delegates to `g_application_run`, unremarkably

```swift
// Sources/GtkBackend/GtkBackend.swift:118-155
public func runMainLoop(_ callback: @escaping @MainActor () -> Void) {
    gtkApp.run { window in
        ...
        callback()
        ...
        #if !os(macOS)
            Self.mainRunLoopTicklingLoop()
        #endif
    }
}
```

```swift
// Sources/Gtk/Application.swift:72-79
public func run(_ windowCallback: @escaping (ApplicationWindow) -> Void) -> Int {
    self.windowCallback = windowCallback
    let status = g_application_run(applicationPointer.cast(), 0, nil)
    ...
}
```

`g_application_run` is the standard, idiomatic GTK4 entry point — it owns the process's default
`GMainContext` for the app's lifetime, and GDK's own backend (win32 on Windows) integrates its
display-connection event source into that same context during `GApplication`/`GtkApplication`
startup, before `activate` ever fires. Nothing here manually re-implements or bypasses GLib's own
dispatch loop; `gtkApp.registerSession = true` and the `open`/`activate` signal wiring
(`Sources/Gtk/Application.swift:43-70`) are unremarkable. **Ruled out as the defect by itself.**

### §2.2 — `CustomRootWidget`, the root container: no picking override

```c
// Sources/GtkCHelpers/gtk_custom_root_widget.c:7-12
static void gtk_custom_root_widget_class_init(GtkCustomRootWidgetClass *klass) {
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);
    widget_class->measure = gtk_custom_root_widget_measure;
    widget_class->size_allocate = gtk_custom_root_widget_allocate;
    widget_class->get_request_mode = gtk_custom_root_widget_size_request_mode;
}
```

`CustomRootWidget` (`Sources/Gtk/Widgets/CustomRootWidget.swift`, wrapping every window's content
per `GtkBackend.setChild(ofWindow:to:)` at `GtkBackend.swift:221-224`) only overrides `measure`/
`size_allocate`/`get_request_mode` — it never overrides `pick`/`contains`, never sets
`can-target`/`can-focus`, and chains up to `GtkWidgetClass`'s default picking behavior implicitly.
**Ruled out**: the root container does not itself block hit-testing.

### §2.3 — Event-controller attachment: real, and already independently confirmed working

CUESYNC-8 §2.1 already proved `GtkBackend.createTapGestureTarget`/`createHoverTarget`
(`GtkBackend.swift:1535-1616` at that audit) wire real `GestureClick`/`EventControllerMotion`
instances via `Widget.addEventController` → `gtk_widget_add_controller`, not stubs — re-confirmed
unchanged here. This machinery is irrelevant to Fork W by construction: it only matters once input
already reaches a widget's controller, and Fork W's defect is upstream of that (nothing reaches
*any* widget, including the ones CUESYNC-8 already proved are wired correctly).

### §2.4 — No Windows-specific GDK backend/display init in this checkout

```
$ grep -rln "os(Windows)\|win32\|Win32\|GDK_BACKEND" Sources/Gtk Sources/GtkBackend
Sources/GtkBackend/GtkBackend.swift   # only hit: `#if !os(Windows)` around `revealFile`'s
                                       # dbus-send subprocess call (GtkBackend.swift:316) —
                                       # unrelated to input/display init
```

There is no `setenv("GDK_BACKEND", ...)`, no explicit `gdk_win32_*` call, and no manual
`g_main_context` iteration anywhere in `Sources/Gtk`/`Sources/GtkBackend`. The actual win32 ↔ GLib
message-pump integration lives entirely inside the prebuilt GTK4 C library (gvsbuild), outside
this Swift source tree and outside what a `patches/*.patch` against this checkout can touch.
**Ruled out as a *source*-level suspect** (would be suspect (1)'s upstream-C-library variant, not
fixable here; see "Scope of this audit" below).

### §2.5 — The one non-macOS-only mechanism that touches the OS event queue: the run-loop tickler

```swift
// Sources/GtkBackend/GtkBackend.swift:157-169 (pre-patch)
private static func mainRunLoopTicklingLoop(nextDelayMilliseconds: Int? = nil) {
    Self.runInMainThread(afterMilliseconds: nextDelayMilliseconds ?? 50) {
        // This performs one pass through the run loop
        let nextDate = RunLoop.main.limitDate(forMode: .default)
        ...
        mainRunLoopTicklingLoop(nextDelayMilliseconds: nextDelay)
    }
}
```

Introduced by upstream commit `9c5c8620` ("GtkBackend,Gtk3Backend: Implement main run loop
tickler (#141)", fixing issue #140 — confirmed via `gh issue view 140`/`gh pr view 141` against
`moreSwift/swift-cross-ui`): **"Enables the use of `@MainActor` and `DispatchQueue.main` under Gtk
on non-Apple platforms (gtk already services the main run loop on macOS)."** This is why the
guard is `#if !os(macOS)` rather than `#if os(Linux)` — it is meant to run on **both** Linux and
Windows, and CueSync's own `.task { state.loadPreferences() }`
(`CueSync/CueSync/UI/CueSyncApp.swift`) depends on exactly this mechanism to run at all under
GtkBackend on Windows. It cannot simply be deleted for Windows without regressing PR #141's fix.

Cross-referencing swift-corelibs-foundation (fetched directly from
`https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/main/Sources/Foundation/RunLoop.swift`
and `.../Sources/CoreFoundation/CFRunLoop.c`, since the box has network access, matching this
ticket's on-box-audit model):

```swift
// swift-corelibs-foundation, Sources/Foundation/RunLoop.swift (RunLoop._mainRunLoop)
internal static nonisolated(unsafe) var _mainRunLoop: RunLoop = {
    let cfObject: CFRunLoop! = CFRunLoopGetMain()
#if os(Windows)
    // Enable the main runloop on Windows to process the Windows UI events.
    // Windows, similar to AppKit and UIKit, expects to process the UI
    // events on the main thread.
    _CFRunLoopSetWindowsMessageQueueMask(cfObject, QS_ALLINPUT, kCFRunLoopDefaultMode)
#endif
    return RunLoop(cfObject: cfObject)
}()
```

```c
// swift-corelibs-foundation, Sources/CoreFoundation/CFRunLoop.c:3106-3172 (Windows run-loop wait)
#elif TARGET_OS_WIN32
    // Here, use the app-supplied message queue mask...
    __CFRunLoopWaitForMultipleObjects(waitSet, NULL, poll ? 0 : TIMEOUT_INFINITY, rlm->_msgQMask, &livePort, &windowsMessageReceived);
...
    if (windowsMessageReceived) {
        ...
        MSG msg;
        if (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE | PM_NOYIELD)) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
        ...
    }
```

`RunLoop.main` is therefore **unconditionally** bound to `QS_ALLINPUT` on Windows — every
`.default`-mode pass (exactly the mode `mainRunLoopTicklingLoop` ticks via `limitDate(forMode:
.default)`) calls `PeekMessage(NULL, 0, 0, PM_REMOVE|PM_NOYIELD)` for **any window this thread
owns**, then `DispatchMessage`. This is a second, independent consumer of the *same* thread-global
Win32 message queue GDK's own win32 backend is already draining via this same GLib main loop — two
uncoordinated message-pump owners on one thread's queue, each capable of winning the next
`PeekMessage` race. `DispatchMessage` does route to the correct window's WNDPROC regardless of
which loop called it, so this is not a hard, universal "every message is lost forever" bug; it is
an unspecified-ownership race between GDK's poll-driven dispatch and Foundation's independent
50 ms-interval drain, which is the class of defect that produces "paints (whichever consumer
services a given WM_PAINT-adjacent redraw path still gets it) but no input (mouse/keyboard
delivery is non-deterministic against a competing consumer)" — Fork W's signature.

## §3 — Root cause and ranked-suspect disposition

**Root cause named:** suspect **(1)**, upstream GtkBackend input wiring / GLib-loop ↔ Win32-pump
integration — specifically `GtkBackend.swift:157-169`'s `mainRunLoopTicklingLoop`, which on
Windows installs Foundation's `RunLoop.main` as a second, uncoordinated consumer of the same
Win32 message queue GDK's own GLib-integrated win32 backend depends on for input delivery
(§2.5). This is a genuine architectural collision unique to non-Apple `GtkBackend` + Windows
(macOS is explicitly excluded already; Linux has no such message-queue-ownership conflict since
there is no Win32 message queue to fight over).

- **Suspect (2) — modal/invisible grab:** ruled out. Nothing in `Sources/Gtk`/`Sources/GtkBackend`
  creates a `Gtk.Window`/dialog/popover at startup ahead of the main window (`Application.activate()`,
  `Application.swift:81-93`, creates exactly one `ApplicationWindow` and returns), and CueSync's own
  `.task`/`.sheet` usage is confined to explicit user actions (duration modal, alerts), not app launch.
  No `gtk_grab_add`/`GtkEventController` grab call exists in this checkout outside the standard
  per-widget gesture controllers already audited in CUESYNC-8 §2.1.
- **Suspect (3) — window-level flags:** ruled out at the root-container level (§2.2: `CustomRootWidget`
  never touches `can-target`/`can-focus`) and at the top-level window level
  (`GtkBackend.createWindow`, `GtkBackend.swift:171-196`, sets only `defaultSize`/`setChild`/
  `notifyIsActive` — no `can-target`/`can-focus`/input-region call anywhere).

## Scope of this audit

Unlike CUESYNC-8 §2's framing, this environment (the build agent's sandbox) had working
`github.com` network access and successfully ran `swift package resolve` against this repo's own
pinned manifest, so the `.build/checkouts/swift-cross-ui` audit above was read directly rather than
deferred to "the box." What this environment does **not** have is the click-probe gate itself (no
Windows runner, no synthesized-click harness, no `.factory/probe/` evidence from a prior round) —
so the Fork W classification in §1 is corroborated by re-reading the pinned source, not by a fresh
screenshot diff. The fix in this ticket's patch (§4/patches/swift-cross-ui-0.8.0-windows-input.patch)
is this round's single suspect for the real click-probe gate to confirm or refute per spec step 5;
if it does not move the probe, it must be reverted before trying suspect (2)/(3) above with fresh
on-box evidence rather than stacked speculatively.

## Fix

> Superseded by **§0.1** (round 2). The round-1 description below is retained as the record of
> why the drain alone was the right suspect but insufficient; the shipped
> `patches/swift-cross-ui-0.8.0-windows-input.patch` now implements §0.1's priority + floor +
> drain, not the drain alone.

**Round 2 (shipped):** `Sources/GtkBackend/GtkBackend.swift`'s `mainRunLoopTicklingLoop` /
`runInMainThread(afterMilliseconds:)` keep ticking `RunLoop.main` on Windows (PR #141's
`@MainActor`/`DispatchQueue.main` fix must not regress), but (1) the tickler's `g_timeout_add_full`
is scheduled at `G_PRIORITY_DEFAULT_IDLE` (200), below `GDK_PRIORITY_EVENTS` (0) and
`GDK_PRIORITY_REDRAW` (120), so GLib skips it in any iteration where GDK has pending input or a
queued repaint — GDK, not Foundation's `PeekMessage`/`DispatchMessage`, owns the win32 queue that
frame; (2) the reschedule is floored at 8 ms so the tickler can never busy-loop at 0 ms; and
(3) it still drains GLib's default `GMainContext` (`g_main_context_iteration(nil, 0)` until empty)
before the `limitDate` pass. All `#if os(Windows)`; Linux/macOS byte-identical to upstream. No new
dependency, no `sed`/text-substitution, no `GtkFixed`/absolute positioning — every symbol used
(`g_timeout_add_full`, `g_main_context_iteration`) is GLib's own public C API already reachable from
this file. See `patches/swift-cross-ui-0.8.0-windows-input.patch` for the full diff and rationale.

**Round 1 (superseded):** `mainRunLoopTicklingLoop` kept ticking `RunLoop.main` on Windows but only
drained GLib's own default `GMainContext` non-blockingly (`g_main_context_iteration(nil, 0)` in a
loop until nothing is pending) on every tick, `#if os(Windows)` only — giving GDK first refusal
*within* a tick but not overcoming a same-priority tickler that then runs `limitDate` and re-arms at
0 ms. Confirmed a non-mover against the live probe (§0.1); replaced, not stacked.
