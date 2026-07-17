# CUESYNC-6e — Repair the *nested* swift-java symlink on Windows (generically, all layers)

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> Faithful port. This ticket writes **no application code and no test code**. It touches
> exactly one file — `.github/workflows/swift-windows.yml` — and inside it, exactly one step
> (present identically in both the `windows-build` and `windows-test` jobs): the
> **"Repair swift-java Windows plugin symlinks"** step CUESYNC-6d added. Everything else in the
> workflow — the Swift 6.3.3 install + retry, the pinned gvsbuild GTK 4 acquisition and its
> SHA-256 gate, the `.pc` prefix rewrite, the SwiftPM caches, the swift-cross-ui gulong/gsize
> patch, `Build (release)`, `Test`, the `wldd` closure check with its negative control, and
> every action SHA pin — stays **byte-for-byte as CUESYNC-6d left it**. `Package.swift`,
> `Package.resolved`, `GtkBackend`, and `xcodebuild -scheme CueSync build` are untouched. No
> screen is ported; no view is touched.
>
> **Definition of Done:** both Windows jobs get **past** the swift-java plugin compile — no more
> `cannot find 'readConfiguration' in scope` — and reach the real CueSync `Build (release)` /
> `Test`. macOS stays green. Whatever the *next* real error is (most likely a genuine
> CueSync+GtkBackend build/link failure) becomes the next finding — that is forward progress,
> not this ticket's concern.

---

## 0. Confirmed premises (read before editing)

Unlike CUESYNC-6d, this ticket's premises are **confirmed against the branch you are on**, not
assumptions — verify them yourself in one pass, then proceed:

1. **The pin.** `Package.resolved` pins `swift-java` to
   `stackotter/swift-java` revision `e04c0ed6af98936ca6300e94be9a19869df418a2`, version `0.5.1`.
   *(Confirmed: `Package.resolved` lines 86–92.)*
2. **Layer #1 is already repaired.** The step
   **"Repair swift-java Windows plugin symlinks (pinned via Package.resolved, 0.5.1)"** exists in
   *both* the `windows-build` and `windows-test` jobs and, today, loops over a **hardcoded** list
   of three plugin names (`JExtractSwiftPlugin`, `SwiftJavaPlugin`, `JavaCompilerPlugin`),
   replacing each `Plugins/<Plugin>/_PluginsShared` link with an NTFS **Junction** to
   `Plugins/PluginsShared`. This is the layer that already works.
   *(Confirmed: `.github/workflows/swift-windows.yml` lines 354–370 and 715–731.)*
3. **Layer #2 is NOT repaired.** `Plugins/PluginsShared/SwiftJavaConfigurationShared` is itself a
   git symlink → `../../Sources/SwiftJavaConfigurationShared`. It is never touched by the
   hardcoded 3-plugin loop, so on Windows it remains a dead reparse point. `readConfiguration`
   is defined in `Sources/SwiftJavaConfigurationShared/Configuration.swift`, reachable from the
   plugins **only** through this second link — hence `cannot find 'readConfiguration' in scope`
   when it is broken. The repo ships `Plugins/PluginsShared/0_PLEASE_SYMLINK.txt` as a marker
   that these dirs are meant to be symlinks, not vendored.
4. **No test guards the repair step.** No file under `Tests/` asserts on this step's name,
   its plugin list, or its use of junctions. The adversarial supply-chain tests inspect only
   `uses:` pins and the GTK-acquisition (`vcpkg|pacman|gvsbuild|download`) surface — none of
   which this change goes near. *So this ticket is expected to touch `Tests/` in zero places.*
   Confirm with a grep for `Repair`, `_PluginsShared`, `Junction`, `ls-files` under `Tests/`
   (all empty today); if that changes, apply the repo's §E.24 rule — retarget, never weaken.

The root cause is therefore not a source defect but a **generic Windows symlink-materialization
problem**: this dependency shares plugin sources via git symlinks in more than one layer, git's
parallelized Windows checkout materializes those symlinks as broken reparse points (or plain
text files, or raced directories), and CUESYNC-6d only repaired the one layer it enumerated by
hand. The fix is to repair **every** git symlink in the checkout generically, not to add
layer #2 to a second hardcoded list.

---

## 1. Problem

CUE SYNC's Windows CI builds the full SwiftPM package graph, which transitively resolves and
compiles `stackotter/swift-java`'s SwiftPM plugins even though CueSync only links `GtkBackend`.
That dependency shares source between plugin targets using **two nested layers** of git
symlinks. CUESYNC-6d fixed only the outer layer (`Plugins/<Plugin>/_PluginsShared`) using a
hardcoded list of three plugin names, and left the inner layer
(`Plugins/PluginsShared/SwiftJavaConfigurationShared → ../../Sources/SwiftJavaConfigurationShared`)
a dead reparse point on Windows. Because `readConfiguration` lives behind that inner link, both
Windows jobs fail to compile the plugins with `cannot find 'readConfiguration' in scope`, which
blocks them before they ever reach CueSync's own `Build (release)` / `Test`. The user-facing
outcome: the Windows CI leg is stuck on a dependency-plumbing error that has nothing to do with
CueSync's code, and the port can't make forward progress until the Windows plugin checkout is
whole. This ticket makes the repair **generic** — it repairs every broken git symlink in the
`swift-java` checkout (both layers, and any future ones) by reading each link's intended target
from git's own index and re-materializing it as a privilege-free NTFS junction — so the Windows
jobs get past swift-java and hit the real CueSync build. Nothing about the app changes; a DJ on
macOS sees no difference.

---

## 2. Plan

**One file, one step, both jobs.** Replace the body of the existing
**"Repair swift-java Windows plugin symlinks"** step in **both** `windows-build` (workflow
lines ~354–370) and `windows-test` (lines ~715–731) with a single generic implementation, kept
byte-identical between the two jobs. Keep the step's position unchanged — **after**
`swift package resolve` (which materializes `.build\checkouts\swift-java`) and **before** the
swift-cross-ui gulong patch and `Build (release)` / `Test`. Do not add, remove, reorder, or edit
any other step.

Steps are atomic:

1. **Confirm §0** — the pin (`Package.resolved`), that the "Repair swift-java …" step exists in
   both jobs with the hardcoded 3-plugin loop, and that no `Tests/` file references the repair
   step. If any is false, stop and report.

2. **Replace the hardcoded loop with a generic enumeration** driven by git's index — the
   authoritative record of which tracked entries are symlinks, independent of how Windows
   materialized them on disk. Use `git -c core.quotePath=false -C <checkout> ls-files -s` and
   keep only entries whose mode is `120000` (symlink). This single mechanism covers the outer
   `_PluginsShared` links **and** the nested `PluginsShared/SwiftJavaConfigurationShared` link
   **and** any other symlink the repo adds later — replacing, not extending, the 3-name list.

3. **For each symlink entry**, in order:
   1. Read the **intended POSIX target** from the git blob itself — the blob content of a symlink
      *is* its target text, with no trailing newline. Use the blob SHA from `ls-files -s`:
      `git -C <checkout> cat-file blob <sha>`. (Read from git, **not** from the on-disk
      materialization, which may be an unreadable broken reparse point or a text file.) Trim
      surrounding whitespace/CR.
   2. **Resolve to an absolute path** relative to the symlink's own directory using
      `[System.IO.Path]::GetFullPath([System.IO.Path]::Combine($linkDir, $posixTarget))` —
      `GetFullPath` normalizes both `..` segments and POSIX `/` on Windows. Do **not** hardcode a
      separator or a drive path.
   3. **Assert the target exists** on disk (`Test-Path -LiteralPath`). If it does not, the fix is
      wrong for that entry — `Write-Error` + `exit 1`. Do **not** create a junction to a
      nonexistent path.
   4. **Delete whatever git materialized** at the link path, handling all three forms: a reparse
      point (`Remove-Item -Force`), a real directory (`Remove-Item -Recurse -Force`), or a plain
      file (`Remove-Item -Force`). `-Force` also clears the read-only attribute SwiftPM sets on
      Windows checkouts, so no separate `IsReadOnly` reset is needed (matches the proven layer-#1
      precedent, which creates junctions inside the same read-only checkout).
   5. **Re-materialize** the link: for a **directory** target, an NTFS
      `New-Item -ItemType Junction` (needs no privilege, transparent to directory enumeration —
      exactly why it already fixed layer #1); for a **file** target (none known today, but the
      generic walk must not crash on one), an NTFS `New-Item -ItemType HardLink`. Log each
      `link -> target` mapping.

4. **Fail loud on an empty result.** There are at least four known symlinks (three
   `_PluginsShared` + one `SwiftJavaConfigurationShared`). If the enumeration repairs **zero**
   entries, the enumeration mechanism itself is broken — `Write-Error` + `exit 1` rather than
   letting the job proceed to a confusing `cannot find …` failure later. Also fail if
   `git ls-files` / `git cat-file` returns a nonzero exit. This honors the ticket's rule: **do
   not allowlist errors into silence.**

5. **Idempotency.** Re-running must be a no-op-equivalent: on a second pass each repaired path is
   now a reparse-point junction, which step 3.4 deletes and step 3.5 recreates identically.
   State this in the step's comment.

6. **Keep both jobs identical.** Apply the exact same replacement to `windows-build` and
   `windows-test`. A divergence between them means the build artifact and the test evidence come
   from differently-patched checkouts.

7. **Rewrite the step's leading comment** so it describes the generic, all-layers behavior and
   the two confirmed layers (outer `_PluginsShared`, nested `SwiftJavaConfigurationShared`),
   rather than the 3-plugin-only story it tells today. The step name may stay as-is or be lightly
   amended to read "all layers"; either is safe (no test asserts it).

8. **Change nothing else.** No other step, no cache key, no pin, no `uses:` ref, no comment
   elsewhere, and no file under `CueSync/`, `Sources/`, `Tests/`, `Package.swift`, or
   `Package.resolved`.

9. **Verify on real CI** — every failure mode here (checkout race, junction creation, git-index
   read) is Windows-only and unobservable locally. Push, read the run, and confirm each §3 item
   against actual logs.

### Reference implementation (target shape — verify on CI, adapt as the logs demand)

```yaml
      - name: Repair swift-java Windows symlinks (all layers, generic; pinned via Package.resolved 0.5.1)
        shell: pwsh
        run: |
          # swift-java shares plugin sources via git symlinks in TWO nested layers:
          #   1. Plugins/<Plugin>/_PluginsShared          -> ../PluginsShared            (outer)
          #   2. Plugins/PluginsShared/SwiftJavaConfigurationShared
          #                                               -> ../../Sources/SwiftJavaConfigurationShared  (nested)
          # readConfiguration lives behind layer #2 (Sources/SwiftJavaConfigurationShared/
          # Configuration.swift), so a broken layer #2 on Windows produces
          # "cannot find 'readConfiguration' in scope". CUESYNC-6d repaired only
          # layer #1, by a hardcoded plugin list. This repairs EVERY git symlink in
          # the checkout generically: git's index is the source of truth for which
          # tracked entries are symlinks (mode 120000), regardless of how Windows
          # materialized them (broken reparse point / plain text file / raced dir).
          # Directory targets become privilege-free NTFS junctions (transparent to
          # enumeration, which is why junctions already fixed layer #1). Idempotent:
          # a second pass deletes the junction it made and recreates an equivalent one.
          $repo = ".build\checkouts\swift-java"
          if (-not (Test-Path -LiteralPath $repo)) {
            Write-Error "swift-java checkout not found at $repo — did 'swift package resolve' run?"; exit 1
          }
          $entries = & git -c core.quotePath=false -C $repo ls-files -s
          if ($LASTEXITCODE -ne 0) { Write-Error "git ls-files failed in $repo"; exit 1 }

          $repaired = 0
          foreach ($entry in $entries) {
            # "<mode> <sha> <stage>\t<path>" — keep symlinks only
            if ($entry -notmatch '^120000\s+([0-9a-f]{40})\s+\d+\t(.+)$') { continue }
            $blobSha = $Matches[1]; $relPath = $Matches[2]

            $linkFull = [System.IO.Path]::GetFullPath((Join-Path $repo $relPath))
            $linkDir  = Split-Path -Parent $linkFull

            $target = (& git -C $repo cat-file blob $blobSha | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($target)) {
              Write-Error "could not read symlink target for $relPath"; exit 1
            }
            $targetAbs = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($linkDir, $target))
            if (-not (Test-Path -LiteralPath $targetAbs)) {
              Write-Error "symlink $relPath -> $targetAbs : target does not exist on disk"; exit 1
            }

            $existing = Get-Item -LiteralPath $linkFull -Force -ErrorAction SilentlyContinue
            if ($existing) {
              if ($existing.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                Remove-Item -LiteralPath $linkFull -Force
              } elseif ($existing.PSIsContainer) {
                Remove-Item -LiteralPath $linkFull -Recurse -Force
              } else {
                Remove-Item -LiteralPath $linkFull -Force
              }
            }

            if (Test-Path -LiteralPath $targetAbs -PathType Container) {
              New-Item -ItemType Junction -Path $linkFull -Target $targetAbs | Out-Null
              Write-Host "junction: $relPath -> $targetAbs"
            } else {
              New-Item -ItemType HardLink -Path $linkFull -Target $targetAbs | Out-Null
              Write-Host "hardlink: $relPath -> $targetAbs"
            }
            $repaired++
          }

          if ($repaired -eq 0) {
            Write-Error "no git symlinks (mode 120000) found under $repo — enumeration is broken; refusing to proceed silently"; exit 1
          }
          Write-Host "repaired $repaired swift-java symlink(s)"
```

---

## 3. Acceptance criteria

- **The repair is generic, not a second hardcoded list.** In both `windows-build` and
  `windows-test`, the repair step enumerates symlinks from git's index
  (`ls-files -s`, mode `120000`) rather than iterating a fixed set of plugin names.
- **Both layers are repaired.** The step repairs the outer `Plugins/<Plugin>/_PluginsShared`
  links **and** the nested `Plugins/PluginsShared/SwiftJavaConfigurationShared` link. The CI log
  for the step shows at least four `link -> target` mappings, including one ending in
  `SwiftJavaConfigurationShared`.
- **Directory targets become NTFS junctions** (no `-ItemType SymbolicLink`, no elevated
  privilege, no Developer Mode requirement).
- **The step fails loud, never silent.** It `exit 1`s if `git ls-files`/`git cat-file` errors, if
  a resolved target does not exist, or if it repairs **zero** symlinks. It does not swallow or
  allowlist any of these into a pass.
- **The step is idempotent** — re-running replaces each link with an equivalent one and still
  exits 0.
- **Both Windows jobs carry byte-identical repair steps.**
- **The `readConfiguration` error is gone.** Neither Windows job emits
  `cannot find 'readConfiguration' in scope` (nor the sibling `getEnvironmentBool` /
  `SwiftJavaPluginProtocol` "cannot find … in scope" errors from the same broken shared-sources
  layers). Both jobs get **past** swift-java's plugin compilation and into CueSync's own
  `Build (release)` / `Test`.
- **Forward progress is reported, not hidden.** Whatever the next real error is (most likely a
  genuine CueSync + GtkBackend build/link failure) is surfaced as the next finding rather than
  worked around here.
- **macOS is provably unaffected.** The repair step runs only in the two Windows (`pwsh`) jobs;
  the `macos` job has no such step and uses native symlinks. `swift build -c release` stays green
  on macOS, and `xcodebuild -scheme CueSync build` still succeeds. *(The known, separate macOS
  `Test` failure is out of scope and is not attributable to this Windows-only change.)*
- **Test count does not regress.** Re-establish the current XCTest baseline `N` empirically
  (`swift test -c release`, `CueSyncCoreTests`) — do **not** treat the ticket's "179" as the
  target; CUESYNC-6d established the real number empirically (~245). `N` must not decrease, and no
  test is added, deleted, skipped, `XCTSkip`-ed, commented out, or weakened.
- **The DLL closure check still passes and its negative control still fires** on `windows-build`
  (this change does not touch it, but it must remain green once the build gets far enough to run
  it).
- **The diff is workflow-only.** `git diff` against the branch base touches exactly two paths:
  `.github/workflows/swift-windows.yml` and `specs/CUESYNC-6e.md`. Within the workflow, only the
  two repair steps (and their leading comments) change; every other step, cache key, comment, and
  action SHA pin is byte-identical. No file under `CueSync/`, `Sources/`, `Tests/`,
  `Package.swift`, or `Package.resolved` changes.

---

## 4. Threat model

No runtime input handling, no parsing, no user-facing surface, and **no network fetch** is added.
This is a CI-only change that reads local git blobs and creates local NTFS reparse points.

**Inputs crossing a trust boundary**

| Input | Boundary | Control |
|---|---|---|
| The symlink target text read from each git blob (`git cat-file blob`) | Pinned dependency tree → a junction target on the runner | The text comes from `swift-java` pinned to the **immutable revision** `e04c0ed6…` in `Package.resolved` — a commit whose code the build already compiles and trusts. Reading its symlink targets and re-materializing them as junctions grants no capability the build did not already have. The step additionally asserts each resolved target **exists on disk** before creating a link, and never creates a link to a nonexistent path. |
| The `swift-java` checkout on disk (however git raced it) | git checkout → repair step | Not trusted as the source of truth — the step reads the *intended* target from git's index/blob, not from the possibly-broken on-disk materialization, and deletes whatever git produced (reparse point, file, or dir) before recreating the link. |

**Defense-in-depth (recommended, not required for DoD):** the resolved junction target is
derived from attacker-influenced-only-insofar-as-the-pin-is symlink text; both known targets
(`Plugins/PluginsShared`, `Sources/SwiftJavaConfigurationShared`) resolve *inside* the checkout
root. Optionally assert `targetAbs` starts with the checkout's full path and `Write-Error` +
`exit 1` otherwise, so a future dependency revision that shipped an out-of-tree symlink
(`../../../../Windows`) could not silently junction outside the checkout. This is cheap hardening
consistent with the repo's fail-loud posture; it is not mandated because the dependency is
already pinned to a trusted immutable commit.

**Secrets / credentials:** none. The step reads no `secrets.*`, touches no keychain, and adds no
`GITHUB_TOKEN` usage beyond what `actions/checkout` already does at default permissions. It
downloads nothing and logs no environment.

**Cryptographically secure primitives:** none required and none introduced — no tokens, nonces,
identifiers, randomness, or hashing. The 40-hex value handled here is a **git blob SHA-1 content
address supplied by git**, used only to name the blob to read; it is not a security check, not
generated here, and must not be presented as one. (SHA-256 integrity verification remains the
concern of the *download* steps this ticket does not touch.)

**Portability:** no `/tmp`, path separator, or line-ending literal is hardcoded. Paths are built
with `Join-Path` / `[System.IO.Path]::Combine` + `GetFullPath` (both of which accept the POSIX
`/` in git's blob text and normalize it on Windows). The step is Windows-only `pwsh` by design —
symlink materialization is only broken on Windows — and the backslash paths it does contain are
confined to that Windows-only step, matching the existing convention in this file.

---

## 5. Target platforms

| Platform | Status after this ticket | Notes |
|---|---|---|
| **macOS** (arm64/x64) | ✅ Shipping, unaffected | `CueSync.xcodeproj` / SwiftUI app is the product; unchanged. The repair step exists only in the two Windows jobs — macOS resolves the same `swift-java` symlinks natively and never runs it. `swift build -c release` and `xcodebuild -scheme CueSync build` stay green. The separate, pre-existing macOS `Test` failure is a different ticket and is not caused by this change. |
| **Windows x64** | ✅ The platform this ticket fixes | Both `windows-build` and `windows-test` now repair *all* layers of `swift-java`'s shared-source symlinks and get past the plugin compile into CueSync's real build/test. Junctions and hardlinks are standard NTFS reparse points requiring no privilege. |
| **Windows ARM64** | ➖ Not verified, **no new gap introduced here** | Still no hosted GitHub Actions Windows-ARM64 runner (unchanged infrastructural gap), and CUESYNC-6d's gvsbuild-is-x64-only narrowing still stands — but **this ticket adds no new ARM64 limitation**. Junctions/hardlinks and `git ls-files`/`cat-file` are architecture-neutral NT/Git features available identically on ARM64 Windows; the symlink repair would work there the moment a runner and an ARM64 GTK exist. |
| **Linux** | ➖ Not targeted | No Linux CI leg exists and this ticket adds none. Linux checks out these symlinks natively, so the Windows-only repair step is irrelevant there. `GtkBackend` still makes Linux the most plausible future target, but nothing here advances it. |

**Dependency lacking Windows-ARM64 support introduced by this ticket: none.** The x64-only
narrowing belongs to CUESYNC-6d's gvsbuild pin, not to this change; the symlink-repair mechanism
is fully architecture-neutral.
