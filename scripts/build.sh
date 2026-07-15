#!/usr/bin/env bash
set -euo pipefail

# CueSync build script (Xcode-based).
# Produces CueSync.app at the project root from xcodebuild.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/CueSync.app"
SCHEME="CueSync"
CONFIG="${CONFIG:-Release}"
BUILD_DIR="$ROOT/build"

# Find the Xcode project (handles both flat and nested layouts)
if [ -d "$ROOT/CueSync.xcodeproj" ]; then
    PROJECT="$ROOT/CueSync.xcodeproj"
elif [ -d "$ROOT/CueSync/CueSync.xcodeproj" ]; then
    PROJECT="$ROOT/CueSync/CueSync.xcodeproj"
else
    echo "CueSync.xcodeproj not found at $ROOT or $ROOT/CueSync"
    exit 1
fi

cd "$ROOT"

echo "==> xcodebuild -scheme $SCHEME -configuration $CONFIG"
echo "    Project: $PROJECT"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    build

# Find the built app
BUILT_APP="$BUILD_DIR/Build/Products/$CONFIG/CueSync.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "Built app not found at $BUILT_APP"
    exit 1
fi

# Copy to project root for signing
echo "==> Copying to $APP_DIR"
rm -rf "$APP_DIR"
cp -R "$BUILT_APP" "$APP_DIR"

echo "==> Built $APP_DIR"
echo "Run: open '$APP_DIR'"
