# CUE SYNC - Parser Specifications

Detailed specifications for parsing each import format. Includes file structure, parsing algorithm, and sample data.

---

## 1. Rekordbox XML Parser

### File Extension
`.xml`

### Source Location
Exported from Rekordbox via: **File → Export Collection in xml format**

### File Structure
```xml
<?xml version="1.0" encoding="UTF-8"?>
<DJ_PLAYLISTS Version="1.0.0">
  <PRODUCT Name="rekordbox" Version="6.x.x" />
  <COLLECTION Entries="123">
    <TRACK TrackID="1" Name="Track Name" Artist="Artist" Album="Album" 
           Genre="House" TotalTime="300" AverageBpm="128.00" 
           Tonality="Am" Location="file://localhost/path/to/file.mp3">
      <POSITION_MARK Name="Intro" Type="0" Start="0.000" Red="40" Green="226" Blue="20"/>
      <POSITION_MARK Name="Drop" Type="0" Start="64.500" Red="255" Green="0" Blue="0"/>
    </TRACK>
    <!-- More tracks... -->
  </COLLECTION>
  <PLAYLISTS>
    <NODE Type="0" Name="ROOT">
      <NODE Type="0" Name="Folder Name">
        <NODE Type="1" Name="Playlist Name" KeyType="0" Entries="5">
          <TRACK Key="1"/>
          <TRACK Key="2"/>
        </NODE>
      </NODE>
    </NODE>
  </PLAYLISTS>
</DJ_PLAYLISTS>
```

### Parsing Algorithm

```pseudocode
function parseRekordboxXml(xmlString):
    doc = parseXML(xmlString)
    
    // Parse tracks
    tracks = []
    for each TRACK in doc.querySelectorAll("COLLECTION > TRACK"):
        track = {
            id: TRACK.getAttribute("TrackID"),
            name: TRACK.getAttribute("Name") or "Unknown Track",
            artist: TRACK.getAttribute("Artist") or "",
            album: TRACK.getAttribute("Album") or "",
            genre: TRACK.getAttribute("Genre") or "",
            totalTime: parseInt(TRACK.getAttribute("TotalTime")) or 0,
            bpm: parseFloat(TRACK.getAttribute("AverageBpm")) or 0,
            tonality: TRACK.getAttribute("Tonality") or "",
            location: decodeURIComponent(TRACK.getAttribute("Location").replace("file://localhost", "")),
            cuePoints: []
        }
        
        for each POSITION_MARK in TRACK.querySelectorAll("POSITION_MARK"):
            cue = {
                id: generateUUID(),
                start: parseFloat(POSITION_MARK.getAttribute("Start")) or 0,
                name: POSITION_MARK.getAttribute("Name") or "",
                color: rgb(
                    POSITION_MARK.getAttribute("Red") or 255,
                    POSITION_MARK.getAttribute("Green") or 0,
                    POSITION_MARK.getAttribute("Blue") or 0
                ),
                yValue: 100.0,
                curve: 1,  // Linear default
                enabled: true
            }
            track.cuePoints.append(cue)
        
        track.cuePoints.sortBy(cue => cue.start)
        tracks.append(track)
    
    // Parse playlists
    playlists = parsePlaylists(doc)
    
    return { tracks, playlists }

function parsePlaylists(doc):
    playlists = []
    rootNode = doc.querySelector("PLAYLISTS > NODE")
    
    function parseNode(node):
        type = node.getAttribute("Type")
        name = node.getAttribute("Name")
        
        if type == "0":  // Folder
            folder = {
                id: generateUUID(),
                name: name,
                type: "folder",
                trackIds: [],
                children: []
            }
            for each childNode in node.children:
                if childNode.tagName == "NODE":
                    folder.children.append(parseNode(childNode))
            return folder
        
        else if type == "1":  // Playlist
            playlist = {
                id: generateUUID(),
                name: name,
                type: "playlist",
                trackIds: [],
                children: []
            }
            for each trackRef in node.querySelectorAll("TRACK"):
                playlist.trackIds.append(trackRef.getAttribute("Key"))
            return playlist
    
    for each childNode in rootNode.children:
        playlists.append(parseNode(childNode))
    
    return playlists
```

### Sample Test File
See: `reference/sample-rekordbox.xml`

---

## 2. Serato DJ Parser

### Supported File Extensions
`.mp3`, `.aif`, `.aiff`, `.wav`, `.flac`, `.m4a`

### Storage Location
Serato stores cue points **inside the audio file** as ID3v2 GEOB (General Encapsulated Object) tags.

### Tag Structure

**Tag Name:** `Serato Markers2`  
**MIME Type:** `application/octet-stream`

**Binary Format:**
```
Byte 0-1: Version header (0x01 0x01)
Then repeating entries:
  - Entry type (null-terminated string): "CUE", "LOOP", "BPMLOCK", etc.
  - Payload length (4 bytes, big-endian)
  - Payload data
```

**CUE Payload Format (13+ bytes):**
```
Byte 0:    Always 0x00
Byte 1:    Cue index (0-7)
Byte 2-5:  Position in milliseconds (big-endian uint32)
Byte 6:    Always 0x00
Byte 7-9:  RGB color (R, G, B)
Byte 10:   Always 0x00
Byte 11+:  Name (null-terminated UTF-8 string)
```

### Parsing Algorithm

```pseudocode
function parseSeratoFile(file):
    data = readBinaryFile(file)
    extension = getFileExtension(file)
    
    // Extract metadata and Serato tag based on file type
    if extension in ["mp3", "aif", "aiff"]:
        markers2Data = parseID3v2(data).getGEOB("Serato Markers2")
    else if extension == "wav":
        markers2Data = parseWAVSeratoTags(data)
    else if extension == "flac":
        markers2Data = parseFLACVorbisComment(data).get("SERATO_MARKERS_V2")
    else if extension in ["m4a", "mp4"]:
        markers2Data = parseMP4SeratoAtoms(data)
    
    if markers2Data == null:
        return null
    
    cuePoints = parseSeratoMarkers2(markers2Data)
    return cuePoints

function parseSeratoMarkers2(data):
    cuePoints = []
    
    // Data may be base64 encoded
    if data starts with 0x01 0x01:
        stream = data
    else:
        // Try base64 decode
        stream = base64Decode(stripNullsAndNewlines(data))
        if stream[0:2] != [0x01, 0x01]:
            return []
    
    pos = 2  // Skip version header
    
    while pos < stream.length - 4:
        // Read entry type (null-terminated)
        entryType = readNullTerminatedString(stream, pos)
        pos += entryType.length + 1
        
        // Read payload length (big-endian uint32)
        payloadLength = readBigEndianUint32(stream, pos)
        pos += 4
        
        if payloadLength <= 0 or pos + payloadLength > stream.length:
            break
        
        payload = stream[pos : pos + payloadLength]
        pos += payloadLength
        
        if entryType == "CUE" and payloadLength >= 13:
            cue = {
                id: generateUUID(),
                start: readBigEndianUint32(payload, 2) / 1000.0,  // ms to seconds
                name: readNullTerminatedString(payload, 11) or "Cue " + (payload[1] + 1),
                color: rgb(payload[7], payload[8], payload[9]),
                yValue: 100.0,
                curve: 1,
                enabled: true
            }
            cuePoints.append(cue)
    
    cuePoints.sortBy(cue => cue.start)
    return cuePoints
```

### Serato Default Colors
```
Index 0: #CC0000 (Red)
Index 1: #CC8800 (Orange)
Index 2: #CCCC00 (Yellow)
Index 3: #00CC00 (Green)
Index 4: #00CCCC (Cyan)
Index 5: #0000CC (Blue)
Index 6: #CC00CC (Purple)
Index 7: #CC0088 (Pink)
```

---

## 3. Engine DJ Parser

### File Location
`~/Music/Engine Library/Database2/m.db`

### File Type
SQLite database

### Relevant Tables

**Track table:**
```sql
CREATE TABLE Track (
    id INTEGER PRIMARY KEY,
    title TEXT,
    artist TEXT,
    album TEXT,
    genre TEXT,
    length INTEGER,  -- Duration in seconds
    bpmAnalyzed REAL,
    key INTEGER,     -- Numeric key code
    path TEXT,
    filename TEXT
);
```

**PerformanceData table:**
```sql
CREATE TABLE PerformanceData (
    trackId INTEGER,
    quickCues BLOB  -- Compressed cue data
);
```

### quickCues BLOB Format

**Structure:**
```
Byte 0-3:  Uncompressed size (little-endian uint32)
Byte 4+:   Zlib-compressed data
```

**Decompressed Format:**
```
Byte 0-7:  Header (last byte = number of cue slots)
Then 8 cue slots, each:
  Byte 0:      Name length (0 = empty slot)
  Byte 1-N:    Name (UTF-8)
  Byte N+1-8:  Position (big-endian float64, samples at 44100 Hz)
  Byte +4:     Unknown/padding
```

### Parsing Algorithm

```pseudocode
function parseEngineDJDatabase(dbFile):
    db = openSQLite(dbFile)
    
    // Load tracks
    tracks = []
    for row in db.exec("SELECT * FROM Track"):
        track = {
            id: "engine-" + row.id,
            name: row.title or row.filename or "Unknown",
            artist: row.artist or "",
            album: row.album or "",
            genre: row.genre or "",
            totalTime: row.length or 0,
            bpm: row.bpmAnalyzed or 0,
            tonality: mapEngineKeyToName(row.key),
            location: row.path + row.filename,
            cuePoints: [],
            engineTrackId: row.id
        }
        tracks.append(track)
    
    // Load cue points
    for row in db.exec("SELECT trackId, quickCues FROM PerformanceData"):
        track = findTrackByEngineId(tracks, row.trackId)
        if track == null or row.quickCues == null:
            continue
        
        // Decompress
        uncompressedSize = readLittleEndianUint32(row.quickCues, 0)
        compressed = row.quickCues[4:]
        decompressed = zlibInflate(compressed)
        
        // Parse cue slots
        pos = 8  // Skip header
        cueIndex = 0
        
        while pos < decompressed.length - 12:
            nameLen = decompressed[pos]
            
            if nameLen == 0:
                // Empty slot - skip 13 bytes
                pos += 13
                cueIndex++
                continue
            
            name = readUTF8(decompressed, pos + 1, nameLen)
            pos += 1 + nameLen
            
            // Position as big-endian float64 (samples at 44100 Hz)
            positionSamples = readBigEndianFloat64(decompressed, pos)
            positionSeconds = positionSamples / 44100.0
            pos += 8
            
            // Skip unknown bytes
            pos += 4
            
            cue = {
                id: generateUUID(),
                start: positionSeconds,
                name: name or "Cue " + (cueIndex + 1),
                color: ENGINE_CUE_COLORS[cueIndex % 8],
                yValue: 100.0,
                curve: 1,
                enabled: true
            }
            track.cuePoints.append(cue)
            cueIndex++
        
        track.cuePoints.sortBy(cue => cue.start)
    
    return tracks
```

### Engine DJ Cue Colors
```
Index 0: #F4D338 (Yellow)
Index 1: #EF8130 (Orange)
Index 2: #AA55C4 (Purple)
Index 3: #CE3239 (Red)
Index 4: #86C64B (Green)
Index 5: #20C670 (Teal)
Index 6: #00A8A9 (Cyan)
Index 7: #1571E2 (Blue)
```

---

## 4. ShowKontrol Parser

### File Extension
`.cue`

### File Format
CSV (comma-separated values)

### Line Format
```
HH:MM:SS:FF,compact,milliseconds,name,TAG,commands,,,,,
```

**Fields:**
1. Timecode (`HH:MM:SS:FF`) — Hours:Minutes:Seconds:Frames (30fps)
2. Compact — Always 0
3. Milliseconds — Position in milliseconds (integer)
4. Name — Cue name
5. TAG — Always "TAG"
6. Commands — Empty or ShowKontrol commands

### Special Cases

**CUE0 at position 0:**  
If a cue named "CUE0" exists at position 0, and field 5 contains a time (not "TAG"), that time represents the track duration.

**Format for duration in field 5:** `MM:SS` or `MM:SS:MS`

### Parsing Algorithm

```pseudocode
function parseShowKontrolCue(content):
    lines = content.split("\n")
    cuePoints = []
    maxTimeMs = 0
    cue0DurationMs = null
    
    for line in lines:
        if line.isEmpty() or line.startsWith("\r") or line.startsWith("\n"):
            continue
        
        parts = splitCSV(line)
        if parts.length < 4:
            continue
        
        timecode = parts[0]
        milliseconds = parseInt(parts[2]) or 0
        cueName = parts[3] or "Cue " + (cuePoints.length + 1)
        tagOrTime = parts[4] if parts.length > 4 else ""
        
        // Check for CUE0 duration info
        if cueName == "CUE0" and tagOrTime != "TAG" and tagOrTime != "":
            parsedDuration = parseDurationString(tagOrTime)
            if parsedDuration > 0:
                cue0DurationMs = parsedDuration
        
        // Track max time
        if milliseconds > maxTimeMs:
            maxTimeMs = milliseconds
        
        // Skip CUE0 at position 0 (it's metadata, not a real cue)
        if cueName == "CUE0" and milliseconds == 0:
            continue
        
        cue = {
            id: generateUUID(),
            start: milliseconds / 1000.0,
            name: cueName,
            color: "#ef288a",  // ShowKontrol pink
            yValue: 0,
            curve: 1,
            enabled: true
        }
        cuePoints.append(cue)
    
    // Add Start cue if not present
    hasStartCue = cuePoints.any(cue => cue.start == 0)
    if not hasStartCue and cuePoints.length > 0:
        cuePoints.prepend({
            id: generateUUID(),
            start: 0,
            name: "Start",
            color: "#ef288a",
            yValue: 0,
            curve: 1,
            enabled: true
        })
    
    cuePoints.sortBy(cue => cue.start)
    
    // Determine suggested duration
    suggestedDuration = cue0DurationMs if cue0DurationMs != null else 60000
    
    return {
        cuePoints: cuePoints,
        suggestedDurationMs: suggestedDuration
    }

function parseDurationString(str):
    // Try MM:SS:MS format
    match = regex("^(\d+):(\d{2}):(\d+)$").match(str)
    if match:
        minutes = parseInt(match[1])
        seconds = parseInt(match[2])
        ms = parseInt(match[3])
        return (minutes * 60 + seconds) * 1000 + ms
    
    // Try MM:SS format
    match = regex("^(\d+):(\d{2})$").match(str)
    if match:
        minutes = parseInt(match[1])
        seconds = parseInt(match[2])
        return (minutes * 60 + seconds) * 1000
    
    return -1
```

### Sample Test File
```
00:00:00:00,0,0,CUE0,3:30,
00:00:05:00,0,5000,Intro,TAG,
00:01:00:00,0,60000,Verse,TAG,
00:02:30:00,0,150000,Chorus,TAG,
00:03:30:00,0,210000,End,TAG,
```

---

## 5. Resolume Envelope Parser

### File Extension
`.xml`

### File Format
Resolume Arena envelope preset XML

### File Structure
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Preset name="Envelope Name">
  <point x="0.0" y="0.5" curve="1" />
  <point x="0.333" y="1.0" curve="3" />
  <point x="0.666" y="0.0" curve="1" />
  <point x="1.0" y="0.5" curve="1" />
</Preset>
```

**Attributes:**
- `x` — Normalized position (0.0 to 1.0)
- `y` — Normalized value (0.0 to 1.0)
- `curve` — Curve type ID (1-23)

### Parsing Algorithm

```pseudocode
function parseResolumeEnvelope(xmlContent):
    doc = parseXML(xmlContent)
    
    // Get preset name
    presetElement = doc.querySelector("Preset")
    presetName = presetElement.getAttribute("name") or "Imported Envelope"
    
    // Parse points
    points = []
    for each pointElement in doc.querySelectorAll("point"):
        point = {
            x: parseFloat(pointElement.getAttribute("x")) or 0,
            y: parseFloat(pointElement.getAttribute("y")) or 0,
            curve: parseInt(pointElement.getAttribute("curve")) or 1
        }
        points.append(point)
    
    points.sortBy(point => point.x)
    
    return {
        presetName: presetName,
        points: points
    }

function convertToCuePoints(points, durationSeconds):
    cuePoints = []
    
    for i, point in enumerate(points):
        cue = {
            id: generateUUID(),
            start: point.x * durationSeconds,
            name: "Start" if i == 0 else ("End" if i == points.length - 1 else "Point " + i),
            color: "#ffd700",  // Gold for Resolume imports
            yValue: point.y * 100.0,
            curve: point.curve,
            enabled: true
        }
        cuePoints.append(cue)
    
    return cuePoints
```

### Note on Duration
Resolume envelope files do **not** contain duration information. When importing, the user must specify the target duration. The `x` values (0.0 to 1.0) are then multiplied by this duration to get absolute times.

---

## Common Utilities

### UUID Generation
```pseudocode
function generateUUID():
    return random hex string of 8-16 characters
    // Example: "a1b2c3d4" or "a1b2c3d4-e5f6"
```

### RGB Color Formatting
```pseudocode
function rgb(r, g, b):
    return "rgb(" + r + ", " + g + ", " + b + ")"
    // Example: "rgb(255, 0, 0)"
```

### Big-Endian Integer Reading
```pseudocode
function readBigEndianUint32(data, offset):
    return (data[offset] << 24) | 
           (data[offset+1] << 16) | 
           (data[offset+2] << 8) | 
           data[offset+3]
```
