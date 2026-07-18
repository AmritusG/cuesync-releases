#!/usr/bin/env bash
set -euo pipefail

# Applies patches/swift-cross-ui-0.8.0-gtk-interactivity.patch (CUESYNC-8) to the
# resolved swift-cross-ui checkout, so the dev / ci-local loop can iterate without
# GitHub CI. Mirrors the `git apply` step this same patch gets in
# .github/workflows/swift-windows.yml — see that file for the CI-side version.
#
# The dependency source itself is never edited in this repo; this script only ever
# touches the checkout under .build/checkouts, which is gitignored and rebuilt by
# `swift package resolve`.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/patches/swift-cross-ui-0.8.0-gtk-interactivity.patch"
CHECKOUT="$ROOT/.build/checkouts/swift-cross-ui"

if [ ! -f "$PATCH" ]; then
    echo "patch-swift-cross-ui.sh: missing $PATCH" >&2
    exit 1
fi

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

if git apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "==> swift-cross-ui gesture/interactivity patch already applied — skipping"
else
    echo "==> Applying swift-cross-ui gesture/interactivity patch"
    git apply "$PATCH"
fi
