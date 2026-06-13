# CUE SYNC v1.0.1

Maintenance + feature release on top of v1.0.0. Universal binary, Developer-ID signed and Apple-notarized.

## What's new

### Y=0 import toggle (Project section, row 2)
New **Import Settings** control on the Project section header row. When set to **True**, every cue point imported from Rekordbox, Serato, Engine DJ, ShowKontrol, or a Resolume envelope gets its Y value zeroed automatically. Default is **False** (preserve source Y values). The setting persists across launches and only affects imports after it's flipped — existing tracks are not retroactively modified.

### Configure section toolbar alignment
Realigned the Track Duration / Cue Position / Add Cue Point / Offset Duplicate / Load Audio File row. The row now uses `.top` alignment with placeholder labels on the bare buttons, so every column lines up at the header row regardless of whether the column has a visible label. Removed the previous magic-number `.padding(.top, 18)` hacks.

### Gumroad licensing removed
The app is now a single open distribution. The previously bundled-but-disabled `LicenseManager` and `LicenseView` are gone, along with all the commented-out re-enable scaffolding in `CueSyncApp` and `ExportSectionView`. No demo mode, no purchase prompt, no Keychain lookups.

### Build & release pipeline
Added `scripts/build.sh`, `sign.sh`, `notarize.sh`, `make-dmg.sh`, `install.sh`, and `run.sh` covering the full Developer ID → notarized DMG flow. See `CLAUDE.md` → *Release build pipeline* for the one-shot command.

### Repo hygiene
Added MIT `LICENSE` and a `.gitignore` covering `build/`, `builds/`, `DerivedData/`, `xcuserdata/`, signing artifacts, and `.DS_Store`. README rewritten for GitHub (replaces the original spec-package README).

## Supported workflows
- **Imports:** Rekordbox XML, Serato (ID3 GEOB), Engine DJ (SQLite), ShowKontrol `.cue`, Resolume envelope XML
- **Exports:** Resolume Arena envelope XML (23 curve types), ShowKontrol `.cue` (30 fps, `\r` line endings)
- **Project files:** `.cueproj` (JSON)

## Compatibility
- macOS 14 Sonoma or later
- Apple Silicon + Intel (universal binary)

## Installation
1. Download `CueSync-v1.0.1.dmg`
2. Open the DMG, drag CueSync to Applications
3. Launch from Applications or Spotlight

The DMG is signed and notarized — no Gatekeeper warnings.

## Known notes
- After flipping the Import Settings toggle, re-import any tracks you want zeroed.
- `scripts/build-icon.sh` still references the GlEnc source paths it was adapted from; not used in this release.
