# CUESYNC-7 — `TextTools` module: `slugify()` + secure `generateToken()`

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> Scope note. The full swift-cross-ui UI re-host under this ticket number already landed
> (see the Windows/macOS CI jobs and `CueSyncCore`, the Foundation-only cross-platform
> target exercised on `windows-latest`). This iteration adds one small, self-contained
> cross-platform helper module — `TextTools` with `slugify()` and a **cryptographically
> secure** `generateToken()` — to that already-shared core. **No UI change, no exporter
> rewiring, no new dependency.** The two helpers must compile and behave *identically* on
> macOS, Windows x64, Windows ARM64, and Linux. This is a faithful-port addition: it lives
> in the existing Swift `CueSyncCore` target and follows the house style of the neighbouring
> `Support/Hex.swift` (a `public enum` namespace of static functions with security-aware
> doc comments).

---

## 1. Problem

CueSync turns arbitrary, user- and file-supplied text (preset names, track titles imported
from Rekordbox XML, Serato ID3 tags, Engine DJ databases, ShowKontrol/Resolume files) into
**export filenames** and into **identifiers embedded in exported documents**. Today those two
jobs are done ad hoc and unsafely: names are only lightly cleaned before becoming filenames
(so a title like `../../set` or the Windows device name `CON` can escape or collide with a
reserved name — a real risk now that the app ships on Windows), and the Resolume envelope's
`uniqueId` is derived from a millisecond timestamp (`ResolumeExporter.swift:32`), which is
predictable and collides when two exports happen in the same millisecond. This iteration adds
a single shared, dependency-free `TextTools` module with two functions: `slugify()`, which
turns any string into a safe, deterministic, cross-platform filename component, and
`generateToken()`, which produces an unguessable, collision-resistant identifier drawn from a
cryptographically secure random source. The user-facing outcome: exports get predictable,
portable, non-colliding names on every platform CueSync ships on, and no crafted title can
write outside the folder the user chose.

## 2. Plan

Atomic steps, all inside the existing `CueSync/` tree. No `Package.swift` edit is required —
`Support/` is already a source directory of the `CueSyncCore` target (`Package.swift` line 57,
`sources: ["Models", "Parsers", "Exporters", "Support"]`), so a new file there is compiled and
tested on every platform automatically.

1. **Create `CueSync/CueSync/Support/TextTools.swift`.** Declare `public enum TextTools` (a
   namespace, never instantiated), mirroring the shape of `Support/Hex.swift`. `import Foundation`
   only — **no** `AppKit`, `SwiftUI`, `Security`, `Combine`, or third-party import, so it stays
   in the shared core and links on Windows/Linux.

2. **Add `public static func slugify(_ input: String, maxLength: Int = 80, fallback: String = "untitled") -> String`.**
   Behaviour contract (implement, do not gold-plate beyond this):
   - Apply Unicode default-case-folding via `String.lowercased()` (locale-independent — do **not**
     use `lowercased(with:)` or any `Locale`-based API; Turkish-I divergence must not occur).
   - Reduce to the ASCII set `[a-z0-9-]`: every character not already in `[a-z0-9]` becomes a
     separator; **strip** non-ASCII letters rather than transliterating them (see §5 for why
     transliteration is not portable). NUL (`\0`) and all control characters are removed.
   - Collapse any run of separators (whitespace, `/`, `\`, `.`, `-`, stripped chars) to a single
     `-`; trim leading/trailing `-`.
   - Guarantee the result contains no `/`, no `\`, and is never `.` or `..` — i.e. it can only
     ever be a single, traversal-free path *component*.
   - Escape Windows reserved device names case-insensitively — `CON`, `PRN`, `AUX`, `NUL`,
     `COM1`–`COM9`, `LPT1`–`LPT9` — and a reserved name followed by an extension (`con.txt`), by
     prefixing the emitted slug with `_` so it is never emitted verbatim. Also ensure no trailing
     `.` or space survives (Windows silently strips those).
   - Truncate to `maxLength` characters on a separator boundary so truncation never leaves a
     trailing `-`.
   - If the cleaned result is empty (input was empty, whitespace-only, or entirely stripped),
     return `fallback` (which is itself a valid, non-empty slug).
   - Be a pure function: deterministic and idempotent (`slugify(slugify(x)) == slugify(x)`).

3. **Add `public static func generateToken(length: Int = 32) -> String`.** Behaviour contract:
   - Produce a `length`-character string over the URL- and filesystem-safe hex alphabet
     `[0-9a-f]`.
   - Source every byte from a **cryptographically secure** RNG: instantiate one
     `var rng = SystemRandomNumberGenerator()` and draw bytes/values through it (e.g.
     `UInt8.random(in: .min ... .max, using: &rng)`), then hex-encode. Hex encoding of whole
     bytes is used specifically so there is **no modulo bias**. Do **not** use `Date`, a counter,
     a PID, `Int.random(in:)` without the system generator, or any seedable/deterministic
     generator.
   - `length == 0` returns `""`; a negative `length` is treated as `0`. Odd lengths are supported
     (emit the final nibble of one extra byte).
   - Reuse `Support/Hex.swift`'s conventions if a hex helper is factored there; otherwise keep the
     encoding local. Do not add a dependency for hex.

4. **Add `Tests/CueSyncCoreTests/TextToolsTests.swift`** — an `XCTest` case in the
   `CueSyncCoreTests` target (runs under `swift test` on `windows-latest` + `macos-latest`, and in
   the existing custom runner). One test per acceptance criterion in §3.

5. **Do not modify `ResolumeExporter` or any exporter/filename call site in this ticket.** Rewiring
   the timestamp `uniqueId` (and existing filename sanitisation) to use `TextTools` is called out as
   the motivating use case but is explicitly **out of scope** here — it would touch the
   deterministic-export test contract (`ResolumeTests.testExportIsDeterministic…`) and belongs in a
   follow-up. This ticket ships the helper + its tests only.

## 3. Acceptance criteria

`slugify()`:
- `slugify("Hello World")` == `"hello-world"`.
- Runs of separators collapse: `slugify("a   b__c")` and `slugify("a---b")` contain no `--` and no
  leading/trailing `-`.
- Output is drawn only from `[a-z0-9-]`; any input outside that set (spaces, punctuation, emoji,
  accented/CJK letters) does not appear literally in the output.
- Path traversal is impossible: for inputs `"../../etc/passwd"`, `"..\\..\\win.ini"`, `"a/b\\c"`,
  the result contains no `/`, no `\`, no `..`, and is not `.` or `..`.
- NUL and control characters are dropped: `slugify("a\u{0}b\tc")` has no NUL/control chars.
- Windows reserved names are escaped: `slugify("CON")`, `slugify("con")`, `slugify("COM1")`,
  `slugify("LPT9")`, `slugify("NUL.txt")` each return a value that is **not** equal (case-insensitively)
  to a reserved device name.
- No trailing dot or space survives: `slugify("name.")` and `slugify("name ")` end in an alphanumeric
  or the trimmed slug, never `.` or ` `.
- Empty/degenerate input returns the non-empty fallback: `slugify("")`, `slugify("   ")`,
  `slugify("/// ...")` all equal `"untitled"` (default) and are never `""`.
- Result length ≤ `maxLength`, and a truncated result never ends in `-`.
- Deterministic and idempotent: same input → same output; `slugify(slugify(x)) == slugify(x)` for a
  representative input set.

`generateToken()`:
- `generateToken()` returns a 32-character string; `generateToken(length: n)` returns exactly `n`
  characters for `n` in a representative range (including odd `n`).
- Every character is in `[0-9a-f]`.
- `generateToken(length: 0)` == `""`; `generateToken(length: -5)` == `""`.
- Uniqueness/entropy: a batch of 10,000 default-length tokens contains zero duplicates, and two
  successive calls return different values.
- **Not** timestamp- or sequence-derived: tokens generated in a tight loop are not monotonically
  increasing and share no long common prefix (guards against a `Date`/counter regression).
- Distribution has no obvious modulo bias: over a large sample, all 16 hex symbols appear (sanity
  check that the alphabet is fully reachable).
- The implementation constructs a `SystemRandomNumberGenerator` and contains no `Date`,
  `timeIntervalSince`, seeded-RNG, or `arc4random`-with-fixed-seed usage (enforce via a source-grep
  test or code review checklist item).

Both:
- The module imports only `Foundation`; a grep test asserts `TextTools.swift` contains no `import AppKit`
  / `import SwiftUI` / `import Security`, keeping it in the cross-platform core.
- `swift build` and `swift test` pass on both `macos-latest` and `windows-latest` CI.

## 4. Threat model

- **Inputs crossing a trust boundary.** Every string reaching `slugify()` may originate from an
  **untrusted external file** parsed by `CueSyncCore` — Rekordbox XML, Serato ID3 GEOB tags, Engine DJ
  SQLite rows, ShowKontrol `.cue`, Resolume XML — or from a user-typed preset/track name. When such a
  value becomes an **export filename**, an unsanitised string enables directory traversal
  (`../../`), absolute-path escape (`/etc/…`, `C:\…`), NUL truncation, and — specifically on the newly
  supported Windows targets — collision with reserved device names (`CON`, `NUL`, `COM1`…) and the
  silent trailing-dot/space stripping that makes two distinct names resolve to one file. `slugify()`
  is the sanitiser at that boundary and must neutralise all of these; it emits a single path
  *component* and never a path.
- **Secrets / credentials touched.** No passwords, API keys, or licence tokens are handled — the
  Gumroad code is gone. `generateToken()` produces an **unguessable identifier**, not a secret to be
  stored; its security property is unpredictability + collision-resistance. It replaces the predictable
  `ResolumeExporter` `uniqueId = Int(Date().timeIntervalSince1970 * 1000)` anti-pattern (guessable,
  collides within a millisecond). The token must never be derived from time, PID, a counter, or a
  seedable RNG.
- **Value that must use a cryptographically secure primitive.** The token's random bytes. The required
  primitive is Swift's `SystemRandomNumberGenerator` — the standard-library CSPRNG that maps to
  `arc4random` on Darwin, `getrandom`/`/dev/urandom` on Linux, and `BCryptGenRandom` on Windows. Using
  any non-CSPRNG source for these bytes is a defect, not a style choice.
- **No filesystem side effects in the module.** `slugify()`/`generateToken()` return strings only; they
  never open, read, or write files and never construct absolute paths. Any caller needing a scratch path
  must join the component under `FileManager.default.temporaryDirectory` — never a hardcoded `/tmp` or a
  literal `\`/`/` separator.

## 5. Target platforms

- **macOS 14+** — native SwiftUI/AppKit build via `CueSync.xcodeproj`; `CueSyncCore` (and thus
  `TextTools`) compiles here unchanged.
- **Windows x64** and **Windows ARM64** — via SwiftPM (`swift build` / `swift test`, no Xcode).
  `TextTools` lives in `CueSyncCore`, already built and tested on `windows-latest` CI. It imports no
  AppKit/`Security`, so nothing gates it out.
- **Linux** — via SwiftPM; same source, same behaviour.
- **Dependencies:** Swift standard library + Foundation only — **zero third-party packages** added.
  `SystemRandomNumberGenerator` is part of the standard library and is present and cryptographically
  secure on all four targets, so **no dependency lacks Windows ARM64 support**. (Deliberately avoids
  `SecRandomCopyBytes`, which would require an `#if canImport(Security)` Darwin-only branch, and avoids
  pulling in `swift-crypto` for something the stdlib already provides.)
- **Cross-platform behaviour caveats honoured so output is byte-identical everywhere** (notably on
  Windows ARM64, where ICU behaviour can differ): `slugify()` must **not** use
  `String.applyingTransform(_:)` / `StringTransform` (Darwin-only ICU transliteration, unavailable or
  divergent on swift-corelibs-foundation) nor `String.folding(options: .diacriticInsensitive)` (ICU-
  dependent). It strips non-ASCII instead of transliterating, and relies only on
  `String.lowercased()` (Unicode default case folding, locale-independent) — all deterministic across
  platforms.
