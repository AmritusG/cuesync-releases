# CUESYNC-8 §2 findings — reading the pinned GtkBackend source

Recorded per spec step 2 ("Do not assume; read it"). Verified by running `swift package
resolve` against this repo's pinned `Package.swift` (`exact: "0.8.0"`) and reading
`.build/checkouts/swift-cross-ui`, confirmed at `HEAD` == tag `v0.8.0`, commit
`a6d206370812e3b9edba259d167e848892c5013d` (`git log -1 --format=%H` inside the checkout).
All file:line citations below are relative to that checkout unless stated otherwise.

## §2.1 — H1 (missing wiring): ruled out

`GtkBackend` declares real conformance to the composite feature protocol the two modifiers
need:

```swift
// Sources/GtkBackend/GtkBackend.swift:15-34
public final class GtkBackend:
    BaseAppBackend,
    ...
    BackendFeatures.Gestures,
    ...
```

`BackendFeatures.Gestures` is `TapGestures & HoverGestures`
(`Sources/SwiftCrossUI/Backend/BackendFeatures/Gestures/Gestures.swift:9`). Both requirements
are implemented with real GTK primitives, not stubs:

```swift
// Sources/GtkBackend/GtkBackend.swift:1535-1616
public func createTapGestureTarget(wrapping child: Widget, gesture: TapGesture) -> Widget {
    var gtkGesture: GestureSingle
    switch gesture.kind {
        case .primary: gtkGesture = GestureClick()
        ...
    }
    child.addEventController(gtkGesture)
    return child
}
public func updateTapGestureTarget(...) {
    ... gesture.pressed = { _, nPress, _, _ in ... action() } ...
}
public func createHoverTarget(wrapping child: Widget) -> Widget {
    child.addEventController(EventControllerMotion())
    return child
}
public func updateHoverTarget(...) {
    ... gesture.enter = { ... action(true) }; gesture.leave = { ... action(false) } ...
}
```

`Widget.addEventController` (`Sources/Gtk/Widgets/Widget.swift:125-129`) calls the real
`gtk_widget_add_controller` and registers the GTK signal handlers — not a no-op. The call
site in `OnTapGestureModifier`/`OnHoverModifier` is guarded by the `@CastBackend` macro
(`Sources/SwiftCrossUIMacrosPlugin/CastBackendMacro.swift:114-119`), which expands to:

```swift
guard let castedBackend = backend as? any BaseAppBackend & TapGestures else {
    fatalError("'\(Backend.self)' does not implement 'TapGestures'")
}
```

If `GtkBackend` didn't conform, every `.onTapGesture`/`.onHover` in the app would `fatalError`
on first render. The GTE's report is silent non-response, not a crash — so this cast is
succeeding at runtime, confirming the real GtkBackend implementation above is what's running.
**H1 does not hold**: the backend hook is implemented and invoked.

## §2.2 — H2 (overlay interception): confirmed, with a concrete mechanism

### The shared container primitive

Every multi-child layout construct (`Group`, `.overlay`, `.background`, stacks) funnels
through the same backend primitive:

```swift
// Sources/GtkBackend/GtkBackend.swift:569-586
public func createContainer() -> Widget { return Fixed() }
public func insert(_ child: Widget, into container: Widget, at index: Int) {
    let container = container as! Fixed
    container.put(child, index: index, x: 0, y: 0)
}
```

`Gtk.Fixed` (`Sources/Gtk/Widgets/Fixed.swift`) places children by absolute coordinates with
**no automatic layout** and, per its own `put`/`swap` implementation
(`Sources/Gtk/Widgets/Fixed.swift:47-56`, `GtkBackend.swift:594-601`), z-order for overlapping
children follows raw GTK child-insertion order and cannot be rearranged after the fact
("Gtk.Fixed doesn't let us rearrange children... overlapping widgets may end up with
unexpected z ordering" — `GtkBackend.swift:595-598`, an admission already in the vendored
comments).

### What `.overlay` builds

```swift
// Sources/SwiftCrossUI/Views/Modifiers/Layout/OverlayModifier.swift:45-50, 83-101
func asWidget(...) -> Backend.Widget { body.asWidget(children, backend: backend) }
// body is TupleView2<Content, Overlay> — TupleView's default asWidget wraps in Group:
//   Sources/SwiftCrossUI/Views/TupleView.swift:28-36 -> Group(content: self).asWidget(...)
//   Sources/SwiftCrossUI/Views/Group.swift:17-24:
//     let container = backend.createContainer()          // a Fixed
//     for (index, child) in children.widgets(...) { backend.insert(child, into: container, at: index) }
```

So `.overlay { RoundedRectangle().stroke(...) }` produces one `Fixed` whose two children are
`[content, borderShape]` at the **same position**, `content` inserted first (index 0),
`borderShape` second (index 1) — i.e. the border paints on top per the insertion-order z-rule
above. `.cornerRadius(n)` does not add a wrapping widget:

```swift
// Sources/GtkBackend/GtkBackend.swift:615-621
public func createCornerRadiusContainer(wrapping child: Widget) -> Widget { child }
public func setCornerRadius(of widget: Widget, to radius: Int) { widget.css.set(...) }
```

### The concrete break: compound controls, not simple buttons

`CollapsibleSection` (`CueSync/CueSync/UI/CollapsibleSection.swift`) attaches
`.onTapGesture` to the **header row only**:

```swift
// CollapsibleSection.swift:44-77
HStack(spacing: 10) { ... }
    .padding(.horizontal, 20).padding(.vertical, 14)
    .onTapGesture { ... state.collapsedSections ... }   // gesture lives HERE, on the header
```

...then wraps the **whole section** (header + content VStack) in a decorative border
afterward, at the outer level, with no gesture re-attached there:

```swift
// CollapsibleSection.swift:87-92
.background(colors.sectionBG)
.overlay {
    RoundedRectangle(cornerRadius: 10).stroke(colors.border, style: StrokeStyle(width: 1))
}
.cornerRadius(10)
```

Per §2.2's container mechanics, the outer `.overlay` creates a new `Fixed` whose two children
are `[header+content, borderShape]`, with `borderShape` on top and stretched to the full
section rectangle (GTK hit-tests a widget's allocated box, not its painted stroke outline) —
covering the header row too. The header's `GestureClick` lives several levels **below** the
content child, on a widget that is a **sibling**, not an ancestor, of the picked border
widget — so a click on the header is captured by the border sibling and never reaches the
header's own gesture. `StepperField` has the identical shape: the ▲/▼ arrows carry their own
`.onTapGesture` (`Controls/StepperField.swift:52,62`), and the *whole field* gets a second,
outer `.overlay` border afterward (`StepperField.swift:73-78`) that covers the arrows too.

The single-region controls (`BrandButtons.swift`, `HoverButton.swift`) apply `.onTapGesture`
**after** `.overlay`, so the gesture sits on the same outer `Fixed` that the border is a child
of — an ancestor relationship that GTK's default `propagation-phase="GTK_PHASE_BUBBLE"`
(`Sources/GtkCodeGen/GirFiles/Gtk-4.0.gir:53498`, confirmed as the constructor default for
`GestureClick`/`EventControllerMotion`, which set no explicit phase) should in principle still
deliver to. Regardless of that ordering nuance, the border sibling is still the widget GTK
*picks* for those clicks, and nothing in this codebase ever needs a decorative `Shape` to be
clickable (§2.3) — so the fix below removes the intercepting sibling from picking entirely,
which is a strict superset fix covering both the proven-broken compound controls and the
single-region controls, independent of exactly how deep the bubble-phase gap actually runs.

### No existing hit-test-transparency mechanism

```
$ grep -rniI "can.?target" Sources/    # (from the checkout root)
<zero results>
```

`can-target` (GTK's hit-test-transparency flag, `default-value="TRUE"`,
`Sources/GtkCodeGen/GirFiles/Gtk-4.0.gir:178172-178180`, "Whether the widget can receive
pointer events" — the literal GTK analogue of SwiftUI's `.allowsHitTesting(false)`) is never
read or set anywhere in the pinned swift-cross-ui checkout. There is no existing protection
against a decorative sibling stealing a pick; the macOS original's `GridOverlay`
(`Views/ContentView.swift:187`) gets this for free from `.allowsHitTesting(false)`, which has
no swift-cross-ui counterpart today.

**H2 confirmed.** Root cause: decorative `Shape`-backed overlay/background/divider widgets
default to `can-target = TRUE` and, being painted on top within a shared `Gtk.Fixed`, are
picked ahead of the sibling subtree that actually owns the tap/hover gesture.

## §2.3 — Fix locus: every `Shape` in this app is decorative

All `Shape`-backed widgets (`RoundedRectangle`, `Rectangle`, `Circle`, …) funnel through one
GtkBackend entry point:

```swift
// Sources/GtkBackend/GtkBackend.swift:1620-1622
public func createPathWidget() -> Widget { DrawingArea() }
```

used exclusively by `Shape.asWidget` (`Sources/SwiftCrossUI/Views/Shapes/Shape.swift:73`).
Grepping every `.onTapGesture`/`.onHover` call site in `CueSync/CueSync/UI/` confirms none is
ever attached directly to a `Shape` — they land on `HStack`/`VStack`/`Text` rows only (borders,
step-badge fills, and the `Rectangle` divider inside `CollapsibleSection` are used purely as
decoration/fill throughout `UI/`). Setting `can-target = false` on the widget
`createPathWidget()` returns is therefore safe for the whole app today, mirrors the macOS
`GridOverlay.allowsHitTesting(false)` precedent the spec cites, and is a one-property,
one-call-site change — no new dependency, no `GtkFixed`/absolute-position API added (`Fixed`
is pre-existing framework internals, not something this patch introduces).

## §2.4 — Step 5 (envelope canvas): no drag/location primitive exists at 0.8.0

`BackendFeatures.Gestures = TapGestures & HoverGestures` only
(`Sources/SwiftCrossUI/Backend/BackendFeatures/Gestures/Gestures.swift:9`) — there is no
`DragGestures` feature protocol anywhere in the checkout:

```
$ grep -rln "DragGesture" Sources/SwiftCrossUI    # <zero results>
$ grep -rln "public func onDrag\|public func onPointer\|public struct DragGesture\|PointerEvent\|onMouse" Sources/SwiftCrossUI   # <zero results>
```

`onTapGesture`'s action closure is `() -> Void`
(`Sources/SwiftCrossUI/Views/Modifiers/Handlers/OnTapGestureModifier.swift:33-38`) — no
pointer location is ever surfaced to app code, even after the gesture patch (the patch fixes
*delivery* of the tap/hover events that already exist; it cannot add a location parameter or a
drag primitive the public `SwiftCrossUI` API doesn't expose). `EnvelopeCanvasView.swift:18-19`
already documents this gap ("no pointer location on tap, no `DragGesture`") and is correct —
**confirmed cannot-reproduce-faithfully, unchanged.** The toolbar + `CuePointsTableView` editor
remain the complete, fully-interactive path for adding/selecting/moving cue points once the
gesture patch lands (their controls are the same `.onTapGesture`/`TextField`/`Picker` primitives
this ticket makes responsive).

## Net effect on the plan

H1 is ruled out by direct evidence (real GTK controllers wired, no `fatalError`, so the
`@CastBackend` cast is provably succeeding at runtime). H2 is confirmed with a specific,
citable mechanism (decorative `Shape` siblings painted on top in a shared `Gtk.Fixed`,
`can-target` never used anywhere in the checkout). The fix (step 3) is: add a `canTarget`
`@GObjectProperty` to `Sources/Gtk/Widgets/Widget.swift` (mirroring the existing `sensitive`
property at line 135) and set it `false` in `GtkBackend.createPathWidget()`
(`Sources/GtkBackend/GtkBackend.swift:1620-1622`) — two small, targeted hunks, expressed as a
`git apply` patch against the pinned checkout per step 3, never editing the dependency in
place. Step 5's envelope-canvas drag/click editing stays out of scope: 0.8.0 exposes no
location-aware tap or drag primitive at the public `SwiftCrossUI` layer for the patch to wire
up, gesture-delivery fix or not.
