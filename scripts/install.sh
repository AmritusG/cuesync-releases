#!/usr/bin/env bash
set -euo pipefail

# Install the locally-built CueSync.app to /Applications/CueSync.app.
#
# This script always rm -rf's the staging CueSync.app, re-assembles
# from scratch via build.sh, signs, copies to /Applications, and
# refreshes LaunchServices.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CueSync.app"
DEST="/Applications/CueSync.app"
BUILD_SH="$ROOT/scripts/build.sh"
SIGN_SH="$ROOT/scripts/sign.sh"

# ---- Preflight 1: SIGNING_IDENTITY must be present in the environment.
if [ -z "${SIGNING_IDENTITY:-}" ]; then
    cat >&2 <<EOF
ERROR: SIGNING_IDENTITY is not set.

scripts/install.sh needs SIGNING_IDENTITY exported in the environment.

Fix one of:
  (a) Export in your shell startup file:
          export SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
  (b) Pass inline:
          SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/install.sh

List available codesigning identities:
  security find-identity -v -p codesigning
EOF
    exit 1
fi

# ---- Preflight 2: required sibling scripts present and executable.
[ -x "$BUILD_SH" ] || { echo "ERROR: $BUILD_SH missing or not executable" >&2; exit 1; }
[ -x "$SIGN_SH" ]  || { echo "ERROR: $SIGN_SH missing or not executable"  >&2; exit 1; }

# ---- Step 1: nuke the staging bundle.
echo "==> Removing stale staging bundle ($APP)"
rm -rf "$APP"

# ---- Step 2: re-assemble from scratch.
echo "==> Running scripts/build.sh"
"$BUILD_SH"

# ---- Preflight 3: post-build verification.
if [ ! -d "$APP" ]; then
    cat >&2 <<EOF
ERROR: scripts/build.sh completed but $APP does not exist.
EOF
    exit 1
fi

# ---- Step 3: sign the fresh bundle.
echo "==> Signing $APP"
"$SIGN_SH"

# ---- Step 4: quit any running instance.
echo "==> Quitting any running CueSync"
osascript -e 'tell application "CueSync" to quit' 2>/dev/null || true
sleep 1
pkill -f "CueSync.app/Contents/MacOS/CueSync" 2>/dev/null || true
sleep 0.5

# ---- Step 5: remove existing /Applications copy.
if [ -d "$DEST" ]; then
    echo "==> Removing existing $DEST"
    rm -rf "$DEST"
fi

# ---- Step 6: install.
echo "==> Copying $APP → $DEST"
cp -R "$APP" "$DEST"

# ---- Step 7: post-install codesign verification.
echo "==> Verifying codesign on $DEST"
if ! codesign --verify --deep --strict --verbose=2 "$DEST"; then
    cat >&2 <<EOF
ERROR: codesign --verify --deep --strict FAILED on $DEST.
EOF
    exit 1
fi

# ---- Step 8: confirm install location actually has the bundle.
if [ ! -d "$DEST" ]; then
    echo "ERROR: $DEST does not exist after install" >&2
    exit 1
fi

# ---- Step 9: refresh LaunchServices + Dock.
echo "==> Registering with LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DEST"

echo "==> Refreshing Dock"
killall Dock 2>&1 || true

cat <<EOF

==> SUCCESS — CueSync installed at $DEST

Launch from /Applications, Spotlight, or:
    open $DEST
EOF
