# CueSync

**Bridge your DJ cue points to VJ and lighting control.**

CueSync is a native macOS app that imports cue points from DJ software and exports them as automation envelopes for visual performance tools. Stop manually recreating your track markers — sync them in seconds.

---

## What It Does

```
┌─────────────────┐      ┌──────────┐      ┌────────────────────┐
│  DJ Software    │ ───▶ │ CueSync  │ ───▶ │  VJ / Lighting     │
│                 │      │          │      │                    │
│  • Rekordbox    │      │  Import  │      │  • Resolume Arena  │
│  • Serato DJ    │      │  Map     │      │  • ShowKontrol     │
│  • Engine DJ    │      │  Export  │      │                    │
└─────────────────┘      └──────────┘      └────────────────────┘
```

**Import** cue points with their labels, colors, and positions from your DJ library. **Map** them to automation curves. **Export** ready-to-use envelope files that drop directly into your VJ software.

---

## Features

### Import Sources

#### Rekordbox
| Item | Details |
|------|---------|
| **Format** | XML library export |
| **How to export** | Rekordbox → File → Export Collection in xml format |
| **Default location** | User-selected (no fixed path) |
| **What's imported** | Memory cues, hot cues, loops with labels and colors |

#### Serato DJ
| Item | Details |
|------|---------|
| **Format** | ID3 GEOB tags embedded in audio files |
| **Library location** | `~/Music/_Serato_/` |
| **Database files** | `~/Music/_Serato_/Serato DJ Pro/History/` (session history) |
| **Crate files** | `~/Music/_Serato_/Subcrates/*.crate` |
| **How it works** | Serato stores cue points directly in MP3/FLAC/etc files as ID3v2 GEOB (General Encapsulated Object) tags. CueSync reads the `Serato Markers2` tag from each audio file. |
| **What's imported** | Hot cues (up to 8), loops, saved loops, track color |

> **Note:** Serato doesn't use a central database for cue points — they travel with the audio files. Point CueSync at a folder of tracks, and it reads each file's embedded markers.

#### Engine DJ (Denon)
| Item | Details |
|------|---------|
| **Format** | SQLite database |
| **Library location** | `~/Music/Engine Library/` |
| **Database file** | `~/Music/Engine Library/Database2/m.db` |
| **USB/SD export** | `[USB]/Engine Library/Database2/m.db` |
| **Tables used** | `Track`, `CuePoint`, `Loop`, `Playlist`, `PlaylistTrack` |
| **How it works** | CueSync reads the `m.db` SQLite database directly. For USB drives prepared with Engine DJ Desktop, the database is at the drive root under `Engine Library/`. |
| **What's imported** | Hot cues (up to 8), memory cues, loops, track metadata |

> **Engine DJ versions:** The `Database2/m.db` path applies to Engine DJ 2.x and later. Older Engine Prime used `Database/m.db`. CueSync checks both locations.

---

### Export Targets
| Target | Format | Notes |
|--------|--------|-------|
| **Resolume Arena** | `.xml` envelope | 23 curve types, normalized coordinates |
| **ShowKontrol** | `.cue` file | 30fps timecode, lighting automation |

### Curve Types
CueSync supports all 23 Resolume envelope curve types:

| ID | Curve | ID | Curve | ID | Curve |
|----|-------|----|-------|----|-------|
| 1 | Hold | 9 | Sine In | 17 | Back In |
| 2 | Linear | 10 | Sine Out | 18 | Back Out |
| 3 | Smooth | 11 | Sine In/Out | 19 | Back In/Out |
| 4 | Quad In | 12 | Expo In | 20 | Elastic In |
| 5 | Quad Out | 13 | Expo Out | 21 | Elastic Out |
| 6 | Quad In/Out | 14 | Expo In/Out | 22 | Elastic In/Out |
| 7 | Cubic In | 15 | Circ In | 23 | Bounce |
| 8 | Cubic Out | 16 | Circ Out | | |

---

## Installation

### Requirements
- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

### Download
1. Download `CueSync-x.x.x.dmg` from [Releases](../../releases)
2. Open the DMG and drag CueSync to Applications
3. Launch from Applications folder

> The app is signed and notarized by Apple. No Gatekeeper warnings.

---

## Quick Start

### 1. Import Your DJ Library

**Rekordbox:**
1. In Rekordbox: File → Export Collection in xml format
2. In CueSync: Click **Browse** → select your `.xml` file
3. Your tracks and cue points appear in the list

**Serato DJ:**
1. In CueSync: Click **Browse** → navigate to `~/Music/_Serato_/` or select a folder of tracks
2. CueSync scans audio files for embedded Serato markers
3. Tracks with cue points appear in the list

**Engine DJ:**
1. In CueSync: Click **Browse** → navigate to `~/Music/Engine Library/`
   - Or select a USB/SD card with Engine DJ export at its root
2. CueSync reads the `Database2/m.db` SQLite file
3. All tracks with cue points appear in the list

### 2. Configure Mapping

- Select which cue types to include (memory cues, hot cues, loops)
- Choose default curve type for transitions
- Set envelope duration and timing

### 3. Export

**For Resolume Arena:**
1. Select tracks to export
2. Click **Export → Resolume Envelope**
3. Drop the `.xml` file into Resolume's clip envelope editor

**For ShowKontrol:**
1. Click **Export → ShowKontrol**
2. Import the `.cue` file in ShowKontrol

---

## File Formats

### Resolume Envelope (`.xml`)
```xml
<Envelope>
  <Point x="0.0" y="0.0" curve="2"/>
  <Point x="0.25" y="1.0" curve="3"/>
  <Point x="1.0" y="0.0" curve="1"/>
</Envelope>
```
- `x`: Position (0.0–1.0, normalized to clip length)
- `y`: Value (0.0–1.0)
- `curve`: Curve type ID (1–23)

### ShowKontrol (`.cue`)
```
00:00:00:00	CUE1	Start
00:01:15:00	CUE2	Drop
00:03:30:00	CUE3	Breakdown
```
- Timecode at 30fps
- Tab-separated fields
- `\r` line endings (macOS Classic format — required by ShowKontrol)

### Project (`.cueproj`)
CueSync saves your work as `.cueproj` files (JSON format). These store:
- Import source paths
- Track selections
- Mapping configuration
- Export settings

---

## Workflow Examples

### DJ Set Preparation
1. Export your set's playlist from Rekordbox
2. Import into CueSync
3. Export Resolume envelopes for each track
4. In Arena: load clips, apply envelopes to opacity/effects
5. Cues now trigger visual changes automatically during your set

### Lighting Sync
1. Import cue points from your DJ software
2. Export ShowKontrol `.cue` file
3. Import into ShowKontrol timeline
4. Map cues to DMX fixtures
5. Lights follow your track structure

---

## Troubleshooting

### Serato: "No cue points found"
- Serato stores cues in the audio files themselves, not a database
- Make sure you're pointing at the actual audio files, not the `_Serato_` folder
- Re-analyze tracks in Serato DJ Pro to ensure cues are saved

### Engine DJ: "Database not found"
- Check for `Database2/m.db` inside `Engine Library/`
- Older Engine Prime versions use `Database/m.db` — CueSync checks both
- For USB drives: the `Engine Library/` folder must be at the drive root

### Rekordbox: "Invalid XML"
- Use File → Export Collection in xml format (not "Export playlist")
- Ensure the XML file is complete (not truncated mid-export)

---

## Building from Source

```bash
git clone https://github.com/AmritusG/cuesync-releases.git
cd cuesync-releases

# Build
xcodebuild -project CueSync/CueSync.xcodeproj \
    -scheme CueSync \
    -configuration Release

# Or open in Xcode
open CueSync/CueSync.xcodeproj
```

See [RELEASE.md](RELEASE.md) for signing and notarization.

---

## License

MIT License — see [LICENSE](LICENSE)

---

## Author

Built by [Amrit Rosell](https://github.com/AmritusG) for the VJ and live visual community.

Part of a toolkit including [GlEnc](https://github.com/AmritusG/glenc) (DXV3/HAP encoder), Glance, and other Resolume workflow tools.
