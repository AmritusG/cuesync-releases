# CUESYNC-9 — `TextTools`: slugify() + a cryptographically secure generateToken()

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> ⚠️ **Scope / collision notice (read first).** A prior `specs/CUESYNC-9.md` on this
> branch described a *different* CUESYNC-9 — the "input is DEAD end-to-end" GTK/
> swift-cross-ui click-probe work that every commit on `adw/CUESYNC-9` targets. That
> file has been replaced by this one to match the ticket as handed to this run. The
> earlier content is preserved in git history (`git show HEAD:specs/CUESYNC-9.md`).
> Separately, the module this ticket asks for **already exists and is committed** at
> `CueSync/CueSync/Support/TextTools.swift` with a full XCTest suite at
> `Tests/CueSyncCoreTests/TextToolsTests.swift`; its own comments attribute it to
> CUESYNC-7. This spec therefore documents the *existing* contract as the source of
> truth so the Build Agent verifies (and, if anything drifted, restores) it rather
> than re-deriving a second, divergent implementation. **No new module, no API change,
> no gold-plating** beyond what the acceptance criteria below pin.

---

## 1. Problem

CueSync turns arbitrary, often untrusted text — track titles parsed out of Rekordbox /
Serato / Engine DJ files, user-typed preset names — into on-disk artifacts (export
filenames, `.cueproj` fields) and, in a few places, needs an unguessable identifier.
Two hardening jobs recur and must live in one small, dependency-free, cross-platform
place so every call site behaves identically on macOS, Windows (x64 **and** ARM64), and
Linux: (a) reduce any string to a single, traversal-free, filesystem-safe path
*component* (`slugify`), and (b) mint an unpredictable token from a cryptographically
secure source (`generateToken`). The user-facing outcome: exporting a track named
`../../etc/passwd`, `CON`, `café`, or `line1␍␊line2` never writes outside the chosen
folder, never collides with a Windows reserved device name, never produces an empty or
`.`/`..` filename, and never leaks a predictable token — with byte-identical results on
every target platform.

## 2. Plan

All work is in the shared, Foundation-only `CueSyncCore` target
(`CueSync/CueSync/…`, `sources: ["Models", "Parsers", "Exporters", "Support"]` in
`Package.swift`) so it compiles unchanged under both `CueSync.xcodeproj` (macOS) and
`swift build` (Windows/Linux). Atomic steps:

1. **Module.** `CueSync/CueSync/Support/TextTools.swift` — `public enum TextTools`
   (namespace, non-instantiable). `import Foundation` only. **No** `import AppKit`,
   `SwiftUI`, `Security`, or `Combine` (those pull in platform-specific or Apple-only
   frameworks and would break the Windows/Linux build and the port-compliance test).

2. **`slugify`.** `public static func slugify(_ input: String, maxLength: Int = 80, fallback: String = "untitled") -> String`. Pipeline, in order:
   1. `input.lowercased()` — **no `Locale`** (Unicode default case fold; deterministic
      across platforms, immune to the Turkish dotless-I divergence a locale-aware
      lowercase introduces).
   2. Walk `unicodeScalars`; keep only ASCII `[a-z0-9]` (scalar in `0x61…0x7A` or
      `0x30…0x39`). Every other scalar — whitespace, `/`, `\`, `.`, NUL, control chars,
      `\r`/`\n`/`\r\n`, Unicode line/paragraph/NEL/VT/FF separators, non-ASCII
      letters/digits, RTLO/zero-width/bidi controls — is a **separator**, dropped (not
      transliterated: ICU transliteration is not byte-identical across platforms).
   3. Join non-empty runs with a single `-` (this *is* "collapse separator runs, trim
      leading/trailing `-`").
   4. If the result is empty → return `fallback`.
   5. Truncate to `maxLength` **on a separator boundary** (back up to the last `-`
      inside the window; hard-cut only when no `-` fits) so the result never ends in
      `-` and never exceeds `maxLength`. `maxLength <= 0` → `fallback`.
   6. **After** truncation, if the slug equals a Windows reserved device name, prefix
      `_`. The reserved-name check must run on the *truncated* text, because truncation
      can itself land on a bare reserved token (e.g. `con-aaaa…` cut to `con`).
   7. If the underscore prefix pushes length past `maxLength`, re-truncate on a
      separator boundary (a no-op except at the exact boundary; a `_`-prefixed slug can
      never re-collapse into a bare reserved name). Empty at any guard → `fallback`.

3. **Reserved-name set.** Case-insensitive `Set<String>`: `con`, `prn`, `aux`, `nul`,
   `com1`…`com9`, `lpt1`…`lpt9` (22 names). Matched against the fully-reduced slug.

4. **`generateToken`.** `public static func generateToken(length: Int = 32) -> String`.
   Lowercase-hex `[0-9a-f]` of exactly `length` characters. `length <= 0` → `""`.
   Draw `ceil(length/2)` **whole bytes** from `SystemRandomNumberGenerator` (the Swift
   standard library CSPRNG) and hex-encode each byte's two nibbles; for odd `length`,
   emit the extra byte's first nibble via a final `prefix(length)`. **Whole-byte
   hex-encode — never `Int.random(in:) % n`** (no modulo bias). **No** `Date`,
   `timeIntervalSince*`, `ProcessInfo`, `getpid`, `srand`, counters, or any
   time/PID/sequence-derived value.

5. **Tests.** `Tests/CueSyncCoreTests/TextToolsTests.swift` (in the `CueSyncCoreTests`
   XCTest target) — one assertion cluster per acceptance criterion in §3, runnable via
   `swift test` on `macos-latest` and `windows-latest`.

6. **No call-site or `Package.swift` changes.** The module is additive to the existing
   `Support` sources; do not modify parsers/exporters as part of this ticket.

## 3. Acceptance criteria

Each bullet is a checkable statement backed by a test in `TextToolsTests.swift`.

**slugify — core**
- `slugify("Hello World") == "hello-world"` (lowercased, hyphen-joined).
- Separator runs collapse: `slugify("a   b__c") == "a-b-c"`, `slugify("a---b") == "a-b"`; output has no `--`, no leading `-`, no trailing `-`.
- Output scalars are drawn only from `[a-z0-9-]` for every input, including `café`, `日本語`, `🎧🎛️`, and mixed case/punctuation.
- Idempotent and deterministic: `slugify(slugify(x)) == slugify(x)` and repeated calls agree, for all inputs.

**slugify — security / trust boundary**
- Path-traversal inputs never yield `/`, `\`, or `..`, and never equal `.` or `..`: `slugify("../../etc/passwd")`, `slugify("..\\..\\win.ini")`, `slugify("a/b\\c")` all pass.
- NUL and control characters are dropped: `slugify("a\u{0}b\tc") == "a-b-c"`; no scalar `< 0x20` survives.
- Bidi/RTLO (`U+202E`), zero-width (`U+200B`/`U+200D`), and non-ASCII whitespace (`U+00A0`/`U+2003`) never appear literally in the output.
- Windows reserved device names are escaped with a `_` prefix across all casings: for every name in {`con`,`prn`,`aux`,`nul`,`com1`…`com9`,`lpt1`…`lpt9`}, `slugify(name) == "_" + name`; `slugify("NUL.txt")` does not equal a bare reserved name.
- No trailing `.` or space survives: `slugify("name.") == "name"`, `slugify("name ") == "name"` (Windows silently strips these, enabling collisions).
- CRLF and Unicode line separators each collapse to a single `-`, including the two-char `\r\n` (no doubled `--`).

**slugify — fallback & length**
- Empty/degenerate input returns the fallback: `slugify("")`, `slugify("   ")`, `slugify("/// ...")` all `== "untitled"`; a custom `fallback:` is returned verbatim.
- Result length never exceeds `maxLength`; truncation lands on a separator boundary with no trailing `-` (`slugify("hello world again", maxLength: 8) == "hello"`).
- `maxLength <= 0` returns the fallback; `maxLength` equal to the slug length does **not** truncate; `maxLength: 1` on a separator-less window hard-cuts to one char (`slugify("hello world", maxLength: 1) == "h"`).

**generateToken — correctness & security**
- Default length is 32 characters; explicit lengths (incl. odd: 1, 5, 7, 33) produce exactly that many characters; `length <= 0` → `""`.
- Every character is lowercase hex `[0-9a-f]`; across a large sample all 16 symbols appear.
- Uniqueness/entropy: 10,000 default-length tokens are all distinct; successive calls differ; tokens are **not** monotonically increasing and share no long common prefix (guards against a `Date`/counter regression).
- Very large `length` (e.g. 10,000) returns the exact count without crashing.

**Port-compliance (static source assertions)**
- `TextTools.swift` imports `Foundation` and contains none of `import AppKit`/`SwiftUI`/`Security`/`Combine`.
- Source contains `SystemRandomNumberGenerator` and none of `Date(`, `timeIntervalSince`, `arc4random_buf`, `srand`, `ProcessInfo`, `getpid(`.
- Source has no filesystem side effects: none of `FileManager`, `contentsOf`, `.write(to:`, `fileURLWithPath`.

## 4. Threat model

- **Trust boundary — slugify input.** Callers pass attacker-influenced text: track
  titles/artist/comment fields read out of third-party DJ files (Rekordbox XML, Serato
  ID3 GEOB, Engine DJ SQLite) and user-typed preset names. That text becomes a **path
  component** in an export filename. Threats mitigated by the allowlist-not-blocklist
  design (keep only `[a-z0-9]`, everything else is a separator):
  - *Path traversal / absolute paths* — `/`, `\`, `..`, `.` can never survive, so a slug
    is always a single component under the chosen directory, never an escape.
  - *NUL / control-char injection* — truncates C-string paths, corrupts logs; stripped.
  - *Windows reserved device names* (`CON`, `COM1`, …) — opening such a filename targets
    a device; escaped with `_`.
  - *Trailing dot/space* — Windows strips them, enabling silent collisions/traversal;
    removed.
  - *Homoglyph / RTLO / zero-width disguise* (e.g. `U+202E` reversing `exe`→`gnp`) — all
    non-ASCII scalars dropped, so the visible/actual name cannot diverge.
  - *Empty-name / dotfile* — degenerate input yields a non-empty, non-`.`/`..` fallback.
- **Cryptographically secure primitive — generateToken.** The token is the one value
  here that must be **unpredictable**; if a call site uses it as an unguessable id,
  predictability is a security defect. It **must** be sourced from
  `SystemRandomNumberGenerator` — the standard library CSPRNG, which maps to
  `arc4random` (Darwin), `getrandom`/`/dev/urandom` (Linux), and `BCryptGenRandom`
  (Windows). Explicitly forbidden: `Date`/timestamp, PID, process-global counters, or
  any seeded/reproducible RNG; and modulo reduction of a wide integer into the hex
  alphabet (bias). Whole-byte hex-encoding is unbiased. Entropy: default 32 hex chars =
  16 bytes = 128 bits.
- **Secrets/credentials.** None are read, stored, or logged by this module. The token
  itself is the only sensitive value produced; the module returns it as a string and
  performs no logging.
- **No side effects.** `slugify`/`generateToken` are pure string→string; they must not
  touch the filesystem, network, environment, or global mutable state. This is asserted
  statically (§3 port-compliance) and keeps the trust-boundary reasoning local to the
  call site that writes the file.

## 5. Target platforms

Faithful port target set — all supported, no platform-specific code path in this module:

| Platform | Build | Status |
|---|---|---|
| **macOS** 14.0+ | `CueSync.xcodeproj` (⌘R) and `swift build` | ✅ supported |
| **Windows x64** | `swift build` (SwiftPM; no Xcode) | ✅ supported |
| **Windows ARM64** | `swift build` | ✅ supported |
| **Linux** | `swift build` | ✅ supported |

- **No third-party dependency is introduced.** The module uses only the Swift standard
  library (`String`, `unicodeScalars`, `SystemRandomNumberGenerator`, `UInt8.random`)
  plus `import Foundation` for `String` — all present in swift-corelibs-foundation on
  Windows and Linux. Therefore **nothing here lacks Windows-ARM64 support**; there is no
  dependency to flag. (The unrelated `swift-cross-ui`/`GtkBackend` dependency already
  pinned in `Package.swift` is out of scope for this ticket.)
- **Cross-platform primitives, no hardcoding.** Randomness comes from the stdlib CSPRNG
  (resolves to the correct OS primitive per platform) — no `/dev/urandom` path is
  written literally. The module produces a filename *component* only; it never
  concatenates path separators, never hardcodes `/tmp` (callers own directory choice via
  `NSSavePanel`/portable temp dirs elsewhere), and its output is line-ending-agnostic
  (all of `\r`, `\n`, `\r\n` are treated as separators, not emitted).
- **Determinism across platforms.** Case folding uses locale-independent `.lowercased()`
  and the scalar allowlist is pure ASCII, so a given input yields the identical slug on
  every target — required for reproducible export filenames and for the CI suite to
  assert equality on both `macos-latest` and `windows-latest`.
