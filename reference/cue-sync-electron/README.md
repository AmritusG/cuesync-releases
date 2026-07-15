# Cue Sync

**Rekordbox • Serato • Engine DJ • ShowKontrol → Resolume**

Cue Sync is a desktop application that converts cue points from various DJ software into Resolume Arena/Avenue envelope clips.

## Features

- **Import from multiple sources:**
  - Rekordbox XML exports
  - Serato DJ (reads directly from audio files)
  - Engine DJ databases
  - ShowKontrol .cue files

- **Envelope editing:**
  - Visual envelope preview with drag-and-drop point editing
  - 23 curve types matching Resolume's easing functions
  - Lock X/Y axis for precise editing
  - Add/remove cue points
  - Undo/Redo support (Ctrl+Z / Ctrl+Y)

- **Export options:**
  - Resolume XML envelope files
  - ShowKontrol .cue files
  - Project files for saving your work

## Installation

### From Release
Download the latest release for your platform from the [Releases](https://github.com/cuesync/releases) page.

### From Source

```bash
# Clone the repository
git clone https://github.com/cuesync/cue-sync.git
cd cue-sync

# Install dependencies
npm install

# Run in development mode
npm run dev

# Build for production
npm run build
```

## Keyboard Shortcuts

| Action | Windows/Linux | macOS |
|--------|---------------|-------|
| New Project | Ctrl+N | ⌘N |
| Open Project | Ctrl+O | ⌘O |
| Save Project | Ctrl+S | ⌘S |
| Save As | Ctrl+Shift+S | ⌘⇧S |
| Export XML | Ctrl+E | ⌘E |
| Export SK Cue | Ctrl+Shift+E | ⌘⇧E |
| Undo | Ctrl+Z | ⌘Z |
| Redo | Ctrl+Y / Ctrl+Shift+Z | ⌘Y / ⌘⇧Z |
| Create Envelope | Ctrl+Shift+N | ⌘⇧N |
| Add Cue Point | Ctrl+D | ⌘D |

## Menu Commands

### File Menu
- **New Project** - Start a fresh project
- **Open Project** - Load a saved .cueproj file
- **Save Project** - Save current project
- **Save Project As** - Save to a new location
- **Import** - Import from Rekordbox, Serato, Engine DJ, or ShowKontrol
- **Export** - Export to Resolume XML or ShowKontrol Cue
- **Set Default XML Export Path** - Configure default save location for XML exports
- **Set Default SK Cue Export Path** - Configure default save location for ShowKontrol exports

### Edit Menu
- **Undo/Redo** - Undo or redo recent changes
- **Cut/Copy/Paste** - Standard clipboard operations

### Envelope Menu
- **Create Envelope** - Create a new manual envelope
- **Add Cue Point** - Add a cue point at the current position
- **Lock X Axis** - Prevent horizontal movement when dragging points
- **Lock Y Axis** - Prevent vertical movement when dragging points

## Building for Distribution

```bash
# Build for all platforms
npm run build

# Build for specific platform
npm run build:mac    # macOS (dmg, zip)
npm run build:win    # Windows (nsis, portable)
npm run build:linux  # Linux (AppImage, deb)
```

## Tech Stack

- **Electron** - Desktop application framework
- **React 18** - UI framework
- **esbuild** - JavaScript bundler
- **electron-builder** - Application packaging
- **electron-store** - Persistent settings storage

## License

MIT License - See LICENSE file for details.

## Support

For issues, feature requests, or contributions, please visit the [GitHub repository](https://github.com/cuesync/cue-sync).

---

Built for VJs ◈
