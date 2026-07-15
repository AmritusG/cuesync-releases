# CUE SYNC - Style Guide

Complete visual design specifications including colors, typography, spacing, and component styling.

---

## Color Palette

### Dark Theme (Default)

| Name | Hex | RGB | Usage |
|------|-----|-----|-------|
| Background | `#0a0a0f` | `10, 10, 15` | Main app background |
| Section BG | `#14141e` | `20, 20, 30` | Section/card backgrounds |
| Surface | `#1a1a2e` | `26, 26, 46` | Modals, dropdowns |
| Accent Green | `#1ed760` | `30, 215, 96` | Primary accent, buttons |
| Accent Pink | `#ef288a` | `239, 40, 138` | ShowKontrol branding |
| Accent Gold | `#ffd700` | `255, 215, 0` | Create envelope, Resolume |
| Accent Teal | `#5de4c7` | `93, 228, 199` | Resolume import |
| Accent Blue | `#0068a9` | `0, 104, 169` | Serato branding |
| Accent Mint | `#5bd29f` | `91, 210, 159` | Engine DJ branding |
| Text Primary | `#e0e0e8` | `224, 224, 232` | Primary text |
| Text Secondary | `#888888` | `136, 136, 136` | Secondary/dim text |
| Text Muted | `#666666` | `102, 102, 102` | Placeholders, hints |
| Text Disabled | `#555555` | `85, 85, 85` | Disabled states |
| Border | `rgba(255,255,255,0.08)` | - | Subtle borders |
| Border Accent | `rgba(30,215,96,0.2)` | - | Accent borders |

### Light Theme

| Name | Hex | RGB | Usage |
|------|-----|-----|-------|
| Background | `#f5f5f7` | `245, 245, 247` | Main app background |
| Section BG | `#ffffff` | `255, 255, 255` | Section/card backgrounds |
| Surface | `#ffffff` | `255, 255, 255` | Modals, dropdowns |
| Accent Green | `#1db954` | `29, 185, 84` | Primary accent (darker) |
| Text Primary | `#1d1d1f` | `29, 29, 31` | Primary text |
| Text Secondary | `#666666` | `102, 102, 102` | Secondary text |
| Border | `rgba(0,0,0,0.1)` | - | Subtle borders |

---

## Typography

### Font Stack

```css
font-family: 'JetBrains Mono', 'Fira Code', 'SF Mono', Menlo, Monaco, monospace;
```

**Fallback for macOS native:**
```swift
NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
```

### Font Sizes

| Name | Size | Weight | Usage |
|------|------|--------|-------|
| Title | 20px | 700 | Logo text |
| Heading | 18px | 600 | Modal titles |
| Section Title | 12px | 600 | Section headers (uppercase) |
| Body | 12px | 400 | General text |
| Small | 11px | 500 | Buttons, labels |
| Caption | 10px | 600 | Group labels, hints |
| Tiny | 9px | 400 | Table cells, metadata |

### Letter Spacing

| Context | Spacing |
|---------|---------|
| Section titles | `1px` |
| Button labels | `0.5px` |
| Normal text | `0` (default) |

---

## Spacing

### Base Grid
- **Base unit:** 4px
- All spacing should be multiples of 4px

### Common Spacing Values

| Name | Value | Usage |
|------|-------|-------|
| xs | 4px | Tight gaps, icon padding |
| sm | 8px | Button padding, small gaps |
| md | 12px | Section padding, medium gaps |
| lg | 16px | Section gaps, large padding |
| xl | 20px | Main content padding |
| xxl | 24px | Modal padding, large sections |

### Section Spacing
- **Section padding:** 16px horizontal, 20px vertical
- **Section gap:** 16px between sections
- **Content gap:** 12px between elements within sections

---

## Border Radius

| Name | Value | Usage |
|------|-------|-------|
| Small | 4px | Inputs, small buttons, badges |
| Medium | 5px | Buttons, tags |
| Large | 6px | Checkboxes, dropdowns |
| Section | 10px | Sections, cards |
| Modal | 12px | Modals, dialogs |

---

## Shadows

```css
/* Modal shadow */
box-shadow: 0 20px 60px rgba(0, 0, 0, 0.5);

/* Card hover shadow */
box-shadow: 0 4px 20px rgba(30, 215, 96, 0.1);

/* Cue point glow */
box-shadow: 0 0 6px currentColor;
```

---

## Component Styles

### Buttons

#### Primary Button (Green)
```
Background: rgba(30, 215, 96, 0.2)
Border: 1px solid #1ed760
Color: #1ed760
Border-radius: 5px
Padding: 10px 16px
Font-size: 11px
Font-weight: 600

Hover:
  Background: #1ed760
  Color: #000
```

#### Secondary Button (Neutral)
```
Background: rgba(255, 255, 255, 0.08)
Border: 1px solid rgba(255, 255, 255, 0.2)
Color: #e0e0e8
Border-radius: 5px
Padding: 8px 12px
Font-size: 11px
Font-weight: 500

Hover:
  Background: rgba(255, 255, 255, 0.12)
  Border-color: rgba(255, 255, 255, 0.3)
```

#### Import Buttons (Brand Colors)

| Type | Background | Border | Text |
|------|------------|--------|------|
| Rekordbox | `rgba(255,255,255,0.08)` | `rgba(255,255,255,0.2)` | `#e0e0e8` |
| Serato | `rgba(0,104,169,0.15)` | `rgb(0,104,169)` | `#fff` |
| Engine DJ | `rgba(91,210,159,0.15)` | `rgb(91,210,159)` | `#fff` |
| ShowKontrol | `rgba(239,40,138,0.15)` | `rgb(239,40,138)` | `#fff` |
| Resolume | `rgba(93,228,199,0.15)` | `#5de4c7` | `#fff` |
| Create Envelope | `rgba(255,215,0,0.15)` | `#ffd700` | `#fff` |

### Text Inputs

```
Background: rgba(0, 0, 0, 0.4)
Border: 1px solid rgba(255, 255, 255, 0.15)
Border-radius: 5px
Color: #fff
Padding: 8px 12px
Font-size: 12px

Focus:
  Border-color: #1ed760
  Outline: none
```

### Checkboxes

```
Size: 14px × 14px
Border-radius: 4px
Accent-color: #1ed760

Unchecked:
  Background: rgba(0, 0, 0, 0.4)
  Border: 1px solid rgba(255, 255, 255, 0.3)

Checked:
  Background: #1ed760
  Checkmark: #000
```

### Tables

```
Header:
  Background: rgba(255, 255, 255, 0.05)
  Font-size: 9px
  Font-weight: 700
  Text-transform: uppercase
  Letter-spacing: 1px
  Color: #888

Row:
  Border-bottom: 1px solid rgba(255, 255, 255, 0.05)
  Padding: 8px 12px
  
Row (hover):
  Background: rgba(30, 215, 96, 0.1)

Row (selected):
  Background: rgba(30, 215, 96, 0.15)
  Border-color: rgba(30, 215, 96, 0.3)
```

### Dropdowns

```
Trigger:
  Background: rgba(0, 0, 0, 0.4)
  Border: 1px solid rgba(255, 255, 255, 0.15)
  Border-radius: 5px
  Padding: 6px 10px

Menu:
  Background: #1a1a2e
  Border: 1px solid rgba(255, 255, 255, 0.15)
  Border-radius: 6px
  Box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4)
  Max-height: 300px
  Overflow-y: auto

Menu Item:
  Padding: 6px 10px
  
Menu Item (hover):
  Background: rgba(30, 215, 96, 0.15)
  
Menu Item (selected):
  Background: rgba(30, 215, 96, 0.2)

Group Header:
  Font-size: 9px
  Font-weight: 600
  Color: #666
  Text-transform: uppercase
  Padding: 4px 10px
  Background: rgba(255, 255, 255, 0.03)
```

---

## Section Layout

### Section Container
```
Background: linear-gradient(135deg, rgba(20, 20, 30, 0.8) 0%, rgba(15, 15, 22, 0.9) 100%)
Border: 1px solid rgba(255, 255, 255, 0.08)
Border-radius: 10px
Padding: 16px 20px
```

### Section Header
```
Display: flex
Align-items: center
Gap: 12px
Font-size: 12px
Font-weight: 600
Text-transform: uppercase
Letter-spacing: 1px
Margin-bottom: 14px
```

### Step Number Badge
```
Width: 26px
Height: 26px
Background: #1ed760
Color: #000
Border-radius: 6px
Font-size: 14px
Font-weight: 700
Display: flex
Align-items: center
Justify-content: center
```

---

## Envelope Canvas

### Canvas Container
```
Background: rgba(0, 0, 0, 0.4)
Border-radius: 6px
Border: 1px solid rgba(255, 255, 255, 0.1)
Aspect-ratio: 825 / 220
```

### Grid Lines
```
Vertical lines: 10 segments (10% each)
Horizontal lines: 5 segments (20% each)
Color: rgba(255, 255, 255, 0.1)
Stroke-width: 0.5px
```

### Envelope Curve
```
Stroke: #1ed760
Stroke-width: 2px
Fill: none
```

### Fill Area (below curve)
```
Fill: rgba(30, 215, 96, 0.1)
```

### Cue Points

#### Normal Point
```
Radius: 6px
Fill: #1ed760
Stroke: none
Cursor: pointer
```

#### Selected Point
```
Radius: 10px
Fill: #1ed760
Stroke: #fff
Stroke-width: 2px
Filter: drop-shadow(0 0 8px rgba(30, 215, 96, 0.6))
```

#### Disabled Point
```
Radius: 4px
Fill: #888
Opacity: 0.5
```

---

## Animations

### Transitions
```css
/* Default transition */
transition: all 0.2s ease;

/* Fast transition (hover states) */
transition: all 0.15s ease;

/* Collapse animation */
transition: height 0.3s ease, opacity 0.3s ease;
```

### Button Hover
```css
/* Scale on hover */
transform: scale(1.02);

/* Icon scale */
svg { transform: scale(1.1); }
```

### Loading States
```css
/* Pulsing animation */
@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.5; }
}
animation: pulse 1.5s ease-in-out infinite;
```

---

## Icons

### Icon Sizes
| Context | Size |
|---------|------|
| Button icons | 14px |
| Import button icons | 16px |
| Header icons | 24px |
| Table icons | 10-12px |

### Icon Colors
- Default: `currentColor` (inherits text color)
- Accent: `#1ed760`
- Disabled: `#666`

### Brand Icons (SVG)
- Rekordbox: Cube shape
- Serato: Vinyl record with waveform
- Engine DJ: "e" letterform
- ShowKontrol: "S" curves
- Resolume: "A" with stripes

---

## Responsive Behavior

### Minimum Window Size
- Width: 1000px
- Height: 700px

### Grid Layout
```
Default: 2-column grid (sections distributed)
Side-by-side: Configure section spans both columns
Single column: All sections stack vertically
```

### Section Collapsing
- Collapsed: Only header visible (40px height)
- Expanded: Full content visible
- Transition: 0.3s ease animation
