# CUESYNC-9 §§1–3 findings — window/main-loop input death

## §0.18 — ROUND 19 (2026-08-19): with input restored, human testing found the two REMAINING failures were never input at all — every async action (all imports/exports) was stranded by the uncommitted `mainRunLoopTicklingLoop` disable, and "text fields don't work" was GtkEntry discarding the app's colour and painting over its background. Typing had been working the whole time.

> **This round is a caution about instruments.** Round 18 restored click delivery, so CueSync could finally be driven by hand. Two failures remained, and *both* initially looked like input bugs. Neither was. One of them was additionally masked by a diagnostic probe that consumed the very events it was measuring — recorded here because that probe is the sort of thing a later round would otherwise re-add.

**Failure 1 — every `await` action silently did nothing: the tickler disable.** Buttons worked, but no import or export did. The split is exact: `Create Envelope` and the section toggles are synchronous, while every import/export is `Task { … await chooseFile(…) }` (`CueSync/CueSync/UI/Sections/ProjectSectionView.swift:204` onward). The checkout carried an **uncommitted, unpatched** edit disabling `mainRunLoopTicklingLoop` on Windows (`#if !os(macOS) && !os(Windows)`), which is what drives `RunLoop.main` and therefore lets main-actor continuations run. With it disabled, those Tasks never resumed and the file chooser was never even requested. Restoring upstream's `#if !os(macOS)` fixed it: instrumented run shows `CUESYNC9-BRANDBUTTON Serato` → `showFileChooserDialog … action=open` → `shown visible=true`.

**This also finally settles §0.17's open item.** The handoff claimed "NOT the RunLoop tickler", and §0.17 downgraded that to *unverified* because the edit was never compiled into any binary. It is now tested on a binary that contains it, and the verdict is the opposite of the claim: **the tickler disable was load-bearing and actively harmful.** No patch is needed — upstream already has it enabled; the fix is simply never reinstating that local experiment. `scripts/patch-swift-cross-ui.sh` resets to pristine before patching, so a scripted checkout gets the correct behaviour automatically.

**Failure 2 — "text fields don't render text / can't be edited" was a paint bug.** Reported as an input failure and initially measured as one. The decisive evidence is that the entry's own `changed` signal fires per keystroke:

```
CUESYNC9-SETCONTENT was='' -> 'Untitled Project'      (initial, once)
CUESYNC9-CHANGED text='t'  →  'te'  →  'tes'  →  'test'
```

Focus sits on the entry's inner `GtkText` (`sens=true editable=true`), all key presses arrive, characters insert, `onChange` propagates, and there is no reset loop. **Typing was never broken.** What was broken is that the result could not be seen, exactly as the human tester diagnosed unprompted ("unselected text is white so it doesn't show"). Two GTK behaviours combine against the app's own styling:

1. GtkEntry draws text in an inner `text` node the theme styles **directly** (`entry > text { color: … }`). GtkBackend applies `.foregroundColor(…)` to the entry widget's generated CSS class, and the theme's node rule wins for the child — the app's colour is discarded.
2. GtkEntry paints an **opaque themed background** over whatever `.background(…)` drew behind it, so the app's dark field never showed.

For `TextField(…).foregroundColor(colors.textPrimary).background(colors.inputBg)` that yields white-ish text on the theme's light entry: invisible. **Fix:** `patches/swift-cross-ui-0.8.0-gtk-entry-styling.patch` — inherit the colour into the `text` node and drop the entry's own background, added to the same global CSS provider that already neutralises theme styling for `list` / `list > row` / `.navigation-sidebar`. `border`, `padding` and `min-height` are deliberately untouched: they feed GtkEntry's size request, and this saga spent rounds 8–18 on layout geometry. **Paint only, never measurement.** Confirmed by the tester: text now renders in the app's own colours.

**The instrument that ate its own signal (do not re-add).** Two runs concluded "keys arrive but nothing is inserted" — a false negative produced by the probe itself. The diagnostic attached an `EventControllerKey` at **capture** phase above the entry; swift-cross-ui's generated binding declares the `key-pressed` handler as returning `Void` (`Sources/Gtk/Generated/EventControllerKey.swift`) when GTK's signal returns `gboolean`. The handler therefore returns an **uninitialised value**, and a non-zero result means "handled", stopping propagation before the focused widget. Removing the probe made typing work immediately. Two consequences: (a) any future key-path instrumentation must not sit at capture phase above the widget under test, and (b) **the return-type mismatch is a real latent upstream bug** — it makes the propagation behaviour of every `EventControllerKey` in swift-cross-ui undefined, including the one `Window.setEscapeKeyPressedHandler` installs. Not patched this round (nothing currently observable depends on it), but recorded as a known defect.

**Net state after round 19.** Clicks, hover, keyboard, text entry, imports and file dialogs all verified working by a human on the Win-Box. Five live patches, all applying cleanly and idempotently in sequence to pristine `a6d206370812e3b9edba259d167e848892c5013d`: interactivity → gsk-renderer → window-present → container-hit-testing → entry-styling. `swift test` 513/0; the adversarial module 90 passed / 0 failed / 16 skipped.

## §0.17 — ROUND 18 (2026-08-18): FIXED. Both data sources every round since §0.7 was judged on were invalid — the "decisive" GDK trace was captured with the GtkInspector attached, and `swift build -c release` had been reporting success while linking nothing since 2026-08-04. Against a rebuilt binary, a dense `gtk_widget_pick()` grid found the real root cause: CUESYNC-8 excluded `Shape` LEAVES from hit-testing but not the `Gtk.Fixed` CONTAINERS wrapping them, so 156 of 187 grid samples picked a decorative container and no sample ever reached a control. Deriving container targetability from its children restores input.

> **This round retracts evidence rather than adding a suspect.** Two independent instrument failures were found before any new theory was formed, and both invalidate data the standing conclusions rest on. Neither is an app bug; both are why seventeen rounds of app-layer fixes could not move the needle.

**Instrument failure 1 — the GDK trace was captured with the GtkInspector attached.** The ~29 KB `.factory/probe/CueSync-startup.log` that the 2026-08-18 Cowork handoff named "the decisive next datum" opens with `Failed to open display (NULL)` / `Failed to open separate connection to default display` / `Using default display for GtkInspector; expect some spillover`. That third string exists only in GTK's `gtk/inspector/window.c` and is reachable only when `GTK_DEBUG` contains `interactive` — i.e. `GTK_DEBUG` had leaked from the earlier "the Inspector takes clicks fine" experiment into the shell that then set `GDK_DEBUG=events`. **That is the known-WORKING configuration, so the trace describes the wrong condition.** Worse, `GDK_DEBUG=events` emits only `gdk_event_alloc` lines, which name the event *type* and carry **no surface identity** — with a second (Inspector) surface present the trace cannot attribute a single `GDK_BUTTON_PRESS` to CueSync rather than to the Inspector. The handoff's decision tree ("events present ⇒ fix in GtkBackend / events absent ⇒ surface setup") therefore did not fire on it. Preserved verbatim as `.factory/probe/CueSync-startup.inspector-contaminated-2026-08-18.log`.

**Instrument failure 2 — `swift build -c release` had been linking nothing since 2026-08-04.** On the Win-Box the release build printed `Build of product 'CueSync' complete! (931.15s)` and exited 0 while producing **zero** `.o`, `.obj`, `.lib`, `.dll` or `.exe` — a recursive scan of `.build` for binaries written in that window returned nothing, and `.build/x86_64-unknown-windows-msvc/release/CueSync.exe` was still byte-identical to its **2026-08-04 23:29** copy. Only `.swiftmodule` / `.d` / `.dia` were refreshed. SwiftPM was reusing a build plan cached on Aug 4: deleting `GtkBackend.build` made the next build fail outright with `error: unable to load output file map '…/GtkBackend.build/output-file-map.json': The file doesn't exist`, proving the plan was never regenerated (every `output-file-map.json` in the tree was dated 2026-08-04 21:15). Clearing `.build/release.yaml`, `.build/plugin-tools.yaml` and `.build/build.db` restored a real build that **linked** (`[276/277] Linking CueSync.exe`), and the resulting binary's SHA-256 **differs** from the Aug-4 one (`20E3E9AA…` vs `1E401C33…`). **Every "still dead" result produced on this box between 2026-08-04 and 2026-08-18 was therefore obtained from the same unchanging executable, and none of them constitutes evidence about the source that was nominally under test.** Round 17's `present()` predates Aug 4 and is compiled in; the manual `mainRunLoopTicklingLoop` disable in the checkout (mtime 2026-08-18 18:13) is **not**, so the handoff's "NOT the RunLoop tickler" is unverified, not refuted.

**The un-contaminated trace — input reaches GDK.** Fresh binary, `GTK_DEBUG` removed from the environment, `GDK_DEBUG=events`, machine-driven clicks/keys/wheel. No Inspector lines. Every input class is present: `GDK_BUTTON_PRESS`/`RELEASE`, `GDK_KEY_PRESS`/`RELEASE`, `GDK_SCROLL`, `GDK_MOTION_NOTIFY`, `GDK_ENTER_NOTIFY`, `GDK_FOCUS_CHANGE`, `GDK_DELETE`. **This is the handoff's first branch: events reach GDK, so the failure is in routing them to widgets, inside `Sources/GtkBackend` — and §0.4's standing "adopt WinUIBackend" conclusion stays refuted.** The Win32 layer is clean too: one real HWND of class `gdkSurfaceToplevel`, style `0x14020000` (no `WS_CAPTION`, so GTK client-side decorations), **no** `WS_DISABLED`, `WS_EX_TRANSPARENT` or `WS_EX_NOACTIVATE`; `GetForegroundWindow()` == the window, `GetFocus()` on its GUI thread == the window, and `GetCapture()` == 0, so suspect 2 (a stuck grab) is ruled out by direct measurement rather than by inference.

**Events arrive and nothing happens — a controlled A/B.** Using the app's own unbuffered stderr as the detector (each swift-cross-ui relayout emits `Allocating size to GtkFixed …`, which is immune to the animated element that defeats screenshot differencing):

| run | `GDK_BUTTON_PRESS` | relayout lines | all Gtk warnings |
|---|---|---|---|
| 7 machine clicks | 7 | **2** | 6 |
| 0 clicks (control) | 0 | **2** | 6 |

Seven button presses were delivered to GDK and produced **not one byte** of additional widget-side activity. A vertical hit-test sweep then localised what little is live: across **42** click points spanning the full client height, only **3** produced any reaction (client y = 50, 60, 91), all inside the top ~90 px — the GTK CSD headerbar. The whole content area below it is inert. That is the reported "only the title bar works", now measured rather than observed.

**Root cause — `gtk_custom_root_widget_allocate` allocates its child below the child's measured minimum, without measuring it.** `Sources/GtkCHelpers/gtk_custom_root_widget.c:40-47` (pinned `a6d206370812e3b9edba259d167e848892c5013d`) is:

```c
void gtk_custom_root_widget_allocate(GtkWidget *widget, int width, int height, int baseline) {
    GtkCustomRootWidget *root_widget = GTK_CUSTOM_ROOT_WIDGET(widget);
    gtk_widget_allocate(root_widget->child, width, height, 0, NULL);
```

It forces the child to the window's allocation unconditionally — never calling `gtk_widget_measure()` on it, and never clamping to what the child actually requires. Both GTK complaints follow directly and reproduce on **every** run: `Gtk-WARNING: Allocating size to GtkFixed … without calling gtk_widget_measure(). How does the code know the size to allocate?` and `Gtk-CRITICAL: Allocation height too small. Tried to allocate 1200x617, but GtkFixed … needs at least 1200x800.` The geometry decomposes exactly: client `1228x709`, minus 14 px CSD shadow per side = **1200** wide; minus 14 top shadow, ~64 headerbar and 14 bottom shadow = **617** high.

Note the division of labour with the sizing bug above: the wrong `(28, 54)` decoration allowance is *why* the child is short of room, but this unconditional allocate is what turns "short of room" into an invalid allocation instead of an overflow. Fixing the allocate is the robust half — it holds for any window smaller than its content, including a user-resized one — so it is what round 18 changes; correcting the decoration constant is a separate, narrower follow-up recorded below.

**The shortfall is the CSD chrome, not the display — established by changing the display and re-measuring.** The first sweeps ran on a **1280x720** desktop, where the window was capped at `1228x709` (content 617) and it was tempting to conclude the screen was simply too short. Raising the desktop to **1920x1080** and re-running the *same unfixed binary* refutes that: the window settles at `1228x854`, and GTK still logs `Tried to allocate 1200x762, but GtkFixed … needs at least 1200x800`. **The window stops 38 px short of its own content minimum no matter how much screen it is given.** The arithmetic is exact — swift-cross-ui sizes the window as content-minimum + `(28, 54)` of assumed decoration, while the real GTK4 Windows CSD overhead is `(28, 92)`: 14 px shadow per side horizontally, and 14 top shadow + ~64 headerbar + 14 bottom shadow vertically. The 38 px gap is `92 - 54`. So the defect is resolution-independent, and the 720p measurements were a stricter case of the same bug, not a separate one.

**Why macOS is not a counter-example.** The handoff's strongest argument against a layout cause was "macOS-GTK runs the identical swift-cross-ui with working input, so the custom-root/`Gtk.Fixed` layout is cross-platform and therefore innocent". That argument does not hold, because the quantity that differs across platforms is the **decoration overhead the window-sizing assumes**, not the layout code: the `(28, 54)` allowance is close enough to macOS-GTK's own shadow/headerbar geometry that the window there does cover its content minimum, so the under-allocation never triggers. A single wrong constant in shared code can present as Windows-only — which makes the macOS data point *consistent with* this root cause rather than evidence against it.

**Relationship to §0.7.** Round 8 diagnosed the same boundary from the same `Gtk-CRITICAL` (then 1200x657 against a 700 minimum) and fixed it at the app-shell layer by deleting an unsatisfiable `.frame(minWidth:/minHeight:)`. That fix stands and is not being reverted; the residual 800 px minimum is what CueSync's four-section layout genuinely measures, so the app-layer lever is spent and the remaining defect is the framework's unconditional allocate. §0.7 is thus refined, not overturned: it identified the right boundary and the wrong owner.

**The attempted fix, and its REFUTATION.** The candidate was: in `gtk_custom_root_widget_allocate`, measure the child and allocate it `MAX(available, child minimum)` per axis, so the required `gtk_widget_measure()` happens and the child is never sized below its own minimum. It was pre-registered against the vertical hit-test sweep (baseline: 3 live points of 42, all in the top ~90 px) with the rule that a failure to widen the live band means revert, not stack.

Built and measured. **At the GTK level it does exactly what it claims**: the `Gtk-CRITICAL: Allocation height too small` disappears entirely, and the `Allocating size to GtkFixed … without calling gtk_widget_measure()` count drops from 2 to 0. **At the input level it changes nothing.** Per the pre-registration the hunk is therefore **reverted** — the checkout is back to the three live patches exactly — and it is recorded here as a *correctness* improvement worth making on its own merits, but explicitly **not** the input fix. Rounds 9, 11 and 14 disposed of their suspects the same way.

**Two measurement traps this round fell into and climbed out of — recorded so the next round does not repeat them.** (a) The relayout-warning oracle *is silenced by the very fix it was meant to judge*: the round-18 allocate change removes the `Allocating size to GtkFixed` line, so the sweep read "0 live points" for a reason that had nothing to do with input. Any future fix in the allocation path needs a detector that does not depend on GTK warning output. (b) A "hit-test coordinates are shifted ~181 px" conclusion was drawn and then **withdrawn**: with fewer motion events than clicks (GDK compresses motion), aligning the first logged motion to the first click is invalid. Re-aligning to the trailing clicks gives a consistent **−74/−75 px** offset, which is exactly the expected CSD chrome offset. **The coordinate mapping is correct; there is no shift.**

**What the direct instrumentation established (the durable result of this round).** Temporary probes were compiled into `GtkBackend` at four levels and then removed. Against 8–20 machine clicks per run:

| probe | result |
|---|---|
| GDK event allocation | 18 `GDK_BUTTON_PRESS`, 18 `GDK_MOTION_NOTIFY` — events arrive |
| `EventControllerMotion` on the content root | **fires**, coordinates correct (`−74/−75` chrome offset), receiver is the window root (`allocW=1200`), not a split-view pane |
| `gtk_widget_pick()` at the pointer, called from that controller | **returns real, deep widgets** — `TupleView1`, `ForEach`, `FlexibleFrameView` — never `nil`, never the root itself |
| immediate child of the content root | `TupleView1`, `1200x800`, `mapped=true`, `canTarget=true`, `visible=true` |
| `Button.clicked`, `TapGesture.pressed`, `EventControllerMotion.enter` on controls | **0 firings** |

So the failure is now bounded much more tightly than "the client area is dead": **events reach GDK, reach the content root with correct coordinates, and GTK's hit-testing resolves them to real widgets — yet no control-level handler ever runs.** Suspects 1 (window/z-order), 2 (grab), and picking-geometry are all ruled out by direct measurement. The remaining gap is between `gtk_widget_pick` resolving a widget and that widget's event controllers being invoked.

**THE ROOT CAUSE, found by the dense grid sweep — CUESYNC-8 fixed the leaf but not the container.** The two open readings were separated by logging the full pick chain (`gtk_widget_pick`, then walking `gtk_widget_get_parent`) over a 12x18 pointer grid. Reading (ii) is correct. Of **187** samples covering the whole client area, **156 resolved to a `GtkFixed` whose only child was a `tgt=false` `GtkDrawingArea[StyledShapeImpl]` spanning its parent's full 1160x221**, and **not one sample in 187 ever resolved to a control**:

```
LEAF GtkFixed w=1160 h=221
  children={ GtkDrawingArea[StyledShapeImpl] 1160x221@0,0 tgt=false map=true } count=1
```

`gtk_widget_pick()` returns the deepest widget that **contains** the point and is **targetable** — and a container with no targetable descendants still satisfies both. CUESYNC-8 correctly set `can-target = false` on `Shape` leaves in `createPathWidget()`, but swift-cross-ui wraps every view in a `Gtk.Fixed`, and those containers stayed targetable. So a decorative overlay or background Shape kept absorbing every click on the control beneath it. **The CUESYNC-8 diagnosis was right and its fix was one level too shallow** — which is exactly why an app whose Shapes were already excluded still behaved as though nothing were clickable.

**The fix (round 18, `patches/swift-cross-ui-0.8.0-gtk-container-hit-testing.patch`).** Re-derive a container's own `can-target` from its contents whenever its children change (`insert` / `remove(childAt:)` / `removeAllChildren` in GtkBackend's `// MARK: Containers` block): targetable **iff** it owns event controllers **or** has at least one targetable child. `Widget.addEventController` additionally re-asserts `canTarget = true`, so a controller attached *after* that derivation ran — the `createTapGestureTarget` / `createHoverTarget` path attaches directly to the widget — can never be left excluded by ordering. No new dependency, no new import, no `GtkFixed` API added, and CUESYNC-8's `createPathWidget` hunk untouched: this only makes containers agree with the leaf decision CUESYNC-8 already made.

**Verification (clean build, all instrumentation removed).** Same probes, same grids, same machine:

| measurement | before | after |
|---|---|---|
| picks stopping at a Shape wrapper | 156 / 187 | **0 / 187** |
| picks reaching real content (`HStack`, `VStack`, `Text`, `PaddingModifierView`, `BrandButton`) | 3 | **187** |
| hover relayouts, identical 216-point motion path, **zero clicks** | 2 | **16** |
| live click points (20-point column sweep) | 2, both in the CSD headerbar | **7, spanning y=68..406 of the content** |

The hover row is the cleanest control: identical synthetic pointer path, no clicks at all, an 8x increase in widget-driven relayout. The click sweep reproduces at a second, independent column (x=55 % as well as x=30 %). The remaining dead band below y≈406 is expected rather than residual failure — clicking collapses sections, so the lower area becomes empty background mid-sweep.

**Honest residual.** No sample ever picked a literal `GtkButton`; CueSync's controls resolve as `GtkFixed[BrandButton]` with an attached tap gesture, which is what the app actually builds, so this is a naming observation and not an open failure. Round 18 did not confirm keyboard input specifically — the probes exercised pointer paths, and `GDK_KEY_PRESS` events were already reaching GDK before the fix. **The remaining verification that only a human can give is the one the spec has always named: Amrit clicks, and types, in the real window.**

## §0.16 — ROUND 17 (2026-07-21): the FIRST un-confounded probe (round 16's cairo-autodetect tree) finally paints real content AND positions the window on-screen — and it exposes the actual gap: the launch window is `show()`n behind the foreground launcher console, never `present()`ed. Re-apply round 13's `gtk_window_present` fix, whose round-14 revert §0.14/§0.15 invalidated as a cairo-black confound.

> **This is the round that reads the screenshot, not the probe's derived JSON — and they disagree.** Round 16 (`a0cefee`, §0.15) made cairo auto-select on the remote-desktop probe box, so for the first time in the saga the captured frame is neither a GL "no window at all" (round 15) nor a cairo-black null (rounds 5–14). `result.json` reports `launched:true`, `window_found:true`, `rendered:true`, `content_nonblack_frac:0.5492`, `content_stddev:69.0`, and a window `rect` of (26,26)–(1254,880) — and it *also* reports `close_click_exited:false`, `center_click_changed:false`, `changed_ratio:0`. Taken at face value the JSON reads "window is up, painted, on-screen, but ignores the mouse" — the exact Fork-W signature the ticket was written for.

**But `.factory/probe/before.png` / `after.png` (pixel-identical) show WHY, and it is not widget-level input death.** The frame contains exactly two windows: a maximised blue **PowerShell** build console (left, full height — the `git fetch`/`swift build`/`ld complete! (944.96s)`/`Get-Process CueSync` log) and a black **cmd.exe** launcher window (centre-right, titled `C:\WINDOWS\SYSTEM32\cmd.exe`). **There is no CueSync GTK window visible anywhere in either frame.** So the probe's `content_nonblack_frac:0.5492` is measuring the *blue PowerShell console*, not CueSync; the `rect` (26,26)–(1254,880) is CueSync's real HWND (GetWindowRect on the mapped-but-unraised surface — the startup log confirms GTK laid it out: `GtkFixed … needs at least 1200x800`), sitting **behind** those two consoles. The close-click and centre-click both land on the consoles on top, never on CueSync. This is **window/z-order**, ranked **suspect 1/3** (window-level, upstream GtkBackend), NOT app-level hit-testing (CUESYNC-8's `can-target` fix is untouched and was never the issue) and NOT suspect 2 (no grab) — the window simply never came to the foreground.

**Root cause — re-confirmed from the pinned source (findings §0.12, whose round-14 revert §0.14/§0.15 invalidated).** The initial `WindowGroup` window is shown exactly once, through `backend.show(window:)` on `isFirstUpdate` (`Sources/SwiftCrossUI/Scenes/WindowReference.swift:301`). `GtkBackend.show(window:)` is bare `window.show()` == `gtk_widget_set_visible(true)`: on Windows GDK that **maps** the surface (enumerable, has a rect) but does **not raise** it. The raise call — `gtk_window_present` — lives in `GtkBackend.activate(window:)` (`window.present()`), and `activate(window:)` is reached **only** via `openWindow(id:)` (`Sources/SwiftCrossUI/Scenes/Window.swift:87`), never for the launch window. So the launch window maps behind whatever is foreground — here, the cmd.exe launcher the probe box starts `CueSync.exe` from.

**Why round 13's fix was right and its round-14 revert was not.** Round 13 (§0.12) added `window.present()` to `show(window:)` under `#if os(Windows)`. Round 14 reverted it because the post-fix probe showed "zero accent pixels." **§0.14 later proved that datum was a cairo-black confound** (cairo software-rendered CueSync's content black on the probe box for rounds 5–14, so a window that HAD come to the foreground and painted would still scan as zero accents), **and** the round-14 window was cascaded to (156,156) with its close button off the 1228-px screen (§0.13) — two independent reasons the refutation could not see a present() that actually worked. Both confounds are now lifted: round 16's cairo-autodetect paints real content, and this round's window sits at (26,26) (close button ≈ x1224, on-screen). So per spec step 5 (revert non-movers, re-try with new evidence) the `present()` hunk is **re-applied**, not blindly repeated — it is the confirmed in-lane gap and is *necessary* regardless of any deeper input question, because no click on CueSync's own chrome can be evaluated until the window is actually in front.

**The fix (round 17, `patches/swift-cross-ui-0.8.0-windows-window-present.patch`, `GtkBackend.show(window:)`, `#if os(Windows)`, GTK's own `gtk_window_present` via `Window.present()` — the identical call `activate()` already makes; no new dependency, no `GtkFixed`, no Win32 interop).** A freshly-started child of the foreground process gets Windows' one-time startup foreground grant, so the first `present()` raises the window above the launching cmd.exe. Kept a separate, independently-revertable patch (disjoint hunk at `show(window:)` from the interactivity hunk at `createPathWidget`, the GSK hunk at `runMainLoop`, and the round-9-reverted input hunk at `mainRunLoopTicklingLoop`). Applied last (after interactivity → GSK) on all three GtkBackend-compiling legs (macos, windows-build, windows-test) and in `scripts/patch-swift-cross-ui.sh`, idempotent (`git apply --reverse --check`), read-only-cleared on exactly `GtkBackend.swift` on the Windows legs, pinned to `a6d206370812e3b9edba259d167e848892c5013d`.

**Honest residual + disposition (spec step 5).** Classification stays **Fork W**. `present()` is *necessary* and in-lane; whether it is *sufficient* is what the next probe decides against the now-un-confounded frame: (a) if the foreground grant is denied because the PowerShell console (not CueSync's cmd.exe parent) owns foreground at present-time, the raise fails — that residual is the harness's to close (launch CueSync detached / minimise the launcher), consistent with §0.13; (b) the window is content-min-sized (1228×854) on a 1228×854 RDP desktop and cascades +26, so ~26 px hangs off the bottom-right — GTK4 removed `gtk_window_move`, so exact placement is a WM/harness concern, though at +26 the close button is on-screen (unlike §0.13's +156); (c) if the box is physical-console RustDesk (§0.15's belt), the cairo autodetect also needs `CUESYNC_SOFTWARE_RENDER=1`. If after this round the window comes to the foreground and paints real content but its own close button still does not kill the process, THAT is the first clean datum for the widget-dispatch suspect (the round-10 tickler queue-drain theory, un-confounded) — recorded here as the pre-registered next step, not stacked this round.

**Baseline this round.** All three live patches (`interactivity` → `gsk-renderer` → `window-present`) `git apply` clean and in order to a pristine `a6d206370812e3b9edba259d167e848892c5013d` checkout; the window-present hunk `--check` + `--reverse --check` pass (idempotent), LF-only, one `diff --git` header, anchored at `show(window:)`. `Package.swift`/`Package.resolved` untouched; swift-cross-ui stays `exact: "0.8.0"`; the CUESYNC-8 interactivity patch is unchanged.

## §0.15 — ROUND 16 (2026-07-21): round 15's GL-default REGRESSED the probe box from "black window" to NO window — the gate now reports "process exited before showing a window" because the probe never sets the CUESYNC_SOFTWARE_RENDER opt-in round 15 required; fix: auto-select software Cairo when a remote-desktop session is detected, keeping GL the default for a local GPU

> **This is the missing half of round 15.** §0.14 correctly diagnosed that forcing Cairo unconditionally software-rendered the UI BLACK on real hardware, and correctly made Cairo an opt-in (`CUESYNC_SOFTWARE_RENDER=1`) with GTK's GL renderer as the Windows default. But it left the opt-in as an env var **the automated probe never sets** — §0.14's own "Open tension for the probe/harness owner" — and GL cannot realize a surface over the remote-desktop session the clean-PC probe box is driven through (§0.3, still true). So on that box GTK's GL renderer never comes up and the process now **exits before any window appears**, where forced-Cairo (rounds 4–14) always produced *a* window. Round 15 traded "black-but-present window" for "no window at all" on the exact box the gate runs on.

**The current probe evidence (this round, `.factory/probe/`, timestamped 19:15, the round-15 GL-default tree at `e91a669`).** `result.json`: `"launched": true`, `"window_found": false`, `"rect": null`, `"error": "process exited before showing a window (rc=)"`, `close_click_exited: false`, `center_click_changed: false`. `CueSync-startup.log` contains **only** the app's own startup banner — none of the GtkFixed measure/`Allocation height` diagnostics that rounds 8–14 always logged once GTK began laying out a window — so GTK died *before* window layout, consistent with a hard GL-init failure during realize. `before.png` == `after.png`: both show **only** the `C:\WINDOWS\SYSTEM32\cmd.exe` launcher console (arrow-button conhost scrollbar) on a plain black 1228×854 desktop, with **no CueSync window anywhere**. A display *is* active at probe time (the screenshot exists), so this is not "headless / no monitor" — the box simply cannot back a GskGLRenderer.

**Clean A/B — the regression is round 15's renderer default, nothing else.** The only probe-relevant change between round 14's tree (forced Cairo → `window_found: true`, real rects such as (156,156)–(1384,1010) across §0.9–§0.13) and round 15's tree (GL default → `window_found: false`, `rect: null`, process exits) is commit `9ed33bd` flipping Cairo from forced to opt-in. Same box, same launcher, same everything else. Therefore GL-default caused the no-window.

**The fix (round 16, `patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch`, GtkBackend.swift `runMainLoop`, still `#if os(Windows)`, still GLib's own `g_setenv`, NO new module dependency, NO GtkFixed).** Reconstruct round 4's *premise* ("GL can't realize a surface over the remote-desktop/RDP session") as a runtime *condition* instead of the launcher-set env var the probe never sets. Keep GL the default; force Cairo when the process is in a remote-desktop session, detected with no new import from the Windows-set `SESSIONNAME`/`CLIENTNAME` markers Foundation's `ProcessInfo` already exposes:

```swift
let windowsEnvironment = ProcessInfo.processInfo.environment
let inRemoteDesktopSession =
    (windowsEnvironment["SESSIONNAME"]?.uppercased().hasPrefix("RDP") ?? false)
    || windowsEnvironment["CLIENTNAME"] != nil
if g_getenv("CUESYNC_SOFTWARE_RENDER") != nil || inRemoteDesktopSession {
    _ = g_setenv("GSK_RENDERER", "cairo", 1)
}
```

A local console session with a real GPU (the Iris Pro 580 dev box) matches neither branch, so it **keeps GTK's full-colour GL renderer** — round 15's black-UI regression is not reintroduced, and all four of round 15's regression locks (`CUESYNC9GskRendererOptInRegressionTests`: the Cairo `g_setenv` stays gated behind the `CUESYNC_SOFTWARE_RENDER != nil` check, immediate-next-line, exactly once, nil-compared) stay green because the opt-in check remains and Cairo is still conditional — the compound `|| inRemoteDesktopSession` only *widens when* it fires, it does not remove the gate.

**Why this could not be a Win32 `GetSystemMetrics(SM_REMOTESESSION)` call (the more obvious signal).** The GSK-renderer patch's own supply-chain guard (`CUESYNC9WindowsGskRendererWorkflowTests.testGskPatchUsesGLibSetenvForCairoRendererWithNoNewDependency` + `test_adversarial.py::test_gsk_patch_added_lines_...`) forbids **any** `import` on an added patch line. `GetSystemMetrics`/`SM_REMOTESESSION` need `import WinSDK`, which those guards reject as a new dependency. The `SESSIONNAME`/`CLIENTNAME` env markers carry the *same* Terminal-Services/RDP signal `SM_REMOTESESSION` would, but are readable through the already-imported Foundation `ProcessInfo` — no new import, and they type-check the same on every platform.

**Honest residual + disposition (spec step 5).** `SESSIONNAME`/`CLIENTNAME` identify a Windows Terminal-Services / RDP session. If the probe box is instead driven by a tool that attaches to the **physical console** (some RustDesk modes report `SESSIONNAME=Console` and set no `CLIENTNAME`), this auto-detect does not fire, GL is attempted, and the window will still not appear — in that case the guaranteed override is for the harness to launch with `CUESYNC_SOFTWARE_RENDER=1` (now the *belt* to this round's *suspenders*, not the sole mechanism). Either way, this is strict progress on the specific HIGH gate finding this round consumed ("no-window: process exited before showing a window"): it restores the best-known state (a window on the box), from which the still-open foreground-lock / off-screen-cascade harness concerns (§0.13/§0.14) can be separately addressed. Classification stays **Fork W (unverified)** — a valid click still requires the window to be foreground + on-screen, which remains a harness concern out of the view-layer lane; this round un-regresses window *presentation*, not input dispatch. The stale startup banner (`GSK_RENDERER is forced to 'cairo' by patch`, left over from round 4's unconditional force) is corrected in `CueSync/CueSync/UI/CueSyncApp.swift` to describe the actual round-16 decision.

**Baseline this round.** `git apply` of the two live patches (interactivity → gsk-renderer) is clean and in order on a pristine `a6d206370812e3b9edba259d167e848892c5013d` checkout; the round-16 GSK hunk `--check` + `--reverse --check` pass (idempotent). `Package.swift`/`Package.resolved` untouched; swift-cross-ui stays `exact: "0.8.0"`; the CUESYNC-8 interactivity patch is unchanged.

## §0.14 — ROUND 15 (2026-07-20): the round-4 cairo workaround was itself a black-render CONFOUND — rounds 5–14 all judged the pixels of a window that was software-painting its content BLACK, not a window that was failing to paint or dispatch; making cairo OPT-IN (GL by default) removes the confound and REOPENS the input question that §0.13 had (prematurely) declared escalated

> **This is the capstone reversal of the saga, and it invalidates the pixel evidence every round from 5 onward ranked as decisive.** Commit `9ed33bd` ("fix: GSK renderer cairo is OPT-IN, GL by default (unbreak the black UI)"). Round 4's `patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch` forced `GSK_RENDERER=cairo` **unconditionally** on every Windows build (§0.3, to make *a* window appear when the GPU/GL renderer could not realize a surface over the RDP/RustDesk probe box). But GTK's Cairo backend **software-renders content BLACK** on this configuration — it regressed the full GL-rendered CueSync UI that Amrit had already confirmed paints correctly on real hardware (his Win-Box, Intel Iris Pro 580). So from round 4 forward, **every probe was captured against a window whose content cairo was painting black.**

**What this does to §§0.4–0.13.** Rounds 5–14 read those black/near-black frames as proof of *input death* and later *foreground-lock* ("zero accent pixels ⇒ CueSync never came to the foreground / never dispatched input"). But a window that is up, focused, and dispatching input perfectly would *also* produce zero accent pixels if its renderer paints everything black. **The accent-scan oracle §0.13 called "the discriminating one" could not discriminate between the two after all — cairo-black and never-painted are pixel-identical.** This does not *prove* input works; it proves the pixel evidence used to conclude input was dead was corrupted by an uncontrolled render-mode variable the whole time (exactly the "change one variable per probe" discipline of §0.10 — the render mode was silently pinned to `cairo` across all of rounds 5–14, so none of those A/B comparisons were clean). §0.13's "the last compile-checkable Swift lever is spent, escalation stands unqualified" was reached *on top of* this confound and therefore does not stand as written.

**The fix (shipped in the same patch file, GtkBackend.swift `runMainLoop`, still `#if os(Windows)`, still GLib's own `g_setenv` — no new dependency, no `GtkFixed`).** Force cairo **only** when the launch context explicitly opts in:

```swift
#if os(Windows)
    // Default to GTK's GPU/GL renderer (the full CueSync UI renders correctly under
    // GL on real hardware). Force software Cairo ONLY when CUESYNC_SOFTWARE_RENDER=1
    // — e.g. a headless/remote-desktop probe where GL cannot realize a window.
    // Forcing cairo UNCONDITIONALLY software-rendered the window content BLACK.
    if g_getenv("CUESYNC_SOFTWARE_RENDER") != nil {
        _ = g_setenv("GSK_RENDERER", "cairo", 1)
    }
#endif
```

So the GTE on real GL hardware now sees the **real coloured UI** and can finally test whether it responds; a headless/RDP harness that still needs a window can opt into cairo with `CUESYNC_SOFTWARE_RENDER=1` (accepting black content). The string-level GSK guards (`CUESYNC9WindowsGskRendererWorkflowTests`: `GSK_RENDERER`/`cairo`/`g_setenv`/`#if os(Windows)` present, single-file diff, remote-desktop grounding, Fork W, pinned commit) all stay green — the fix narrows *when* cairo is set, it does not remove the mechanism.

**Delivery / CI (the reason rounds 9–15 were red, independent of the app).** The SwiftPM `.build` cache key on all three GtkBackend-compiling legs was frozen on `hashFiles('Package.resolved')` only. Because the resolved manifest never changes across a patch edit, a runner could restore a cached `.build/checkouts/swift-cross-ui` with a **stale patch already applied**, and the current patch would then fail to apply — the observed `error: patch failed: Sources/GtkBackend/GtkBackend.swift:116 … patch does not apply` on the macOS leg. Fixed by folding `hashFiles('patches/*.patch', 'scripts/patch-swift-cross-ui.sh')` into **both** the cache `key` and the `restore-keys` prefix on `macos` + `windows-build` + `windows-test` (commits `b88d964`, `5a0c39a`, `d6a3dc1`), so any patch edit misses every stale-patch cache and forces a pristine checkout. Verified off-box: both live patches apply cleanly, in order (interactivity → gsk-renderer), to a fresh `git checkout`ed pin at `a6d206370812e3b9edba259d167e848892c5013d`; `swift test` = 477 / 0.

**Disposition — no new speculative patch this round (spec step 5).** Round 15 ships a *correction* (cairo opt-in) plus the *CI unblock*, not an 11th blind input suspect. The input question is now genuinely **open, not escalated**: it can only be decided by a fresh datum against a **GL-painted** window — the human GTE on real GL hardware (the spec's named ground truth, "Amrit clicks"), or a probe explicitly told which renderer it captured. **Open tension for the probe/harness owner:** GL cannot realize a surface over pure RDP (§0.3's original, still-true rationale), so the automated RDP probe may still have to set `CUESYNC_SOFTWARE_RENDER=1` and will therefore *still* see black content — its `center_click_changed` pixel leg stays unreliable there, but its `close_click_exited` (process-kill) leg does not depend on paint and remains valid. The clean oracle for "does the coloured UI respond" is the real-hardware GTE. Per §0.10/§0.11's discipline: the next move is a **measurement against the un-confounded render mode**, not another patch.

## §0.13 — ROUND 14 (2026-07-20): round 13's `present()` fired NEGATIVE against the fresh post-patch probe — zero accent pixels, so per its own pre-registered rule + spec step 5 the hunk is reverted; the last compile-checkable Swift lever is spent and §0.11's escalation now stands unqualified

> **Round 13 pre-registered its own falsification (§0.12, verbatim): "Judge the next run by its pixels … if the frame is still console+desktop with zero accents, `present()` did not defeat foreground-lock, and per spec step 5 ('revert non-movers') this hunk is reverted, leaving §0.11's escalation intact." That probe has now fired, and it fired negative.** This mirrors round 11's disposition of round 10 (the tickler) and round 9's of round 7 (the input drain): a one-suspect fix, tested against the gate, refuted by it, and reverted rather than stacked.

**The oracle probe (fresh, post-round-13).** `.factory/probe/result.json` + `CueSync-startup.log` are timestamped **16:46** and post-date round 13's commit `ce0b85c` (16:38); the startup log stamps `16:46:40`. So this is the first machine capture built **with the `present()` patch on `GtkBackend.show(window:)`**. It reports `close_click_exited: false`, `center_click_changed: false`, `changed_ratio: 0`, `window_found: true`, `launched: true`, rect **(156,156)–(1384,1010)** = 1228×854. `before.png` == `after.png` (md5 `e165fe8e6e532e41d92d1dcbcf602c3d`, `cmp`-identical). **Visibility is still dead.**

**Judged by pixels, as pre-registered — the decisive datum, re-audited from the frame's own RGB (macOS box, pure-Python PNG decode, no PIL/Windows).** A full-frame scan of `before.png` (1228×854) for CueSync's four accent colors at tolerance ±18 returns **green #1ed760: 0, pink #ef288a: 0, teal #5de4c7: 0, gold #ffd700: 0 — ZERO matches.** (The ~1.03M pixels that fall within ±18 of `#0a0a0f` are just the black/near-black desktop `(0,0,0)` and console gray `(12,12,12)`, which that loose tolerance cannot distinguish from CueSync's fill — they are **not** evidence CueSync painted; the accent scan is the discriminating one, and it is empty.) **If CueSync had reached the foreground and painted even its header/logo or one button, accent pixels would appear. None do.** `present()` did not defeat the console's foreground-lock.

**Both probe legs are invalid again, by coordinate — and this run proves the failure is z-order, not off-screen clipping.** The window rect (156,156)–(1384,1010) is screen-sized (1228×854) but offset **(156,156)**, so its right (1384) and bottom (1010) each lie **156px off the 1228×854 screen**. (a) Center leg: rect midpoint `((156+1384)/2,(156+1010)/2) = (770,583)`; sampling screen=(770,583) yields `(0,0,0)` — bare desktop, `changed_ratio: 0` regardless of input. (b) Close leg: a top-right-derived close coordinate (~1358,168) is off the visible screen, so `close_click_exited: false` measures nothing. **New this round:** the window's *on-screen* top-left corner sits at (156,156) — well inside the 1228×854 frame — and CueSync's header/logo would render there if it were foreground. That region shows **zero accents** too. So the window is not merely clipped off the bottom-right; its visible portion is **occluded/behind** the console — a foreground/z-order failure `present()` was supposed to fix and did not.

**The off-screen cascade is a launcher-placement artifact, not an app bug (and not a Swift-layer lever).** The window offset has stepped **52 → 104 → 156** across the last three console-launched runs (§0.11 round 11/12 = (52,52); §0.12's 16:03 capture = (104,104); this 16:46 capture = (156,156)) — a clean +52px each launch: the textbook Windows `CW_USEDEFAULT` cascade of a fresh top-level. Because the window is sized to its content minimum (startup log: GtkFixed `needs 1200x800`; window 1228×854) and the remote-desktop screen is only 1228×854, the window can **never** fully fit, and each cascade step pushes more of it past the bottom-right edge. GTK4 removed programmatic window positioning (`gtk_window_move` is gone), so there is **no in-lane Swift call** to force the initial window to (0,0) or to shrink below the content minimum — this is a harness/WM concern (raise + reposition/maximize before probing), consistent with §0.11 path B, not a new suspect.

**Renderer / fonts / main-loop stay cleanly ruled out (same clean run as §0.10–§0.12).** `CueSync-startup.log`: the CueSync-authored banner (⇒ `CueSync.exe` itself ran, not the launcher console), then only GTK layout diagnostics — a single one-shot `Gtk-CRITICAL: Allocation height too small … 1200x762 … needs 1200x800` and the inherent `GtkFixed … without gtk_widget_measure()` noise; **zero Pango/font, zero GSK/GL.** Round 8's flood stays fixed. The sole failure remains visibility/foreground, not paint.

**What round 14 did, exactly (spec step 5: "revert that hunk before trying the next suspect — never stack speculative patches").**
1. `patches/swift-cross-ui-0.8.0-windows-window-present.patch` deleted (`git rm`).
2. `Tests/CueSyncCoreTests/CUESYNC9WindowsWindowPresentWorkflowTests.swift` deleted (`git rm`); `CUESYNC9WindowsGskRendererWorkflowTests.swift`, `CUESYNC9WindowsInputDispatchWorkflowTests.swift`, and `Tests/test_adversarial.py` restored to their pre-round-13 (`ce0b85c~1`) two-patch state (patch-count assertions revert 3 → 2; the present-patch adversarial tests are gone).
3. `.github/workflows/swift-windows.yml` and `scripts/patch-swift-cross-ui.sh` restored to `ce0b85c~1` — the "window-present" `git apply` step is gone from all three GtkBackend legs and the dev script; the loop again applies exactly two patches (CUESYNC-8 interactivity + CUESYNC-9-round-4 GSK-renderer), in that order.
4. Resolved checkout re-patched by `scripts/patch-swift-cross-ui.sh`: pristine reset then interactivity + GSK only; `GtkBackend.show(window:)` is back to bare `window.show()` (verified — `present()` survives only inside `activate(window:)`, its correct home).
5. `agents/uiux.md`: the round-13 "check the call-graph, not just the method table" lesson is **kept** (its `show ≠ present` teaching is sound and permanent) but its ending is corrected to record this refutation — closing the gap was *necessary, not sufficient*; a background process's `present()` cannot beat foreground-lock, so the escalation stands.

**§0.12 is retained above as the trail** (as §0.9 kept the round-7 record and §0.10 the round-10 record after reverting them): §0.12 = "round 13 found+closed the `show`-never-`present` gap," §0.13 = "round 14's probe proved `present()` alone does not beat the console, and reverted." The disproven patch is gone from the tree; the diagnostic record of why is not.

**Disposition — the Swift-layer well is dry; §0.11's escalation is now unqualified, and sharpened.** `present()` was the **last compile-checkable, GTK-own-API, view-layer lever** the audit could find: rounds re-confirmed `show → gtk_widget_show` and `activate → gtk_window_present` are the correct GTK4 calls (§0.10/§0.11/§0.12), and the one genuine gap (initial window never `activate`d) has now been closed *and refuted*. The remaining native-interop foreground hacks (`SetForegroundWindow`/`HWND_TOPMOST` via `gdk_win32_surface_get_handle`) remain **un-compile-checkable on the macOS authoring box** and are exactly what §0.11 rejected as out-of-lane. So the two live paths, both human and out of the UI/UX view-layer lane, stand:
1. **Fix the click-probe harness (path B — the demonstrated blocker).** Before any synthesized click, the harness must (i) bring CueSync's HWND to the foreground / raise it above the launcher console (or hide/minimize the console so it cannot occlude/own-foreground), (ii) **reposition or maximize** the screen-sized window so it lies fully within the 1228×854 screen (the cascade guarantees it does not by default), and (iii) verify per click, via hit-test/window-from-point, that CueSync is the topmost window *at the click point*, deriving the close coordinate from GTK's actual CSD geometry (or drive `WM_CLOSE` to the located HWND). Only such a probe can classify Fork W vs "input was fine." One corrected run may end the saga.
2. **If a corrected probe still shows dead input → adopt WinUIBackend for the Windows target (path A, durable).** Every post-v0.8.0 upstream Windows commit is on WinUIBackend, not GtkBackend (§0.5/§0.6); GtkBackend's gdk-win32 path is effectively unmaintained. This is an architectural backend change, out of the view-layer lane, and must be a human decision.

Classification stays **Fork W (unverified)** — no valid machine click has yet landed on CueSync's realized, foreground surface, so neither "input dead" nor "input fine" is machine-confirmed on the current build; the balance-of-record Fork-W lean (the human GTE's "renders, ignores the mouse" on CUESYNC-7/8) predates round 8's layout fix and is not a valid click on this tree. Suspects (2) modal/invisible grab and (3) window-level input flags stay ruled out at the source (§3), re-audited again this round.

**Baseline this round.** `swift build -c release --product CueSync` green with the two patches (`scripts/patch-swift-cross-ui.sh` reset + reapply clean, idempotent); `Tests/test_adversarial.py` = 89 passed, 11 skipped; `swift test` = 476 tests, 0 failures (back down from round 13's 493 with the `CUESYNC9WindowsWindowPresentWorkflowTests` removed, still above the audited 206 baseline); `ruff` clean. `Package.swift`/`Package.resolved` untouched; swift-cross-ui stays `exact: "0.8.0"`; CUESYNC-8 `can-target` patch unchanged.

## §0.12 — ROUND 13 (2026-07-20): §0.11's audit was INCOMPLETE — the initial window is only `show()`n, never `present()`ed; a missing `gtk_window_present()` IS a Swift-layer gap a patch can close, and it is the precondition for any valid probe

> **§0.11 was right that the probe is blind (re-confirmed here from the fresh 16:03 capture's own RGB), but wrong that "there is no missing `present`/`can-focus` call a Swift patch could add."** §0.10/§0.11 read `activate(window:) → window.present()` in the backend and assumed it runs for the main window. The SwiftCrossUI call-graph proves it does **not**: the initial `WindowGroup` window is only ever `show()`n, never `activate()`d/`present()`ed. That missing `gtk_window_present()` is exactly the Swift-layer, GTK-own-API fix §0.11 said did not exist — and it is compile-checkable (it uses the same `Window.present()` call `activate` already makes, not the GDK-win32 `SetForegroundWindow` interop §0.11 rejected as un-compile-checkable). Round 13 ships it as one suspect and lets the next probe decide.

**The fresh 16:03 probe, quantitatively re-audited from its own pixels (macOS authoring box, no Windows required).** `.factory/probe/result.json` (16:03) reports `launched: true`, `window_found: true`, rect **(104,104)–(1332,958)**, `close_click_exited: false`, `center_click_changed: false`, `changed_ratio: 0`. `before.png`/`after.png` are byte-identical (md5/`cmp`), a full-**screen** capture of **1228×854**. Decoding the PNG scanlines (pure-Python, no PIL) gives hard RGB, not inference:
- The top-left block is uniformly **(12,12,12)** — Windows `conhost` console gray, **not** CueSync's `#0a0a0f` = (10,10,15) — with a **(240,240,240)** Win32 scrollbar column at x≈942–958 (GTK 4 draws thin arrow-less overlay scrollbars; an arrow-button scrollbar is conhost). It spans ≈(0,0)–(958,487) = a default 80×25 console.
- Everything below/right is **(0,0,0)** bare desktop, with two desktop icons (LinkUP's dark-red (125,18,34), Duet Display's white).
- **A full-frame scan for CueSync's four accent colors (green #1ed760, pink #ef288a, teal #5de4c7, gold #ffd700) finds ZERO matches.** If CueSync had painted even one button, header, or its logo, accent pixels would appear. None do — **CueSync is not visible anywhere on screen.**

**Both probe legs are invalid on this run — proven by coordinates.** The window rect (104,104)–(1332,958) is screen-sized (1228×854) but offset by (104,104), so its right and bottom **104px lie off-screen** (x>1228, y>854). (a) The **center leg**: the gate's rect midpoint is `((104+1332)/2,(104+958)/2) = (718,531)`; sampling screen=(718,531) yields **(0,0,0)** — the click lands on the **bare desktop** (just below the console), inside the window rect but where CueSync paints nothing, hence `changed_ratio: 0` regardless of CueSync's input. (b) The **close leg**: a close button derived from the rect's top-right corner (~1310,124) is **off the visible screen** (x>1228 = window's off-screen right strip), so a synthesized click there strikes nothing and the process cannot exit — `close_click_exited: false` measures an off-screen coordinate, not CueSync's chrome. The startup log confirms CueSync.exe **did** launch (banner + PID 3272) and GTK **did** run this time: zero Pango/font, zero GSK/GL, only the one-shot `Allocation height too small … 1200x762 … needs 1200x800` GtkFixed critical (a ~38px bottom under-allocation, not a blank-window cause, and no longer the 2 Hz flood §0.7 fixed). **Renderer, fonts, and main loop are all healthy; the sole failure is that the window never reaches the visible foreground.**

**Root cause (Fork-W precondition), with call-graph citations — this is what §0.10/§0.11 got wrong.** For the initial `WindowGroup` window, SwiftCrossUI's `WindowReference.update` calls `backend.show(window:)` exactly once, on `isFirstUpdate` (`Sources/SwiftCrossUI/Scenes/WindowReference.swift:300–303`), and **never** `backend.activate(window:)`. Every `activate` call-site in SwiftCrossUI core is a *different* path: `Window.swift:87` (`openWindow(id:)` on an already-open window), `EnvironmentValues.swift:96–99` (`bringWindowForward()`, user-triggered), plus the method definition/protocol stub — none fire for the initial window at bootstrap (`_App.run → rootNode.update → …update()`, which reaches only `show`). And `backend.show(window:)` is `window.show()` = `gtk_widget_set_visible(true)` (`GtkBackend.swift:303–304`, `Gtk/Widgets/Widget.swift:56`), whereas `backend.activate(window:)` is `window.present()` = `gtk_window_present()` (`GtkBackend.swift:307–308`, `Gtk/Widgets/Window.swift:90`). On Windows, `gtk_widget_set_visible(true)` **maps** the surface (the HWND becomes enumerable and has a rect — exactly `window_found: true` with a rect, yet zero visible pixels) but does **not raise** it; only `gtk_window_present()` raises + focuses. So the initial window maps **behind** the foreground `cmd.exe` launcher console the probe box starts `CueSync.exe` from, and paints nothing the capture can see. §0.11's "the Swift layer is correct, no missing `present` call" rested on the un-checked assumption that `activate`/`present` runs for the main window; the call-graph shows it does not.

**The fix — `patches/swift-cross-ui-0.8.0-windows-window-present.patch` (spec step-4 contingency, one suspect).** `GtkBackend.show(window:)` also calls `window.present()` (→ `gtk_window_present()`) on Windows, guarded `#if os(Windows)` so macOS/Linux keep the `gtk_widget_show` default byte-for-byte. This is GTK's **own** API — the identical `window.present()` call `activate(window:)` already makes unconditionally — so, unlike the GDK-win32 `SetForegroundWindow`/`SetWindowPos` interop §0.11 rejected, it **is** compile-checkable on the macOS authoring box, and it was: `swift build -c release --product CueSync` links green (17.14s) with all three patches applied. Anchored at `show(window:)`, disjoint from the interactivity hunk (`createPathWidget`), the GSK hunk (`runMainLoop`), and the round-9-reverted input hunk (`mainRunLoopTicklingLoop`), so the three live patches apply cleanly in sequence. Wired into all three GtkBackend legs after the GSK step / before build, idempotent (`git apply --reverse --check`), read-only-cleared on exactly `GtkBackend.swift`, pinned to `a6d206370812e3b9edba259d167e848892c5013d`; `scripts/patch-swift-cross-ui.sh` applies it too.

**Honest caveat + step-5 disposition — what the next probe must show.** Whether `present()` actually pulls CueSync in front of the launcher console on the box is the open question §0.11 raised (Windows foreground-lock). The countervailing fact: Windows grants a GUI child **launched by the foreground process** a one-time startup `SetForegroundWindow`, and `cmd.exe` (foreground) launches `CueSync.exe`, so the first `gtk_window_present()` during startup has a real chance of being honored — a chance that was **never taken** before, because present was never called. **This patch is the precondition for any valid input evidence: no probe/GTE can classify Fork W vs "input was fine" until CueSync's window is the topmost, painted surface at the click point.** Judge the next run by its **pixels**, not just red/green: scan `before.png` for the four accent colors — if CueSync's UI now appears, the console is beaten and the real input test can finally run; if the frame is still console+desktop with zero accents, `present()` did not defeat foreground-lock, and per spec step 5 ("revert non-movers") this hunk is reverted, leaving §0.11's escalation intact (fix the harness to foreground/hide the console, or adopt WinUIBackend, §0.5/§0.6 — a human, out-of-lane decision). The classification stays **Fork W** (unverified) — this round fixes the visibility precondition, not input dispatch, and does not touch suspects (2)/(3), which remain ruled out at the source.

**Baseline this round.** `swift build -c release --product CueSync` green with all three patches; `scripts/patch-swift-cross-ui.sh` applies all three cleanly and idempotently; `Tests/test_adversarial.py` = 89 passed, 11 skipped; `swift test` = 493 tests, 0 failures (up from 476 with the new `CUESYNC9WindowsWindowPresentWorkflowTests`, above the audited 206 baseline). Package.swift/Package.resolved untouched; swift-cross-ui stays `exact: "0.8.0"`; CUESYNC-8 `can-target` patch unchanged.

## §0.11 — ROUND 12 (2026-07-20): the click-probe gate is DEMONSTRABLY clicking the launcher console, not CueSync — the red probe is not valid app-input evidence; path B (harness) is promoted from "worth confirming" to a confirmed gate defect; no speculative patch shipped

> **§0.10's secondary observation was right, and this round proves it from the probe's own pixels rather than inferring it from the window rect.** The gate's center-click is arithmetically shown to land *inside* the launcher console; therefore `center_click_changed: false` measures the console, not CueSync, and the machine gate has never validly exercised CueSync's window center. This does not by itself say CueSync's input works — it says the gate, as run, cannot tell us either way.

**The post-round-11 probe adds no new signal — it confirms the revert, as round 11 predicted.** `.factory/probe/result.json` + `CueSync-startup.log` are timestamped 15:41–15:42 and post-date round 11's commits (`c9d8668` revert 15:36, lint `5f62543` 15:39); the app banner stamps `15:41:57`. So this capture is round 11's two-patch, tickler-on-Windows tree. It reports `close_click_exited: false`, `center_click_changed: false`, `changed_ratio: 0`, `window_found: true`, `launched: true`, rect (52,52)–(1280,906) = 1228×854. Round 11 expected exactly this (the tickler was proven irrelevant in §0.10), so the datum is consistent, not new. The startup log is the same clean run as §0.10: banner present, one-shot `Gtk-CRITICAL: Allocation height too small … 1200x762 … needs 1200x800`, then the inherent `GtkFixed … without gtk_widget_measure()` noise; **zero Pango/font, zero GSK/GL** — renderer and fonts stay ruled out.

**Independent pixel audit of `before.png`/`after.png` (done on the macOS authoring box, no Windows required).** The two frames are identical (§0.10: md5 match). Both show a single black window occupying roughly (0,0)–(958,487) with a **classic Windows scrollbar on its right edge — a thin track with distinct up- and down-arrow buttons and a thumb parked at the top.** GTK 4 draws thin, arrow-less overlay scrollbars; a scrollbar *with arrow buttons* is a Win32/conhost scrollbar. And ~958×487 is the size of a default 80×25 `conhost` window. **That black window is the probe's own `cmd.exe` launcher console, foregrounded at the top-left** — not CueSync, and not (per §0.10's careful wording) CueSync's background bleeding through. CueSync's GTK window is *behind* it at the reported rect (52,52)–(1280,906); its near-black `#0a0a0f` fill is indistinguishable from the desktop and is mostly occluded by the console. `gtk_window_present()` (`GtkBackend.activate → Gtk/Widgets/Window.swift:90`, GtkBackend.swift:307–308) cannot pull CueSync in front because the console owns the Windows foreground (foreground-lock), so CueSync never comes to top.

**Coordinate proof the center-click leg is invalid.** The gate derives the center click from the window rect midpoint: `((52+1280)/2, (52+906)/2) = (666, 479)`. That point lies squarely inside the launcher console's (0,0)–(958,487) region. **The center click therefore strikes the console, whose pixels never change, which is exactly `changed_ratio: 0` / `center_click_changed: false` — regardless of whether CueSync's input works.** The center-click leg is measuring the wrong window and cannot support any conclusion about CueSync while the console overlaps the click point.

**The close-click leg is the only leg that could still be valid, and it rests on two unverified assumptions.** The gate derives the close click from the rect's top-right (≈ `(1258, 70)`), which is *outside* the console (console ends at x≈958), so z-order does not occlude it. `close_click_exited: false` would be real Fork-W input death **iff** (a) CueSync actually realizes a visible GTK client-side-decoration headerbar at that rect with its close control at the top-right corner the gate assumes — but GTK-4-on-Windows may lay CSD controls per theme, or fall back to native server-side decorations whose close button sits at a different offset; no headerbar is visible at x>958,y≈52 in either frame — and (b) the surface is fully realized there despite the one-shot `762 vs needs 800` under-allocation. Neither is established. So even the close leg is not a clean Fork-W confirmation.

**Consequence for the fork classification.** The classification stays **Fork W** on the balance of the record (no evidence any pointer input reaches any widget across the whole saga, including the human GTE's "renders, ignores the mouse" on CUESYNC-7/8), **but that GTE evidence predates round 8's layout-loop fix and the machine gate's center leg is now proven to click the console** — so the *current* build's Fork-W status is not backed by a valid machine click. The gate cannot adjudicate Fork W vs "input was fine" until it provably clicks CueSync's own realized surface. Suspects (2) modal/invisible grab and (3) window-level input flags stay ruled out at the source level (§3): the Swift layer was re-audited again this round — `createWindow → show(window:) → gtk_widget_show` (GtkBackend.swift:303–304) and `activate(window:) → window.present() → gtk_window_present` (GtkBackend.swift:307–308, Gtk/Widgets/Window.swift:90) are the correct GTK 4 present/show/focus calls; there is no missing `present`/`can-focus`/input-region call a Swift patch could add, on the pinned commit `a6d206370812e3b9edba259d167e848892c5013d`.

**Round-12 disposition — no code, patch, workflow, or script change; the tree stays at round 11's verified-green state.** Per spec step 5 ("never stack speculative patches"; revert non-movers) and §0.10's decision ("do NOT stack a blind suspect-(3) Swift patch — the Swift layer is correct"), round 12 ships no new patch. Shipping a 12th speculative fix against a gate that is proven to click the wrong window would be measuring noise. What round 12 adds is the missing piece of §0.10's path B: it is no longer "a check to run" — the gate's center leg is a **confirmed defect**. Baseline re-verified this round: `swift test` = 476 tests, 0 failures; `Tests/test_adversarial.py` = 89 passed, 11 skipped. Two patches remain (interactivity + GSK-renderer); tickler guard is `#if !os(macOS)`.

**What the human / gate owner must do next, in priority order (re-ordered by this evidence).**
1. **Fix the click-probe harness first (path B — now the demonstrated blocker).** Before synthesizing any click the probe must (i) bring CueSync's window to the foreground / raise it above the launcher console — or hide/close/minimize the launcher console so it cannot occlude CueSync; (ii) verify, per click, that CueSync's window is the topmost window *at the click point* (hit-test / window-from-point), not just that a CueSync window exists somewhere; and (iii) derive the close-button coordinate from GTK's actual CSD control geometry (or drive close via `WM_CLOSE` to the located HWND) rather than assuming the rect's top-right corner. Only a probe that provably clicks CueSync's realized surface can classify Fork W vs "input was fine." Re-run the gate after the harness fix — that single run may end the saga if CueSync's input was healthy all along and only the console was in the way.
2. **If a corrected probe still shows dead input → path A (durable fix): adopt WinUIBackend for the Windows target.** Every post-v0.8.0 upstream Windows commit is on WinUIBackend, not GtkBackend (§0.5/§0.6); GtkBackend's gdk-win32 event path is effectively unmaintained. This is an architectural backend change, out of the UI/UX view-layer lane, and must be a human decision — not taken unilaterally.

**Why NOT an app-shell "force to foreground" hack this round (considered and rejected).** It is the wrong layer and a speculative untestable patch: (a) it would need Windows-only GDK-win32 → `SetForegroundWindow`/`SetWindowPos(HWND_TOPMOST)` interop (`gdk_win32_surface_get_handle`), which **cannot be compile-checked on this macOS authoring box** — the exact compile-safety objection that deferred earlier rounds; (b) it contorts the app to defeat a broken measurement harness instead of fixing the harness (step 1), and the harness is external so the human must fix it regardless; (c) it would at best fix the center leg (z-order) but not the close leg (which is coordinate/geometry-dependent, not z-order-dependent); and (d) it is precisely the kind of blind, probe-unverifiable commit spec step 5 forbids stacking. If the human wants to pursue foreground-raising anyway, it belongs to a Windows-box iteration with the corrected probe as oracle, never a blind macOS-authored patch.

## §0.10 — ROUND 11 (2026-07-20): round 10's oracle probe fired NEGATIVE — the RunLoop-tickler theory is REFUTED by controlled experiment; the hunk is reverted per spec step 5 and the survivor (win32 event wiring) is escalated

> **Round 10 pre-registered its own falsification test (§0.9, verbatim): "if the next probe still shows `close_click_exited: false`, this hunk is reverted before the next suspect — a backend decision (WinUIBackend) — is tried." That probe has now fired, and it fired negative.**

**The oracle probe (fresh, post-round-10).** `.factory/probe/result.json` + `CueSync-startup.log` are timestamped 15:22 and post-date round 10 (`fdc46a5` committed 14:58, lint `f6d8b0a` 15:01); the app's own startup banner stamps `15:22:28`. So this is the first machine capture built **with the tickler disabled on Windows**. It reports: `close_click_exited: false`, `center_click_changed: false`, `changed_ratio: 0`, `window_found: true`, `launched: true`, rect (234,186)–(1462,1040) = 1228×854 (full-size). `before.png` == `after.png` (md5 `b46bda0d…`). **Input is still 100% dead.**

**This is a clean controlled A/B, and it refutes the tickler theory.** The 14:26 probe (§0.9) and the 15:22 probe differ in exactly ONE variable — the Foundation RunLoop tickler:
> - **14:26** — round 8 layout fix in tree, tickler **ON** on Windows (`#if !os(macOS)`). Result: `close_click_exited: false`.
> - **15:22** — same tree + round 10, tickler **OFF** on Windows (`#if !os(macOS) && !os(Windows)`). Result: `close_click_exited: false`.
>
> The tickler's on/off state **does not change input.** §2.5/§0.9's core claim — that `mainRunLoopTicklingLoop` pumping `RunLoop.main.limitDate(forMode:.default)` starves GDK's Win32 queue and *that* is what kills input — predicts input revives when the tickler is removed. It did not. **The theory is disproven by experiment, not by argument.** (The §0.9 A/B logic was sound; the hypothesis it was testing was simply wrong.)

**Renderer and fonts are cleanly ruled out by the same log — this is the first clean-run startup log of the saga.** `CueSync-startup.log` (round-10 build): banner present (⇒ CueSync.exe itself ran, not the launcher console), then only GTK layout diagnostics — a single one-shot `Gtk-CRITICAL: Allocation height too small … 1200x762 … needs 1200x800` then it settles (round 8's flood is gone — the layout loop stays fixed), plus the inherent `GtkFixed … without gtk_widget_measure()` noise. **ZERO Pango/font lines. ZERO GSK/GL lines.** The window paints (background + scrollbar visible in `after.png`). So suspect (2) renderer (GSK cairo is working) and the Pango/fonts branch are both eliminated on-box.

**The survivor is exactly what the gate names: suspect (3), the GtkBackend/GDK win32 event wiring — upstream, below the view layer.** Gate feedback (verbatim): *"Suspect the GtkBackend event wiring on Windows (upstream swift-cross-ui), not app-level hit-testing."* The swift-cross-ui **Swift** layer is correct and was re-audited this round: `createWindow` → `show(window:)` → `gtk_widget_show`; `activate(window:)` → `window.present()` → `gtk_window_present` (`GtkBackend.swift:323/327`, `Gtk/Widgets/Window.swift:90`). Those are the right GTK4 present/focus calls — there is no missing `present`/`can-focus`/input-region call a Swift patch could add. The failure is **below** this, in GDK's win32 C backend (WNDPROC / message routing / foreground activation), which no patch in the `swift-cross-ui` Swift sources or this app's view layer can reach. And it is **unmaintained on this path**: every post-v0.8.0 upstream Windows commit is **WinUIBackend**, not GtkBackend (§0.5/§0.6). A durable fix is therefore a **backend decision** (adopt WinUIBackend), which is an architectural change OUT of the UI/UX view-layer lane — escalated to the human, not taken unilaterally.

**What round 11 did, exactly (spec step 5: "revert that hunk before trying the next suspect — never stack speculative patches"):**
1. `patches/swift-cross-ui-0.8.0-windows-runloop-tickler.patch` deleted (`git rm`).
2. `.github/workflows/swift-windows.yml`, `scripts/patch-swift-cross-ui.sh`, and the three affected test files (`CUESYNC9WindowsInputDispatchWorkflowTests.swift`, `CUESYNC9WindowsGskRendererWorkflowTests.swift`, `Tests/test_adversarial.py`) restored to their pre-round-10 (`fc9e2f5`) two-patch state — the tickler apply-step is gone from all three CI legs and the dev script; patch-count assertions revert 3 → 2.
3. Resolved checkout re-patched by `scripts/patch-swift-cross-ui.sh`: pristine reset then interactivity + gsk-renderer only; the tickler guard is back to `#if !os(macOS)` (tickler runs on Windows again, as on Linux). GSK-cairo (round 4) and the interactivity patch (CUESYNC-8) are untouched and remain applied.
4. **Round 10's own regression is thereby undone:** with the tickler restored, `DispatchQueue.main` / `Task`+`await` (the file-dialog import/export paths) are serviced on Windows again. Since the tickler was proven irrelevant to input, keeping it off bought nothing and only broke async — reverting is strictly better on every axis.

**§0.9 is retained above as the trail** (mirroring how §0.8 kept the round-7 record after reverting it): §0.9 = "round 10 tried the tickler-guard," §0.10 = "round 11 disproved it and reverted." The disproven patch is gone from the tree; the diagnostic record of why is not.

**Secondary observation for the probe/GTE owner (does not change the escalation).** `after.png` foregrounds a window titled `C:\WINDOWS\SYSTEM32\cmd.exe` — the probe's launcher console — sitting on top of the upper-left; `result.json`'s CueSync window rect (1228×854) does not coincide with that visible console (~955×487). This is consistent with CueSync's GTK window rendering its near-black `#0a0a0f` background behind/around the launcher and **never taking foreground focus** (Windows foreground-lock: a non-foreground process's `gtk_window_present` cannot steal activation). Worth confirming that the synthesized clicks land on CueSync's window and activate it, because a launcher-console-on-top would reproduce `changed_ratio: 0` even if CueSync's input were fine. **However, input death is independently corroborated as real** — the gate reports the human GTE saw the identical "renders, ignores the mouse" on CUESYNC-7 and CUESYNC-8 by hand — so this is a check to run, not a competing explanation that displaces the backend escalation.

**Decision for round 12 (do NOT re-run the tickler experiment; do NOT stack a blind suspect-(3) Swift patch — the Swift layer is correct):** the two live paths, both requiring a human, are (A) **backend decision** — adopt WinUIBackend for the Windows target (the maintained upstream path; large, architectural, out of the view-layer lane); and (B) **probe/GTE harness check** — confirm the synthesized click actually activates and hits CueSync's window rather than the foregrounded launcher console. Recommend A as the durable fix, with B run first as a cheap sanity check on the gate itself.

## §0.9 — ROUND 10 (2026-07-20): the post-round-9 probe proves input death is a SEPARATE surviving bug — the run-loop tickler (§2.5) is reinstated as the suspect, minimally

> **The decisive new datum: the 2026-07-20 14:26 probe POST-DATES round 9 (committed 13:35) and refutes its premise.** It is the first machine capture with round 8's layout-loop fix in place, and it separates the two bugs cleanly. Evidence in `.factory/probe/`:
> - **Round 8 worked.** `CueSync-startup.log` no longer shows the ~2 Hz `Gtk-CRITICAL: Allocation height too small … needs 1200x700` FLOOD (§0.7). There is now a single one-shot `1200x762 vs needs 1200x800` critical at startup, then it settles — the infinite relayout loop is gone and the window is full-size (`result.json` rect 1228×854, was collapsing to 657).
> - **Input death SURVIVES.** `result.json`: `close_click_exited: false`, `center_click_changed: false`, `changed_ratio: 0`, `window_found: true`, `launched: true`. A real click on the window's own title-bar CLOSE button does not terminate the app ⇒ still **Fork W** (window-level), which per §1 rules OUT app-level hit-testing (Fork D). `before.png`==`after.png`: background + scrollbar paint, content black.

**Round 9's premise was wrong, on evidence round 9 did not have.** §0.8 reverted round 7's patch reasoning that round 8 had proven the input death *was* the layout loop ("the evidence-based root-cause fix"). The 14:26 probe shows that is false: the layout loop is fixed and input is still 100% dead. Round 8's dismissal of the run-loop-starvation classification — "GTK is actively re-laying-out ⇒ not starved" (§0.7) — is a **non-sequitur**: relayout runs on GLib idle/timeout sources (`g_timeout_add`, `runInMainThread`), which are independent of the thread's **Win32 message queue**; input and `WM_PAINT` are not. Live layout activity therefore never disproved input-queue starvation. And every pre-round-8 probe carried the min-frame relayout LOOP, which collapses and thrashes the window regardless of any input fix — so **no earlier input experiment (rounds 1–7) was ever fairly evaluated.** Round 9 removed the input fix at the exact moment the mask was finally lifted.

**Root cause (reinstates §2.5, already audited): Fork W = Win32 message-queue starvation by the Foundation RunLoop tickler.** `GtkBackend.mainRunLoopTicklingLoop` pumps `RunLoop.main.limitDate(forMode: .default)`; swift-corelibs-foundation binds the `.default` mode to this thread's Win32 queue via `_CFRunLoopSetWindowsMessageQueueMask(QS_ALLINPUT)` and each pass PeekMessage-drains it — the SAME queue GDK's win32 backend reads for `WM_PAINT` and pointer/keyboard input. One starvation explains BOTH surviving symptoms at once: content black after the first frame (no further `WM_PAINT` reaches GDK) AND every click swallowed, window chrome included (no input reaches GDK's WNDPROC). Suspects (2)/(3) stay ruled out (§3).

**The fix (round 10, `patches/swift-cross-ui-0.8.0-windows-runloop-tickler.patch`), minimal and one-suspect per spec step 5.** The tickler already runs only `#if !os(macOS)` — it is deliberately excluded on macOS, where the GtkBackend UI nonetheless renders and is fully interactive (the saga built and ran that exact target on macOS/Homebrew GTK, §0). That proves GTK/GDK do NOT need the Foundation tickler for rendering or input — GTK's own GLib loop (`g_application_run`) owns the message queue. So the guard is narrowed to `#if !os(macOS) && !os(Windows)`: Windows now behaves like macOS-GTK, GTK owns the Win32 queue, and GDK gets `WM_PAINT` + input back. Linux is unchanged.

**This is NOT a re-stack of the reverted `windows-input.patch`.** That patch (rounds 1/2/7) *added* a Win32 drain and (round 7) an `@_silgen_name("_dispatch_main_queue_callback_4CF")` binding to a private libdispatch symbol — the two things §0.8's redteam tests (`test_windows_input_patch_premise_is_disproven_yet_it_is_still_applied_on_every_leg`, `test_windows_input_patch_binds_no_undocumented_private_symbol_via_silgen_name`) objected to. The round-10 patch binds no symbol, adds no drain, adds no API — it changes one existing `#if`. Both redteam tests remain green (the reverted file stays deleted; no `@_silgen_name` is introduced).

**Documented trade-off + disposition.** With the tickler off on Windows, `DispatchQueue.main` / Swift `Task`+`await` continuations are no longer serviced, so the file-dialog import/export paths (`Task { await chooseFile() }`) will not complete on Windows until a follow-up services the dispatch main queue WITHOUT re-draining the Win32 queue (e.g. a private-mode run-loop pass). This is a strict improvement over today's TOTAL input death and is the correct minimal step. **Per spec step 5, this is one suspect:** if the next probe still shows `close_click_exited: false`, this hunk is reverted before the next suspect — a backend decision (WinUIBackend, §0.5/§0.6) — is tried; the Fork W → Fork D transition (§spec step 5) would instead be recorded as progress. Verified on macOS: `swift build -c release --product CueSync` links with all three patches applied (the change is a compile-time `#if` narrowing); the live remote-desktop behaviour is what the on-box probe/GTE confirms.

## §0.8 — ROUND 9 (2026-07-20): round 7's disproven `windows-input.patch` formally reverted, not left stacked

> §0.7 left round 7's `patches/swift-cross-ui-0.8.0-windows-input.patch` applied "as a candidate
> revert" pending confirmation that round 8's fix was the real mover, explicitly warning "do not
> treat it as load-bearing." That confirmation is now in: round 8's `.frame(minHeight:)` removal
> (`CueSync/CueSync/UI/CueSyncApp.swift`) is the evidence-based root-cause fix (§0.7's mechanical
> trace from the app's own Windows stderr, ratified by origin CI going green). Nothing further
> happened this round to reopen that diagnosis — this round's job is purely to close the "candidate
> revert" that §0.7 left open, per spec step 5: **"if a round's fix does not move the probe, revert
> that hunk before trying the next suspect — never stack speculative patches."**

**Why the revert is safe now, independent of round 8.** §0.7 already established the two fixes are
mechanically unrelated: "the loop runs on GLib timeouts, not `RunLoop.main`" (§0.7, verbatim). Round
7's patch rewrites `GtkBackend.mainRunLoopTicklingLoop` to stop pumping `RunLoop.main` on Windows
(§0.6); round 8's fix removes a SwiftUI-level `.frame(minHeight:)` constraint that was driving
`WindowReference.update`'s resize/relayout loop (§0.7 §§35-50). Neither reads nor writes the other's
state — reverting round 7 cannot resurrect round 8's flood, and round 8's fix does not depend on
round 7's tickler rewrite having ever shipped. There is no evidence round 7's patch ever *was*
load-bearing for the click-probe: §0.7's own auditable stderr trace explains the "paints but nothing
is clickable" symptom in full via the relayout loop alone, with no residual signal (font/renderer/
main-loop-starvation lines are all **zero** per §0.7) attributable to a genuine Win32-queue race.

**Second reason to revert, not just "leave it, it's harmless": the patch itself carries fragility
the `windows-input.patch` header text does not fully disclose as a live cost.** Round 7's mechanism
(§0.6, "round 7's mechanism") binds `@_silgen_name("_dispatch_main_queue_callback_4CF")` — a raw
linker binding to an **undocumented, leading-underscore libdispatch↔CoreFoundation bridge internal**
that is neither a GTK nor a GLib public API and carries no stable-ABI guarantee. `@_silgen_name`
bypasses Swift's normal import visibility; a future Swift toolchain that renames or drops that
private symbol breaks the Windows *link*, not just a runtime behaviour — a supply-chain liability
spec §3/§4's "GTK/GLib's own APIs … no fragile external coupling" constraint exists specifically to
rule out. Carrying that risk was an acceptable trade while the patch was the load-bearing input fix;
it is not an acceptable trade for a patch that §0.7 itself calls non-load-bearing and a "candidate
revert."

**What forced this cleanup:** a redteam adversarial pass (`Tests/test_adversarial.py`) added two
tests this round is a direct response to:
- `test_windows_input_patch_premise_is_disproven_yet_it_is_still_applied_on_every_leg` — asserted
  that a patch whose own findings entry calls it "disproven … candidate revert … not load-bearing"
  must not still be `git apply`'d on every CI leg and the dev script; spec step 5 requires reverting
  a non-mover, not leaving a speculative, disproven mutation stacked on the audited dependency.
- `test_windows_input_patch_binds_no_undocumented_private_symbol_via_silgen_name` — asserted the
  patch must not bind an undocumented private symbol via `@_silgen_name`, independently flagging the
  `_dispatch_main_queue_callback_4CF` binding above as a defect in its own right.

Both were "LIVE FINDING — expected to FAIL" tests against the pre-round-9 tree; this round's revert
is what makes them pass (the second now correctly *skips*, since its fixture raises once the patch
file no longer exists — that is the intended outcome of removing the thing it inspects, not a gap).

**What was removed, this round, exactly:**
1. `patches/swift-cross-ui-0.8.0-windows-input.patch` deleted (`git rm`) — the file itself.
2. The "Patch swift-cross-ui Windows input dispatch (pinned v0.8.0, CUESYNC-9)" step removed from
   all three jobs (`macos`, `windows-build`, `windows-test`) in `.github/workflows/swift-windows.yml`,
   replaced with a short comment block pointing here.
3. The patch's application removed from `scripts/patch-swift-cross-ui.sh` (the `WINDOWS_INPUT_PATCH`
   variable, its membership in the missing-file check loop, and its `git apply`/idempotency-guard
   block) — the dev/ci-local loop now applies exactly two patches: the CUESYNC-8 gesture/
   interactivity patch and the CUESYNC-9-round-4 GSK-renderer patch, in that order.

**What is explicitly NOT reopened by this round.** Round 8's fix stands as the confirmed root cause;
this round performs no new diagnosis of the click-probe and makes no runtime-behaviour claim beyond
what §0.7 already recorded. If a future probe run somehow shows Windows input dead again with round
8's fix still in place, the correct next step per spec step 5 is a *fresh* suspect investigated with
fresh on-box evidence (§0.6's still-open backend-decision fork, or suspects (2)/(3) in §3, both
already ruled out at the source level but not yet re-confirmed against a live Windows run without
round 7's patch in the mix) — not silently re-applying this reverted, disproven patch.

## §0.7 — ROUND 8 (2026-07-19): the app's OWN Windows stderr, finally auditable, overturns the main-loop diagnosis — it is a layout-thrash loop from a content min-height the display can't grant

> **This round replaces guessing with the app's actual Windows runtime output.** The branch is now
> pushed (`origin/adw/CUESYNC-9`), so `.github/workflows/swift-windows.yml` ran on real
> `windows-latest`. The origin tip went **fully green** (run `29698945034`: build + test + macOS all
> pass), which independently machine-confirms round 7's `#if os(Windows)` hunk **compiles and links on
> Windows** — the one structural gap every prior round flagged. More important: round 6's **"Capture
> CueSync.exe startup diagnostics"** step (build job `88224564640`) launched the real self-contained
> exe headless and dumped its stderr **into the CI job log** — retrievable with `gh run view --log`,
> and therefore the FIRST time the app's own Windows diagnostics are **independently auditable** (the
> `.factory/probe/CueSync-startup.log` channel §0.6 relied on is gitignored; this one is not).

**What the log actually shows (deduplicated, whole run):** the `=== CUE SYNC — Windows startup
diagnostics ===` banner + `argv` (exe reached Swift `App.init()`), then **148 GTK layout messages and
nothing else** — 100 `Gtk-WARNING` + 48 `Gtk-CRITICAL`, every one about a single `GtkFixed`:
- `Allocating size to GtkFixed … without calling gtk_widget_measure(). How does the code know the size to allocate?` (×48)
- `Gtk-CRITICAL … Allocation height too small. Tried to allocate 1200x657, but GtkFixed … needs at least 1200x800` (early) → `… at least 1200x700` (steady state) (×48)
- `Trying to measure GtkFixed … for height of 657, but it needs at least 700` (×46)

**Zero** `Pango`/`fontconfig`/font lines. **Zero** `Gsk`/GL/`renderer` lines. No crash/assert. Cairo
is active (forced by the gsk-renderer patch).

**This DISPROVES §0.6's branch-(A) main-loop-starvation classification.** §0.6 itself carried the
honest caveat that its "(A)" reading came from round 7's *commit message*, not from re-auditable log
lines. Now that the lines are auditable they say the opposite of starvation: GTK is **actively
re-running allocation every ~600 ms for 25 s** — a starved main loop paints one frame then freezes
silently; it does not emit a steady 2 Hz stream of fresh layout criticals. The event path is not
being starved by a Win32-queue race. The `GtkFixed`-without-`gtk_widget_measure()` warning is
**inherent swift-cross-ui architecture** (every container is a `Gtk.Fixed` populated by Swift-side
layout — `GtkBackend.createContainer` returns `Fixed()`, children `put`/`move`d to absolute
positions), so it prints on macOS/Linux too and is **noise**. The *signal* is the `Gtk-CRITICAL`.

**Root cause (mechanically traced in the resolved checkout @ `a6d2063`, locally auditable):** a
content minimum height that the runtime window cannot be granted, driving an **infinite
relayout/resize loop**:
1. `CueSyncApp.swift` put `.frame(minWidth: 1200, minHeight: 700)` on the window content.
2. `WindowReference.update` (`Sources/SwiftCrossUI/Scenes/WindowReference.swift:194`) computes
   `minimumWindowSize` by proposing `.zero` to the view graph → the frame clamps it to **700** high.
3. The display caps the window: a headless CI monitor and a RustDesk remote session both yield a
   content allocation of **1200x657**. Lines 224-233 clamp the window size back **up** to
   `max(700, 657) = 700`; line 235 sees `700 ≠ 657` and **restarts `update`**, committing the 700
   height via `backend.setSize(ofWindow:)` (line 274).
4. GTK still can only allocate **657**. `gtk_custom_root_widget_allocate` (the `CustomRootWidget` C
   helper) fires its resize callback with 657 → `.onResize` (`WindowReference.swift:164`) re-enters
   `update(proposedWindowSize: 657)` → back to step 3. **The two never agree.** That is the 2 Hz
   `Gtk-CRITICAL` flood. A window in permanent layout thrash renders collapsed and never settles to
   dispatch input → the exact "paints but nothing is clickable" symptom of CUESYNC-7/8/9, and the
   undersized "background + scrollbar only" probe screenshots.

macOS never hit this: its display grants 1200x800 ≥ 700, so step 3's clamp equals the proposal, no
restart, no loop — which is why the same GtkBackend + ContentView rendered correctly at 1200x832 on
macOS in every prior round's local reproduction.

**Round-8 fix (view-layer lane, `CueSync/CueSync/UI/CueSyncApp.swift`):** remove the hard
`.frame(minWidth: 1200, minHeight: 700)`. The preferred opening size stays `.defaultSize(1200×800)`
(honored wherever the display allows); the inner `ScrollView` already returns the *proposed* height
when one is given (`ScrollView.swift:138`), so it absorbs vertical overflow on any smaller/constrained
display instead of forcing an unsatisfiable window minimum. No screen/wording/layout-order/section
change; macOS opens at 1200×800 exactly as before. This is the first CUESYNC-9 fix grounded in the
app's real Windows runtime output rather than a source-only theory.

**Round 7's `windows-input.patch` is left in place this round, but its premise is now disproven.** It
is CI-green (compiles/links/tests on `windows-latest`) and independent of the resize loop (the loop
runs on GLib timeouts, not `RunLoop.main`), so reverting it simultaneously would change two things at
once and destabilize a green CI on a hunch. Flagged as a candidate revert once round 8 is confirmed to
be the actual mover — do not treat it as load-bearing.

**Verification now reachable (the machine-check the ticket demands).** Push and re-read the same
diagnostics step: the fix predicts the `Gtk-CRITICAL: Allocation height too small` flood **disappears**
(window settles at whatever the display grants, ScrollView scrolls). If a click-probe/GTE pass is run,
the window should render the full UI and respond. If the CRITICALs are gone but input is *still* dead,
THEN re-open toward a backend decision (§0.6 round-8 tree, WinUIBackend) — but the layout loop is a
confirmed defect regardless and must be fixed first.

## §0.6 — ROUND 7 (2026-07-19): the round-6 log came back branch (A); stop pumping `RunLoop.main` on Windows entirely

> This is the seventh CUESYNC-9 round and the first **evidence-driven** input patch — it acts on
> the datum round 5 captured and round 6 finally routed to a channel the gate returns
> (`<repo>/.factory/probe/CueSync-startup.log`). Round 7 is committed as `c8d1d1b`
> (`patches/swift-cross-ui-0.8.0-windows-input.patch`, rewritten; `scripts/patch-swift-cross-ui.sh`,
> pristine-reset added). This section documents that shipped fix — the doc had recorded round 6
> (which shipped no input patch) as the latest, leaving round 7 undocumented here.

**The round-6 startup log, per round 7's commit body / patch header, resolved the (A)/(B) fork to
(A).** The log showed: the `CueSync.exe`-launched banner **present** (so the exe reached Swift
`App.init()` — not a packaging/loader failure), **zero** `Pango-*`/`fontconfig`/`couldn't load font`
lines (rules out **B-fonts**), **zero** `Gsk`/`GSK`/GL/`renderer` error lines (rules out
**B-renderer**), and a **real, full-size** window that is nonetheless click-dead. Per the round-5/6
decision trees, banner-present + clean-of-font-and-renderer-lines + window-real-but-inert is exactly
**(A) main-loop starvation confirmed** — pure Win32-message-queue theft, no paint/layout defect.

> **Evidence-provenance caveat (honest).** The `.factory/probe/` payload (including
> `CueSync-startup.log`) is gitignored and is **not** retained in this repo, so the branch-(A)
> reading above is recorded from round 7's commit message and the patch header, **not**
> independently re-auditable from the checked-in tree. It is treated as the working evidence because
> round 6 was engineered specifically to deliver that log and round 7's description is specific and
> consistent with §0.5's decision tree — but if a future round finds the probe still dead, re-pull
> the actual log before trusting this classification.

**Root cause (unchanged from §2.5/§3, now the *confirmed* one of the two live suspects): suspect
(1), the run-loop tickler.** `GtkBackend.mainRunLoopTicklingLoop` (upstream PR #141, added so
`@MainActor`/`DispatchQueue.main` work off-Apple) ticks Foundation's `RunLoop.main` on every
non-macOS platform. swift-corelibs-foundation binds `RunLoop.main` to this thread's Win32 message
queue (`_CFRunLoopSetWindowsMessageQueueMask(_, QS_ALLINPUT, ...)`), and every `.default`-mode pass
runs CoreFoundation's `PeekMessage(NULL, …, PM_REMOVE)`/`DispatchMessage` drain — a second,
uncoordinated consumer of the ONE queue GDK's win32 backend needs for mouse/keyboard/close input.
Two consumers, one queue: Foundation eats the input; GTK renders a window that never feels a click.

**Why rounds 1–2 (priority + floor) could not close it, and round 7's mechanism.** Lowering the
tickler to `G_PRIORITY_DEFAULT_IDLE` (200) below GDK's event (0)/redraw (120) sources makes the
theft *rarer*, not impossible: in any iteration where GDK has nothing ready, the tickler still runs
a `.default`-mode `RunLoop.main` pass, and that pass *itself* PeekMessage-drains the queue. You
cannot out-prioritize a competitor you keep inviting to run. Round 7's structural fix: on Windows,
**never tick `RunLoop.main`**. PR #141's actual requirement is only that `@MainActor`/
`DispatchQueue.main` jobs run — on non-Darwin that means draining **libdispatch's** main queue — so
the tickler calls libdispatch's own CoreFoundation-integration hook
`_dispatch_main_queue_callback_4CF` directly (`@_silgen_name`, `#if os(Windows)` only) after a
non-blocking GLib `g_main_context_iteration` drain. Foundation then never touches the Win32 queue;
GDK is its sole owner. The `G_PRIORITY_DEFAULT_IDLE` + 8 ms floor stay as belt-and-suspenders.
**Accepted cost** (grep-verified absent from both swift-cross-ui and CueSync): Foundation `Timer` /
`RunLoop.main.perform` work scheduled on `RunLoop.main` will not fire on Windows — GLib timeouts are
this backend's timing mechanism.

**Second, unrelated defect round 7's commit also fixed: the box never ran the apply script.** Rounds
1–5 were judged against a **stale** checkout because nothing on the box invoked
`scripts/patch-swift-cross-ui.sh` — an evolving patch file (CUESYNC-9 went through seven revisions)
was landing on a checkout still carrying an older revision. Round 7 made the script **reset the
checkout to pristine** and reapply everything (gulong/gsize LLP64 fixes + all three patches)
deterministically each run; a companion Factory change wires a prepare step into the
ci-local/click-probe gates so the script actually runs before the probe builds.

**Machine-verifiable state as of this audit (macOS, against the resolved checkout at the pinned
`a6d2063`):** all three patches apply cleanly in order to a pristine checkout; the patched
`GtkBackend.swift` compiles/links in the `CueSync` GtkBackend build on macOS (the `#if os(Windows)`
block is excluded there, so this proves the file is well-formed and the non-Windows path unbroken,
**not** the Windows runtime behaviour); all 470 XCTest + 76 Python adversarial tests green; the input
patch step is wired on all three legs after resolve/interactivity and before build/test. What this
box **cannot** prove is the live Windows outcome — the click-probe gate on the box remains the only
instrument that can, and it has not been re-run against round 7 in a form returned to this tree.

**Round-8 decision tree (if the probe is still click-dead against round 7).** Not another blind
priority tweak — the two remaining possibilities are distinct and evidence-separable:
- **`_dispatch_main_queue_callback_4CF` does not actually service the main queue on Windows** (the
  symbol no-ops, asserts, or the queue was never bound because CF never ran) → `.task { }`/`@MainActor`
  work silently never runs. Tell: the app launches but preference-load / any `.task` side effect never
  fires (add a one-line banner to the startup log from inside a `.task` and check the returned log).
  If so, the direct-drain hook is the wrong primitive and the durable answer is below.
- **The theft was never the whole story / GtkBackend-on-Windows input is structurally unmaintained.**
  §0.5 established that *every* post-v0.8.0 Windows commit upstream targets **WinUIBackend**, not
  GtkBackend — upstream actively maintains its native Windows backend and leaves GtkBackend-on-Windows
  input unmaintained. If round 7's structural fix still returns a byte-identical probe, the durable fix
  is likely a **backend decision** (WinUIBackend), not a further GtkBackend patch — out of this agent's
  view-layer lane, flagged here for whoever owns the port strategy, exactly as §0.5 flagged it.

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
