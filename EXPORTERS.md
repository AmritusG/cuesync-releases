# CUE SYNC - Export Specifications

Detailed specifications for generating export files. Includes exact output formats and generation algorithms.

---

## 1. Resolume Arena XML Export

### File Extension
`.xml`

### Target Application
Resolume Arena 7+ (tested with 7.23.2)

### Usage
Drag the exported XML file onto a clip's envelope parameter in Resolume Arena.

### Output Format

```xml
<?xml version="1.0" encoding="utf-8"?>
<Preset name="PRESET_NAME" uniqueId="MOD_ENVELOPE" className="Envelope" default="0">
	<versionInfo name="Resolume Arena" majorVersion="7" minorVersion="23" microVersion="2" revision="51094"/>
	<ModifierEnvelope name="ModifierEnvelope" altName="Envelope" uniqueId="UNIQUE_ID">
		<points>
			<point x="0.0" y="0.5" curve="1"/>
			<point x="0.333" y="1.0" curve="3"/>
			<point x="1.0" y="0.0" curve="1"/>
		</points>
	</ModifierEnvelope>
</Preset>
```

### Field Descriptions

| Field | Description |
|-------|-------------|
| `Preset/@name` | User-defined preset name |
| `Preset/@uniqueId` | Always "MOD_ENVELOPE" |
| `Preset/@className` | Always "Envelope" |
| `Preset/@default` | Always "0" |
| `versionInfo` | Resolume version info (cosmetic, can be hardcoded) |
| `ModifierEnvelope/@uniqueId` | Unique timestamp or random number |
| `point/@x` | Normalized time position (0.0 to 1.0) |
| `point/@y` | Normalized value (0.0 to 1.0) |
| `point/@curve` | Curve type ID (1-23) |

### Generation Algorithm

```pseudocode
function generateResolumeXml(cuePoints, trackDuration, presetName):
    if trackDuration <= 0:
        showError("Please set the track duration first.")
        return null
    
    // Convert cue points to envelope points
    envPoints = []
    for cue in cuePoints:
        if not cue.enabled:
            continue
        
        point = {
            x: cue.start / trackDuration,  // Normalize to 0-1
            y: cue.yValue / 100.0,          // Normalize to 0-1
            curve: cue.curve
        }
        envPoints.append(point)
    
    // CRITICAL: Resolume requires points at x=0 and x=1
    hasStartPoint = envPoints.any(p => p.x == 0)
    hasEndPoint = envPoints.any(p => p.x == 1)
    
    if not hasStartPoint:
        envPoints.prepend({ x: 0, y: 0, curve: 1 })
    
    if not hasEndPoint:
        envPoints.append({ x: 1, y: 0, curve: 1 })
    
    // Sort by x position
    envPoints.sortBy(p => p.x)
    
    // Generate XML
    uniqueId = currentTimestamp()
    
    pointsXml = ""
    for point in envPoints:
        pointsXml += '\t\t\t<point x="' + point.x + '" y="' + point.y + '" curve="' + point.curve + '"/>\n'
    
    xml = '<?xml version="1.0" encoding="utf-8"?>\n'
    xml += '<Preset name="' + escapeXml(presetName) + '" uniqueId="MOD_ENVELOPE" className="Envelope" default="0">\n'
    xml += '\t<versionInfo name="Resolume Arena" majorVersion="7" minorVersion="23" microVersion="2" revision="51094"/>\n'
    xml += '\t<ModifierEnvelope name="ModifierEnvelope" altName="Envelope" uniqueId="' + uniqueId + '">\n'
    xml += '\t\t<points>\n'
    xml += pointsXml
    xml += '\t\t</points>\n'
    xml += '\t</ModifierEnvelope>\n'
    xml += '</Preset>'
    
    return xml
```

### Important Notes

1. **x=0 and x=1 Required**: Resolume expects envelope points at the start and end. Always ensure these exist.

2. **Normalized Values**: Both x and y are 0.0-1.0 range. Divide time by duration, value by 100.

3. **Curve Types**: Must use exact Resolume curve IDs (1-23). See DATA_MODELS.md for full list.

4. **XML Encoding**: Use UTF-8. Escape special characters in preset name (`&` → `&amp;`, `<` → `&lt;`, etc.)

5. **Indentation**: Use tabs, not spaces, to match Resolume's native format.

### Sample Output

For a 60-second track with cues at 0s, 30s, 60s:

```xml
<?xml version="1.0" encoding="utf-8"?>
<Preset name="My Envelope" uniqueId="MOD_ENVELOPE" className="Envelope" default="0">
	<versionInfo name="Resolume Arena" majorVersion="7" minorVersion="23" microVersion="2" revision="51094"/>
	<ModifierEnvelope name="ModifierEnvelope" altName="Envelope" uniqueId="1709912345678">
		<points>
			<point x="0" y="0" curve="1"/>
			<point x="0.5" y="1" curve="1"/>
			<point x="1" y="0" curve="1"/>
		</points>
	</ModifierEnvelope>
</Preset>
```

---

## 2. ShowKontrol .cue Export

### File Extension
`.cue`

### Target Application
TC Supply ShowKontrol

### Usage
Import the .cue file into ShowKontrol for timecode-triggered automation.

### Output Format

CSV format with specific columns:

```
HH:MM:SS:FF,HHMMSSFF,milliseconds,name,TAG,,,,,,
```

### Field Descriptions

| Index | Field | Description |
|-------|-------|-------------|
| 0 | Timecode | `HH:MM:SS:FF` format (30fps) |
| 1 | Compact | Same timecode without colons: `HHMMSSFF` |
| 2 | Milliseconds | Position in milliseconds (integer) |
| 3 | Name | Cue name (commas replaced with spaces) |
| 4 | TAG | Always "TAG" |
| 5-10 | Reserved | Empty fields (for future use) |

### Line Ending
Use `\r` (carriage return only, not `\r\n`)

### Generation Algorithm

```pseudocode
function generateShowKontrolCue(cuePoints):
    if cuePoints.length == 0:
        return null
    
    lines = []
    
    for cue in cuePoints:
        if not cue.enabled:
            continue
        
        tc = secondsToTimecode(cue.start)
        
        // Clean cue name (remove commas to avoid CSV issues)
        cleanName = cue.name.replace(",", " ")
        if cleanName.isEmpty():
            cleanName = "CUE" + (index + 1)
        
        line = tc.formatted + "," +
               tc.compact + "," +
               tc.milliseconds + "," +
               cleanName + "," +
               "TAG,,,,,,"
        
        lines.append(line)
    
    return lines.join("\r")

function secondsToTimecode(seconds):
    totalFrames = round(seconds * 30)  // 30fps
    frames = totalFrames % 30
    
    totalSeconds = floor(totalFrames / 30)
    secs = totalSeconds % 60
    
    totalMinutes = floor(totalSeconds / 60)
    mins = totalMinutes % 60
    
    hours = floor(totalMinutes / 60)
    
    return {
        formatted: sprintf("%02d:%02d:%02d:%02d", hours, mins, secs, frames),
        compact: sprintf("%02d%02d%02d%02d", hours, mins, secs, frames),
        milliseconds: round(seconds * 1000)
    }
```

### Sample Output

For cues at 0s (Start), 90s (Drop), 180s (End):

```
00:00:00:00,00000000,0,Start,TAG,,,,,,
00:01:30:00,00013000,90000,Drop,TAG,,,,,,
00:03:00:00,00030000,180000,End,TAG,,,,,,
```

### Important Notes

1. **Frame Rate**: Always use 30fps for frame calculations.

2. **Milliseconds Field**: Must be integer, not decimal.

3. **Cue Names**: Replace commas with spaces to avoid breaking CSV.

4. **Line Ending**: Use `\r` only, not `\r\n` or `\n`.

5. **Empty Fields**: Trailing commas are required to maintain column count.

---

## 3. Project File Export (.cueproj / .cuesync)

### File Extension
`.cueproj` or `.cuesync`

### Format
JSON (UTF-8 encoded, pretty-printed)

### Schema

```json
{
  "version": "3.0",
  "name": "Project Name",
  "savedAt": "2026-03-16T12:30:00.000Z",
  "tracks": [
    {
      "id": "track-1",
      "name": "Track Name",
      "artist": "Artist",
      "album": "Album",
      "genre": "House",
      "totalTime": 300,
      "bpm": 128.0,
      "tonality": "Am",
      "location": "/path/to/file.mp3",
      "cuePoints": [
        {
          "id": "cue-1",
          "start": 0,
          "name": "Intro",
          "color": "rgb(30, 215, 96)",
          "yValue": 0,
          "curve": 1,
          "enabled": true
        }
      ]
    }
  ],
  "playlists": [
    {
      "id": "playlist-1",
      "name": "My Playlist",
      "type": "playlist",
      "trackIds": ["track-1", "track-2"],
      "children": []
    }
  ],
  "selectedTrackId": "track-1",
  "cuePoints": [
    {
      "id": "cue-1",
      "start": 0,
      "name": "Start",
      "color": "#1ed760",
      "yValue": 0,
      "curve": 1,
      "enabled": true
    }
  ],
  "trackDuration": 300,
  "presetName": "My Envelope"
}
```

### Generation Algorithm

```pseudocode
function saveProject(projectName, tracks, playlists, selectedTrack, cuePoints, trackDuration, presetName):
    projectData = {
        version: "3.0",
        name: projectName,
        savedAt: new Date().toISOString(),
        tracks: tracks,
        playlists: playlists,
        selectedTrackId: selectedTrack?.id or null,
        cuePoints: cuePoints,
        trackDuration: trackDuration,
        presetName: presetName
    }
    
    jsonString = JSON.stringify(projectData, null, 2)  // Pretty print with 2-space indent
    
    return jsonString
```

### Loading Algorithm

```pseudocode
function loadProject(jsonString):
    data = JSON.parse(jsonString)
    
    // Validate version
    if data.version != "3.0":
        showWarning("Project was created with a different version. Some features may not work correctly.")
    
    // Restore state
    setProjectName(data.name)
    setTracks(data.tracks)
    setPlaylists(data.playlists)
    setCuePoints(data.cuePoints)
    setTrackDuration(data.trackDuration)
    setPresetName(data.presetName)
    
    // Restore selected track
    if data.selectedTrackId:
        selectedTrack = findTrackById(data.tracks, data.selectedTrackId)
        setSelectedTrack(selectedTrack)
    
    setHasUnsavedChanges(false)
```

---

## Common Export Utilities

### XML Escaping

```pseudocode
function escapeXml(str):
    return str
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&apos;")
```

### Filename Sanitization

```pseudocode
function sanitizeFilename(name):
    // Remove or replace characters not allowed in filenames
    return name.replace(/[^a-zA-Z0-9\-_ ]/g, "_")
```

### Default Filename Generation

```pseudocode
function getDefaultFilename(presetName, extension):
    sanitized = sanitizeFilename(presetName)
    if sanitized.isEmpty():
        sanitized = "envelope"
    return sanitized + "." + extension
```

---

## File Save Dialogs

### Native macOS (Cocoa)

```pseudocode
function showSaveDialog(suggestedFilename, allowedExtensions):
    panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedFilename
    panel.allowedContentTypes = allowedExtensions.map(ext => UTType(filenameExtension: ext))
    
    result = panel.runModal()
    if result == .OK:
        return panel.url
    return null
```

### Electron

```javascript
const { dialog } = require('electron');

async function showSaveDialog(suggestedFilename, filters) {
  const result = await dialog.showSaveDialog({
    defaultPath: suggestedFilename,
    filters: filters  // e.g., [{ name: 'XML', extensions: ['xml'] }]
  });
  return result.filePath;
}
```

---

## Validation Before Export

### Resolume XML

```pseudocode
function validateForResolumeExport(cuePoints, trackDuration):
    errors = []
    
    if trackDuration <= 0:
        errors.append("Track duration must be greater than 0")
    
    enabledPoints = cuePoints.filter(p => p.enabled)
    if enabledPoints.length < 2:
        errors.append("At least 2 enabled cue points required")
    
    return errors
```

### ShowKontrol .cue

```pseudocode
function validateForShowKontrolExport(cuePoints):
    errors = []
    
    enabledPoints = cuePoints.filter(p => p.enabled)
    if enabledPoints.length == 0:
        errors.append("At least 1 enabled cue point required")
    
    return errors
```
