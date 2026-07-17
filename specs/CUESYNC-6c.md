# CUESYNC-6c — Bump the Windows Swift toolchain to 6.3.3 and make the install retry

**Ticket type:** `port` · **Strategy:** faithful-native · **Language stays Swift.**

> Faithful port. This ticket writes **no application code**. It touches exactly one file —
> `.github/workflows/swift-windows.yml` — and within it exactly the two
> `compnerd/gha-setup-swift` steps plus a retry wrapper and the cache keys those steps
> invalidate. `GtkBackend`, the vcpkg GTK 4 install, the DLL bundling step, and the `wldd`
> dependency-closure check with its negative control stay **exactly as CUESYNC-6 left them**.
> No screen is ported, no view is touched, `xcodebuild -scheme CueSync build` is unaffected.
> Definition of Done: both Windows jobs install Swift 6.3.3, `swift build -c release` is
> green on `macos-latest` and `windows-latest`, the test suite is green on both legs with no
> test lost, and the closure check still passes **and still fails its negative control**.

---

## 0. STOP — read this before touching anything

Two of this ticket's stated premises are false against the branch you are standing on. Both
are blocking. Resolve them in the order below.

### 0.1 — This branch does not contain the work the ticket describes (BLOCKING)

`adw/CUESYNC-6c` is branched from `main` at `875b10e`. Verified:

```
git merge-base adw/CUESYNC-6c adw/CUESYNC-6   →  875b10e   (= this branch's HEAD)
git branch --merged main                       →  main, adw/CUESYNC-6c   (CUESYNC-6 absent)
```

CUESYNC-6 was **never merged to `main`**. Its work lives only on `adw/CUESYNC-6`
(`5d0af2b`), which is 99 files / ~306k insertions ahead of this branch, including
`Package.swift`, `Package.resolved`, `Sources/CSQLite`, `Sources/CZlib`,
`Tests/CueSyncCoreTests/`, and `specs/CUESYNC-3..6`.

Consequences — every one of these is checkable right now:

| Ticket says | This branch actually has |
|---|---|
| "both `compnerd/gha-setup-swift` steps" | **one** such step |
| "from Swift 6.1" | **6.0.3** |
| inputs `swift-version:` / `swift-build:` | inputs `branch:` / `tag:` |
| "keep GtkBackend / GTK vcpkg / DLL bundling / wldd" | **none of these exist in the file** |
| "the 179 tests" | no `Package.swift`, so `swift test` cannot run at all |

The ticket is written verbatim against `adw/CUESYNC-6`'s copy of the workflow, which has
exactly two `gha-setup-swift` steps (in `windows-build` and `windows-test`), both pinned to
`compnerd/gha-setup-swift@eeda069c5bc95ac8a9ac5cea7d4f588ae5420ca5 # v0.4.0` with
`swift-version: swift-6.1-release` / `swift-build: 6.1-RELEASE`. There is no reading of this
ticket that can be executed on `875b10e`.

**Required action, before step 1:** rebase this branch onto `adw/CUESYNC-6`.

```bash
git rebase adw/CUESYNC-6      # this branch carries only specs/CUESYNC-6c.md; expect no conflicts
```

Do **not** attempt to satisfy the ticket by editing `875b10e`'s workflow into something that
merely resembles the description — that would silently re-implement CUESYNC-6 from the
ticket's one-line summary of it, which is precisely the failure this section exists to
prevent. If the rebase is refused or CUESYNC-6 is expected to land on `main` first, **stop
and report**; this ticket is blocked on CUESYNC-6, not on anything in its own scope.

Everything from §1 onward assumes the rebase is done and describes `adw/CUESYNC-6`'s file.

### 0.2 — Swift 6.3.3 is UNVERIFIED (BLOCKING)

This planning pass had **no network access** (`WebFetch` and `WebSearch` are ungranted,
`curl` is blocked by the sandbox), matching the precedent set by CUESYNC-5 §0 and CUESYNC-6
§0. Therefore **nothing below about Swift 6.3.3 may be carried into the workflow unchecked.**
Resolve all four of these first and record the answers verbatim in the PR:

1. **That `6.3.3-RELEASE` exists and publishes a Windows x64 package.** Check
   `https://www.swift.org/install/windows/` and the `swiftlang/swift-org-website` release
   data, or `https://download.swift.org/swift-6.3.3-release/windows10/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE-windows10.exe`.
   If `6.3.3-RELEASE` does not exist, **stop and report** — do not silently substitute the
   nearest version you can find. Which version to pin is the ticket author's decision, not
   the Build Agent's.
2. **That the two input strings are right for this action at the pinned SHA.** The ticket
   specifies `swift-version: swift-6.3.3-release` and `swift-build: 6.3.3-RELEASE`. These are
   consistent with the naming convention already proven twice in this repo's own history
   (`main`: `branch: swift-6.0.3-release` / `tag: 6.0.3-RELEASE`; CUESYNC-6:
   `swift-version: swift-6.1-release` / `swift-build: 6.1-RELEASE`) — a three-component
   patch version keeps all three components in both strings. Consistent is not verified;
   confirm against `action.yml` at the pinned commit `eeda069c…` (v0.4.0), **not** at `main`.
3. **That v0.4.0 of the action can still resolve a 6.3.3 URL.** The action's pin is ~2 years
   older than the toolchain being requested. If swift.org's Windows download path layout
   changed after v0.4.0 was cut, the action will 404 no matter how many times it retries —
   and a retry loop around a deterministic 404 is worse than no retry, because it turns a
   fast red into a slow red. If v0.4.0 cannot resolve 6.3.3, **stop and report**: bumping the
   action's pin is a supply-chain re-audit (§4) and a separate decision.
4. **That the Windows package is published with whatever signature material the action
   expects.** The comment block at the top of the file records the original reason for
   choosing compnerd over SwiftyLab: recent swift.org Windows installers ship *without* a
   `.sig`, and SwiftyLab hard-fails on that. Confirm 6.3.3 does not reintroduce a gate
   compnerd v0.4.0 also enforces.

### 0.3 — "the 179 tests" is UNVERIFIED and probably stale

Do not treat 179 as a target. Counting `func test` declarations on `adw/CUESYNC-6` gives
**252** across 13 files in `Tests/CueSyncCoreTests/`; CUESYNC-6's own findings doc §0.5
recorded **206/206** passing at an earlier commit, before `a53120d "redteam: adversarial
tests"` added more. Three different numbers, none of them 179.

**Establish the real baseline empirically**, before making any edit: run the suite on the
rebased branch and record the count each leg reports. That observed number — not 179 — is the
baseline every criterion in §3 refers to. Report the discrepancy in the PR rather than
reconciling it silently.

---

## 1. Problem

CUE SYNC's Windows CI installs its Swift toolchain with `compnerd/gha-setup-swift`, and that
install is the single most failure-prone step in the pipeline: it reaches out to swift.org
for a large installer over the public network, and a transient 404 or a dropped connection
fails the whole job — after the expensive vcpkg GTK 4 build and the SwiftPM compile have
already been paid for, or worse, before them, so that a network blip and a real compile error
are indistinguishable from the outside. The pinned toolchain (6.1) is also now well behind
current Swift, which means the Windows leg is proving the port against a compiler the project
does not otherwise target. This ticket does two narrow things: it moves both Windows jobs to
Swift 6.3.3, and it makes the install survive a transient failure by retrying it instead of
failing the job on the first blip. Nothing about the app changes — a DJ on macOS sees no
difference and the Windows artifact's contents are unchanged. What changes is the
trustworthiness of a red X: after this, a red Windows leg means the code is broken, not that
swift.org hiccupped.

---

## 2. Plan

One file: `.github/workflows/swift-windows.yml`. **No file under `CueSync/` is touched** —
this ticket has no application-code surface, and any diff there is out of scope.

Steps are atomic and ordered. §0 is blocking and comes first.

1. **Complete §0.1** — rebase onto `adw/CUESYNC-6`. Confirm the file now contains two
   `compnerd/gha-setup-swift@eeda069c…` steps at `swift-6.1-release` / `6.1-RELEASE`, one in
   `windows-build` and one in `windows-test`. If it does not, stop and report.

2. **Complete §0.2** — verify 6.3.3 exists, resolves through v0.4.0, and needs no new
   signature material. Record verbatim in the PR. If any check fails, stop and report.

3. **Complete §0.3** — record the observed baseline test count on the rebased branch, per leg.

4. **Bump the `windows-build` toolchain step.** Change only the two input values:
   `swift-version: swift-6.1-release` → `swift-6.3.3-release`, and
   `swift-build: 6.1-RELEASE` → `6.3.3-RELEASE`. **Leave the `@eeda069c…` SHA pin and its
   `# v0.4.0` comment exactly as they are** — pinning the action by commit is a §4 control
   that this ticket does not relax. Update the step's preceding comment block to say 6.3.3
   where it explains the pin, so the comment does not immediately lie about the code under it.

5. **Bump the `windows-test` toolchain step.** Identical change, identical constraints. Both
   steps must end on the same version — a split toolchain between the build and test jobs
   would mean the artifact and the test evidence come from different compilers.

6. **Add a retry around each toolchain step, using conditional re-run — not a new action.**
   GitHub Actions has no native retry, and the common third-party wrappers
   (`nick-fields/retry` and friends) can only wrap a `run:` shell step, never a `uses:` step —
   so they cannot wrap this one at all. Adding a dependency that cannot do the job is worse
   than adding none. Use the idiomatic `uses:`-compatible pattern instead: give the step an
   `id`, mark it `continue-on-error: true`, and follow it with an identical step guarded by
   `if: steps.<id>.outcome == 'failure'`.

   Apply in both `windows-build` and `windows-test`. Shape:

   ```yaml
   - id: swift-install
     continue-on-error: true
     uses: compnerd/gha-setup-swift@eeda069c5bc95ac8a9ac5cea7d4f588ae5420ca5 # v0.4.0
     with:
       swift-version: swift-6.3.3-release
       swift-build: 6.3.3-RELEASE

   - name: Retry Swift toolchain install
     if: steps.swift-install.outcome == 'failure'
     uses: compnerd/gha-setup-swift@eeda069c5bc95ac8a9ac5cea7d4f588ae5420ca5 # v0.4.0
     with:
       swift-version: swift-6.3.3-release
       swift-build: 6.3.3-RELEASE
   ```

   Four properties this shape must preserve, each of which is easy to break:
   - **The last attempt must NOT be `continue-on-error`.** Only the first attempt swallows its
     failure. If both attempts carried it, a total install failure would fall through to
     `swift build` and surface as a confusing compile error instead of an honest install
     error. Fail-loud is the point.
   - **`outcome`, not `conclusion`.** Under `continue-on-error: true`, a failed step reports
     `outcome: failure` but `conclusion: success`. Gating on `conclusion` would mean the retry
     never fires — a retry that silently never runs is the worst possible outcome here,
     because it looks exactly like a retry that works.
   - **Two attempts, not more.** Two covers the transient-blip case this ticket exists for. A
     deterministic 404 (§0.2 item 3) is not fixed by a third attempt, only delayed.
   - **Re-running the action must be safe on a partial install.** Confirm at the pinned SHA
     that a second invocation over a half-installed toolchain re-installs cleanly rather than
     tripping over its own leftovers. If it is not idempotent, report it — do not paper over
     it with a cleanup step invented here.

7. **Add the Swift version to both Windows SwiftPM cache keys.** This is a direct consequence
   of step 4/5, not separate work. Swift `.swiftmodule` files are compiler-version-locked: a
   module built by 6.1 cannot be imported by 6.3.3. Both Windows jobs restore `.build` via
   `restore-keys:` prefixes (`windows-build-spm-vcpkg-`, `windows-test-spm-`) that will
   cheerfully hand a 6.1-built tree to a 6.3.3 compiler on the first run after this change.
   Neither key mentions the toolchain, so nothing invalidates them. Insert the version into
   both the `key:` and the `restore-keys:` prefix so 6.1 artifacts cannot be restored:

   - `windows-build-spm-vcpkg-…` → `windows-build-spm-swift-6.3.3-vcpkg-…`
   - `windows-test-spm-…` → `windows-test-spm-swift-6.3.3-…`

   Leave the vcpkg commit component and the `hashFiles('Package.resolved')` component exactly
   where they are. **Do not touch `windows-build`'s separate `vcpkg/installed` cache** — GTK 4
   is built by MSVC, not by Swift, so the toolchain bump does not invalidate it, and
   rebuilding GTK from cold costs 45+ minutes (CUESYNC-6 findings §0.4).

   **Do not touch the macOS `macos-spm-…` key.** The macOS leg uses the preinstalled
   toolchain and this ticket does not change it.

8. **Leave everything else byte-for-byte.** Explicitly unchanged: the `macos` job in full;
   `Setup VS Dev Environment`; the vcpkg clone/checkout/bootstrap/install at
   `52c9e08cdf8580d2d9762f547d22b96fd81e82f2`; `Configure pkg-config for vcpkg GTK 4`;
   `Build (release)`; the `Test` step and its XCTest-summary parsing; `Bundle GTK 4 runtime
   DLLs next to CueSync.exe`; the pinned `wldd` v1.5.0 install and its pre-extraction SHA-256
   check; `Verify DLL closure (clean run, then negative control)` including the system
   allowlist and the deliberate exclusion of the Swift runtime DLLs; both
   `upload-artifact` steps; the `on:` triggers; and every other action SHA pin.

9. **Verify on real CI.** The failure modes this ticket introduces are all remote —
   toolchain resolution, cache poisoning, retry misfire. None can be observed locally. Push
   and read the run. Confirm each item in §3 against the actual logs, not against
   expectations.

---

## 3. Acceptance criteria

Baseline `N` = the test count observed in §0.3 / step 3, per leg. Not 179.

**Toolchain**
- [ ] `.github/workflows/swift-windows.yml` contains exactly **two** `compnerd/gha-setup-swift`
      steps per §0.1's file (four after step 6's retries — two attempts × two jobs); every one
      of them requests `swift-version: swift-6.3.3-release` and `swift-build: 6.3.3-RELEASE`.
- [ ] No occurrence of `6.1-RELEASE` or `swift-6.1-release` remains in the file.
- [ ] Every `compnerd/gha-setup-swift` reference is still pinned to
      `@eeda069c5bc95ac8a9ac5cea7d4f588ae5420ca5`. No `@main`, no `@v0.4.0` float.
- [ ] Both Windows jobs' `Swift version` step prints a 6.3.3 version string in the CI log.
      This is the assertion that the bump took effect; a passing build alone does not prove it.

**Retry**
- [ ] In each Windows job, the first toolchain attempt has an `id` and `continue-on-error: true`;
      the second is guarded by `if: steps.<id>.outcome == 'failure'` and does **not** carry
      `continue-on-error`.
- [ ] The guard reads `.outcome`, not `.conclusion`.
- [ ] On a green run, the retry step is reported **skipped** — the retry costs nothing when
      the install works.
- [ ] Negative control, and it is mandatory — a retry nobody has watched fire is not a retry.
      In a scratch commit, set the first attempt's `swift-build` to a value that cannot
      resolve (e.g. `0.0.0-RELEASE`), leave the retry attempt correct, and confirm from the
      logs that attempt 1 fails, the retry fires, and **the job goes green**. Then confirm the
      converse: with *both* attempts set to the bad value, the job goes **red**. Revert the
      scratch commit. Paste both log excerpts in the PR.
- [ ] No new third-party action is added to the file.

**Cache**
- [ ] Both Windows `.build` cache keys and their `restore-keys` prefixes contain `6.3.3`.
- [ ] The `vcpkg/installed` cache key is unchanged, and the CI log shows a vcpkg **cache hit**
      (i.e. GTK 4 was not rebuilt from cold by this ticket).
- [ ] The `macos-spm-` key is unchanged.

**Nothing else moved**
- [ ] `git diff adw/CUESYNC-6 -- .` touches exactly two paths:
      `.github/workflows/swift-windows.yml` and `specs/CUESYNC-6c.md`.
- [ ] Within the workflow, the diff touches only: the four toolchain steps, their comment
      blocks, and the two `.build` cache keys. `GtkBackend`, the vcpkg install, the
      pkg-config step, the DLL bundling step, and the `wldd` closure check are byte-identical
      to `adw/CUESYNC-6`.

**Still green**
- [ ] `macos` job green: `swift build -c release` and `swift test -c release`, `N` tests pass,
      0 failures.
- [ ] `windows-build` job green: `swift build -c release` links `GtkBackend` under 6.3.3.
- [ ] `windows-test` job green: `N` tests pass, 0 failures. **`N` has not decreased.** No test
      was deleted, skipped, or `XCTSkip`-ed to accommodate the toolchain bump; if 6.3.3
      surfaces a genuine failure, report it — do not silence it.
- [ ] The DLL closure check still passes **and its built-in negative control still fails for
      the right reason** (the log shows the check correctly failing with a DLL removed, then
      passing again once restored). A closure check that passes because it silently stopped
      checking is the exact failure CUESYNC-6 §D.19 exists to catch.
- [ ] The `cuesync-windows` artifact still contains `CueSync.exe` plus the GTK 4 DLL set.
- [ ] `xcodebuild -scheme CueSync build` still succeeds on macOS (unaffected — this ticket
      touches no `.xcodeproj` input; assert it rather than assume it).

---

## 4. Threat model

This ticket adds no runtime input handling, no parsing, and no user-facing surface. Its entire
threat surface is **CI supply chain** — what the workflow downloads and executes, and with
what privileges.

**Inputs crossing a trust boundary**

| Input | Boundary | Control |
|---|---|---|
| Swift 6.3.3 Windows installer from `download.swift.org` | Public network → code executed as the runner user | Pinned by exact version. The action verifies swift.org's published signature material if present; §0.2 item 4 requires confirming what 6.3.3 actually publishes. **Bumping 6.1 → 6.3.3 changes which binary CI executes** — this is the ticket's one real supply-chain delta and must be stated as such in the PR, not treated as a version-string edit. |
| `compnerd/gha-setup-swift` action code | Third-party → runner | Pinned to commit `eeda069c…` (v0.4.0). **Unchanged by this ticket.** The retry re-invokes the same pinned commit; it does not widen the surface. |
| vcpkg / GTK 4 / `wldd` | Public network → runner | Unchanged (vcpkg commit pin; `wldd` v1.5.0 SHA-256 verified pre-extraction). Out of scope — do not touch. |

**Secrets / credentials:** none. The workflow reads no `secrets.*`, and this change adds no
read. `GITHUB_TOKEN` is used only implicitly by `actions/checkout` and `actions/cache` at
their default permissions; the change neither needs nor requests elevation. Nothing here
should print an environment dump — the retry must not log the action's inputs or environment
in an attempt to be helpful about why attempt 1 failed.

**Cryptographically secure primitives:** none required. This ticket generates no tokens, no
nonces, no identifiers, and no randomness of any kind. The only cryptography in scope is
**integrity verification of downloaded artifacts** (SHA-256 for `wldd`; swift.org's signature
material for the toolchain), and it is verification, not generation. Retry interacts with this
in one specific way that must not be got wrong: **a retry must re-run the same verification,
never bypass it.** Because the retry step is a verbatim re-invocation of the same pinned
action with the same inputs, this holds by construction — which is a further reason to prefer
the conditional-re-run pattern over hand-rolling a download-and-unzip fallback that would have
to re-implement (and could quietly omit) the integrity check.

**The retry's own risk, stated plainly:** retry logic converts a *loud, fast* failure into a
*quiet, slow* one. If 6.3.3 is unresolvable through v0.4.0 (§0.2 item 3), this change makes
every Windows run take twice as long to tell you so. That is why §0.2 is blocking rather than
advisory, and why §3's negative control demands watching the retry both fire *and* give up.

**Portability:** no path, separator, or line-ending literal is introduced. The two PowerShell
steps that handle paths are pre-existing and untouched.

---

## 5. Target platforms

| Platform | Status after this ticket | Notes |
|---|---|---|
| **macOS** (arm64/x64) | ✅ Shipping, unaffected | `CueSync.xcodeproj` / SwiftUI app is the product; unchanged. The `macos` SwiftPM job uses the **preinstalled** toolchain — this ticket does not touch it, so 6.3.3 lands on Windows only. That asymmetry is pre-existing and deliberate; both legs must stay green regardless. |
| **Windows x64** | ✅ CI-verified build+test, now on Swift 6.3.3 | The only platform this ticket changes. Still: builds and links only — **CI never executes the exe**. The `wldd` closure check remains the sole runtime evidence, and its known gap is unchanged and still real: the **Swift runtime DLLs (`swiftCore.dll`, `Foundation.dll`, `dispatch.dll`, `BlocksRuntime.dll`) are not bundled**, resolving on the runner only via the toolchain's `PATH`. A DJ's machine has no such `PATH`. Bumping to 6.3.3 does not close this gap and arguably sharpens it — the runtime DLLs that would need bundling are now a *different, newer* set. Out of scope; still the next ticket's work; must not be described in the PR as solved. |
| **Windows ARM64** | ❌ Not verified, and cannot be | **Flagged dependency gap, carried forward from CUESYNC-6 findings §0.7 and unchanged here.** vcpkg does document an `arm64-windows` triplet for the `gtk` port, so GTK 4 is not itself the blocker — **the blocker is that no hosted GitHub Actions Windows ARM64 runner exists**, so there is nowhere to run the leg. No ARM64 job, and no ARM64 claim may be made. Additionally unverified by this ticket: whether swift.org publishes a 6.3.3 **ARM64** Windows package at all. Do not add an ARM64 leg here. |
| **Linux** | ❌ Not targeted | No CI leg exists and this ticket adds none. `GtkBackend` makes Linux the most plausible future target (GTK 4 is native there, via `apt` per `CGtk`'s declared providers), but plausible is not verified and nothing in this ticket advances it. |

**Dependency lacking Windows-ARM64 support:** none identified as *lacking* it — GTK 4 via
vcpkg claims `arm64-windows`, and Swift on Windows ARM64 is a documented target. The gap is
**verification infrastructure**, not dependency availability. Stating it the other way round
would misreport a "we cannot test this" as a "this does not work".
