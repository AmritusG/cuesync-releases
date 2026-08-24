#!/usr/bin/env bash
set -euo pipefail

# Applies patches/swift-cross-ui-0.8.0-gtk-interactivity.patch (CUESYNC-8) and
# patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch (CUESYNC-9 round 4) to the
# resolved swift-cross-ui checkout, in that order, so the dev / ci-local loop can
# iterate without GitHub CI. Mirrors the `git apply` steps these same patches get in
# .github/workflows/swift-windows.yml — see that file for the CI-side version.
#
# CUESYNC-9 rounds 1-2 also shipped a third patch, a Windows `mainRunLoopTicklingLoop`
# fix for a Win32-message-queue race. Round 8 (specs/CUESYNC-9-findings.md
# §0.7-§0.8) proved from the app's own auditable Windows stderr that the real input
# death is an unrelated unsatisfiable-window-minimum relayout loop, and round 9
# reverted the disproven patch here per spec step 5 ("revert that hunk before trying
# the next suspect — never stack speculative patches") rather than leave it stacked
# on the audited dependency. See specs/CUESYNC-9-findings.md §0.8 for the full
# disposition and what was removed.
#
# The dependency source itself is never edited in this repo; this script only ever
# touches the checkout under .build/checkouts, which is gitignored and rebuilt by
# `swift package resolve`.

# Every patch below is written against the PINNED swift-cross-ui v0.8.0 checkout,
# tag v0.8.0 == commit a6d206370812e3b9edba259d167e848892c5013d (matches
# Package.swift's `exact: "0.8.0"` / Package.resolved). This script is the single
# apply path — CI's macos / windows-build / windows-test legs all call it — so the
# audited revision is named here rather than repeated per CI step.
AUDITED_SWIFT_CROSS_UI_REVISION="a6d206370812e3b9edba259d167e848892c5013d"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT="$ROOT/.build/checkouts/swift-cross-ui"

INTERACTIVITY_PATCH="$ROOT/patches/swift-cross-ui-0.8.0-gtk-interactivity.patch"
GSK_RENDERER_PATCH="$ROOT/patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch"
# CUESYNC-9 round 17 (specs/CUESYNC-9-findings.md §0.16): a third live patch on
# GtkBackend.swift — show(window:) also gtk_window_present()s the initial window on
# Windows so it raises above the launcher console instead of mapping behind it.
# Distinct root cause/file-region/mechanism from the round-9-reverted windows-input
# patch; applied last (after interactivity + GSK) so it lands on the shifted
# show(window:) anchor via git apply's context match.
WINDOW_PRESENT_PATCH="$ROOT/patches/swift-cross-ui-0.8.0-windows-window-present.patch"
# CUESYNC-9 round 18 (specs/CUESYNC-9-findings.md §0.17): a fourth live patch. GTK's
# gtk_widget_pick() stops at any container that contains the point and is targetable,
# even when nothing inside it can be targeted — so the Gtk.Fixed wrapping a CUESYNC-8
# `canTarget = false` Shape still swallowed every click on the control beneath it.
# Derives container targetability from its children. Touches the `// MARK: Containers`
# block and Widget.addEventController — disjoint from the three patches above, and
# applied last so it lands on their shifted anchors via git apply's context match.
CONTAINER_HIT_TESTING_PATCH="$ROOT/patches/swift-cross-ui-0.8.0-gtk-container-hit-testing.patch"
# CUESYNC-9 round 19 (specs/CUESYNC-9-findings.md §0.18): a fifth live patch. GtkEntry
# styles its inner `text` node from the theme and paints an opaque background over the
# app's own, so `.foregroundColor(...)`/`.background(...)` were discarded and CueSync's
# text fields rendered invisible. Paint-only CSS in the existing global provider.
ENTRY_STYLING_PATCH="$ROOT/patches/swift-cross-ui-0.8.0-gtk-entry-styling.patch"

for patch in "$INTERACTIVITY_PATCH" "$GSK_RENDERER_PATCH" "$WINDOW_PRESENT_PATCH" \
    "$CONTAINER_HIT_TESTING_PATCH" "$ENTRY_STYLING_PATCH"; do
    if [ ! -f "$patch" ]; then
        echo "patch-swift-cross-ui.sh: missing $patch" >&2
        exit 1
    fi
done

if [ ! -d "$CHECKOUT" ]; then
    echo "==> Resolving package dependencies (no existing swift-cross-ui checkout)"
    (cd "$ROOT" && swift package resolve)
fi

if [ ! -d "$CHECKOUT" ]; then
    echo "patch-swift-cross-ui.sh: $CHECKOUT still missing after 'swift package resolve'" >&2
    exit 1
fi

cd "$CHECKOUT"

# CUESYNC-9 round 20: NO `git checkout --` OF THE DEPENDENCY TREE. Read this before
# re-adding one.
#
# An earlier revision of this script normalized the checkout to LF
# (`git config core.autocrlf false` + `git checkout -- .`) and reset it to pristine
# (`git checkout -- Sources`). Both are removed:
#
#   * The LF normalization targeted a failure that does not exist. `git apply`
#     honours `core.autocrlf` when applying to a CRLF working tree — verified
#     directly: all five patches apply to a genuine CRLF checkout of
#     a6d206370812e3b9edba259d167e848892c5013d, individually AND cumulatively. The
#     real CRLF hazard was this SCRIPT's own line endings under `bash`, which the
#     repo-root `.gitattributes` (`*.sh text eol=lf`) fixes.
#   * Both are `git checkout --` over a tree that checks out READ-ONLY on Windows.
#     Dependency sources are read-only there (it is why every CI patch step used to
#     clear the flag explicitly), and this script had never run on CI before round
#     20 — so this rewrite-everything path was never exercised against a read-only
#     tree until it turned both Windows legs red at step 12.
#
# Consequence, deliberately accepted: this script no longer force-resets an
# already-patched checkout to pristine. Re-application stays safe because each apply
# below is guarded by `git apply --reverse --check` (already applied -> skip), and an
# EDITED patch landing on a checkout carrying its older revision now fails loudly on
# both the reverse-check and the forward apply rather than being silently reset. Wipe
# `.build/checkouts/swift-cross-ui` (or `swift package reset`) when iterating on a
# patch's bytes.

# Dependency sources check out read-only on Windows — clear it before patching.
# Deliberately NOT suppressed with `2>/dev/null || true`: a silent failure here
# leaves the tree read-only and the real error surfaces later as a confusing
# `git apply` failure, which is exactly how round 20 lost two CI cycles.
echo "==> Clearing read-only flag on swift-cross-ui sources"
if ! chmod -R u+w Sources; then
    echo "patch-swift-cross-ui.sh: failed to clear the read-only flag on $CHECKOUT/Sources." >&2
    echo "  Dependency sources check out read-only on Windows; patch application" >&2
    echo "  cannot write to them until this succeeds." >&2
    exit 1
fi

# LLP64 gulong/gsize fixes (mirrors the PowerShell -replace step in
# .github/workflows/swift-windows.yml — needed again after every reset;
# idempotent because each pattern vanishes once replaced; perl for BSD/GNU
# portability, \Q..\E for literal matching).
perl -pi -e 's/\Qg_signal_handler_disconnect(gobjectPointer, id)\E/g_signal_handler_disconnect(gobjectPointer, .init(id))/' Sources/Gtk/GObject.swift
perl -pi -e 's/\Qg_signal_handler_block(gobjectPointer, signalID)\E/g_signal_handler_block(gobjectPointer, .init(signalID))/' Sources/Gtk/GObject.swift
perl -pi -e 's/\Qg_signal_handler_unblock(gobjectPointer, signalID)\E/g_signal_handler_unblock(gobjectPointer, .init(signalID))/' Sources/Gtk/GObject.swift
perl -pi -e 's/\Qg_bytes_new(rgbaData, UInt(rgbaData.count))\E/g_bytes_new(rgbaData, .init(rgbaData.count))/' Sources/Gtk/MemoryTexture.swift

# Dependency sources can check out read-only (observed on Windows; harmless
# elsewhere) — clear it before attempting to patch, same rationale as the
# existing gulong/gsize -replace step in swift-windows.yml.
chmod -R u+w Sources/Gtk/Widgets/Widget.swift Sources/GtkBackend/GtkBackend.swift

if git apply --reverse --check "$INTERACTIVITY_PATCH" 2>/dev/null; then
    echo "==> swift-cross-ui gesture/interactivity patch already applied — skipping"
else
    echo "==> Applying swift-cross-ui gesture/interactivity patch"
    git apply "$INTERACTIVITY_PATCH"
fi

if git apply --reverse --check "$GSK_RENDERER_PATCH" 2>/dev/null; then
    echo "==> swift-cross-ui Windows GSK-renderer patch already applied — skipping"
else
    echo "==> Applying swift-cross-ui Windows GSK-renderer patch"
    git apply "$GSK_RENDERER_PATCH"
fi

if git apply --reverse --check "$WINDOW_PRESENT_PATCH" 2>/dev/null; then
    echo "==> swift-cross-ui Windows window-present patch already applied — skipping"
else
    echo "==> Applying swift-cross-ui Windows window-present patch"
    git apply "$WINDOW_PRESENT_PATCH"
fi

if git apply --reverse --check "$CONTAINER_HIT_TESTING_PATCH" 2>/dev/null; then
    echo "==> swift-cross-ui container hit-testing patch already applied — skipping"
else
    echo "==> Applying swift-cross-ui container hit-testing patch"
    git apply "$CONTAINER_HIT_TESTING_PATCH"
fi

if git apply --reverse --check "$ENTRY_STYLING_PATCH" 2>/dev/null; then
    echo "==> swift-cross-ui GtkEntry styling patch already applied — skipping"
else
    echo "==> Applying swift-cross-ui GtkEntry styling patch"
    git apply "$ENTRY_STYLING_PATCH"
fi
