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

The fix (`patches/swift-cross-ui-0.8.0-windows-input.patch`) keeps ticking `RunLoop.main` (PR
#141's fix must not regress) but drains GLib's own default `GMainContext` non-blockingly first,
`#if os(Windows)` only, every tick — giving GDK deterministic first refusal on whatever input is
already queued before Foundation's competing drain ever runs. Kept as a separate patch file from
CUESYNC-8's `can-target` fix, since the two are unrelated root causes at different layers
(widget-picking vs. main-loop/event-source integration) that happen to share the same dependency.
