# CUE SYNC — Claude Code Instructions

Native SwiftUI macOS app for converting DJ cue points to Resolume Arena envelope automation.

## Project Location
```bash
~/Documents/claude/cue-sync-build/CueSync/
```

## Build & Run
Open `CueSync.xcodeproj` in Xcode, then **⌘R**.

---

## Architecture

```
CueSync/
├── App/
│   ├── CueSyncApp.swift      # @main entry, menu commands
│   ├── AppState.swift        # Central state (546 lines) - tracks, cues, undo/redo
│   └── LicenseManager.swift  # ⚠️ DELETE - Gumroad licensing (not used)
├── Models/
│   ├── CuePoint.swift        # Cue point struct
│   ├── CurveType.swift       # 23 Resolume curve types
│   ├── Track.swift           # Audio track metadata
│   ├── Playlist.swift        # Playlist/folder hierarchy
│   └── Project.swift         # Project file format
├── Parsers/
│   ├── RekordboxParser.swift     # Rekordbox XML import
│   ├── ShowKontrolParser.swift   # ShowKontrol .cue import
│   ├── ResolumeParser.swift      # Resolume envelope import
│   ├── SeratoParser.swift        # Serato ID3 GEOB parsing (737 lines!)
│   └── EngineDJParser.swift      # Engine DJ SQLite parsing
├── Exporters/
│   ├── ResolumeExporter.swift    # Resolume XML generation
│   └── ShowKontrolExporter.swift # ShowKontrol .cue generation
├── Views/
│   ├── ContentView.swift         # Main layout
│   ├── HeaderView.swift          # Logo + version
│   ├── FooterView.swift          # Footer text
│   ├── CollapsibleSection.swift  # Reusable section wrapper
│   ├── HoverButton.swift         # Animated buttons
│   ├── BrandIcons.swift          # SVG icons for import buttons
│   ├── LicenseView.swift         # ⚠️ DELETE - License input UI (not used)
│   └── Sections/
│       ├── ProjectSectionView.swift    # Import buttons, project controls
│       ├── BrowseSectionView.swift     # Track list + playlist tree
│       ├── ConfigureSectionView.swift  # Envelope + cue table
│       ├── ExportSectionView.swift     # Export buttons (has commented license code)
│       ├── EnvelopeCanvasView.swift    # Canvas drawing
│       ├── CuePointsTableView.swift    # Editable cue table
│       ├── DurationInputModal.swift    # Duration dialog
│       ├── DurationInputView.swift     # Duration fields
│       └── StepperField.swift          # Numeric stepper
├── Theme/
│   └── ThemeColors.swift     # Dark/light color definitions
├── Utilities/
│   ├── FileDialogs.swift         # NSOpenPanel/NSSavePanel wrappers
│   └── NonSelectingTextField.swift
└── Resources/
    ├── Info.plist
    ├── CueSync.entitlements
    └── Assets.xcassets/
```

---

## ⚠️ GUMROAD REMOVAL — Files to Delete

The licensing code is **already disabled** (commented out) but the files still exist:

### 1. Delete these files:
- `App/LicenseManager.swift` (288 lines)
- `Views/LicenseView.swift` (182 lines)

### 2. Clean up commented code in:

**CueSyncApp.swift** — Remove lines 6-36 (licensing comments):
```swift
// DELETE these comments entirely:
// NOTE: Gumroad licensing is disabled but kept in code for future use.
// To re-enable: uncomment licenseManager lines...
// @State private var licenseManager = LicenseManager()
// .environment(licenseManager)
// .task { ... }
// .sheet(isPresented: ...) { LicenseView() }
```

**ExportSectionView.swift** — Remove lines 6-7 and 70-89 (licensing comments):
```swift
// DELETE:
// LICENSING DISABLED — to re-enable, uncomment:
// @Environment(LicenseManager.self) private var licenseManager
// ... (demo mode overlay block)
```

### 3. Update Xcode project
After deleting files, remove them from the Xcode project navigator.

---

## Current State — What Works

### ✅ Fully Functional
- **Imports**: Rekordbox XML, ShowKontrol .cue, Resolume envelope, Serato audio files, Engine DJ database
- **Exports**: Resolume XML, ShowKontrol .cue  
- **Project**: Save/Load (.cueproj JSON)
- **UI**: All 4 sections, collapsible, dark theme
- **Envelope**: Canvas with draggable points, curve interpolation
- **Cue Table**: Editable name, position, Y-value, curve dropdown
- **Undo/Redo**: Full history support
- **Menu shortcuts**: ⌘N, ⌘O, ⌘S, ⌘E, ⌘Z, etc.

### 🎉 No Bugs Known
The app is feature-complete and stable. Just needs license code removal for GitHub release.

---

## Stats

| Component | Lines |
|-----------|-------|
| AppState.swift | 546 |
| SeratoParser.swift | 737 |
| ProjectSectionView.swift | 490 |
| ConfigureSectionView.swift | 395 |
| **Total Swift** | ~6,400 |
| Files to delete | ~470 |

---

## Color Scheme (ThemeColors.swift)

```swift
// Dark theme
background:     Color(red: 0.039, green: 0.039, blue: 0.059)  // #0a0a0f
sectionBg:      Color(red: 0.078, green: 0.078, blue: 0.118)  // #14141e
accentGreen:    Color(red: 0.118, green: 0.843, blue: 0.376)  // #1ed760
accentPink:     Color(red: 0.937, green: 0.157, blue: 0.541)  // #ef288a
accentGold:     Color(red: 1.0, green: 0.843, blue: 0.0)      // #ffd700
accentTeal:     Color(red: 0.365, green: 0.894, blue: 0.780)  // #5de4c7
```

---

## GitHub Release Checklist

### Gumroad removal (done)

1. [x] Delete LicenseManager.swift
2. [x] Delete LicenseView.swift
3. [x] Clean CueSyncApp.swift comments
4. [x] Clean ExportSectionView.swift comments
5. [x] Remove deleted files from Xcode project
6. [x] Build succeeds (`xcodebuild -scheme CueSync build` — verified)
7. [ ] App runs without license prompt (manual ⌘R in Xcode)
8. [ ] Export works without restrictions (manual smoke test)
9. [x] Add `.gitignore` (xcuserdata, build/, builds/, DerivedData/, etc.)

### Release build pipeline

The `scripts/` folder (adapted from GlEnc) drives the full Developer-ID
release pipeline. Each script does one thing; run them in order:

| Step | Script | What it does |
|------|--------|--------------|
| 1 | `scripts/build.sh` | `xcodebuild -configuration Release` → copies `CueSync.app` to repo root. `CONFIG=Debug` env var to override. |
| 2 | `scripts/sign.sh` | Signs `CueSync.app` with Developer ID + entitlements (`scripts/entitlements.plist`, sandbox off). Reads `SIGNING_IDENTITY` env or `$1`. |
| 3 | `scripts/notarize.sh` | Zips with `ditto`, submits via `xcrun notarytool` using keychain profile **`amritus-notary`**, staples the ticket, verifies with `spctl`. |
| 4 | `scripts/make-dmg.sh` | Builds `CueSync-v<version>.dmg` (UDZO) with `/Applications` symlink, signs the DMG. Version pulled from `Info.plist`. |

Helper scripts:

- `scripts/run.sh` — `build.sh` then `open CueSync.app` (dev loop).
- `scripts/install.sh` — rebuilds + signs + installs to `/Applications/CueSync.app` (requires `SIGNING_IDENTITY`). Quits any running instance and refreshes LaunchServices.
- `scripts/build-icon.sh` — re-renders `.icns` from SVG via `rsvg-convert` + `iconutil`. ⚠️ Still references `assets/GlEnc-icon.svg`; adapt paths before use.
- `scripts/entitlements.plist` — sandbox disabled, `user-selected.read-only` true.

**Prerequisites:**
- Apple Developer ID Application cert installed in login keychain (Team `3A3L2C6DFB`, identity `AMRIT STEFAN ANDERS ROSELL`).
- Notarization keychain profile created once:
  ```bash
  xcrun notarytool store-credentials amritus-notary \
      --apple-id amrit.rosell@me.com --team-id 3A3L2C6DFB
  ```
- `librsvg` (only for `build-icon.sh`): `brew install librsvg`.

**One-shot release:**
```bash
export SIGNING_IDENTITY="Developer ID Application: AMRIT STEFAN ANDERS ROSELL (3A3L2C6DFB)"
scripts/build.sh && scripts/sign.sh && scripts/notarize.sh && scripts/make-dmg.sh
```

### Repo / publish

10. [x] Add LICENSE file (MIT)
11. [x] Update README.md for GitHub
12. [ ] Initial git commit + push (repo currently has 0 commits)
13. [ ] Tag `v1.0.0` and attach `CueSync-v1.0.0.dmg` to GitHub release

---

## File Formats

### Resolume XML Export
```xml
<?xml version="1.0" encoding="utf-8"?>
<Preset name="NAME" uniqueId="MOD_ENVELOPE" className="Envelope" default="0">
  <versionInfo name="Resolume Arena" majorVersion="7" minorVersion="23" microVersion="2" revision="51094"/>
  <ModifierEnvelope name="ModifierEnvelope" altName="Envelope" uniqueId="TIMESTAMP">
    <points>
      <point x="0" y="0" curve="1"/>
      <point x="1" y="0" curve="1"/>
    </points>
  </ModifierEnvelope>
</Preset>
```

### ShowKontrol .cue Export
```
HH:MM:SS:FF,HHMMSSFF,milliseconds,name,TAG,,,,,,
```
Line ending: `\r` only

### Project File (.cueproj)
JSON with tracks, playlists, cuePoints, duration, presetName.

---

## Notes

- **Deployment target**: macOS 14.0+
- **Swift version**: 5.9+
- **Framework**: SwiftUI + AppKit interop
- **Bundle ID**: com.cuesync.app
- **Team ID**: 3A3L2C6DFB (Amrit's)
