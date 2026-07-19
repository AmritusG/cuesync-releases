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

The fix (`patches/swift-cross-ui-0.8.0-windows-input.patch`) keeps ticking `RunLoop.main` (PR
#141's fix must not regress) but makes GDK win the queue *structurally* rather than by luck, all
`#if os(Windows)`: it schedules the tickler's `g_timeout_add_full` at `G_PRIORITY_DEFAULT_IDLE`
(200) — below `GDK_PRIORITY_EVENTS` (0) and `GDK_PRIORITY_REDRAW` (120), so GLib skips the tickler
in any main-loop iteration where GDK has a pending input message or a queued repaint — floors the
reschedule at 8 ms so it can never busy-loop at 0 ms and wake the context every iteration, and
still drains GLib's default `GMainContext` first each tick. (Round 1 shipped only that last drain
and did not move the probe: a one-shot drain can't overcome a *same-priority* tickler that re-arms
at 0 ms — the generalizable trap is that on Windows `RunLoop.main` is bound to the Win32 message
queue, so anything pumping it competes with GDK for the same queue; lower it below GDK's sources,
don't just race it.) Kept as a separate patch file from CUESYNC-8's `can-target` fix, since the two
are unrelated root causes at different layers (widget-picking vs. main-loop/event-source
integration) that happen to share the same dependency.

**Generalized addition to the rule above:** when a GTK window on Windows both paints nothing and
ignores input, suspect the *main loop*, not the renderer or the widgets — specifically any second
consumer of the thread's Win32 message queue (Foundation's `RunLoop.main` is one, bound via
`_CFRunLoopSetWindowsMessageQueueMask(QS_ALLINPUT)`). GLib source **priority** is the lever: GDK's
event (0) and redraw (120) sources must out-prioritize whatever else pumps the queue, or GDK
starves of both input and repaint at once.

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
