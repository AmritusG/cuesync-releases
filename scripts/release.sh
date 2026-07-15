#!/usr/bin/env bash
#
# release.sh — Build, sign, notarize, staple, and package CueSync for distribution
#
# Prerequisites:
#   1. Developer ID Application certificate in Keychain
#   2. Notarytool credentials stored:
#      xcrun notarytool store-credentials cuesync-notary \
#          --apple-id YOUR_EMAIL --team-id 3A3L2C6DFB
#
# Usage:
#   ./scripts/release.sh [version]
#   ./scripts/release.sh 1.0.0
#
set -euo pipefail

VERSION="${1:-1.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CueSync"
BUNDLE_ID="com.cuesync.app"
TEAM_ID="3A3L2C6DFB"
IDENTITY="Developer ID Application: AMRIT STEFAN ANDERS ROSELL ($TEAM_ID)"
NOTARY_PROFILE="${NOTARY_PROFILE:-cuesync-notary}"

XCODE_PROJECT="$ROOT/CueSync/CueSync.xcodeproj"
BUILD_DIR="$ROOT/build"
APP="$ROOT/$APP_NAME.app"
ZIP="$ROOT/$APP_NAME-$VERSION.zip"
DMG="$ROOT/$APP_NAME-$VERSION.dmg"

# Lockfile to prevent concurrent runs

echo "=== CueSync Release Pipeline v$VERSION ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Clean and build with Developer ID signing
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Step 1: Building with Developer ID signing"
rm -rf "$BUILD_DIR" "$APP"

xcodebuild -project "$XCODE_PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    clean build \
    | grep -E '^(Build|Signing|warning:|error:|===)' || true

# Copy built app to project root
cp -R "$BUILD_DIR/Build/Products/Release/$APP_NAME.app" "$APP"
echo "    Built: $APP"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Verify signature before notarization
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: Verifying Developer ID signature"
codesign --verify --verbose=2 "$APP"

# Check it's actually Developer ID signed, not ad-hoc
AUTHORITY=$(codesign -dv --verbose=2 "$APP" 2>&1 | grep "Authority=Developer ID" || true)
if [ -z "$AUTHORITY" ]; then
    echo "ERROR: App is not Developer ID signed!"
    codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "(Authority|Signature|TeamIdentifier)"
    exit 1
fi
echo "    ✓ Signed with: $AUTHORITY"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Notarize
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 3: Notarizing (this takes 1-15 minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "    Submitting $ZIP to Apple..."

xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Staple
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Stapling notarization ticket"
xcrun stapler staple "$APP"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Verify final result
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 5: Verifying notarized app"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | head -5

SPCTL_RESULT=$(spctl --assess --type execute --verbose=2 "$APP" 2>&1)
if echo "$SPCTL_RESULT" | grep -q "source=Notarized Developer ID"; then
    echo "    ✓ App is notarized and ready for distribution"
else
    echo "WARNING: spctl result: $SPCTL_RESULT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Create DMG
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 6: Creating DMG"
rm -f "$DMG"

# Create DMG with hdiutil
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$APP" \
    -ov -format UDZO \
    "$DMG"

# Sign the DMG
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

# Notarize the DMG
echo "    Notarizing DMG..."
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# Staple the DMG
xcrun stapler staple "$DMG"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Release complete ==="
echo ""
echo "Artifacts:"
echo "  App: $APP"
echo "  DMG: $DMG"
echo "  ZIP: $ZIP (intermediate, can delete)"
echo ""
echo "To upload to GitHub:"
echo "  gh release create v$VERSION '$DMG' --title 'CueSync v$VERSION' --notes 'Release notes here'"
