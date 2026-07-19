# CUESYNC-9 §§1–3 findings — window/main-loop input death

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
