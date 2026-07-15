# CUE SYNC - Application Specification

**Version:** 1.0  
**Last Updated:** March 2026  
**Target Platform:** Native macOS (Cocoa/AppKit)

---

## Overview

CUE SYNC is a desktop application that converts cue points from DJ software into envelope automation curves for Resolume Arena and ShowKontrol. It bridges the gap between DJ software (Rekordbox, Serato, Engine DJ) and VJ/lighting control software.

---

## Core Functionality

### 1. Import Sources
- **Rekordbox XML** — Parse library export files containing tracks and cue points
- **Serato DJ** — Read cue points directly from audio file ID3 GEOB tags (MP3, WAV, AIFF, FLAC, M4A)
- **Engine DJ** — Parse SQLite database files from Denon hardware
- **ShowKontrol** — Import existing `.cue` timecode files
- **Resolume Arena** — Import existing envelope preset XML files

### 2. Export Targets
- **Resolume Arena XML** — Envelope presets that can be dragged into Arena
- **ShowKontrol .cue** — Timecode trigger files for TC Supply ShowKontrol

### 3. Envelope Editor
- Visual curve editor showing cue points as draggable nodes
- 23 interpolation curve types (matching Resolume exactly)
- Lock X/Y axis for constrained editing
- Enable/disable individual cue points
- Undo/Redo support

### 4. Track Browser
- Hierarchical playlist view
- Search and filter tracks
- Sort by name, artist, BPM, duration, cue count

---

## Application Sections (UI Layout)

The app has 4 main collapsible sections arranged vertically:

### Section 1: PROJECT
- Project name input field
- Import buttons (Create Envelope, Resolume, Rekordbox, Serato, Engine DJ, ShowKontrol)
- Project management (New, Open, Save)
- Viewport settings (layout presets, theme toggle)

### Section 2: BROWSE AUDIO
- Playlist sidebar (hierarchical tree with folders)
- Track list with search and sort
- Track metadata display (name, artist, album, BPM, duration, cue count)

### Section 3: CONFIGURE ENVELOPE
- Envelope visualization (SVG canvas)
- Cue points table (editable)
- Duration input (minutes:seconds:milliseconds)
- Preset name input
- Lock X/Y checkboxes
- Add/Remove cue point buttons
- Curve type selector

### Section 4: EXPORT
- XML preview (read-only text view)
- Export buttons (Save XML, Save ShowKontrol Cue, Copy to Clipboard)
- Default save path settings

---

## User Interactions

### Envelope Canvas
- **Click** on canvas → Add new cue point at that position
- **Click** on existing point → Select it (highlight in table)
- **Drag** point horizontally → Change time position (if Lock X is OFF)
- **Drag** point vertically → Change Y value (if Lock Y is OFF)
- **Visual feedback**: Selected point has larger radius and glow

### Cue Points Table
- **Click** row → Select cue point (highlight on canvas)
- **Edit** name cell → Rename cue point
- **Edit** position cell → Change time (format: SS.mmm)
- **Edit** Y value cell → Change value (0-100)
- **Checkbox** → Enable/disable cue point
- **Curve dropdown** → Change interpolation curve type

### Import Flow
1. User clicks import button
2. System file picker opens with appropriate filter
3. File is parsed
4. For Rekordbox: Tracks loaded into browser, user selects track
5. For ShowKontrol/Resolume: Duration dialog shown (since files don't contain duration)
6. Cue points loaded into envelope editor

---

## Keyboard Shortcuts

| Action | macOS Shortcut |
|--------|----------------|
| New Project | ⌘N |
| Open Project | ⌘O |
| Save Project | ⌘S |
| Save Project As | ⇧⌘S |
| Export XML | ⌘E |
| Export ShowKontrol | ⇧⌘E |
| Undo | ⌘Z |
| Redo | ⇧⌘Z |
| Add Cue Point | ⌘D |
| Delete Selected | ⌫ (Backspace) |

---

## File Formats

### Project File (.cueproj)
JSON format containing:
- Project name
- Loaded tracks (with cue points)
- Playlists
- Current envelope state
- UI preferences (theme, layout)

### Resolume XML Output
```xml
<?xml version="1.0" encoding="UTF-8"?>
<Preset name="Envelope Name">
  <point x="0.0" y="0.0" curve="1" />
  <point x="0.5" y="1.0" curve="1" />
  <point x="1.0" y="0.0" curve="1" />
</Preset>
```
- `x` = normalized position (0.0 to 1.0)
- `y` = normalized value (0.0 to 1.0)
- `curve` = curve type ID (1-23)

### ShowKontrol .cue Output
```
HH:MM:SS:FF,compact,milliseconds,name,TAG,commands
00:00:00:00,0,0,Start,TAG,
00:01:30:00,0,90000,Drop,TAG,
00:03:00:00,0,180000,End,TAG,
```

---

## Themes

### Dark Theme (Default)
- Background: `#0a0a0f` (near black)
- Section background: `#14141e` (dark purple-gray)
- Accent: `#1ed760` (Spotify green)
- Text: `#e0e0e8` (light gray)
- Dim text: `#888888` (mid gray)

### Light Theme
- Background: `#f5f5f7` (light gray)
- Section background: `#ffffff` (white)
- Accent: `#1db954` (darker green)
- Text: `#1d1d1f` (near black)
- Dim text: `#666666` (mid gray)

---

## Persistence (User Defaults)

Store in NSUserDefaults / electron-store:
- `theme` — "dark" or "light"
- `xmlSavePath` — Last used XML export directory
- `skCueSavePath` — Last used ShowKontrol export directory
- `projectSavePath` — Last used project save directory
- `windowBounds` — Window position and size
- `sectionOrder` — Order of sections (if draggable)
- `collapsedSections` — Which sections are collapsed
- `sideBySideMode` — Layout preference

---

## Error Handling

- Invalid file format → Show alert with specific error
- Missing duration → Show duration input dialog
- Parse failure → Show error alert, don't crash
- No cue points found → Show informative alert

---

## Performance Considerations

- Lazy load tracks (don't parse all cue points until track selected)
- Debounce envelope redraws during drag
- Limit undo history to ~50 states
- Use Core Animation for smooth transitions

---

## Accessibility

- All buttons have tooltips
- Keyboard navigation support
- VoiceOver labels for custom controls
- High contrast mode support
