# CueSync Release Pipeline

This document describes how to build, sign, notarize, and package CueSync for distribution.

---

## Prerequisites

### 1. Apple Developer Account
- Enrolled in the Apple Developer Program ($99/year)
- Developer ID Application certificate installed in Keychain

### 2. Signing Identity
Verify your certificate is installed:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Expected output:
```
X) HASH "Developer ID Application: YOUR NAME (TEAMID)"
```

### 3. Notarization Credentials
Store your Apple ID credentials in the keychain (one-time setup):

```bash
xcrun notarytool store-credentials YOUR_PROFILE_NAME \
    --apple-id "your-apple-id@example.com" \
    --team-id "YOUR_TEAM_ID"
```

When prompted, enter an **app-specific password** generated at [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords.

---

## Release Script

The `scripts/release.sh` script handles the full pipeline:

```bash
NOTARY_PROFILE="YOUR_PROFILE_NAME" ./scripts/release.sh 1.0.0
```

### What It Does

| Step | Action |
|------|--------|
| 1 | Clean build with Developer ID signing + hardened runtime |
| 2 | Verify signature is Developer ID (not ad-hoc) |
| 3 | Submit to Apple notarization service |
| 4 | Staple notarization ticket to app bundle |
| 5 | Verify Gatekeeper acceptance |
| 6 | Create DMG, sign it, notarize it, staple it |

### Output Artifacts

```
CueSync.app           # Signed + notarized app bundle
CueSync-1.0.0.dmg     # Distribution disk image (also notarized)
CueSync-1.0.0.zip     # Intermediate (can delete)
```

---

## Manual Pipeline

If you need to run steps individually:

### Build
```bash
xcodebuild -project CueSync/CueSync.xcodeproj \
    -scheme CueSync \
    -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
    DEVELOPMENT_TEAM="YOUR_TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    clean build

cp -R build/Build/Products/Release/CueSync.app .
```

### Verify Signature
```bash
codesign --verify --verbose=2 CueSync.app
codesign -dv --verbose=2 CueSync.app 2>&1 | grep Authority
```

Must show `Authority=Developer ID Application`, not `Signature=adhoc`.

### Notarize
```bash
# Create zip
ditto -c -k --keepParent CueSync.app CueSync.zip

# Submit and wait
xcrun notarytool submit CueSync.zip \
    --keychain-profile YOUR_PROFILE_NAME \
    --wait

# Check result if failed
xcrun notarytool log SUBMISSION_ID --keychain-profile YOUR_PROFILE_NAME
```

### Staple
```bash
xcrun stapler staple CueSync.app
```

### Verify Final Result
```bash
spctl --assess --type execute --verbose=4 CueSync.app
```

Expected: `source=Notarized Developer ID`

### Create DMG
```bash
hdiutil create -volname "CueSync" \
    -srcfolder CueSync.app \
    -ov -format UDZO \
    CueSync-1.0.0.dmg

# Sign DMG
codesign --force --sign "Developer ID Application: YOUR NAME (TEAMID)" \
    --timestamp CueSync-1.0.0.dmg

# Notarize DMG
xcrun notarytool submit CueSync-1.0.0.dmg \
    --keychain-profile YOUR_PROFILE_NAME \
    --wait

# Staple DMG
xcrun stapler staple CueSync-1.0.0.dmg
```

---

## Common Issues

### "The executable requests com.apple.security.get-task-allow"
This debug entitlement blocks notarization. Fix by adding to xcodebuild:
```bash
CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
```

### "Signature=adhoc" after build
Xcode isn't using your Developer ID. Verify:
- `CODE_SIGN_STYLE=Manual` is set
- `CODE_SIGN_IDENTITY` matches your certificate exactly
- Certificate + private key are both in Keychain

### Notarization hangs
Apple's timestamp server can be slow. The script may appear frozen for 1-15 minutes during notarization. Let it complete.

### "Record not found" on staple
Notarization failed. Check the log:
```bash
xcrun notarytool log SUBMISSION_ID --keychain-profile YOUR_PROFILE_NAME
```

---

## GitHub Release

After the pipeline completes:

```bash
gh release create v1.0.0 CueSync-1.0.0.dmg \
    --title "CueSync v1.0.0" \
    --notes "Release notes here"
```

Or upload via GitHub web UI at the repository's Releases page.

---

## Version Bumping

Before release, update version in:
1. `CueSync/CueSync.xcodeproj` → Target → General → Version
2. `release.sh` argument: `./scripts/release.sh X.Y.Z`

The DMG filename automatically includes the version.

---

## CI/CD Notes

For GitHub Actions automation, you'd need to:
1. Store signing certificate as base64 secret
2. Create temporary keychain in the runner
3. Store notarization credentials as secrets
4. Handle certificate expiration

This is more complex than the local workflow above. For a small project, manual release via `release.sh` is simpler.
