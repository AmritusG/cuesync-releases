# UI/UX porting lessons

Lessons learned porting CueSync's UI across toolkits, for future ports to reuse rather than
rediscover the same failure mode.

## A compiling modifier is not a working control

On swift-cross-ui/GTK (and any retained-mode toolkit with a similar picking model), a view
tree is made of two independent layers: what paints, and what receives pointer events. A
modifier that compiles and even runs its backend hook is not proof the control actually
responds on the real backend — the hook can be wired correctly and still never fire, because
something else in the tree is picked first.

**The generalized rule:** decorative layers — backgrounds, overlays, borders, dividers, fills
placed purely for visual styling — must be excluded from hit-testing (GTK: `can-target =
false`; SwiftUI/AppKit: `.allowsHitTesting(false)`). Any affordance that must receive input
needs a mechanism the target backend actually delivers events for: a real interactive widget
(`Button`, `GtkButton`), or a gesture/event controller the backend genuinely wires end-to-end
— not just a modifier that type-checks. Verify tap/hover/click delivery on the real backend
directly; never assume a modifier that compiles is also live. A view that only renders is not
a control.

**Why this matters mechanically, not just as a rule of thumb:** most toolkits pick the
topmost widget under the pointer first, then walk an ancestor/bubble chain. If a decorative
widget sits on top of (or beside, as a sibling of) the widget that actually owns the gesture,
it gets picked first and swallows the event before the real handler ever sees it — even though
that handler's own wiring is perfectly correct. The fix is not "attach the gesture to a
different widget" (fragile, depends on exact nesting) — it's "make the decorative widget
transparent to picking," which is correct regardless of z-order or nesting depth.

## Concrete instance: CueSync on swift-cross-ui v0.8.0 (CUESYNC-8)

CueSync's Windows/GTK port (`CueSync/CueSync/UI/`) draws every screen correctly but no control
responded to clicks — reported by the GTE as "everything is visible, but I cannot click
anything." The instinctive first guess — "the `.onTapGesture`/`.onHover` backend hooks must be
unimplemented no-ops" — was wrong: reading the pinned checkout
(`specs/CUESYNC-8-findings.md` §2.1) showed `GtkBackend` genuinely implements both with real
`GtkGestureClick`/`GtkEventControllerMotion` event controllers, correctly delivered.

The actual gap (§2.2–§2.3): every `Shape`-backed decorative widget (`RoundedRectangle`,
`Rectangle`, `Circle` — used throughout `UI/` purely as button borders, section backgrounds,
and dividers, e.g. `.overlay { RoundedRectangle().stroke(...) }`) defaulted to GTK's
`can-target = true`. Painted on top of the sibling that actually owned the tap gesture inside
a shared `Gtk.Fixed` container, the decorative border was what GTK picked for a click —
silently swallowing it before it ever reached the real handler underneath. `CollapsibleSection`
header rows and `StepperField`'s ▲/▼ arrows are the clearest cases: each carries its own
`.onTapGesture`, but the *whole control* also gets an outer decorative border afterward,
covering the same area.

The fix (`patches/swift-cross-ui-0.8.0-gtk-interactivity.patch`) is exactly the generalized
rule above: add a `canTarget` GObject-property wrapper to Gtk's `Widget` base class (GTK's
`can-target`, the literal analogue of `.allowsHitTesting(false)`), and set it `false` on every
widget `GtkBackend.createPathWidget()` returns — the one factory every `Shape` funnels through,
and confirmed (by grepping every `.onTapGesture`/`.onHover` call site in `UI/`) to be used
exclusively for decoration in this codebase. No apply-level app code changed; the same
`.onTapGesture` structure the source-pinning tests require stayed untouched — the toolkit
started delivering the events it had always claimed to.

## A window that paints but never dispatches input is not a hit-testing bug

Widget-picking fixes (the section above) only matter once input already reaches *some* widget
in the tree. There is a categorically different failure mode one layer below that: a window
whose event-source/main-loop integration is broken, or whose root surface was created without
real input wiring. In that failure mode, painting still works (redraw doesn't go through the
same path as input dispatch), but *nothing* responds — not the control you're debugging, not
its siblings, not the window's own OS-drawn chrome (close button, scrollbars). Fixing the
widget tree cannot repair this: there is no widget-level defect to fix.

**The generalized rule:** before touching app widgets in response to "nothing is clickable,"
verify with a real synthesized OS-level click on the window's own chrome — its close button,
in a client-side-decoration window — whether *any* input is delivered at all. If that click
doesn't even kill the process, and a click on the window's own content changes no pixels
either, the defect is below the widget tree: the main-loop ↔ OS-event-source integration, or a
root-surface input flag, not a picking/hit-testing bug. Only once chrome-level input is proven
live does it make sense to debug individual widgets.

## Concrete instance: CueSync on swift-cross-ui v0.8.0, Windows (CUESYNC-9)

The GTE reported the *whole* CueSync window inert on Windows — including scrollbars and
`TextField`s, not just the compound controls CUESYNC-8's `can-target` fix targeted — and that
blanket, exhaustive fix (every `Shape`-backed widget in the app, unconditionally) changed
nothing observable. That combination is the signature above: not "one more decorative sibling
was missed," but "the defect is below the widget tree" (`specs/CUESYNC-9-findings.md` §1).

The root cause (findings §2.5/§3): `GtkBackend.runMainLoop`
(`Sources/GtkBackend/GtkBackend.swift:118-155` in the pinned v0.8.0 checkout) ticks a
`mainRunLoopTicklingLoop()` that calls `RunLoop.main.limitDate(forMode: .default)` on every
non-macOS platform, to keep Swift's `@MainActor`/`DispatchQueue.main` working under GtkBackend
(upstream PR #141 — genuinely needed, CueSync's own `.task { }` modifiers depend on it).
swift-corelibs-foundation, however, unconditionally binds `RunLoop.main` to the *same thread's
Win32 message queue* on Windows (`_CFRunLoopSetWindowsMessageQueueMask(_, QS_ALLINPUT, ...)` in
`RunLoop.swift`'s `_mainRunLoop` initializer) that GDK's own win32 backend already drains for
mouse/keyboard/close-button input via this same GLib main loop — two independent, uncoordinated
consumers racing for ownership of one thread-global queue. Neither the app's `.onTapGesture`
wiring nor any `can-target` flag was involved; the defect was one layer below both.

The live click-probe then made the signature sharper than "no input": before/after screenshots
were byte-identical (center click changed 0 pixels) AND the window rendered essentially empty —
only a scroll-bar, no header/buttons/accents, undersized below the requested 1200×800. Empty
render *and* dead input together are one defect, not two: GDK was starved of the single thread
message queue that drives both its win32 event delivery and its frame-clock repaint.

The fix went through two mechanisms, and the difference is the lesson. **Rounds 1–2** kept
ticking `RunLoop.main` (PR #141's fix must not regress) but tried to make GDK win the queue by
*priority*, all `#if os(Windows)`: schedule the tickler's `g_timeout_add_full` at
`G_PRIORITY_DEFAULT_IDLE` (200) — below `GDK_PRIORITY_EVENTS` (0) and `GDK_PRIORITY_REDRAW` (120) —
floor its reschedule at 8 ms so it can never busy-loop at 0 ms, and drain GLib's default
`GMainContext` first each tick. The probe did not move: lowering priority makes the theft *rarer*,
not impossible — in any iteration where GDK has nothing ready, the tickler still runs a
`.default`-mode `RunLoop.main` pass, and *that pass itself* `PeekMessage(NULL, …, PM_REMOVE)`-drains
the one Win32 queue GDK owns. You cannot out-prioritize a competitor you keep inviting to run.
**Round 7** (the shipped `patches/swift-cross-ui-0.8.0-windows-input.patch`) is the structural fix:
on Windows, *never* tick `RunLoop.main` at all. PR #141's real requirement is only that
`@MainActor`/`DispatchQueue.main` jobs run — which on non-Darwin means draining libdispatch's main
queue — so the tickler calls libdispatch's own CoreFoundation-integration hook
`_dispatch_main_queue_callback_4CF` directly (via `@_silgen_name`) instead of routing through
Foundation's run loop. Foundation then never touches the Win32 queue and GDK is its sole owner; the
GLib drain plus the priority/floor stay as belt-and-suspenders. (Accepted cost, grep-verified absent
from swift-cross-ui and CueSync: Foundation `Timer`/`RunLoop.main.perform` work will not fire on
Windows.) Kept as a separate patch file from CUESYNC-8's `can-target` fix, since the two are
unrelated root causes at different layers (widget-picking vs. main-loop/event-source integration)
that share one dependency.

**Generalized addition to the rule above:** when a GTK window on Windows both paints nothing and
ignores input, suspect the *main loop*, not the renderer or the widgets — specifically any second
consumer of the thread's Win32 message queue. Foundation's `RunLoop.main` is one, bound via
`_CFRunLoopSetWindowsMessageQueueMask(QS_ALLINPUT)`; *every* `.default`-mode pass `PeekMessage`-drains
that queue. GLib source **priority** lowers the collision rate but cannot eliminate it while you keep
pumping the run loop at all — the durable answer is to stop pumping `RunLoop.main` on Windows
entirely and service `DispatchQueue.main`/`@MainActor` through libdispatch directly, leaving GDK the
queue's only owner. (Not yet machine-confirmed on the box — see `specs/CUESYNC-9-findings.md` §0.6.)

## Before you debug input, prove the window is even yours (CUESYNC-9, round 3)

The single most expensive mistake on this ticket was **reading a probe screenshot's pixels without
reading its window title.** Rounds 1–2 spent two full iterations patching swift-cross-ui's main-loop
because a black content area with a scrollbar *looked like* "CueSync rendering empty." It wasn't:
the title bar read `C:\WINDOWS\SYSTEM32\cmd.exe` — the probe had screenshotted and clicked the
harness's **launcher console**, and CueSync's own `CUE SYNC`-titled window was **never on screen at
all**. Every downstream symptom (close-click doesn't kill, center-click changes zero pixels) follows
trivially from "there is no app window," and no amount of input-dispatch or renderer patching can
move a probe that isn't pointed at your app.

The generalized rule, in order, before theorizing about input:
1. **Read the window title in the capture.** If it isn't your app's title, you are debugging the
   wrong window. An empty console (black buffer + a scrollbar, because cmd.exe's screen buffer is
   taller than its window) is the classic decoy — it reads as "renders nothing" to a pixel scan.
2. **Confirm the process is actually running.** A `/SUBSYSTEM:WINDOWS` app opens no console, so a
   launch failure is silent on the terminal; the app simply never shows a window.
3. **On a clean PC, a Swift GUI exe that "does nothing" is usually a missing-DLL loader failure, not
   a UI bug.** The Windows loader resolves the exe's import closure *before* `main` runs; if the
   Swift runtime DLLs (`swiftCore.dll`, `Foundation.dll`, `dispatch.dll`, `swiftCRT.dll`, ICU, …)
   aren't next to the exe and the box has no toolchain on PATH, it fails to start with no window and
   no output. Your CI's own dependency-closure log tells you this: if it resolves those DLLs from a
   *toolchain root* rather than the artifact directory, the shipped artifact is not self-contained.
   The fix is packaging (bundle the runtime DLLs into the artifact), not a source patch — CUESYNC-9
   §0.2, `.github/workflows/swift-windows.yml`'s "Bundle Swift runtime DLLs" step.

The through-line with the `can-target` and main-loop lessons above: **classify the failure at the
right layer before fixing it.** Widget hit-testing, main-loop/event-source integration, and
"the exe never loaded" are three different layers; a screenshot alone cannot tell them apart, but
the window title and the DLL-closure log can.

## A self-contained GTK4 exe that shows no window over remote desktop is a GL-renderer failure (CUESYNC-9, round 4)

Once the artifact is self-contained (GTK **and** Swift runtime DLLs bundled, closure check green) and the
probe *still* shows only the launcher console, stop blaming packaging and **read the box's environment in
the screenshot.** On CUESYNC-9 the clean PC's own desktop carried a **RustDesk** shortcut (plus TeamViewer):
it is a **remote-controlled** machine, and the app is launched into an RDP/remote session. That single fact
reclassifies the failure:

- GTK 4's default GSK renderer on Windows is the **GPU/OpenGL-backed `ngl`/`gl` renderer**. It must create
  an OpenGL context on the window's surface. Over RDP / RustDesk / headless remote, the exposed GL surface
  **cannot back a `GskGLRenderer`** — context creation fails, no `GskRenderer` realizes, and the window
  **never paints or presents** even though the process is alive and `gtk_window_present` was called.
- The discriminating tell vs. a missing-DLL loader failure: a load failure raises a hard Windows
  **error dialog**; a GL-renderer failure shows **no dialog**, just no window. No dialog ⇒ the exe loaded
  and ran ⇒ suspect the renderer, not the closure.
- The fix is a **launch-env config**, not a source bug: force GTK's software renderer with
  `GSK_RENDERER=cairo` (Cairo needs no GPU/GL and always succeeds), set via **GLib's own `g_setenv`** before
  `gtkApp.run` (`GtkBackend.runMainLoop`). Prefer `g_setenv` over the Windows-only `ucrt` `_putenv_s`: it is
  in scope wherever `CGtk` is imported, so it **compiles on macOS too** — you can machine-verify the symbol
  without a Windows box, instead of shipping an un-compile-checked `#if os(Windows)` hunk. CUESYNC-9 §0.3,
  `patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch`.

Generalized: **when a GTK app runs but never shows a window, and the host is remote/virtual/headless, force
the software renderer before touching anything else.** GL-over-remote is the single most common cause, and
`GSK_RENDERER=cairo` is a one-line, framework-native, always-available workaround. Read the *environment*
(remote-desktop tooling on the desktop, VM chrome, session type) as evidence — it is as diagnostic as the
window title.

## When N blind rounds all yield byte-identical probes, ship the instrument, not round N+1's guess (CUESYNC-9, round 5)

Rounds 1–4 each shipped one Windows-only fix reasoned purely from source (main-loop drain, GLib
priority, DLL bundling, `GSK_RENDERER=cairo`) and each came back with a **byte-identical**
`before.png`/`after.png`. Round 4's cairo fix did move the needle — a real GTK window (with a
GTK-drawn close button) now paints where before there was only the launcher console — but the window
renders **empty + size-collapsed** and input is dead. That combination is the tell that **you have
two symptoms, not one**: an empty/collapsed *render* is not something pure input-starvation can
produce (starvation freezes a fully-painted UI). So the remaining causes fork — main-loop starvation
(A) vs. a runtime font/DPI/renderer layout collapse (B) — and they need **different** fixes.

The lesson: **when you cannot see the box and every blind fix returns an identical probe, the
highest-value change is not another candidate fix — it is the missing measurement.** Here that was
`CueSync.exe`'s own `stderr`, which every prior round *named* as decisive and then deferred as
"Windows C interop I can't compile-check." Discharge that objection instead of inheriting it:

- Redirect `stderr` to a log file next to the exe at `App.init()` (before the GLib loop starts), so a
  `/SUBSYSTEM:WINDOWS` (console-less) app still retains GTK/GLib/Pango/GSK diagnostics. GTK
  WARNING/CRITICAL go to `stderr` by default — no `G_MESSAGES_DEBUG` needed.
- Keep it compile-checkable on your own box: use **only ISO-C `freopen`/`setvbuf`/`fputs` + Foundation
  `URL`**, compile the redirect body on every platform and guard only the *call site* with
  `#if os(Windows)`, so `Darwin` type-checks the exact shipped call. Settle the one Windows-only
  unknown (does `stderr` exist in Swift's Windows module?) from **code already proven to compile on
  the Windows runner** — swift-cross-ui's `WinUIBackend/Console.swift` uses `freopen_s(_,_,_,stderr)`
  — not from memory.
- Write the log **next to the exe** and hand the box/gate owner an explicit decision tree: no
  log/banner ⇒ the exe never ran (packaging/launch); `Pango`/font lines ⇒ font-collapse; `GSK`/GL
  lines ⇒ renderer; clean log + empty window ⇒ starvation confirmed. Then round N+1 fixes a *named*
  cause instead of guessing. CUESYNC-9 §0.4, `CueSync/CueSync/UI/CueSyncApp.swift`.

Generalized: **a fix you cannot verify is a guess; after two of them miss, stop guessing and
instrument.** One well-placed, compile-safe log redirect is worth more than a fifth plausible patch.

## An instrument is worthless if its output lands where nothing collects it (CUESYNC-9, round 6)

Round 5 did the right thing — capture `CueSync.exe`'s `stderr` — and still learned nothing, because
it wrote the log **next to the exe** (`<repo>/.build/release/`) and assumed "the box owner will
retrieve it." The click-probe gate returns **exactly two files**: `.factory/probe/before.png` and
`.factory/probe/after.png`. Nothing else in the checkout comes back. So the decisive datum was
captured on the box and then discarded at the delivery layer — the round-5 bullet above that says
"write the log **next to the exe**" was itself the bug.

The lesson: **before you place an instrument's output, find out which artifacts the harness actually
returns, and write into one of them.** A measurement is only as good as its channel back to you.

- **Enumerate the return channels first.** Here they were: (1) the two probe PNGs the gate always
  returns, and (2) GitHub CI logs/artifacts (readable via `gh run view`), which run rarely. Point the
  instrument at a channel that returns — not at wherever is convenient to write.
- **Exploit build-tree layout to reach the collected directory.** The Windows exe ships *inside* the
  repo (`<repo>/.build/release/CueSync.exe`), two levels below `.factory/probe/`. So the app can walk
  argv[0] up to the repo root (the first ancestor carrying a committed marker like `Package.swift`)
  and write the log **into `.factory/probe/`**, beside the evidence the gate harvests — creating the
  dir rather than gambling it pre-exists. Scope it: an end-user install has no `Package.swift`
  ancestor, so it falls back to next-to-exe and the routing only activates on the box/CI checkout.
- **Add a channel you fully control.** A `windows-build` CI step that launches the self-contained exe
  headless under a hard timeout, kills it, and `Get-Content`s the log to the CI console makes the same
  datum readable via `gh run view` on an independent, GPU-less headless Windows VM — which also
  exercises the same `GSK_RENDERER=cairo` path and may reproduce the failure directly. Make it a pure
  instrument: `if: always()` + an explicit `exit 0`, so it can never turn CI red.
- **Re-verify "nothing to backport" against the live upstream, not a prior round's note.** Round 6
  re-checked: swift-cross-ui v0.8.0 is still latest and none of the 17 post-tag commits touch
  GtkBackend Windows input — *and every one of the post-tag Windows commits targets WinUIBackend*.
  When the toolkit's own maintainers have moved all Windows work to a different backend, "patch the
  unmaintained backend" may be a losing game; surface that as a backend decision for the ticket owner,
  don't keep grinding one-line patches. CUESYNC-9 §0.5, `CueSync/CueSync/UI/CueSyncApp.swift`.

Generalized: **capture + a dead delivery channel = no measurement.** Wire the instrument to what the
harness returns before you trust it to unblock the next round.

## When the measurement finally arrives, let it overturn the theory — don't make it confirm the story (CUESYNC-9, round 8)

Rounds 1–7 all built on one theory: Foundation's `RunLoop.main` starves GDK of the Win32 message
queue → "paints but no input." Round 6 wired the instrument (capture `CueSync.exe` stderr) and a CI
channel that returns it. Round 8, the branch was pushed, `swift-windows.yml` ran the diagnostics step
on real `windows-latest`, and the log came back **readable via `gh run view --log`** — the first
independently-auditable Windows runtime evidence in the whole saga.

It said the opposite of the theory. The app's only runtime errors were **148 GTK layout messages**
(100 WARNING + 48 CRITICAL), all one widget: `Gtk-CRITICAL: Allocation height too small … 1200x657 …
needs at least 1200x700`, repeating **~2 Hz for 25 s**. Zero Pango/font, zero GSK/GL. A starved main
loop paints one frame and freezes silently — it does **not** emit a steady stream of fresh layout
criticals. GTK was busy re-laying-out the whole time. Root cause: `ContentView`'s
`.frame(minWidth: 1200, minHeight: 700)` became swift-cross-ui's `minimumWindowSize`; when the display
can't grant it (headless/remote-desktop caps the window at 657) `WindowReference.update` clamps back up
to 700, commits it, GTK re-allocates 657, the `CustomRootWidget` resize callback re-enters `update` —
an **infinite relayout loop** that never settles, so the UI renders collapsed and dispatches no input.
Fix: drop the hard content min; keep `.defaultSize`; let the inner `ScrollView` absorb overflow.

- **Separate inherent toolkit noise from the real signal.** The `Allocating size to GtkFixed …
  without calling gtk_widget_measure()` warning is how swift-cross-ui's GtkBackend works on *every*
  platform (every container is a `Gtk.Fixed` positioned by Swift-side layout) — noise. The `CRITICAL`
  was the signal. Grep-dedup the log and count by message type before theorizing.
- **A hard minimum size the display can't satisfy is a deadlock, not a nicety.** On GtkBackend a
  content `.frame(min…)` is not a soft "prefer at least" — it is a window minimum enforced through a
  clamp-and-recommit loop with no floor for "yield to a smaller display." There is no GTK hard window
  minimum that yields; the resilient port has **no** hard min and uses `.defaultSize` + a ScrollView.
- **A faithful-port literal can be the bug.** Spec §B.10 said "minimum 1200×700" and a compliance test
  pinned the exact `minWidth:1200`/`minHeight:700` source tokens — so the test was enforcing the
  root-cause defect. When an acceptance criterion and the ticket's own DoD ("fix input at the root")
  contradict, the criterion that encodes the defect loses: fix the code, flip the test to *forbid* the
  defect (so it can't regress), document the divergence loudly, and surface the spec tension.
- **Don't let a disproven-but-green patch masquerade as load-bearing.** Round 7's input patch is
  CI-green and independent of the resize loop, so it stays this round — but its premise is dead. Flag
  it as a candidate revert; don't let "it's committed and green" harden a fix for a non-problem.

Generalized: **an unverifiable fix is a guess, and a guess repeated seven times is still a guess.**
The moment real evidence lands, rank it above every prior round's narrative — even (especially) your
own. CUESYNC-9 §0.7, `CueSync/CueSync/UI/CueSyncApp.swift`.

## Two bugs with one symptom: fixing the loud one can unmask — not disprove — the quiet one (CUESYNC-9, round 10)

Round 8 fixed the layout-thrash loop (above) and, because the input death vanished from *theory*,
round 9 reverted the run-loop input patch as "disproven." Then the first probe captured **after** that
revert (with round 8's fix in place) came back: layout flood gone, window full-size — **and input still
100% dead** (`close_click_exited: false`, `changed_ratio: 0`, black content). Two independent bugs had
been sharing one symptom ("paints but nothing is clickable"): a layout loop *and* Win32-queue
starvation by the Foundation `RunLoop.main` tickler. The loop was the *louder* one and, while present,
**masked** every input experiment rounds 1–7 ran — so none of those "didn't move the probe" verdicts
were ever valid. Round 9 removed the input fix at the exact moment it could first be tested fairly.

- **"The symptom went away in my model" ≠ "the bug is gone."** Round 8's log disproved *starvation as
  the layout-loop's cause*; it never disproved queue starvation as a *separate* cause. The tell it was
  mis-read as a disproof: "GTK is actively laying out ⇒ not starved" — but layout runs on GLib idle
  timers, independent of the Win32 message queue that carries `WM_PAINT` and input. Don't let one bug's
  evidence acquit another bug on a shared symptom.
- **When two defects share a symptom, fix the dominant one first, then RE-MEASURE before deleting the
  other's fix.** Reverting an unproven fix is right (spec step 5) — but sequence it: land the dominant
  fix, get a clean probe, *then* decide the other fix's fate on evidence, not on the model.
- **The minimal input fix was already in the audit the whole time.** `§2.5` named the tickler as "the
  one non-macOS-only mechanism that touches the OS event queue." The fix isn't a new drain or an
  `@_silgen_name` hook (both reverted, both redteam-flagged) — it's narrowing the tickler's existing
  `#if !os(macOS)` to also exclude Windows, because macOS **already** runs GtkBackend interactively
  *without* the tickler. The strongest fix is often "make the broken platform match the working one,"
  not "add machinery to the broken one." Trade-off (Windows Foundation async now unserviced → file
  dialogs) is documented and strictly better than total input death; still one suspect, gate-verified.

Generalized: **a fix that only ever ran behind a bigger bug was never tested — unmask it, re-probe,
and let the machine, not the story, decide whether it works.** CUESYNC-9 §0.9,
`patches/swift-cross-ui-0.8.0-windows-runloop-tickler.patch`.

## Pre-register the falsification test, and when it fires negative, revert — don't rationalize (CUESYNC-9, round 11)

Round 10 shipped the tickler-guard fix **and wrote down, in advance, exactly what would refute it**:
"if the next probe still shows `close_click_exited: false`, revert this hunk before the next suspect."
The next probe came back `close_click_exited: false`. Because round 10 had disabled the tickler on
Windows and round 8's probe had it enabled, the two probes formed a **clean controlled A/B — one
variable, the tickler, changed; input stayed dead in both.** That is a *machine* refutation of the
Win32-queue-starvation theory (§2.5/§0.9), not another argument about it. Ten rounds of narrative
couldn't kill that theory; one controlled experiment did.

- **A pre-registered "what would prove me wrong" is the antidote to a self-confirming saga.** This
  bug drew nine rounds of plausible stories each "explaining" a byte-identical probe. The thing that
  finally cut through was committing — before seeing the result — to a single boolean oracle and a
  mandatory action on each outcome. Write the falsifier down *with* the fix; then obey it.
- **Change exactly one variable between probes or you learn nothing.** The 14:26-vs-15:22 pair was
  decisive *only* because the sole difference was the tickler's `#if`. Had round 11 also tweaked the
  renderer or layout, the negative probe would have been uninterpretable. One suspect per round isn't
  bureaucracy — it's what makes each probe a measurement instead of an anecdote.
- **When the last in-lane suspect is refuted and the survivor is upstream + unmaintained, escalate —
  don't manufacture suspect N+1.** Renderer (GSK-cairo, clean log) and fonts (zero Pango) are ruled
  out on-box; the Swift layer's window wiring is correct (`gtk_widget_show` + `gtk_window_present`).
  What's left is GDK's win32 C event backend — which every post-v0.8.0 upstream Windows commit
  abandons in favour of **WinUIBackend**. That's an architectural/backend decision, out of the
  view-layer lane. The honest deliverable becomes *the refutation + the escalation*, not an 11th patch.

Generalized: **the value of a disciplined negative result is that it ends a line of inquiry cleanly —
bank it, revert the disproven change, and hand the human the one decision only they can make.**
CUESYNC-9 §0.10; round-10 patch reverted per spec step 5.

## `window_found: true` is not `clicked_your_window: true` — a red gate can be a harness false-negative (CUESYNC-9, round 12)

Round 3's lesson was "prove the window is even yours" — back then the probe screenshotted the launcher
`cmd.exe` console and `window_found` was effectively bogus. Round 12 is the sharper successor: the probe
now *does* find CueSync (`window_found: true`, a plausible rect `(52,52)–(1280,906)`), and the red verdict
still isn't about CueSync. Reading the probe's own `before.png`/`after.png` on the macOS box (no Windows
needed): a black `~958×487` window sits foregrounded at `(0,0)` with a **scrollbar that has up/down arrow
buttons** — a Win32/`conhost` scrollbar, not GTK's arrow-less overlay one; `958×487` is a default 80×25
console. That is the launcher console, on top, and `gtk_window_present()` can't pull CueSync in front of it
(Windows foreground-lock). The gate derives its center click from the rect midpoint `((52+1280)/2,
(52+906)/2) = (666,479)` — which lands **inside** that console. So `center_click_changed: false` measured
the console's (unchanging) pixels, not CueSync, no matter how healthy CueSync's input is.

- **Read the pixels *and* the z-order, not just the boolean.** `window_found: true` says a window with
  that title/class exists; it says nothing about whether the synthesized click reached it. A foreground
  window from another process (here the probe's own launcher) can occlude the exact click point. Verify
  the app is the topmost window *at the click coordinate* (window-from-point), not merely present.
- **A synthesized-input gate can produce a false negative from the harness, not the app.** Before an 11th
  in-app patch, rule out the instrument: is the click landing on your realized surface? Is the click
  coordinate derived from the real control geometry (GTK CSD close-button offset / native titlebar) or
  from a "top-right corner" guess that may miss? A machine oracle is only an oracle once it provably
  exercises the thing under test.
- **The right fix for "the harness clicks the wrong window" is in the harness, not the app.** Forcing the
  app to steal foreground (GDK-win32 → `SetForegroundWindow`/`HWND_TOPMOST`) to defeat a broken probe is
  the wrong layer, needs Windows-only interop you can't compile-check off-box, and only masks a center-leg
  z-order problem while leaving a coordinate-geometry close-leg problem untouched. Fix the probe: raise or
  hide the launcher console, hit-test topmost-at-point, drive close via `WM_CLOSE` to the located handle.

Generalized: **a red result from a machine gate is only evidence against your code once you've proven the
gate actually acted on your code; until then a false-negative harness and a real app bug are
indistinguishable — and a whole saga can burn re-fixing an app the gate never validly touched.**
CUESYNC-9 §0.11; no patch shipped this round (tree stays at the round-11 verified-green state).

## "No missing `present` call" — did you check the call-graph, or just that the method exists? (CUESYNC-9, round 13)

Rounds 11–12 concluded the Swift window wiring was correct and *nothing a patch could add was missing*,
because the backend plainly has both `show(window:) → gtk_widget_show` **and** `activate(window:) →
gtk_window_present`. Both methods exist — but existence is not invocation. Tracing who actually calls them
for the **initial** `WindowGroup` window: SwiftCrossUI's `WindowReference.update` calls `backend.show(window:)`
once on `isFirstUpdate` and **never** `backend.activate(window:)` — `activate`/`present` is reached only via
`openWindow(id:)` and `bringWindowForward()`, neither of which fires at bootstrap. So the initial window is
`gtk_widget_set_visible(true)` (maps the surface — enumerable, has a rect, hence `window_found: true`) but
never `gtk_window_present()` (raises + focuses). On Windows it therefore maps **behind** the foreground
launcher console and paints zero visible pixels — the exact "renders nothing / clicks hit the console"
symptom the whole saga chased as "input death."

- **`show` ≠ `present`. A mapped-but-unraised top-level is `window_found: true` and invisible at once.** On
  GTK4/Windows, `gtk_widget_set_visible(true)` does not bring a window to the foreground; `gtk_window_present()`
  does. "The window has a rect" proves it was mapped, not that it is on top or painted.
- **When you conclude "no Swift fix exists," you are asserting a call-graph fact — verify it as one.** Don't
  stop at "the backend has a present method." Follow the initial-window bootstrap path (`App.run → scene
  update → WindowReference.update`) and see which of show/activate it *actually* reaches. Round 11/12's "no
  missing `present`" was true of the method table and false of the call-graph.
- **Calling the toolkit's OWN `present()` is not the GDK-win32 foreground hack you rejected.** Round 12
  correctly ruled out reaching for `SetForegroundWindow`/`HWND_TOPMOST` via `gdk_win32_surface_get_handle`
  (wrong layer, un-compile-checkable off-box). But making `show(window:)` also call the framework's existing
  `window.present()` — the identical call `activate` already makes — is GTK's own public API, compiles on the
  macOS authoring box (it did: release build green), and closes a real gap. Windows-guarded so macOS/Linux
  are untouched.
- **Step-5 outcome (round 14): the gate fired, and `present()` lost — necessary was not sufficient.** The
  fresh post-patch probe (`before.png`, judged by pixels as pre-registered) still shows console gray
  `(12,12,12)` + bare desktop `(0,0,0)` with **zero** matches for all four accent colors, `changed_ratio: 0`;
  the window merely cascaded further off-screen (offset 52→104→156 px across the last three runs, a textbook
  Windows default-placement cascade of a fresh, screen-sized top-level). Decisively, even the window's
  **on-screen** top-left corner (from offset `(156,156)`) shows no accents — so this is a z-order/foreground
  failure `present()` did **not** beat, not mere off-screen clipping. `gtk_window_present()` from a
  non-foreground process cannot steal activation from the console that owns the Windows foreground; the
  one-time startup grant did not materialize here. Per spec step 5 the hunk was **reverted** (round 14),
  tree back to the two-patch verified-green state.

Generalized: **the call-graph audit was still worth doing — "no fix exists" was genuinely a runtime claim
rounds 11–12 asserted without tracing — but closing the `show`/`present` gap was *necessary, not sufficient*.
A present that is finally invoked can still be refused: on Windows a background process's `gtk_window_present()`
does not defeat another process's foreground-lock. So the fixable in-lane gap was real AND the escalation past
the view layer still stands — the durable blocker (foreground-lock / WinUIBackend, or a harness that raises +
repositions the window before probing) is below the Swift layer, exactly where §0.11 put it. Verify your
call-graph claims (round 13 was right to), but don't assume the newly-reached call *succeeds* off-box — let the
gate's pixels, not the patch's plausibility, decide; when they don't move, revert (round 14 did).** CUESYNC-9
§0.12 (the gap) + §0.13 (the refutation); no patch survives this round.

## The workaround that makes the window appear can be painting every pixel your oracle later reads (CUESYNC-9, round 15)

Round 4 shipped `GSK_RENDERER=cairo` to force GTK's software renderer, because the GPU/GL renderer could
not realize a surface over the RDP/RustDesk probe box (a real, correct diagnosis — §0.3, the lesson two
sections up). It made a window appear. It was also **left forced unconditionally on every Windows build for
eleven rounds** — and GTK's Cairo backend software-renders CueSync's content **black**. So from round 4 on,
every probe frame was a black window, and rounds 5–14 read that blackness as, in turn, empty render, input
death, and foreground-lock. Round 15's one-line correction — gate the cairo force behind an opt-in env
(`if g_getenv("CUESYNC_SOFTWARE_RENDER") != nil { g_setenv("GSK_RENDERER","cairo",1) }`), default to GL —
is what finally lets the real coloured UI paint on real hardware.

- **A "make it appear" fallback and "it isn't painting / isn't responding" are pixel-identical to a
  before/after diff.** A window forced to a software renderer that draws content black produces the exact same
  zero-accent frame as a window that never painted or never took focus. The accent-scan oracle §0.13 trusted
  to "discriminate" could not tell cairo-black from never-painted — the two hypotheses were unfalsifiable *by
  that instrument* the whole time. Before you conclude "the pixels prove X," confirm the pixels *can* show
  not-X: that the renderer under test actually draws the colours you're scanning for.
- **A workaround you leave on is an uncontrolled variable in every experiment that follows it.** Round 10's
  own discipline was "change exactly one variable per probe." Rounds 5–14 honoured that for the *fix under
  test* while silently pinning the *render mode* to a software fallback that corrupted the measurement. When
  you ship a fallback to unblock a probe, treat it as a variable you must be able to turn off — env-gate it,
  default to the real path — so later rounds can measure the app, not the scaffolding.
- **Make diagnostic fallbacks opt-in, not default.** The correct shape is: real renderer by default (so the
  human GTE and any GL-capable box see the true UI), software fallback only when a launch context explicitly
  asks for it (`CUESYNC_SOFTWARE_RENDER=1` for a headless/RDP capture that would otherwise get no window at
  all). The probe then chooses its trade-off knowingly: cairo → a window appears but content is black, so the
  pixel-change leg is meaningless while the process-kill leg still works; GL → real pixels but only where GL
  can realize. A fallback wired as the unconditional default silently makes that choice for every future round.

Generalized: **a workaround that makes the window *appear* is not neutral to what the window *shows* — if it
swaps the renderer, it can black out exactly the pixels your gate measures. Gate every diagnostic fallback
behind an explicit opt-in and default to the real path, or you will spend rounds debugging the scaffolding
you yourself installed.** CUESYNC-9 §0.14; commit `9ed33bd` — cairo made opt-in, GL restored as default.
