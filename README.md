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
| Source | Format | Notes |
|--------|--------|-------|
| **Rekordbox** | XML library export | Memory cues, hot cues, loops |
| **Serato DJ** | Library files | ID3 GEOB tag parsing |
| **Engine DJ** | Database | Direct SQLite read |

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

**Serato / Engine DJ:**
- Point CueSync at your Serato or Engine DJ library folder
- Tracks are read directly from the database

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
- `\r` line endings (macOS Classic format)

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
