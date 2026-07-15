# CUE SYNC - Features Checklist

Complete implementation checklist for native macOS port. Check off items as they are completed.

---

## Priority Legend
- 🔴 **P0** — Critical (must have for MVP)
- 🟠 **P1** — High (should have for release)
- 🟡 **P2** — Medium (nice to have)
- 🟢 **P3** — Low (future enhancement)

---

## Core Data Layer

### Models
- [ ] 🔴 CuePoint struct with all fields (id, start, name, color, yValue, curve, enabled)
- [ ] 🔴 Track struct with nested cuePoints array
- [ ] 🔴 Playlist struct with hierarchical children
- [ ] 🔴 Project container for save/load
- [ ] 🟠 Undo/Redo state management

### Persistence
- [ ] 🔴 Project save to JSON (.cueproj)
- [ ] 🔴 Project load from JSON
- [ ] 🟠 NSUserDefaults for preferences (theme, paths, layout)
- [ ] 🟠 Recent projects list
- [ ] 🟡 Auto-save draft

---

## Import Parsers

### Rekordbox XML
- [ ] 🔴 Parse COLLECTION > TRACK elements
- [ ] 🔴 Extract POSITION_MARK cue points
- [ ] 🔴 Parse track metadata (name, artist, BPM, key, duration)
- [ ] 🔴 Parse PLAYLISTS hierarchy
- [ ] 🔴 Decode file:// location paths

### Serato DJ
- [ ] 🟠 Read MP3 ID3v2 GEOB tags
- [ ] 🟠 Read AIFF ID3 tags
- [ ] 🟠 Read WAV Serato tags
- [ ] 🟡 Read FLAC Vorbis comments
- [ ] 🟡 Read M4A/MP4 Serato atoms
- [ ] 🔴 Parse Serato Markers2 binary format
- [ ] 🔴 Extract CUE entries with position and color

### Engine DJ
- [ ] 🟠 Open SQLite database (m.db)
- [ ] 🟠 Query Track table
- [ ] 🟠 Query PerformanceData table
- [ ] 🟠 Decompress quickCues BLOB (zlib)
- [ ] 🟠 Parse cue slot binary format

### ShowKontrol
- [ ] 🔴 Parse CSV .cue format
- [ ] 🔴 Extract timecode, milliseconds, name
- [ ] 🔴 Handle CUE0 duration metadata
- [ ] 🔴 Show duration input dialog after import

### Resolume Envelope
- [ ] 🔴 Parse XML preset format
- [ ] 🔴 Extract point x/y/curve values
- [ ] 🔴 Show duration input dialog after import
- [ ] 🔴 Convert normalized points to CuePoints

---

## Export Generators

### Resolume XML
- [ ] 🔴 Generate valid XML with header
- [ ] 🔴 Normalize cue positions to 0-1 range
- [ ] 🔴 Normalize Y values to 0-1 range
- [ ] 🔴 Include curve type IDs
- [ ] 🔴 Ensure points at x=0 and x=1
- [ ] 🔴 Escape XML special characters in preset name
- [ ] 🔴 Save dialog with suggested filename

### ShowKontrol .cue
- [ ] 🔴 Generate CSV format
- [ ] 🔴 Convert seconds to HH:MM:SS:FF timecode (30fps)
- [ ] 🔴 Include compact timecode and milliseconds
- [ ] 🔴 Escape commas in cue names
- [ ] 🔴 Use correct line endings (\r)
- [ ] 🔴 Save dialog with suggested filename

### Clipboard
- [ ] 🔴 Copy XML to system clipboard
- [ ] 🟠 Visual feedback on copy success

---

## UI - Header

- [ ] 🔴 Logo with icon and text
- [ ] 🟠 Tagline text
- [ ] 🔴 Project name display
- [ ] 🟠 Version badge
- [ ] 🟠 Unsaved changes indicator (*)

---

## UI - Section 1: PROJECT

### Project Controls
- [ ] 🔴 New Project button
- [ ] 🔴 Open Project button with file picker
- [ ] 🔴 Save Project button
- [ ] 🟠 Save As... (Shift+Cmd+S)
- [ ] 🔴 Project name text field

### Import Buttons
- [ ] 🔴 Create Envelope button (gold theme)
- [ ] 🔴 Resolume import button (teal theme)
- [ ] 🔴 Rekordbox import button
- [ ] 🟠 Serato import button (blue theme)
- [ ] 🟠 Engine DJ import button (green theme)
- [ ] 🔴 ShowKontrol import button (pink theme)
- [ ] 🔴 Hover states with brand colors

### Viewport Controls
- [ ] 🟠 Reset layout button
- [ ] 🟠 Side-by-side toggle
- [ ] 🟡 Save layout button
- [ ] 🟡 Restore saved layout button

### Theme Toggle
- [ ] 🟠 Dark theme button
- [ ] 🟠 Light theme button
- [ ] 🟠 Persist preference

---

## UI - Section 2: BROWSE AUDIO

### Playlist Sidebar
- [ ] 🔴 "All Tracks" item
- [ ] 🔴 Playlist list with names
- [ ] 🔴 Folder expand/collapse with arrow
- [ ] 🔴 Track count badges
- [ ] 🔴 Selection highlight
- [ ] 🟠 Nested folder indentation

### Track List
- [ ] 🔴 Scrollable list view
- [ ] 🔴 Track name (primary)
- [ ] 🔴 Artist, album (secondary)
- [ ] 🔴 BPM, key, duration display
- [ ] 🔴 Cue count indicator
- [ ] 🔴 Row selection
- [ ] 🔴 Hover highlight
- [ ] 🟠 Search/filter field
- [ ] 🟠 Sort dropdown (name, artist, BPM, etc.)

### Track Selection Action
- [ ] 🔴 Load cue points into envelope editor
- [ ] 🔴 Set duration from track totalTime
- [ ] 🔴 Update preset name to track name

---

## UI - Section 3: CONFIGURE ENVELOPE

### Envelope Canvas
- [ ] 🔴 SVG/Core Graphics canvas
- [ ] 🔴 Grid lines (10 vertical, 5 horizontal)
- [ ] 🔴 Draw curve connecting points
- [ ] 🔴 Draw fill area below curve
- [ ] 🔴 Draw cue point circles
- [ ] 🔴 Selected point highlight (larger, glowing)
- [ ] 🔴 Click to add point
- [ ] 🔴 Click point to select
- [ ] 🔴 Drag point to move
- [ ] 🔴 Respect Lock X constraint
- [ ] 🔴 Respect Lock Y constraint
- [ ] 🟠 Disabled point styling (dimmed)
- [ ] 🟠 Curve interpolation visualization (show actual curve, not just lines)
- [ ] 🟡 Point snapping to grid
- [ ] 🟡 Zoom/pan controls

### Cue Points Table
- [ ] 🔴 Table view with columns
- [ ] 🔴 Enable checkbox column
- [ ] 🔴 Color indicator column
- [ ] 🔴 Name column (editable)
- [ ] 🔴 Position column (editable, format: SS.mmm)
- [ ] 🔴 Y Value column (editable, 0-100)
- [ ] 🔴 Curve dropdown column
- [ ] 🔴 Row selection synced with canvas
- [ ] 🔴 Scroll to selected row
- [ ] 🟠 Drag to reorder rows
- [ ] 🟠 Delete key removes row

### Duration Controls
- [ ] 🔴 Minutes input field
- [ ] 🔴 Seconds input field
- [ ] 🔴 Milliseconds input field
- [ ] 🔴 Calculated total display ("= 90.000s")
- [ ] 🔴 Update envelope when duration changes

### Preset Name
- [ ] 🔴 Text input field
- [ ] 🔴 Default to "New Envelope" or track name

### Lock Controls
- [ ] 🔴 Lock X checkbox
- [ ] 🔴 Lock Y checkbox
- [ ] 🔴 Visual lock icon

### Action Buttons
- [ ] 🔴 Add Cue Point button
- [ ] 🔴 Remove Selected button
- [ ] 🟠 Position input for new point

### Curve Dropdown
- [ ] 🔴 All 23 curve types
- [ ] 🔴 Grouped by category
- [ ] 🟠 Curve icon preview in dropdown
- [ ] 🔴 Updates selected point's curve

---

## UI - Section 4: EXPORT

### XML Preview
- [ ] 🔴 Read-only text view
- [ ] 🔴 Monospace font
- [ ] 🔴 Green text on dark bg (dark theme)
- [ ] 🔴 Updates when envelope changes
- [ ] 🟡 Syntax highlighting

### Export Buttons
- [ ] 🔴 Save XML button
- [ ] 🔴 Save ShowKontrol Cue button
- [ ] 🔴 Copy to Clipboard button
- [ ] 🔴 Copy success feedback

### Path Display
- [ ] 🟡 Show last used XML path
- [ ] 🟡 Show last used .cue path
- [ ] 🟡 Click to open folder

---

## UI - Sections (General)

### Collapsible Sections
- [ ] 🔴 Click header to toggle
- [ ] 🔴 Collapse arrow rotation animation
- [ ] 🔴 Persist collapsed state
- [ ] 🟠 Smooth height animation

### Section Reordering
- [ ] 🟡 Drag handle in header
- [ ] 🟡 Drag to reorder sections
- [ ] 🟡 Persist section order

### Step Number Badges
- [ ] 🔴 Green numbered badges (1-4)
- [ ] 🔴 Update numbers when reordered (or keep static)

---

## UI - Modals/Dialogs

### Duration Input Modal
- [ ] 🔴 Minutes/seconds/ms fields
- [ ] 🔴 Cancel button
- [ ] 🔴 Import/Confirm button
- [ ] 🔴 Modal overlay backdrop

### Alert Dialogs
- [ ] 🔴 Error alerts (parse failures, etc.)
- [ ] 🟠 Unsaved changes confirmation
- [ ] 🟠 Delete confirmation

---

## Keyboard Shortcuts

### File Operations
- [ ] 🔴 Cmd+N: New project
- [ ] 🔴 Cmd+O: Open project
- [ ] 🔴 Cmd+S: Save project
- [ ] 🟠 Shift+Cmd+S: Save As

### Export
- [ ] 🟠 Cmd+E: Export XML
- [ ] 🟠 Shift+Cmd+E: Export ShowKontrol

### Editing
- [ ] 🔴 Cmd+Z: Undo
- [ ] 🔴 Shift+Cmd+Z: Redo
- [ ] 🟠 Cmd+D: Add cue point
- [ ] 🔴 Delete/Backspace: Remove selected point

---

## Undo/Redo System

- [ ] 🟠 Track state changes
- [ ] 🟠 Push to undo stack
- [ ] 🟠 Undo restores previous state
- [ ] 🟠 Redo restores undone state
- [ ] 🟠 Limit stack size (~50 states)
- [ ] 🟠 Clear redo on new action

---

## Theming

### Dark Theme
- [ ] 🔴 All colors defined
- [ ] 🔴 Apply to all components

### Light Theme
- [ ] 🟠 All colors defined
- [ ] 🟠 Apply to all components
- [ ] 🟠 Toggle without restart

---

## Window Management

- [ ] 🔴 Minimum size constraints (1000×700)
- [ ] 🟠 Remember window position/size
- [ ] 🟠 Fullscreen support
- [ ] 🟠 Title bar shows project name

---

## Error Handling

- [ ] 🔴 Invalid file format errors
- [ ] 🔴 Parse failure errors
- [ ] 🔴 File not found errors
- [ ] 🔴 Permission errors
- [ ] 🔴 Graceful degradation (don't crash)

---

## Performance

- [ ] 🟠 Lazy load track cue points
- [ ] 🟠 Debounce envelope redraws
- [ ] 🟠 Efficient table rendering (reuse cells)
- [ ] 🟡 Background parsing for large libraries

---

## Testing

### Unit Tests
- [ ] 🟡 Rekordbox parser tests
- [ ] 🟡 Serato parser tests
- [ ] 🟡 ShowKontrol parser tests
- [ ] 🟡 Resolume XML generator tests
- [ ] 🟡 ShowKontrol cue generator tests

### Sample Files
- [ ] 🔴 Sample Rekordbox XML
- [ ] 🔴 Sample ShowKontrol .cue
- [ ] 🔴 Sample Resolume envelope .xml
- [ ] 🟠 Sample audio files with Serato tags
- [ ] 🟠 Sample Engine DJ database

---

## Documentation

- [ ] 🟠 README with build instructions
- [ ] 🟠 User guide
- [ ] 🟡 Developer documentation
- [ ] 🟡 API documentation

---

## Build & Distribution

- [ ] 🔴 CMake/Xcode build configuration
- [ ] 🔴 App bundle with icon
- [ ] 🔴 Info.plist with version info
- [ ] 🟠 Code signing
- [ ] 🟡 Notarization
- [ ] 🟡 DMG installer

---

## Summary

### MVP (P0 items): ~65 items
Core functionality to ship a working product.

### Release (P0 + P1): ~85 items
Polished release with all expected features.

### Full Feature Set (All): ~100+ items
Complete parity with Electron version plus enhancements.
