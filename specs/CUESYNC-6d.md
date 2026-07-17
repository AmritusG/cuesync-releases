# CUESYNC-6d — Replace vcpkg-from-source GTK 4 with a pinned, SHA-verified gvsbuild prebuilt

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> Faithful port. This ticket writes **no application code**. It touches
> `.github/workflows/swift-windows.yml` and — per §0.4, confirmed necessary, not optional —
> exactly two test methods in `Tests/CueSyncCoreTests/CUESYNC6WindowsGtkWorkflowTests.swift`
> that hard-code the vcpkg pin this ticket removes. `Package.swift`, `Package.resolved`,
> `GtkBackend`, the DLL bundling step, the `wldd` closure check with its negative control, and
> the Swift 6.3.3 toolchain with its retry all stay **exactly as CUESYNC-6c left them**. No
> screen is ported, no view is touched, `xcodebuild -scheme CueSync build` is unaffected.
> Definition of Done: both Windows jobs acquire GTK 4 from a pinned gvsbuild release asset
> verified by SHA-256 **before** extraction, `swift build -c release` links `GtkBackend` on
> `macos-latest` and `windows-latest`, the suite is green on both legs with no test lost, the
> closure check still passes **and still fails its negative control**, and the Windows GTK step
> costs minutes rather than 45+.

---

## 0. STOP — read this before touching anything

Four of this ticket's stated premises are false or unverified against the branch you are
standing on. All four are blocking. Resolve them in order.

### 0.1 — This branch does not contain the work the ticket describes (BLOCKING)

`adw/CUESYNC-6d` is branched from `main` at `875b10e`. Verified:

```
git merge-base adw/CUESYNC-6d adw/CUESYNC-6c   →  875b10e   (= this branch's HEAD)
git branch --merged main                        →  main, adw/CUESYNC-6d   (CUESYNC-6c absent)
git diff --stat adw/CUESYNC-6d adw/CUESYNC-6c   →  101 files, ~308k insertions
```

CUESYNC-6c was **never merged to `main`**. The chain `CUESYNC-6 → CUESYNC-6c` lives only on
`adw/CUESYNC-6c` (`77f1fba`), which carries `Package.swift`, `Package.resolved`,
`Sources/CSQLite`, `Sources/CZlib`, `Tests/CueSyncCoreTests/`, and `specs/CUESYNC-3..6c`.

Consequences — every one checkable right now:

| Ticket says | This branch actually has |
|---|---|
| "Remove the vcpkg GTK steps" | **no vcpkg step exists in the file** |
| "Keep Swift 6.3.3" | **6.0.3**, via inputs `branch:` / `tag:` |
| "Keep GtkBackend" | **no `Package.swift` at all** |
| "Keep DLL bundling, the wldd runs-clean check" | **neither exists** |
| "179 tests stay green" | `swift test` cannot run — there is no package |

The ticket is written verbatim against `adw/CUESYNC-6c`'s copy of the workflow, which has the
three vcpkg steps per Windows job (`Cache vcpkg GTK 4 install`, `Install GTK 4 (vcpkg,
pinned)`, `Configure pkg-config for vcpkg GTK 4`), both jobs at
`swift-version: swift-6.3.3-release` / `swift-build: 6.3.3-RELEASE` behind the
`continue-on-error` + `outcome == 'failure'` retry pair. There is no reading of this ticket
that can be executed on `875b10e`.

**Required action, before step 1:** rebase this branch onto `adw/CUESYNC-6c`.

```bash
git rebase adw/CUESYNC-6c     # this branch carries only specs/CUESYNC-6d.md; expect no conflicts
```

Do **not** satisfy the ticket by editing `875b10e`'s workflow into something that resembles
the description — that silently re-implements CUESYNC-6 and 6c from a one-line summary. If the
rebase is refused, **stop and report**: this ticket is blocked on CUESYNC-6c, not on anything
in its own scope. Everything from §1 onward assumes the rebase is done.

### 0.2 — Every gvsbuild fact below is UNVERIFIED (BLOCKING)

This planning pass had **no network access** (`WebFetch`/`WebSearch` ungranted, `curl` blocked
by the sandbox) — the same precedent as CUESYNC-5 §0, CUESYNC-6 §0 and CUESYNC-6c §0.2.
**Nothing here about gvsbuild may be carried into the workflow unchecked.** The Build Agent has
network; resolve all seven and record the answers verbatim in the PR. This ticket names no
gvsbuild version deliberately — **which release to pin is the ticket author's decision, not the
Build Agent's**. If any check fails, stop and report; do not substitute the nearest thing that
works.

1. **That wingtk/gvsbuild publishes a GTK 4 release asset for x64.** Identify the exact release
   tag and asset filename (historically `GTK4_Gvsbuild_<version>_x64.zip` on
   `github.com/wingtk/gvsbuild/releases`). The URL must be of the form
   `releases/download/<tag>/<asset>` — **never** `releases/latest/download/...`. `latest` is
   forbidden by §4 *and* mechanically rejected by the committed
   `AdversarialCUESYNC6GtkSupplyChainTests.testNoInstallStepTracksAMutableLatestChannel`
   (`Patterns.mutableLatest` matches `/latest/download`).
2. **The asset's SHA-256.** Check whether the release publishes checksums. If it does, record
   where. If it does not, compute the hash once and commit the literal — same treatment `wldd`
   already gets. Either way it is verified **before** extraction (§4, and §0.4's ordering rule).
3. **That the asset ships `lib/pkgconfig/*.pc`** — specifically `gtk4.pc` and the transitive
   `Requires:` closure (glib-2.0, gobject-2.0, cairo, pango, harfbuzz, gdk-pixbuf-2.0,
   graphene-1.0, epoxy, …). swift-cross-ui's `CGtk` is a SwiftPM `systemLibrary` with
   `pkgConfig:`; **no `.pc` files means this whole approach fails at step 1** and the ticket
   should be reported blocked rather than worked around with hand-written `-I`/`-L` flags.
4. **The `prefix=` baked into those `.pc` files — this is the likeliest failure and the one
   most likely to be missed.** gvsbuild builds into a fixed prefix (historically
   `C:/gtk-build/gtk/x64/release`) and bakes it into each `.pc`. Relocating the extracted tree
   elsewhere leaves every `prefix=` pointing at a directory that does not exist. **`pkgconf
   --define-prefix` does not rescue this**, because SwiftPM parses `.pc` files *itself*
   (`PackageLoading/PkgConfig.swift`) rather than shelling out for that part — the workflow's
   own `Configure pkg-config…` comment already records this. So confirm what the shipped `.pc`
   actually contains, then choose **one** and state which in the PR:
   - extract to the exact prefix the `.pc` files were built against, or
   - rewrite the `prefix=` line in each `.pc` to the real extraction path.

   Do not assume relocation "just works".
5. **What replaces the `pkg-config` executable.** Removing vcpkg removes
   `vcpkg install pkgconf`, which is where `pkgconf.exe` (copied to `pkg-config.exe`) comes
   from today. Determine whether the gvsbuild asset ships a `pkgconf.exe`/`pkg-config.exe` in
   `bin/`. If it does not, confirm against SwiftPM whether the missing binary is the tolerable
   diagnostic the existing comment claims or a hard failure — and if a replacement is needed,
   **report rather than reach for `choco install pkgconfiglite`**, which is an unpinned mutable
   channel this spec's §4 forbids.
6. **That `GtkBackend` links against gvsbuild's GTK at all.** CUESYNC-6's findings §0.4 chose
   vcpkg *because upstream swift-cross-ui states it only supports GTK-on-Windows via vcpkg.*
   This ticket deliberately contradicts that. The technical argument is that gvsbuild is
   MSVC-built like vcpkg's GTK, so the ABI matches and only `.pc` discovery differs — **that is
   an argument, not evidence.** The CI run is the evidence. If it does not link, report it as
   the upstream-support gap it is; do not patch around it in the workflow.
7. **Windows ARM64.** Confirm whether gvsbuild publishes an ARM64 GTK 4 asset. Expected: it does
   not. This matters for §5 — it is a genuine narrowing versus vcpkg and must be reported, not
   glossed.

### 0.3 — "179 tests" is UNVERIFIED and stale

Do not treat 179 as a target. CUESYNC-6c §6 established the real number empirically:
**245 tests, 0 failures** (`swift test -c release`, `CueSyncCoreTests`). Three different counts
now appear across these tickets (179, 206, 252 raw `func test` matches) and none is 179.

**Re-establish the baseline empirically on the rebased branch before making any edit.** That
observed number — not 179 — is the `N` every criterion in §3 refers to. Report the discrepancy
in the PR rather than reconciling it silently.

### 0.4 — Two committed tests hard-code the vcpkg pin and WILL fail (BLOCKING to plan for)

This is the analogue of the discrepancy CUESYNC-6c hit in its own §6, and it is not optional
scope creep: removing vcpkg makes these two **pre-existing, currently-green** tests fail in
*both* the `macos` and `windows-test` legs, because they read the committed YAML text directly
and run in the same `CueSyncCoreTests` target on every platform.

| Test | File:line | Why it breaks |
|---|---|---|
| `testVcpkgInstalledCacheKeyIsUnchangedByTheToolchainBump` | `CUESYNC6WindowsGtkWorkflowTests.swift:507` | Asserts `key: windows-build-vcpkg-gtk4-52c9e08c…` is present and byte-identical |
| `testUnrelatedPinsSurviveTheToolchainBumpUnchanged` | `CUESYNC6WindowsGtkWorkflowTests.swift:543` | Its `mustStillContain` list includes the vcpkg commit pin `52c9e08cdf8580d2d9762f547d22b96fd81e82f2` |

Both encode a **CUESYNC-6c-era intent** — *"the Swift toolchain bump must not disturb the GTK
install or its cache"* — which was correct for 6c and is exactly what 6d is chartered to
change. Per this repo's standing rule (§E.24: no test may be weakened, skipped, `XCTSkip`-ed or
deleted to route around a failure), the correct resolution is to **retarget each assertion to
the new pin**, preserving its guard strength:

- The cache-key test becomes a check on the **gvsbuild GTK pin** (tag + SHA-256 literal), not
  on a vcpkg key that no longer exists. If §2 step 5 drops the separate GTK cache step, the
  test's subject becomes the pin itself — it must still fail if the pin goes missing or floats.
- The unrelated-pins test drops the vcpkg entry and **gains the gvsbuild tag + SHA-256**, so the
  list still fails loudly on an unpinned GTK. Every other entry (`actions/checkout`,
  `actions/cache`, `actions/upload-artifact`, `gha-setup-vsdevenv`, the `wldd` SHA-256) stays
  byte-for-byte.

**Do not touch anything else in the test suite.** The following are already gvsbuild-safe —
verified by reading them, not assumed — and a "helpful" edit to any of them is out of scope and
will be treated as a regression:

- `AdversarialCUESYNC6Tests.Patterns.gtkCacheInput` = `gtk|vcpkg|msys2|gvsbuild` and
  `.gtkAcquisition` = `vcpkg|pacman|gvsbuild|msys2|…` — **already name gvsbuild**.
- `CUESYNC6WindowsGtkInstallTests` matches `gtk4|gtk 4|libgtk-4` (and `|vcpkg` for
  `windows-test`) — a step named `Install GTK 4 (gvsbuild, pinned)` satisfies it on "GTK 4".
- All of `AdversarialCUESYNC6cTests` — its vcpkg strings live in **synthetic hostile fixtures**,
  not in assertions about the real file. Leave them alone; they must stay green untouched.

---

## 1. Problem

CUE SYNC's Windows CI builds GTK 4 from source with vcpkg, and that build is the dominant cost
of the entire pipeline: a cold-cache `vcpkg install gtk` takes 45+ minutes (CUESYNC-6 findings
§0.4), which is why it needed its own dedicated cache in the first place, and why a cache miss
— a bumped pin, an evicted entry, a new branch — turns a routine push into a 70+ minute wait or
a timeout. Compiling GTK's whole dependency tree on every cold runner is work this project has
no reason to do: it does not patch GTK, it consumes it. wingtk/gvsbuild publishes exactly what
is needed — MSVC-built GTK 4 binaries, as versioned release assets. This ticket swaps the
from-source build for a pinned, SHA-256-verified download and extract, turning the slowest step
in the pipeline into one that costs seconds. Nothing about the app changes: a DJ on macOS sees
no difference, and the Windows artifact still contains `CueSync.exe` plus a GTK 4 runtime whose
dependency closure is checked the same way by the same `wldd` gate. What changes is that the
Windows leg becomes fast enough to be worth waiting for — and, per §4, that the GTK bytes we
redistribute become *someone else's compiled binaries* rather than ones our own runner built
from a pinned source tree. That trade is the real content of this ticket and must be stated in
the PR as such, not buried as a speed optimisation.

---

## 2. Plan

One file — `.github/workflows/swift-windows.yml` — plus the two test methods §0.4 identifies.
**No file under `CueSync/` is touched**; this ticket has no application-code surface, and any
diff there is out of scope. Both Windows jobs (`windows-build` and `windows-test`) carry the
same three vcpkg steps today and both must be changed identically — a split between them means
the artifact and the test evidence come from different GTK builds.

Steps are atomic and ordered. §0 is blocking and comes first.

1. **Complete §0.1** — rebase onto `adw/CUESYNC-6c`. Confirm the file now contains, per Windows
   job: `Cache vcpkg GTK 4 install`, `Install GTK 4 (vcpkg, pinned)`, `Configure pkg-config for
   vcpkg GTK 4`. If not, stop and report.

2. **Complete §0.2** — resolve all seven gvsbuild unknowns with live network. Record verbatim in
   the PR. Any failure ⇒ stop and report.

3. **Complete §0.3** — record the observed baseline `N` per leg on the rebased branch.

4. **Replace the GTK acquisition step in `windows-build`.** Delete `Install GTK 4 (vcpkg,
   pinned)` (the clone, the `git -C vcpkg checkout 52c9e08c…`, the `bootstrap.ps1` call, the
   `vcpkg install gtk --triplet x64-windows`) and put a gvsbuild download in its place, at the
   same position — **before** `swift build -c release`, which
   `CUESYNC6WindowsGtkInstallTests.testWindowsBuildJobInstallsGtk4BeforeInvokingSwiftBuild`
   enforces. Required shape, in this exact order:

   1. `Invoke-WebRequest` the pinned `releases/download/<tag>/<asset>` URL to `$env:RUNNER_TEMP`.
   2. `Get-FileHash -Algorithm SHA256`, compare against the committed literal, `Write-Error` +
      `exit 1` on mismatch.
   3. `Expand-Archive` — **only after** the hash matches.
   4. Apply §0.2 item 4's chosen `.pc` prefix resolution.

   The ordering in 1–3 is not stylistic. `AdversarialCUESYNC6GtkSupplyChainTests.testAnyDownloaded-
   ArchiveIsChecksumVerifiedBeforeItIsExtracted` takes the **first** matching line in the whole
   job for each of download / verify / extract and asserts `verify < extract`. This new step
   lands *earlier* in the job than the existing `wldd` download, so it becomes the first match
   for all three — get the order wrong and it fails, correctly.

   Name the step so it still reads as a GTK install (e.g. `Install GTK 4 (gvsbuild, pinned)`);
   `windows-test`'s guard regex includes `gtk4|gtk 4|libgtk-4`.

5. **Delete `Cache vcpkg GTK 4 install` from `windows-build`.** It exists solely because a cold
   GTK build cost 45+ minutes; a pinned download of a prebuilt asset does not need a cache, and
   an `actions/cache` round-trip of the same extracted tree is not reliably cheaper than
   re-downloading it. Dropping it also removes a staleness risk rather than adding one. Two
   committed rules constrain what is left behind, and both still hold:
   - `testWindowsBuildCacheKeyActuallyHashesTheGtkInstallNotJustADifferentConstant` reads the
     **first** `key:` in the job and requires it to match `gtk|vcpkg|msys2|gvsbuild`. With the
     GTK cache gone, that becomes the SwiftPM key from step 7 — which contains `gvsbuild`. ✓
   - `testWindowsBuildRestoreKeysCannotFallBackOntoAPreGtkCache` requires **every**
     `restore-keys` prefix in the job to match that same regex. Step 7 keeps `gvsbuild` in the
     surviving prefix. ✓

   If §0.2 shows the download is slow enough to want a cache after all, that is a legitimate
   reversal — keep the step, key it on the gvsbuild **tag**, and say so in the PR.

6. **Replace `Configure pkg-config for vcpkg GTK 4` in `windows-build`.** Drop
   `vcpkg install pkgconf` and the `vcpkg\installed\x64-windows\...` paths. Keep the step's two
   real outputs, retargeted at the gvsbuild tree:
   - `PKG_CONFIG_PATH` → the extracted tree's `lib\pkgconfig`, via `Add-Content $env:GITHUB_ENV`.
   - a `pkg-config` executable on `GITHUB_PATH`, per §0.2 item 5's finding. If the asset ships
     `pkgconf.exe`, copy it to `pkg-config.exe` exactly as today. If it does not, **stop and
     report** rather than pulling one from an unpinned channel.

   Build paths with `Join-Path`, as the existing step does. Do not hardcode a separator.

7. **Update `windows-build`'s SwiftPM cache key.** Swap the vcpkg commit component for the
   gvsbuild pin, leaving every other component in place:

   ```
   key:  windows-build-spm-swift-6.3.3-gvsbuild-<tag>-${{ hashFiles('Package.resolved') }}
   restore-keys: |
     windows-build-spm-swift-6.3.3-gvsbuild-<tag>-
   ```

   Three committed rules bind this simultaneously — satisfy all three, do not trade one off:
   - every `windows-build-spm-` restore entry must contain `swift-6.3.3`
     (`AdversarialCUESYNC6cTests.testRealWorkflowPinsTheToolchainInEveryWindowsRestoreKeyFallback`);
   - the version in the key must equal the `swift-build:` actually installed
     (`…testCacheKeyToolchainVersionMatchesTheVersionActuallyInstalled`);
   - every prefix must name a GTK input (step 5's second bullet). `gvsbuild` supplies it.

   Keep the `hashFiles('Package.resolved')` component. **Do not touch the `macos-spm-` key** —
   the macOS leg installs GTK via `brew` and is out of scope.

8. **Apply steps 4, 6 and 7 to `windows-test`, identically.** Its `Cache vcpkg GTK 4 install`
   step goes too (it shares `windows-build`'s key today). Its SwiftPM key becomes
   `windows-test-spm-swift-6.3.3-gvsbuild-<tag>-…` with the matching restore prefix. The GTK
   step must land before `swift test -c release`.

9. **Retarget the two tests §0.4 names.** Nothing else in `Tests/` changes. Neither test may be
   deleted, skipped or weakened — each keeps a guard of equal strength, pointed at the gvsbuild
   pin instead of the vcpkg one.

10. **Update the comment blocks that would otherwise lie.** The long comments above the vcpkg
    steps explain the `bootstrap.ps1` workaround, the `powershell.exe`-not-on-PATH CI finding,
    and the "vcpkg, not gvsbuild/MSYS2" decision from CUESYNC-6 findings §0.4. Those steps are
    gone; the comments must go with them. Replace with a short block recording **why this ticket
    reverses that decision** (cost) and **what it costs in return** (§4's prebuilt-binary trust
    delta), so the next reader sees the trade, not just the speed win.

11. **Leave everything else byte-for-byte.** Explicitly unchanged: the whole `macos` job
    including `brew install pkg-config gtk4`; `Setup VS Dev Environment`; all four
    `compnerd/gha-setup-swift@eeda069c…` steps at 6.3.3 with their `continue-on-error` /
    `outcome == 'failure'` retry shape; `Build (release)`; the `Test` step and its
    `Tee-Object` XCTest-summary parsing; the `wldd` v1.5.0 install and its pre-extraction
    SHA-256 check; `Verify DLL closure (clean run, then negative control)` including the system
    allowlist and the deliberate exclusion of the Swift runtime DLLs; both `upload-artifact`
    steps; the `on:` triggers; every action SHA pin. Only the **source directory** in
    `Bundle GTK 4 runtime DLLs next to CueSync.exe` changes (step 12).

12. **Repoint the DLL bundling step** from `vcpkg\installed\x64-windows\bin` to the gvsbuild
    tree's `bin`. Keep the shape exactly: copy every `.dll` found there next to `CueSync.exe`,
    no hand-curated list — the `wldd` closure check remains what determines whether the set is
    right.

13. **Verify on real CI.** Every failure mode here is remote — asset resolution, `.pc` prefix
    relocation, pkg-config discovery, cache keys, link failure against a non-vcpkg GTK. None is
    observable locally. Push and read the run. Confirm each §3 item against actual logs, not
    expectations.

---

## 3. Acceptance criteria

Baseline `N` = the count observed in §0.3 / step 3, per leg. Not 179.

**vcpkg is gone**
- [ ] No occurrence of `vcpkg` remains in `.github/workflows/swift-windows.yml` — not in a step,
      not in a cache key, not in a comment.
- [ ] The vcpkg commit pin `52c9e08cdf8580d2d9762f547d22b96fd81e82f2` appears nowhere in the
      workflow or in `Tests/`.
- [ ] Neither Windows job clones a repository to obtain GTK.

**gvsbuild is pinned and verified**
- [ ] Both Windows jobs download GTK 4 from a `releases/download/<tag>/<asset>` URL. No
      `releases/latest`, no `/latest/download`.
- [ ] Both jobs verify the asset's SHA-256 against a committed literal, and the verify line
      precedes the extract line **in the file**, in each job.
- [ ] Negative control, mandatory — a checksum gate nobody has watched fire is not a gate. In a
      scratch commit, corrupt one hex digit of the expected SHA-256 and confirm from the logs
      that the job **fails at the verification step and never reaches `Expand-Archive`**. Revert.
      Paste the log excerpt in the PR.
- [ ] The GTK step in each job precedes `swift build -c release` / `swift test -c release`.

**Cache**
- [ ] Both Windows `.build` keys and their `restore-keys` prefixes contain **both** `swift-6.3.3`
      and the gvsbuild pin.
- [ ] No `windows-*-vcpkg-*` cache key or prefix survives.
- [ ] The `macos-spm-` key is byte-identical to `adw/CUESYNC-6c`.

**Speed — the ticket's whole point, so measure it**
- [ ] The GTK acquisition step's own duration is **under 5 minutes** on a cold runner, read off
      the CI timing. Quote the before/after in the PR: the vcpkg cold build was 45+ min.
- [ ] Total wall-clock for `windows-build` on a **cold** cache is reported in the PR. If it has
      not materially improved, this ticket did not achieve its purpose — say so rather than
      shipping it on the strength of the diff looking right.

**Nothing else moved**
- [ ] `git diff adw/CUESYNC-6c -- .` touches exactly three paths:
      `.github/workflows/swift-windows.yml`,
      `Tests/CueSyncCoreTests/CUESYNC6WindowsGtkWorkflowTests.swift`, and `specs/CUESYNC-6d.md`.
- [ ] Within the workflow, the diff touches only: the three vcpkg steps per Windows job, the two
      `.build` cache keys, the bundling step's source directory, and the corresponding comments.
      The toolchain steps and their retry, the `wldd` install and closure check, the `macos` job,
      and every action pin are byte-identical to `adw/CUESYNC-6c`.
- [ ] In `Tests/`, the diff touches exactly the two methods §0.4 names. No other test file
      changes — `AdversarialCUESYNC6cTests.swift` in particular is untouched.
- [ ] No test is deleted, skipped, `XCTSkip`-ed, commented out, or weakened. The §E.24 skip-scan
      and the live-test counter still pass.

**Still green**
- [ ] `macos` job green: `swift build -c release` and `swift test -c release`, `N` tests, 0
      failures. (`brew install … gtk4` is untouched; macOS must not regress.)
- [ ] `windows-build` green: `swift build -c release` links `GtkBackend` against gvsbuild's GTK 4
      under Swift 6.3.3. This is §0.2 item 6's evidence — call it out explicitly in the PR.
- [ ] `windows-test` green: `N` tests, 0 failures. **`N` has not decreased.**
- [ ] The DLL closure check passes **and its built-in negative control still fails for the right
      reason** — the log shows it failing with a DLL removed, then passing once restored. A
      closure check that passes because it silently stopped checking is exactly what §D.19
      exists to catch, and swapping the DLL source is precisely when that would happen.
- [ ] The `cuesync-windows` artifact still contains `CueSync.exe` plus a GTK 4 DLL set. Compare
      the DLL list against the vcpkg-era artifact and **report any difference** — a materially
      shorter list is a missing-dependency bug the closure check may not catch, since the check
      only proves what `CueSync.exe` imports transitively resolves, not that GTK's own runtime
      plugins are present.
- [ ] `xcodebuild -scheme CueSync build` still succeeds on macOS — assert it, don't assume it.

---

## 4. Threat model

No runtime input handling, no parsing, no user-facing surface is added. The entire threat
surface is **CI supply chain** — and unlike CUESYNC-6c, this ticket makes a *material* change to
it that must not be sold as a speed optimisation.

**The delta, stated plainly.** Today the GTK 4 DLLs shipped inside `cuesync-windows` are
compiled **on our own runner** from a source tree pinned to a vcpkg commit. After this ticket
they are **prebuilt binaries produced by a third party** (wingtk), downloaded and redistributed
to DJs, executing with the user's full privileges. The audit story changes from "we built these
bytes from a pinned recipe" to "we trust wingtk's build, identified by a hash". That is a real
reduction in provenance, bought deliberately for a 45-minute saving. The SHA-256 is therefore
not a formality — **it is the entire basis of trust for the change**, and it is the only thing
standing between a DJ and whatever a compromised or swapped release asset contains. The PR must
state this trade in these terms.

**Inputs crossing a trust boundary**

| Input | Boundary | Control |
|---|---|---|
| gvsbuild GTK 4 release asset (**new**) | Public network → DLLs redistributed to end users | Pinned to an exact `releases/download/<tag>/<asset>` URL; SHA-256 verified **before** `Expand-Archive`. `latest` forbidden (§0.2 item 1). Verified-before-extraction because checking a hash after unpacking checks it after untrusted bytes have already touched the filesystem. |
| vcpkg / GTK source build (**removed**) | — | Boundary deleted with the steps. |
| Swift 6.3.3 installer from `download.swift.org` | Public network → code executed as runner | Unchanged (CUESYNC-6c §4). Out of scope. |
| `compnerd/gha-setup-swift`, `actions/*`, `gha-setup-vsdevenv` | Third party → runner | Unchanged; all pinned to 40-char commit SHAs. |
| `wldd` v1.5.0 | Public network → runner | Unchanged; pinned, SHA-256 verified pre-extraction. Do not touch. |

**A gap this ticket does not close, and must not claim to.** The SHA-256 proves the asset is the
one we hashed. It proves nothing about what is *inside* it — gvsbuild's GTK is not built from a
source pin we audit, and no reproducible-build check exists here. A pinned hash of an
unreviewed binary is integrity, not provenance. Both properties matter and this ticket buys
only the first.

**Secrets / credentials:** none. The workflow reads no `secrets.*` and this change adds no read.
`GITHUB_TOKEN` is used only implicitly by `actions/checkout`/`actions/cache` at default
permissions; no elevation is needed or requested. The download step must not log its
environment.

**Cryptographically secure primitives:** none generated. No tokens, nonces, identifiers, or
randomness of any kind — do not introduce any. The only cryptography in scope is **integrity
verification of a downloaded artifact** (SHA-256, via `Get-FileHash`), and it is verification,
not generation. SHA-256 is the required primitive; a non-cryptographic checksum (CRC, size
comparison) or a "the download succeeded so it's fine" exit-code check is not a substitute and
must not be accepted as one. String-compare the hashes case-insensitively — `Get-FileHash`
returns uppercase, and a case mismatch that silently never matches would make the gate
unfirable, which is why §3's negative control is mandatory rather than advisory.

**Portability:** no path separator, `/tmp`, or line-ending literal is introduced. Use
`$env:RUNNER_TEMP` for the download (as the `wldd` step already does) and `Join-Path` for path
construction (as the pkg-config step already does). The only paths that may be spelled with
backslashes are Windows-only PowerShell steps that already are.

---

## 5. Target platforms

| Platform | Status after this ticket | Notes |
|---|---|---|
| **macOS** (arm64/x64) | ✅ Shipping, unaffected | `CueSync.xcodeproj` / SwiftUI app is the product; unchanged. The `macos` SwiftPM leg keeps `brew install pkg-config gtk4` and the preinstalled toolchain — **not** gvsbuild, which is Windows-only. That asymmetry is pre-existing and correct. Both legs must stay green. |
| **Windows x64** | ✅ CI-verified build+test, GTK 4 now prebuilt | The only platform this ticket changes. Still builds and links only — **CI never executes the exe**; the `wldd` closure check remains the sole runtime evidence. Its known gap is unchanged and still real: the **Swift runtime DLLs (`swiftCore.dll`, `Foundation.dll`, `dispatch.dll`, `BlocksRuntime.dll`) are not bundled**, resolving on the runner only via the toolchain's `PATH`. A DJ's machine has no such `PATH`. This ticket does not close that and must not be described as doing so. |
| **Windows ARM64** | ❌ Not verified, and **this ticket narrows the story** | Previously the blocker was purely infrastructural: no hosted GitHub Actions Windows ARM64 runner exists, while vcpkg *did* document an `arm64-windows` triplet for its `gtk` port — so GTK was theoretically available and only the runner was missing. gvsbuild publishes **x64 assets only** (§0.2 item 7 — verify). So after this ticket the gap is **two-fold**: no runner *and* no prebuilt ARM64 GTK. **This is the dependency lacking Windows-ARM64 support, and it is newly introduced by this ticket.** It is an acceptable trade — there is no ARM64 runner to use it on regardless — but it must be reported honestly in the PR, not carried forward as the unchanged "infrastructure-only" gap CUESYNC-6c described. If ARM64 is ever targeted, this decision is the first thing to revisit. No ARM64 job; no ARM64 claim. |
| **Linux** | ❌ Not targeted | No CI leg exists and this ticket adds none. gvsbuild is Windows-only and irrelevant here; Linux would use distro GTK 4 via `apt` per `CGtk`'s declared providers. `GtkBackend` still makes Linux the most plausible future target, but nothing here advances it. |

**Dependency lacking Windows-ARM64 support: gvsbuild** — it ships prebuilt GTK 4 for x64 only.
Stated precisely, because §0.2 item 7 must confirm it and because the honest framing matters:
this is not "we cannot test ARM64" (CUESYNC-6c's accurate framing for vcpkg), it is "the GTK
build we now depend on does not exist for ARM64 at all". Reporting this as unchanged would
misdescribe a real narrowing of the port's future platform reach as a status quo.
