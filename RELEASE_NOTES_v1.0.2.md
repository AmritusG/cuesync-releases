# CUE SYNC v1.0.2

Stability + hardening release on top of v1.0.1. No feature or UI changes — every fix here makes import/export safe against malformed, corrupt, or hostile input. Universal binary, Developer-ID signed and Apple-notarized.

## Crash fixes

A class of bugs where a malformed file (or a hand-edited project / odd field value) could push a non-finite (`NaN`/`Inf`), negative, or out-of-range value into a cue point and crash the app downstream:

- **ShowKontrol export no longer crashes** on a cue whose position is `NaN`/`Inf` or astronomically large. The timecode conversion previously hit an `Int(...)` trap; it now clamps to a safe range. This could be triggered by *any* import (Rekordbox, ShowKontrol, Resolume, Engine DJ, Serato) carrying a bad cue position.
- **Serato import no longer crashes** on a corrupt file with cue index 255 (a `UInt8` overflow) or a malformed `TLEN`/`TBPM` tag (`Int(NaN)` / non-finite BPM).
- **Cue table & duration fields no longer crash** when a non-finite value (`nan`/`inf`) or an out-of-range integer is entered; numeric input is now validated and clamped.
- **Engine DJ import** is hardened against non-finite cue positions and unaligned memory reads in the cue blob.

## Correctness & robustness

- **Resolume envelope export now emits clean, plain-decimal coordinates** capped at 6 decimal places. Previously it could emit scientific notation (e.g. `1.6e-05`) for cues near the start of a track and ~17 digits of floating-point noise; both are gone.
- Every parser now guarantees its cue points are finite, non-negative, with curves in the valid 1–23 range.
- Resolume export validates curve IDs; AIFF parsing no longer aborts on a zero-size chunk; WAV parsing skips the audio data chunk when scanning for markers (faster on large files); ShowKontrol cue names with line breaks can no longer corrupt the `.cue` output.
- `.cueproj` files now load even when keys are missing (older/partial projects), falling back to defaults instead of failing.

## Testing

Added a standalone test suite (`scripts/run-tests.sh`, 49 unit + fuzz tests) covering all parsers and exporters, including deterministic binary fuzzing of the Serato parser and SQLite fixtures for Engine DJ. Every fix above is backed by a regression test.

## Supported workflows
- **Imports:** Rekordbox XML, Serato (ID3 GEOB), Engine DJ (SQLite), ShowKontrol `.cue`, Resolume envelope XML
- **Exports:** Resolume Arena envelope XML (23 curve types), ShowKontrol `.cue` (30 fps, `\r` line endings)
- **Project files:** `.cueproj` (JSON)

## Compatibility
- macOS 14 Sonoma or later
- Apple Silicon + Intel (universal binary)

## Installation
1. Download `CueSync-v1.0.2.dmg`
2. Open the DMG, drag CueSync to Applications
3. Launch from Applications or Spotlight

The DMG is signed and notarized — no Gatekeeper warnings.
