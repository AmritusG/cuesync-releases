# CUE SYNC - Data Models

All data structures used in the application. Presented in a language-agnostic format with Swift/ObjC type hints.

---

## Core Models

### CuePoint
Represents a single automation point on the envelope.

```
CuePoint {
    id: String              // Unique identifier (UUID)
    start: Double           // Time position in seconds (e.g., 45.500)
    name: String            // Display name (e.g., "Drop", "Verse 1")
    color: String           // CSS color string (e.g., "rgb(255, 0, 0)" or "#ff0000")
    yValue: Double          // Value 0-100 (displayed as percentage)
    curve: Int              // Curve type ID (1-23, see CURVE_TYPES)
    enabled: Bool           // Whether this point is included in export
}
```

**Notes:**
- When exporting to Resolume, `start` is normalized to 0.0-1.0 by dividing by track duration
- When exporting to Resolume, `yValue` is normalized to 0.0-1.0 by dividing by 100
- `color` is for visual display only, not exported

---

### Track
Represents an audio track from a DJ library.

```
Track {
    id: String              // Unique identifier
    name: String            // Track title
    artist: String          // Artist name
    album: String           // Album name
    genre: String           // Genre
    totalTime: Int          // Duration in seconds
    bpm: Double             // Beats per minute
    tonality: String        // Musical key (e.g., "Am", "C#m")
    location: String        // File path on disk
    cuePoints: [CuePoint]   // Array of cue points for this track
}
```

**Source Mapping:**

| Field | Rekordbox XML | Serato ID3 | Engine DJ SQLite |
|-------|---------------|------------|------------------|
| id | TrackID | generated | id |
| name | Name | TIT2 tag | title |
| artist | Artist | TPE1 tag | artist |
| album | Album | TALB tag | album |
| totalTime | TotalTime | calculated | length |
| bpm | AverageBpm | - | bpmAnalyzed |
| tonality | Tonality | - | key (mapped) |
| cuePoints | POSITION_MARK | GEOB Serato Markers2 | PerformanceData.quickCues |

---

### Playlist
Represents a playlist or folder in the library hierarchy.

```
Playlist {
    id: String              // Unique identifier
    name: String            // Playlist name
    type: String            // "folder" or "playlist"
    trackIds: [String]      // Array of track IDs in this playlist
    children: [Playlist]    // Nested playlists/folders (for folders)
}
```

---

### Project
The main project container saved to disk.

```
Project {
    version: String         // Project file format version (e.g., "1.0")
    name: String            // Project name
    tracks: [Track]         // All loaded tracks
    playlists: [Playlist]   // Playlist hierarchy
    
    // Current envelope state
    currentTrackId: String? // ID of selected track (or null for manual envelope)
    envelopeMode: Bool      // True if creating envelope from scratch
    cuePoints: [CuePoint]   // Current working cue points
    trackDuration: Double   // Duration in seconds
    presetName: String      // Name for export
    
    // UI state (optional, for restoring session)
    theme: String           // "dark" or "light"
    collapsedSections: [String]  // IDs of collapsed sections
}
```

**File Extension:** `.cueproj`  
**Format:** JSON (UTF-8 encoded)

---

## Enumerations

### CurveType
All 23 curve types matching Resolume Arena exactly.

```
CURVE_TYPES = [
    { id: 1,  name: "Linear",           category: "Basic" },
    { id: 2,  name: "Quadratic In",     category: "Quadratic" },
    { id: 3,  name: "Quadratic Out",    category: "Quadratic" },
    { id: 4,  name: "Quadratic In/Out", category: "Quadratic" },
    { id: 5,  name: "Sine In",          category: "Sine" },
    { id: 6,  name: "Sine Out",         category: "Sine" },
    { id: 7,  name: "Sine In/Out",      category: "Sine" },
    { id: 8,  name: "Circular In",      category: "Circular" },
    { id: 9,  name: "Circular Out",     category: "Circular" },
    { id: 10, name: "Circular In/Out",  category: "Circular" },
    { id: 11, name: "Exponential In",   category: "Exponential" },
    { id: 12, name: "Exponential Out",  category: "Exponential" },
    { id: 13, name: "Exponential In/Out", category: "Exponential" },
    { id: 14, name: "Elastic In",       category: "Elastic" },
    { id: 15, name: "Elastic Out",      category: "Elastic" },
    { id: 16, name: "Elastic In/Out",   category: "Elastic" },
    { id: 17, name: "Back In",          category: "Back" },
    { id: 18, name: "Back Out",         category: "Back" },
    { id: 19, name: "Back In/Out",      category: "Back" },
    { id: 20, name: "Bounce In",        category: "Bounce" },
    { id: 21, name: "Bounce Out",       category: "Bounce" },
    { id: 22, name: "Bounce In/Out",    category: "Bounce" },
    { id: 23, name: "Hold",             category: "Basic" }
]
```

**Category Order for Grouped Display:**
1. Basic (Linear, Hold)
2. Quadratic
3. Sine
4. Circular
5. Exponential
6. Elastic
7. Back
8. Bounce

---

### AudioStatus
State of audio file loading for duration detection.

```
AudioStatus = "idle" | "loading" | "ready" | "error"
```

---

### Theme
Application color scheme.

```
Theme = "dark" | "light"
```

---

## UI State Models

### SectionState
State for collapsible sections.

```
SectionState {
    id: String              // Section identifier
    isCollapsed: Bool       // Whether section is collapsed
    order: Int              // Position in layout (1-4)
}
```

**Section IDs:**
- `"project"` — Section 1: PROJECT
- `"browse"` — Section 2: BROWSE AUDIO
- `"configure"` — Section 3: CONFIGURE ENVELOPE
- `"export"` — Section 4: EXPORT

---

### EnvelopeEditorState
State for the envelope canvas interaction.

```
EnvelopeEditorState {
    selectedPointIndex: Int?    // Index of selected cue point (or null)
    isDragging: Bool            // Currently dragging a point
    lockXAxis: Bool             // Prevent horizontal movement
    lockYAxis: Bool             // Prevent vertical movement
}
```

---

### BrowserState
State for the track browser.

```
BrowserState {
    selectedPlaylist: String    // "all" or playlist ID
    searchQuery: String         // Current search text
    sortBy: String              // "name", "artist", "album", "bpm", "duration", "cues"
    expandedFolders: [String]   // IDs of expanded playlist folders
    hoveredTrack: String?       // ID of track being hovered
}
```

---

## Import/Export Models

### ResolumePoint
Point format for Resolume XML export.

```
ResolumePoint {
    x: Double       // Normalized position (0.0 - 1.0)
    y: Double       // Normalized value (0.0 - 1.0)
    curve: Int      // Curve type ID (1-23)
}
```

**Conversion from CuePoint:**
```
resolumePoint.x = cuePoint.start / trackDuration
resolumePoint.y = cuePoint.yValue / 100.0
resolumePoint.curve = cuePoint.curve
```

---

### ShowKontrolCue
Cue format for ShowKontrol .cue export.

```
ShowKontrolCue {
    timecode: String        // "HH:MM:SS:FF" format (30fps assumed)
    compact: Int            // Always 0
    milliseconds: Int       // Position in milliseconds
    name: String            // Cue name
    tag: String             // Always "TAG"
    commands: String        // Empty string (reserved for future)
}
```

**Conversion from CuePoint:**
```
totalMs = cuePoint.start * 1000
hours = floor(totalMs / 3600000)
minutes = floor((totalMs % 3600000) / 60000)
seconds = floor((totalMs % 60000) / 1000)
frames = floor((totalMs % 1000) / 33.33)  // 30fps
timecode = sprintf("%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
milliseconds = floor(totalMs)
```

---

## Default Values

```
DEFAULT_CUE_POINT = {
    id: generateUUID(),
    start: 0,
    name: "",
    color: "#1ed760",       // Accent green
    yValue: 0,
    curve: 1,               // Linear
    enabled: true
}

DEFAULT_TRACK_DURATION = 60.0   // 60 seconds

DEFAULT_PRESET_NAME = "New Envelope"

DEFAULT_PROJECT_NAME = "Untitled Project"
```

---

## Validation Rules

### CuePoint
- `start` must be >= 0 and <= trackDuration
- `yValue` must be >= 0 and <= 100
- `curve` must be between 1 and 23
- First point should have `start` = 0 (for Resolume compatibility)
- Last point should have `start` = trackDuration (for Resolume compatibility)

### Track
- `totalTime` must be > 0
- `cuePoints` should be sorted by `start` ascending

### Export
- Must have at least 2 cue points (start and end)
- Points must be sorted by time
- Only enabled points are exported
