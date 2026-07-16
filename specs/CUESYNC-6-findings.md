# CUESYNC-6 §0 findings — verified against the pinned swift-cross-ui revision

Recorded per spec §0 ("resolve these before writing a manifest edit... record the answers
verbatim in the PR"). Verified by cloning `https://github.com/moreSwift/swift-cross-ui` and
checking out `a6d206370812e3b9edba259d167e848892c5013d` (confirmed `HEAD` == tag `v0.8.0`,
matching `Package.resolved`) — reading the manifest and docs **at that revision**, not `main`.

## §0.1 — GtkBackend product exists

Confirmed. `Package.swift` (pinned revision) declares:
```swift
.library(name: "GtkBackend", type: libraryType, targets: ["GtkBackend"]),
```
alongside `AppKitBackend`, `Gtk3Backend`, `WinUIBackend`, `DefaultBackend`, `UIKitBackend` —
exactly as expected. Product name is `GtkBackend`, used verbatim in `Package.swift` §A.8.

## §0.2 — How an App selects GtkBackend

Confirmed mechanism, and it's simpler than the spec's indicative sketch assumed:
`Sources/GtkBackend/GtkBackend.swift` carries a **retroactive extension on the `App`
protocol itself**:
```swift
extension App {
    public typealias Backend = GtkBackend
    public var backend: GtkBackend { GtkBackend(appIdentifier: Self.metadata?.identifier) }
}
```
So `import GtkBackend` alone (replacing `import DefaultBackend`) is sufficient — no explicit
`typealias Backend = GtkBackend` is required in `CueSyncApp`. `DefaultBackend`'s own
`typealias DefaultBackend = GtkBackend` (in `Sources/DefaultBackend/DefaultBackend.swift`) is
just a convenience alias, unrelated to how `App.Backend` actually resolves.

We kept an explicit `typealias Backend = GtkBackend` in `CueSyncApp` anyway (redundant with
the above, but harmless and self-documenting — matches the spec's indicative snippet).

## §0.3 — How GtkBackend locates GTK 4 at build time

Confirmed: `CGtk` is a `.systemLibrary` target:
```swift
.systemLibrary(name: "CGtk", pkgConfig: "gtk4",
               providers: [.brew(["gtk4"]), .apt(["libgtk-4-dev clang"])])
```
No Windows entry — SwiftPM's `providers:` only supports `.brew`/`.apt`/`.yum` (advisory
error-message hints on missing deps), so on Windows there is no such nicety; `PKG_CONFIG_PATH`
must be set by hand regardless of GTK distribution chosen.

**(a) Does `pkgConfig:` resolution work on Windows?** Yes — proven by swift-cross-ui's own
CI (`.github/workflows/build-test-and-docs.yml`, `windows` job): it sets
`PKG_CONFIG_PATH: ${{ github.workspace }}/vcpkg_installed/<triplet>/lib/pkgconfig` and
successfully runs `swift build --target SwiftCrossUI -v` against gtk4 headers/libs
installed by vcpkg. **Important caveat:** that job builds `SwiftCrossUI` and `WinUIBackend`
only — it never builds `--target GtkBackend` on Windows, despite the repo's `vcpkg.json`
declaring `gtk` as a dependency. So `pkgConfig:` resolution via `PKG_CONFIG_PATH` is proven
to work on `windows-latest` for this manifest, but **GtkBackend compiling+linking on Windows
has never been demonstrated even by upstream's own CI** — this ticket's DoD is genuinely new
ground, exactly the "binary we believe would run" gap the spec calls out.

**(b) Any build-time code generation against installed GTK headers?** No. `GtkCodeGen` is a
standalone executable target used by maintainers to regenerate the checked-in Swift/GIR
bindings during development — it is not wired as a SwiftPM plugin or build tool and is not
invoked by an ordinary `swift build`.

## §0.4 — Which GTK 4 Windows distribution (the central decision) — REVISED FROM THE SPEC

**Major finding: neither of the spec's two candidates (gvsbuild, MSYS2) is what upstream
uses or documents.** `Sources/SwiftCrossUI/SwiftCrossUI.docc/Backends/GtkBackend.md` states
verbatim: *"On Windows things are a bit complicated (as usual), so we only support
installation via vcpkg."* Neither gvsbuild nor MSYS2 is mentioned anywhere in the
swift-cross-ui repo (docs or CI) in connection with `GtkBackend`.

**Decision: use vcpkg**, matching upstream's own documented and (partially) CI-exercised
path, rather than either spec candidate — both of which would be an unverified, unendorsed
combination that upstream itself doesn't test. vcpkg's default `x64-windows` triplet builds
dynamically-linked, MSVC-ABI DLLs with real `.lib` import libraries and `.pc` files — the
ABI-correct match for Swift's MSVC/UCRT target, same conclusion the spec wanted from
gvsbuild, but via the path upstream actually supports.

**Threat-model deviation to flag (spec §4 assumed a downloaded prebuilt binary pinned by
SHA-256):** vcpkg does not ship a prebuilt GTK 4 binary to download-and-verify — it **builds
GTK 4 from source** via its own portfile/registry system. The correct pin point is therefore
the **vcpkg tool's own git commit/tag** (cloned via `git clone ... && bootstrap-vcpkg`) plus
the port versions resolved through a `builtin-baseline` in `vcpkg-configuration.json` (or an
explicit version constraint in `vcpkg.json`) — not a SHA-256 of a binary asset. This is a
real, necessary deviation from the spec's §4 wording and must be reported as such, not
silently reconciled.

**Real, unresolved tension with the CI time budget:** upstream's own docs warn *"Installation
can take 45+ minutes depending on your machine"* for the global vcpkg GTK install — i.e. the
same order-of-magnitude cost the spec attributed to gvsbuild's from-source build, which the
spec called "far too slow" for CI. `windows-build` is already the job commit `ced8e71` split
out specifically because CI was nearing the 1800s ceiling. A cold-cache vcpkg GTK build will
very likely blow that budget again; upstream's own CI mitigates this with an
`actions/cache` step keyed on `vcpkg-<triplet>-<hash of vcpkg.json>`, which we should copy,
but the **first** (cold-cache) run remains a real risk that must be watched, not assumed away.
This is unresolved and is deliberately left to the CI-wiring step (spec §C), not decided here.

## §0.5 — GTK 4 on macOS for the SwiftPM leg

Confirmed and **locally verified**, not just documented. `brew install pkg-config gtk4`
(4.22.4 as of this check) provides a working `GtkBackend`-compatible GTK 4 on macOS (arm64).
After installing it locally:
- `swift build` — succeeds, `GtkBackend` compiles and links into `CueSync`.
- `swift build -c release` — succeeds, same result (matches DoD literally).
- `swift test` — 206/206 pass (up from the prior 203; three new compliance tests added, none
  removed or weakened).
- `Package.resolved` — byte-for-byte unchanged after the product swap, confirming §A.9's
  prediction.
- `scripts/run-tests.sh` — still 49/49 green, unaffected (doesn't touch the SwiftPM target).
- `xcodebuild -scheme CueSync build` — still **BUILD SUCCEEDED**, unaffected (doesn't touch
  `App/`, `Views/`, `Theme/`, `Utilities/`, or the `.xcodeproj`).

Only output: several `ld: warning: building for macOS-14.0, but linking with dylib ... which
was built for newer version 26.0` — a deployment-target/Homebrew-bottle mismatch, non-fatal,
not something this ticket's manifest change controls. Confirmed upstream itself hits the same
combination in its own CI (`macos` job: `brew install pkg-config gtk4 gtk+3` then
`swift build --target GtkBackend`), which corroborates this is a known-good combination and
not a fluke of this one machine.

## §0.6 — The dependency-checking tool

The ticket's name (`wldd/dependency_runner`) conflated the shipped binary name with the
GitHub owner. The actual repository is **`marcoesposito1988/dependency_runner`** — "ldd for
Windows - and more!", written in Rust. It ships prebuilt release assets per tag, including
`wldd-x86_64-pc-windows-msvc.zip` (the ldd-like frontend the ticket describes) at releases
such as `v1.5.0`, `v1.4.1`, `v1.4.0`, `v1.3.3`, `v1.3.2` (checked via the GitHub releases
API). Pinnable by exact tag + asset URL. No checksums file was found published alongside the
release assets, so pinning requires computing and committing the SHA-256 of the **specific**
asset ourselves at CI-wiring time (spec §4) rather than trusting a published hash. Deferred to
the §D CI-wiring step.

## §0.7 — Windows ARM64 availability

Refines rather than overturns the spec's conclusion. vcpkg documents an explicit
`arm64-windows` triplet for the `gtk` port (`vcpkg install gtk --triplet arm64-windows`) —
more concrete ARM64 support than either gvsbuild or MSYS2 offers per the spec's own
assumptions. However, **no hosted GitHub Actions ARM64 Windows runner exists**, so this
remains unverifiable in CI regardless of which GTK distribution is chosen. The spec's
bottom-line conclusion (no ARM64 CI leg, no ARM64 claim) stands, but for a narrower reason:
it's not that GTK 4 itself lacks a Windows-ARM64 story, it's that there is nowhere to run it.

## Net effect on the plan

§0.1, §0.2, §0.5 confirm the spec's expectations (with §0.2 simpler than assumed). §0.4 and
§0.7 revise the spec's own candidate list and rationale — **vcpkg, not gvsbuild/MSYS2**, is
the distribution to use for §C/§D, and the CI-time-budget risk from a cold-cache vcpkg build
is real and must be designed around (caching, and/or accepting a slow first run) rather than
assumed solved. §0.3 and §0.6 are unchanged in substance but corrected in detail (owner name,
code-gen non-issue). §A/§B (manifest + app-shell backend swap) are implemented and verified
green in this pass; §C (CI GTK install on both legs) and §D (DLL bundling + dependency-closure
check + negative control) are follow-on work, deliberately not attempted in the same step —
they depend on these findings and deserve their own verification pass against real CI, which
cannot be faked locally.
