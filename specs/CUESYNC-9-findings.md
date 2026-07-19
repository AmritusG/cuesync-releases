# CUESYNC-9 §§1–3 findings — window/main-loop input death

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

`Sources/GtkBackend/GtkBackend.swift`'s `mainRunLoopTicklingLoop` keeps ticking `RunLoop.main` on
Windows (PR #141's `@MainActor`/`DispatchQueue.main` fix must not regress), but first drains GLib's
own default `GMainContext` non-blockingly (`g_main_context_iteration(nil, 0)` in a loop until
nothing is pending) on every tick, `#if os(Windows)` only. This guarantees GDK's own win32 backend
gets deterministic first refusal on whatever is already queued before Foundation's competing
`PeekMessage` drain ever runs, on every single tick, rather than relying on incidental GSource
registration-order luck. No new dependency, no `sed`/text-substitution, no `GtkFixed`/absolute
positioning — `g_main_context_iteration` is GLib's own public C API, already reachable from this
file via the existing `CGtk`/`Gtk` imports (the file already calls `g_application_run`,
`g_idle_add_full`, `g_timeout_add_full`, `g_object_unref` directly). See
`patches/swift-cross-ui-0.8.0-windows-input.patch` for the full diff and rationale comment.
