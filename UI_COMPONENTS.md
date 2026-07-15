# CUE SYNC - UI Components

Detailed specifications for every UI component, including behavior, states, and interactions.

---

## Application Structure

```
┌─────────────────────────────────────────────────────────────────┐
│  HEADER (fixed)                                                 │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ ⟡ CUE SYNC  TIMECODE-DRIVEN...       [Project Name] [v1.0] ││
│  └─────────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────────┤
│  MAIN CONTENT (scrollable)                                      │
│  ┌─────────────────────┐ ┌─────────────────────┐                │
│  │ SECTION 1: PROJECT  │ │ SECTION 2: BROWSE   │                │
│  │ [Step 1 badge]      │ │ [Step 2 badge]      │                │
│  │ Import buttons...   │ │ Playlist sidebar... │                │
│  │ Project controls... │ │ Track list...       │                │
│  └─────────────────────┘ └─────────────────────┘                │
│  ┌──────────────────────────────────────────────┐               │
│  │ SECTION 3: CONFIGURE ENVELOPE                │               │
│  │ [Step 3 badge]                               │               │
│  │ Envelope canvas | Cue points table           │               │
│  │ Duration, preset name, lock controls...      │               │
│  └──────────────────────────────────────────────┘               │
│  ┌──────────────────────────────────────────────┐               │
│  │ SECTION 4: EXPORT                            │               │
│  │ [Step 4 badge]                               │               │
│  │ XML preview | Export buttons                 │               │
│  └──────────────────────────────────────────────┘               │
├─────────────────────────────────────────────────────────────────┤
│  FOOTER (fixed)                                                 │
│  CUE SYNC • Resolume Arena Envelope Tool • TC Supply Compatible │
└─────────────────────────────────────────────────────────────────┘
```

---

## Header Component

### Layout
```
┌────────────────────────────────────────────────────────────────┐
│ ⟡ CUE SYNC   TIMECODE-DRIVEN ENVELOPE AUTOMATION   [name] v1.0│
└────────────────────────────────────────────────────────────────┘
```

### Elements

#### Logo
- Icon: Diamond shape `⟡` (or custom SVG)
- Text: "CUE" in white, "SYNC" in accent green
- Font: 20px, weight 700

#### Tagline
- Text: "TIMECODE-DRIVEN ENVELOPE AUTOMATION"
- Font: 9px, uppercase
- Color: `#666`

#### Project Name (right side)
- Shows current project name
- Max width: 200px (truncate with ellipsis)
- Font: 11px
- Color: `#888`

#### Version Badge
- Text: "v1.0.0"
- Background: `rgba(30, 215, 96, 0.15)`
- Border: `1px solid rgba(30, 215, 96, 0.3)`
- Color: `#1ed760`
- Border-radius: 4px
- Padding: 4px 10px

---

## Section Component

### Structure
```
┌──────────────────────────────────────────────┐
│ [≡] [1] SECTION TITLE              [▼]      │ ← Header (clickable to collapse)
├──────────────────────────────────────────────┤
│                                              │
│  Section content goes here                   │ ← Content (hidden when collapsed)
│                                              │
└──────────────────────────────────────────────┘
```

### Header Elements
- **Drag Handle** `≡`: For reordering sections (optional feature)
- **Step Badge**: Numbered 1-4, green background
- **Title**: Uppercase, letter-spacing 1px
- **Collapse Arrow** `▼`: Rotates when collapsed

### States
- **Expanded**: Full content visible
- **Collapsed**: Only header visible, content hidden
- **Dragging**: Reduced opacity, dashed border

### Props
```
SectionComponent {
    id: String           // "project" | "browse" | "configure" | "export"
    title: String        // Display title
    stepNumber: Int      // 1-4
    isCollapsed: Bool    // Collapse state
    onToggle: Function   // Collapse callback
    children: View       // Content
}
```

---

## Section 1: PROJECT

### Layout
```
┌──────────────────────────────────────────────────────────────────┐
│ [1] PROJECT                                                       │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  Project                    Project Name                          │
│  [New] [Open] [Save]        [________________] ✓ X tracks loaded  │
│                                                                   │
│  Create Envelope            Import Envelope    Import Cues        │
│  [+ Create Envelope]        [Resolume]         [Rekordbox]        │
│                                                [Serato]           │
│                                                [Engine DJ]        │
│                                                [ShowKontrol]      │
│                                                                   │
│  Viewport                   Theme                                 │
│  [Reset] [Side-By-Side]     [Dark] [Light]                       │
│  [Save] [Last Saved]                                             │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

### Button Groups

#### Project Buttons
- **New**: Clears current project
- **Open**: Opens file picker for `.cueproj` files
- **Save**: Saves current project (shows save dialog if new)

#### Create Envelope Button
- Golden color theme
- Creates blank envelope with start/end points
- Sets `envelopeMode = true`

#### Import Buttons
Each button opens appropriate file picker:
| Button | File Filter | Action |
|--------|-------------|--------|
| Resolume | `.xml` | Parse envelope, show duration dialog |
| Rekordbox | `.xml` | Parse library, load tracks |
| Serato | `.mp3,.wav,.aiff,.flac,.m4a` | Parse ID3 tags |
| Engine DJ | `.db` | Parse SQLite database |
| ShowKontrol | `.cue` | Parse cues, show duration dialog |

#### Viewport Buttons
- **Reset**: Restore default layout
- **Side-By-Side**: Toggle two-column mode
- **Save**: Save current layout preference
- **Last Saved**: Restore saved layout

#### Theme Toggle
- **Dark** / **Light**: Toggle between themes
- Active state: Filled button
- Persisted to user defaults

---

## Section 2: BROWSE AUDIO

### Layout
```
┌──────────────────────────────────────────────────────────────────┐
│ [2] BROWSE AUDIO                                                  │
├──────────────────────────────────────────────────────────────────┤
│ ┌─────────────┐ ┌──────────────────────────────────────────────┐ │
│ │ PLAYLISTS   │ │ 🔍 Search tracks...            [Sort: Name ▼]│ │
│ │             │ ├──────────────────────────────────────────────┤ │
│ │ 📚 All (42) │ │ Track Name                           3:45    │ │
│ │             │ │ Artist • Album                               │ │
│ │ 📁 Folder   │ │ 128.0 BPM • Am • 4 cues                     │ │
│ │   📋 List 1 │ ├──────────────────────────────────────────────┤ │
│ │   📋 List 2 │ │ Track Name 2                         4:12    │ │
│ │             │ │ Artist 2 • Album 2                           │ │
│ │ 📁 Folder 2 │ │ 125.0 BPM • Cm • 8 cues                     │ │
│ │             │ ├──────────────────────────────────────────────┤ │
│ └─────────────┘ │ ...                                          │ │
│                 ├──────────────────────────────────────────────┤ │
│                 │ Showing 42 of 42 tracks                      │ │
│                 └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### Playlist Sidebar

#### Structure
- Header: "PLAYLISTS" (uppercase, dimmed)
- "All Tracks" item always first
- Folders expandable with `▶` / `▼` arrows
- Playlists show track count badge

#### Item States
- **Normal**: Transparent background
- **Hover**: Subtle highlight
- **Selected**: Green left border, green tint background

### Track List

#### Search Bar
- Placeholder: "🔍 Search tracks, artists, albums..."
- Filters as user types (debounced 300ms)

#### Sort Dropdown
Options:
- Name (default)
- Artist
- Album
- BPM
- Duration
- Cue Count

#### Track Item
Shows:
- Track name (bold)
- Artist • Album
- BPM • Key • Cue count
- Duration (right-aligned)

States:
- **Normal**: Subtle background
- **Hover**: Green tint
- **Selected**: Green border, green tint

#### Empty State
"Import tracks from Rekordbox, Serato, Engine DJ, or ShowKontrol to browse"

---

## Section 3: CONFIGURE ENVELOPE

### Layout
```
┌──────────────────────────────────────────────────────────────────┐
│ [3] CONFIGURE ENVELOPE                          4/6 points active│
├──────────────────────────────────────────────────────────────────┤
│ ┌─────────────────────────────────┐ ┌──────────────────────────┐ │
│ │      ENVELOPE VISUALIZATION     │ │ CUE POINTS               │ │
│ │                                 │ ├──────────────────────────┤ │
│ │    ●───────────●                │ │ ☑ │ ● │ Start  │ 0.000  │ │
│ │   /             \               │ │ ☑ │ ● │ Drop   │ 30.500 │ │
│ │  /               \              │ │ ☐ │ ● │ Break  │ 45.000 │ │
│ │ ●                 ●─────────●   │ │ ☑ │ ● │ End    │ 60.000 │ │
│ │                                 │ │                          │ │
│ └─────────────────────────────────┘ └──────────────────────────┘ │
│                                                                   │
│  Preset Name              Duration                               │
│  [New Envelope____]       [01]:[30]:[000]  = 90.000s             │
│                                                                   │
│  🔒 Lock X    🔒 Lock Y    [+ Add Cue Point] [Remove Selected]   │
│                                                                   │
│  Default Curve: [Linear ▼]                                       │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

### Envelope Canvas

#### Grid
- 10 vertical divisions (10% each)
- 5 horizontal divisions (20% each)
- Grid lines: very subtle (`rgba(255,255,255,0.1)`)

#### Drawing
1. Draw grid lines
2. Draw fill area (below curve)
3. Draw curve line connecting points
4. Draw cue points on top

#### Interactions
- **Click empty space**: Add new cue point at click position
- **Click point**: Select point
- **Drag point**: Move point (respecting lock constraints)
- **Double-click point**: Edit name (optional)

### Cue Points Table

#### Columns
| Column | Width | Content |
|--------|-------|---------|
| Enable | 36px | Checkbox |
| Color | 32px | Color dot |
| Name | flex | Editable text |
| Position | 75px | Time in seconds |
| Y Value | 60px | 0-100 value |
| Curve | 165px | Dropdown |

#### Row Interactions
- Click to select (syncs with canvas)
- Double-click cell to edit (name, position, Y value)
- Checkbox toggles enabled state

### Duration Input

#### Format
```
[MM]:[SS]:[mmm]
```
- Minutes: 2 digits
- Seconds: 2 digits (00-59)
- Milliseconds: 3 digits (000-999)

#### Display
Shows calculated total: "= 90.000s"

### Lock Controls
- **Lock X**: Prevents horizontal movement of points
- **Lock Y**: Prevents vertical movement of points
- Visual: Checkbox with lock icon 🔒

### Action Buttons
- **Add Cue Point**: Opens position input, adds point
- **Remove Selected**: Removes selected point (disabled for start/end)

---

## Section 4: EXPORT

### Layout
```
┌──────────────────────────────────────────────────────────────────┐
│ [4] EXPORT                                                        │
├──────────────────────────────────────────────────────────────────┤
│ ┌─────────────────────────────────┐ ┌──────────────────────────┐ │
│ │ XML PREVIEW                     │ │                          │ │
│ │                                 │ │  [⚡ Save XML]           │ │
│ │ <?xml version="1.0"?>           │ │                          │ │
│ │ <Preset name="My Envelope">     │ │  [💾 Save ShowKontrol]   │ │
│ │   <point x="0" y="0" curve="1"/>│ │                          │ │
│ │   <point x="0.5" y="1" ...      │ │  [📋 Copy to Clipboard]  │ │
│ │   <point x="1" y="0" curve="1"/>│ │                          │ │
│ │ </Preset>                       │ │  ────────────────────    │ │
│ │                                 │ │                          │ │
│ │                                 │ │  XML Save Folder:        │ │
│ │                                 │ │  ~/Documents             │ │
│ │                                 │ │                          │ │
│ └─────────────────────────────────┘ └──────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### XML Preview
- Read-only text view
- Monospace font (Menlo or system mono)
- Green text on dark background
- Syntax highlighting (optional)
- Updates when envelope changes

### Export Buttons

#### Save XML
- Primary action (green accent)
- Opens save dialog
- Default filename: `{presetName}.xml`

#### Save ShowKontrol Cue
- Secondary action (pink accent for ShowKontrol branding)
- Opens save dialog
- Default filename: `{presetName}.cue`

#### Copy to Clipboard
- Copies XML text to system clipboard
- Shows brief "Copied!" feedback

### Path Settings
- Shows last used export directories
- Clicking opens folder in Finder (optional)

---

## Modal Dialogs

### Duration Input Modal
Used for ShowKontrol and Resolume imports (which don't contain duration).

```
┌─────────────────────────────────────────┐
│  Set Track Duration                     │
│                                         │
│  ShowKontrol files don't include        │
│  duration. Please enter track duration: │
│                                         │
│      [01] : [30] : [000]                │
│      min    sec    ms                   │
│                                         │
│              [Cancel]  [Import]         │
└─────────────────────────────────────────┘
```

### Confirmation Dialogs
Standard macOS alert style for:
- Unsaved changes warning
- Delete confirmation
- Error messages

---

## Curve Dropdown

### Trigger
Shows: Icon + Name of selected curve

### Menu Structure
Grouped by category:

```
┌────────────────────────────┐
│ BASIC                      │
│   ─── Linear               │ (selected)
│   ─── Hold                 │
├────────────────────────────┤
│ QUADRATIC                  │
│   ╭─ Quadratic In          │
│   ─╮ Quadratic Out         │
│   ╭╮ Quadratic In/Out      │
├────────────────────────────┤
│ ... (more categories)      │
└────────────────────────────┘
```

### Curve Icons
Small SVG showing curve shape (32×16px)

---

## Keyboard Navigation

### Global
- `Tab`: Move focus between controls
- `Escape`: Close modals/dropdowns
- `Enter`: Confirm dialogs

### Envelope Canvas
- `Delete/Backspace`: Remove selected point
- `Arrow keys`: Nudge selected point (optional)

### Table
- `Up/Down`: Navigate rows
- `Enter`: Edit selected cell
- `Escape`: Cancel editing
