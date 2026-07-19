# CUESYNC-9 (text_tools) — `TextTools`: `slugify()` + secure `generateToken()`

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> ⚠️ **Routing note — read first.** This ticket ("Add a text_tools module with `slugify()`
> and a secure `generate_token()` helper") describes work that is **already implemented,
> tested, and shipped** in this repo:
>
> - Source: `CueSync/CueSync/Support/TextTools.swift` (in the `CueSyncCore` target).
> - Tests: `Tests/CueSyncCoreTests/TextToolsTests.swift` (44 cases across slugify/token/compliance).
> - Live callers: `ExportSectionView.swift:84,103`, `ProjectSectionView.swift:302`.
> - The module and its tests both cite **spec CUESYNC-7 §2/§3/§4/§5** as their home — this
>   is CUESYNC-7 work, not CUESYNC-9.
>
> The number `CUESYNC-9` is *already taken* by an unrelated, actively-worked spec —
> `specs/CUESYNC-9.md` ("input is DEAD end-to-end; fix it at the root, machine-verified"),
> plus `specs/CUESYNC-9-findings.md` and three `CUESYNC9…WorkflowTests.swift`. That spec was
> **left untouched**; this document was written to a non-colliding filename to avoid destroying
> it. This spec therefore serves as the authoritative, retroactive spec for the shipped
> `TextTools` module and as a **verification checklist**, not a request to build from scratch.
> **Build Agent: treat the Plan below as verification steps — do not re-create files that already
> exist; only fill a gap if a criterion in §3 fails.**

---

## 1. Problem

CueSync builds export filenames and identifiers out of arbitrary, frequently-untrusted text —
track titles parsed from Rekordbox XML / Serato GEOB / Engine DJ SQLite / ShowKontrol `.cue`
files, and preset/project names typed by the user. Concatenating that text straight into a path
is unsafe: a title like `../../etc/passwd`, `CON`, `name.`, or one carrying NUL, control, bidi,
or line-separator characters yields a traversal, a reserved Windows device name, or a filename
that behaves differently on macOS vs. Windows vs. Linux. Separately, the app needs unguessable
identifiers that are not derived from a timestamp or a counter. The user-facing outcome: exports
and project files always land at a single, safe, cross-platform filename *component* no matter
what the source text contains, and any generated identifier is unpredictable — with identical
behavior on every target OS.

## 2. Plan

All steps live in the cross-platform `CueSyncCore` target (`path: "CueSync/CueSync"`,
`sources: [..., "Support"]` in `Package.swift`). Standard library + `Foundation` only.

1. Add `CueSync/CueSync/Support/TextTools.swift` exposing `public enum TextTools` (a namespace,
   no instances) with two static functions and no stored state beyond `private static let`
   lookup tables.
2. `slugify(_ input: String, maxLength: Int = 80, fallback: String = "untitled") -> String`:
   1. Case-fold with `input.lowercased()` — **no `Locale`** (default Unicode case folding;
      avoids the Turkish-I divergence a locale-aware lowercase introduces).
   2. Walk `unicodeScalars`; keep only ASCII `[a-z0-9]`, treating every other scalar as a
      separator. Emit maximal keep-runs joined by a single `-` (this collapses separator runs
      and trims leading/trailing `-` in one pass). Non-ASCII letters/digits are **stripped, not
      transliterated** (ICU transliteration is not byte-identical across platforms).
   3. If the reduced slug is empty, return `fallback`.
   4. Truncate to `maxLength` on a `-` boundary (back up to the last `-` in the window; hard-cut
      only when the window contains no `-`) so a truncated slug never ends in `-`.
   5. **After truncation**, if the result equals a Windows reserved device name, prefix `_`.
      (Order matters: truncation can itself land on a bare reserved token, so the escape must run
      on the truncated value.) Re-truncate the escaped value to keep it within `maxLength`.
   6. If anything above collapses to empty (e.g. `maxLength <= 0`), return `fallback`.
3. `generateToken(length: Int = 32) -> String`: return a `length`-character lowercase-hex
   (`[0-9a-f]`) string. `length <= 0` returns `""`. Draw whole bytes from
   `SystemRandomNumberGenerator` (`var rng = SystemRandomNumberGenerator();
   UInt8.random(in: .min ... .max, using: &rng)`) and hex-encode each byte's two nibbles — **never**
   `Int.random(in:) % 16` (modulo bias). Odd `length` draws `⌈length/2⌉` bytes and keeps the
   first `length` characters.
4. Route the app's existing filename construction through `slugify` (already done at
   `ExportSectionView.swift:84,103` and `ProjectSectionView.swift:302` — verify, do not
   duplicate).
5. Keep the module free of any `AppKit` / `SwiftUI` / `Security` / `Combine` import and of any
   filesystem call, so it compiles unchanged in `CueSyncCore` on every platform.

## 3. Acceptance criteria

Each bullet is a checkable statement; the existing `Tests/CueSyncCoreTests/TextToolsTests.swift`
already encodes one test per item.

**`slugify`**
- `slugify("Hello World") == "hello-world"` (lowercased, space → single `-`).
- Runs of separators collapse to one `-` with no leading/trailing `-`: `"a   b__c" → "a-b-c"`,
  `"a---b" → "a-b"`.
- Output contains only `[a-z0-9-]` for accented / CJK / emoji / mixed-case inputs.
- Traversal inputs (`"../../etc/passwd"`, `"..\\..\\win.ini"`, `"a/b\\c"`) never produce `/`, `\`,
  `..`, `.`, or a bare `..`.
- NUL and control characters (`< 0x20`) are dropped: `"a\u{0}b\tc" → "a-b-c"`.
- Windows reserved device names are escaped with a `_` prefix across **all** casings for the full
  matrix `con, prn, aux, nul, com1..9, lpt1..9` (e.g. `"CON" → "_con"`); `"NUL.txt" → "nul-txt"`
  (not reserved, the `.` already split it).
- No trailing `.` or space survives: `"name." → "name"`, `"name " → "name"`.
- Degenerate input (`""`, `"   "`, `"/// ..."`) returns the fallback (`"untitled"`, or a
  caller-supplied `fallback` when given, e.g. `fallback: "no-name"`).
- Result length never exceeds `maxLength`; truncation cuts on a `-` boundary
  (`slugify("hello world again", maxLength: 8) == "hello"`); `maxLength <= 0` returns fallback;
  `maxLength` exactly equal to the slug length does not truncate; a `-`-free window hard-cuts
  (`maxLength: 1` of `"hello world"` == `"h"`).
- Deterministic and idempotent: `slugify(x) == slugify(x)` and `slugify(slugify(x)) == slugify(x)`.
- CRLF, lone `\r`/`\n`, and Unicode NEL/LS/PS/VT/FF each act as a **single** separator (no doubled
  `--` from `\r\n`).
- Bidi-override (U+202E), zero-width (U+200B/200D), and non-ASCII whitespace (U+00A0/2003) are
  never emitted literally.

**`generateToken`**
- Default length is 32 characters; explicit lengths (incl. odd: 1,2,5,7,33,…) return exactly that
  many characters; `length <= 0` returns `""`.
- Every character is lowercase hex `[0-9a-f]`; all 16 symbols are reachable across a large sample.
- 10,000 default-length tokens are all distinct; successive calls differ; tokens are **not**
  monotonically increasing and share no long common prefix (guards against a Date/counter
  regression).
- `length: 10_000` produces exactly 10,000 hex chars without crashing.

**Port compliance**
- `TextTools.swift` imports `Foundation` and **not** `AppKit`, `SwiftUI`, `Security`, or `Combine`.
- Token generation is backed by `SystemRandomNumberGenerator`; the source contains no `Date(`,
  `timeIntervalSince`, `arc4random_buf`, `srand`, `ProcessInfo`, or `getpid(`.
- No filesystem side effects: source contains no `FileManager`, `contentsOf`, `.write(to:`, or
  `fileURLWithPath`.

## 4. Threat model

- **Trust boundary — `slugify` input.** Track titles come from third-party files (Rekordbox XML,
  Serato ID3 GEOB, Engine DJ SQLite, ShowKontrol `.cue`) and are attacker-influenceable; preset
  and project names are user-typed. All of this text is used to build **export filenames**. The
  boundary hardening `slugify` must enforce: no path traversal (`/`, `\`, `..`), never a bare `.`
  or `..`, no NUL or control characters (which truncate/confuse filesystem APIs), no Windows
  reserved device name (`CON`, `NUL`, `COM1`… — opening one can hang or redirect I/O), no trailing
  dot or space (Windows silently strips them, changing the effective name), and no disguising
  scalars (RTLO U+202E, zero-width joiners, non-ASCII whitespace). The output is a single path
  **component**, never a path — the caller composes it under a directory it already controls.
- **Cryptographic primitive — `generateToken`.** The identifier **must** use a cryptographically
  secure RNG. The chosen primitive is the standard library's `SystemRandomNumberGenerator`
  (system CSPRNG on every platform); the value is whole-byte hex-encoded to avoid modulo bias.
  Explicitly forbidden: timestamp-, PID-, or counter-derived values, seedable/`srand`-style PRNGs,
  and `Int.random(in:) % n`. Although the current app does not use the token as an auth secret,
  it is the project's unguessable-identifier primitive and is treated as security-sensitive so it
  stays safe if a future caller uses it for one.
- **No secrets/credentials are read, stored, or logged**, and the module performs **no filesystem
  or network I/O** — it is pure `String → String`. This is asserted by the port-compliance tests
  so a future edit can't quietly add a side effect.

## 5. Target platforms

- **macOS** — supported. `SystemRandomNumberGenerator` → `arc4random`; `Foundation` string APIs.
- **Windows x64** — supported. `SystemRandomNumberGenerator` → `BCryptGenRandom`.
- **Windows ARM64** — supported. Same code path as x64; **no third-party dependency is used**, so
  there is **no Windows-ARM64 gap** to flag. (The one Apple-only crypto primitive that would have
  caused a gap — `Security.framework` / `SecRandomCopyBytes` — is deliberately **not** used.)
- **Linux** — supported. `SystemRandomNumberGenerator` → `getrandom`/`/dev/urandom`.

Cross-platform correctness notes that are load-bearing, not incidental: case-folding uses
`lowercased()` **without a `Locale`** (identical result on every OS; avoids Turkish-I divergence);
non-ASCII is **stripped, not transliterated** (ICU transliteration output is not byte-identical
across platforms); no hardcoded path separator, `/tmp`, or line ending appears anywhere in the
module. The module lives in the `CueSyncCore` library target and compiles identically on all four
platforms with no `#if os(...)` guard required.
