#!/usr/bin/env bash
set -euo pipefail

# Build a distributable DMG from the signed + notarized CueSync.app.
# Output: CueSync-vX.Y.Z.dmg in the project root.
#
# Layout inside the DMG:
#   /CueSync.app
#   /Applications -> /Applications  (symlink, lets user drag-drop install)
#
# Run AFTER scripts/build.sh + scripts/sign.sh + scripts/notarize.sh have
# produced a stapled, notarized CueSync.app. The DMG itself is signed with
# the same Developer ID so Gatekeeper accepts it.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CueSync.app"
[ -d "$APP" ] || { echo "CueSync.app not found at $APP — build + sign + notarize first."; exit 1; }

# Pull version from Info.plist so the filename matches the build.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/CueSync-v${VERSION}.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Staging DMG contents at $STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Verify staged app is still notarized (cp shouldn't break it but we check).
if ! spctl --assess --type execute --verbose "$STAGING/CueSync.app" 2>&1 | grep -q "accepted"; then
    echo "WARNING: staged CueSync.app is not Gatekeeper-accepted. Continuing anyway."
fi

echo "==> Building DMG: $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "CueSync ${VERSION}" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

# Sign the DMG itself so the user's first Gatekeeper check on download
# resolves cleanly. Uses the same signing identity as the .app.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-D2683095DE5421C7A292F448BAF81DB8BAA0141E}"
echo "==> Signing DMG"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"

echo "==> Verifying"
spctl --assess --type open --context context:primary-signature --verbose "$DMG" 2>&1 || true

echo
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
echo
echo "Optional next step: notarize the DMG itself (Apple recommends this"
echo "for distributables that contain a notarized app):"
echo "    xcrun notarytool submit '$DMG' --keychain-profile amritus-notary --wait"
echo "    xcrun stapler staple '$DMG'"
