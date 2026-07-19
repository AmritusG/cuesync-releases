#!/usr/bin/env bash
set -euo pipefail

# Applies patches/swift-cross-ui-0.8.0-gtk-interactivity.patch (CUESYNC-8),
# patches/swift-cross-ui-0.8.0-windows-input.patch (CUESYNC-9 rounds 1-2), and
# patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch (CUESYNC-9 round 4) to the
# resolved swift-cross-ui checkout, in that order, so the dev / ci-local loop can
# iterate without GitHub CI. Mirrors the `git apply` steps these same patches get in
# .github/workflows/swift-windows.yml — see that file for the CI-side version.
#
# The dependency source itself is never edited in this repo; this script only ever
# touches the checkout under .build/checkouts, which is gitignored and rebuilt by
# `swift package resolve`.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT="$ROOT/.build/checkouts/swift-cross-ui"

INTERACTIVITY_PATCH="$ROOT/patches/swift-cross-ui-0.8.0-gtk-interactivity.patch"
WINDOWS_INPUT_PATCH="$ROOT/patches/swift-cross-ui-0.8.0-windows-input.patch"
GSK_RENDERER_PATCH="$ROOT/patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch"

for patch in "$INTERACTIVITY_PATCH" "$WINDOWS_INPUT_PATCH" "$GSK_RENDERER_PATCH"; do
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

if git apply --reverse --check "$WINDOWS_INPUT_PATCH" 2>/dev/null; then
    echo "==> swift-cross-ui Windows input patch already applied — skipping"
else
    echo "==> Applying swift-cross-ui Windows input patch"
    git apply "$WINDOWS_INPUT_PATCH"
fi

if git apply --reverse --check "$GSK_RENDERER_PATCH" 2>/dev/null; then
    echo "==> swift-cross-ui Windows GSK-renderer patch already applied — skipping"
else
    echo "==> Applying swift-cross-ui Windows GSK-renderer patch"
    git apply "$GSK_RENDERER_PATCH"
fi
