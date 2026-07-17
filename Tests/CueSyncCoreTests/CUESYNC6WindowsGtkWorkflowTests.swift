import Foundation
import XCTest

// =============================================================================
// CUESYNC-6 §C/§D compliance — GTK 4 CI wiring, DLL bundling, dependency-closure
// check, and its mandatory negative control.
//
// Everything here is a *structural* check against committed text (the workflow
// YAML, Package.swift, Package.resolved) — the same style PortComplianceTests
// and AdversarialSupplyChainTests already use for Package.swift/.pbxproj, and
// for the same reason: `swift test` is deterministic and network-free and must
// behave identically on windows-latest/macos-latest, so it cannot itself spin
// up a GitHub Actions run, install GTK 4, or execute CueSync.exe to see whether
// the closure check really fails on a missing DLL. What it CAN verify is that
// the workflow declares the steps the spec requires, in the order the spec
// requires, without the vacuous-green shapes spec §0.4/§D.18/§D.19 warn about
// (a permissive allowlist, a check with no negative control, a build step that
// silently keeps compiling with `continue-on-error`).
//
// These tests are expected to fail until the CI-wiring pass (spec §C/§D) lands
// — that is the point: they exist to hand a concrete, itemized failure list
// back to the Build Agent rather than let §C/§D ship unverified.
// =============================================================================

final class CUESYNC6ManifestPinLockTests: XCTestCase {
    /// spec CUESYNC-6 §3 Manifest: "The swift-cross-ui pin is **still** exact:
    /// "0.8.0" / revision a6d206370812e3b9edba259d167e848892c5013d. No branch:,
    /// no from:, no version bump." `PortComplianceTests` already proves the pin
    /// has *a* concrete exact/revision shape (CUESYNC-5's more general check) —
    /// this proves it is specifically *this* ticket's audited revision, which a
    /// well-intentioned "let's just bump to whatever's newest" edit would slip
    /// past the shape-only check while still failing this one.
    func testSwiftCrossUIStaysPinnedToTheExactAuditedTagAndRevision() throws {
        let manifest = try String(contentsOf: RepoPaths.packageSwift, encoding: .utf8)
        XCTAssertTrue(manifest.contains(#"exact: "0.8.0""#),
            "Package.swift must keep swift-cross-ui pinned to exact: \"0.8.0\" — " +
            "spec CUESYNC-6 says plainly \"No ... version bump\"")

        for pin in try PackageResolved.pins() where PackageResolved.identity(of: pin) == "swift-cross-ui" {
            let revision = (pin["state"] as? [String: Any])?["revision"] as? String
            XCTAssertEqual(revision, "a6d206370812e3b9edba259d167e848892c5013d",
                "Package.resolved's swift-cross-ui pin must stay exactly the audited revision")
            return
        }
        XCTFail("Package.resolved contains no swift-cross-ui pin at all")
    }
}

// MARK: - §C: GTK 4 install placement across the three CI jobs

final class CUESYNC6WindowsGtkInstallTests: XCTestCase {

    /// spec §C.13: a GTK 4 install step must be added to `windows-build`,
    /// **before** `swift build`. Deliberately keyword-loose ("gtk" + an install
    /// verb) rather than pinned to one exact tool name, since §0.4's own
    /// findings doc revised the spec's own candidate list once already (vcpkg,
    /// not gvsbuild/MSYS2) — the requirement that matters here is placement,
    /// not which installer wins.
    func testWindowsBuildJobInstallsGtk4BeforeInvokingSwiftBuild() throws {
        let job = try JobBlocks.require("windows-build")
        guard let buildLine = job.firstLineIndex(matching: #"run:\s*swift build -c release"#) else {
            XCTFail("windows-build must still invoke `swift build -c release`")
            return
        }
        guard let gtkLine = job.firstLineIndex(matching: #"gtk4|gtk 4|libgtk-4"#, caseInsensitive: true) else {
            XCTFail("windows-build has no step referencing GTK 4 at all — spec §C.13 requires installing it " +
                    "before swift build so GtkBackend actually has headers/libs to link against")
            return
        }
        XCTAssertLessThan(gtkLine, buildLine,
            "the GTK 4 install step must run BEFORE `swift build -c release` in windows-build (spec §C.13)")
    }

    /// spec §C.14: the ticket text only asks for a Windows GTK install, but once
    /// the `CueSync` executable target depends unconditionally on `GtkBackend`
    /// the macOS SwiftPM leg needs GTK 4 too, or it goes red — the findings doc
    /// (§0.5) confirms `brew install ... gtk4` is the resolution and that it was
    /// locally verified. This must be a real CI step, not just a local finding.
    func testMacosJobInstallsGtk4BeforeInvokingSwiftBuild() throws {
        let job = try JobBlocks.require("macos")
        guard let buildLine = job.firstLineIndex(matching: #"run:\s*swift build -c release"#) else {
            XCTFail("macos job must still invoke `swift build -c release`")
            return
        }
        guard let gtkLine = job.firstLineIndex(matching: #"brew install[^\n]*gtk4"#, caseInsensitive: true) else {
            XCTFail("macos job has no `brew install ... gtk4` step — spec §C.14: once CueSync depends on " +
                    "GtkBackend unconditionally, the macOS SwiftPM leg needs GTK 4 too")
            return
        }
        XCTAssertLessThan(gtkLine, buildLine, "macos job must install gtk4 BEFORE `swift build -c release` (spec §C.14)")
    }

    /// spec §C.15: `windows-test` depends only on CueSyncCore/CSQLite/CZlib and
    /// never on the CueSync executable target, so it needs no GTK — adding an
    /// install step there would put a multi-minute install on the critical path
    /// of the job that exists specifically to be the fast one. This locks in
    /// today's correct shape as a regression guard, not just a §C.13/§C.14 mirror.
    func testWindowsTestJobGetsNoGtk4InstallStep() throws {
        let job = try JobBlocks.require("windows-test")
        XCTAssertNil(job.firstLineIndex(matching: #"gtk4|gtk 4|libgtk-4|vcpkg"#, caseInsensitive: true),
            "windows-test must not grow a GTK/vcpkg install step (spec §C.15) — CueSyncCoreTests never " +
            "touches the CueSync executable target or GtkBackend, and this job exists to be the fast one")
    }

    /// spec §3/§C.16/§5: "not stubbed, not skipped, not `continue-on-error`, and
    /// not silently still DefaultBackend." A `continue-on-error: true` anywhere
    /// in windows-build would let the job report green while GtkBackend fails to
    /// compile or link — exactly the vacuous-green outcome this ticket forbids.
    ///
    /// spec CUESYNC-6c §2 step 6 legitimately introduces one narrow exception: the
    /// first Swift-toolchain-install attempt carries `continue-on-error: true` as
    /// part of its retry-on-transient-network-failure pattern — paired with an
    /// unconditioned retry attempt that does NOT carry it, so a total install
    /// failure still fails the job loudly. This test still forbids the flag
    /// everywhere else (the GTK install, the build step, ...), so a GtkBackend
    /// compile/link failure still cannot be massaged into green.
    func testWindowsBuildStepIsNeitherSkippedNorContinueOnErrorNorConditional() throws {
        let job = try JobBlocks.require("windows-build")
        for (index, lineText) in job.lines.enumerated()
        where lineText.range(of: #"continue-on-error:\s*true"#, options: .regularExpression) != nil {
            let precedingLines = job.lines[max(0, index - 3)..<index]
            XCTAssertTrue(precedingLines.contains { $0.contains("id: swift-install") },
                "windows-build line \(index) sets continue-on-error: true outside the Swift-toolchain-install " +
                "retry step (spec CUESYNC-6c §2 step 6) — a red Windows build reported honestly is the correct " +
                "outcome per spec §0.4, not one massaged into green")
        }

        guard let buildStepLine = job.lines.first(where: {
            $0.range(of: #"run:\s*swift build -c release\s*$"#, options: .regularExpression) != nil
        }) else {
            XCTFail("windows-build's build step must run exactly `swift build -c release`, unconditioned")
            return
        }
        XCTAssertFalse(buildStepLine.contains("||"),
            "the windows-build `swift build -c release` step must not be chained with `||` to swallow a failure")
    }

    /// spec §C.16/§5: no Linux leg, no Windows ARM64 leg — both explicitly out of
    /// scope, and §5 sharpens the ARM64 call-out to "no hosted ARM64 Windows
    /// runner exists" rather than a GTK-availability gap.
    func testNoLinuxOrWindowsArm64RunnerIsAddedToTheMatrix() throws {
        let src = try WorkflowFile.contents()
        let runsOnLines = src.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("runs-on:") }
        XCTAssertGreaterThanOrEqual(runsOnLines.count, 3, "expected at least the three existing jobs' runs-on: lines")
        for line in runsOnLines {
            let lowered = line.lowercased()
            XCTAssertFalse(lowered.contains("ubuntu") || lowered.contains("linux"),
                "no Linux CI leg is in scope for this ticket (spec §C.16): \(line)")
            XCTAssertFalse(lowered.contains("arm"),
                "no Windows ARM64 CI leg is in scope — no hosted runner exists (spec §5): \(line)")
        }
    }
}

// MARK: - §D: bundle the runtime, check the closure, prove the check isn't vacuous

final class CUESYNC6WindowsGtkBundleAndClosureCheckTests: XCTestCase {

    /// spec §D.17: after `swift build -c release`, the GTK 4 (and transitive:
    /// glib/cairo/pango/...) runtime DLLs must be copied next to `CueSync.exe`
    /// so the uploaded `cuesync-windows` artifact is self-contained.
    func testWindowsBuildBundlesRuntimeDLLsNextToTheExecutableAfterBuilding() throws {
        let job = try JobBlocks.require("windows-build")
        guard let buildLine = job.firstLineIndex(matching: #"run:\s*swift build -c release"#) else {
            XCTFail("windows-build must still invoke `swift build -c release`")
            return
        }
        guard let bundleLine = job.firstLineIndex(matching: #"\.dll"#, caseInsensitive: true) else {
            XCTFail("windows-build has no step referencing a .dll at all — spec §D.17 requires copying the " +
                    "GTK 4 runtime DLLs into .build/release/ next to CueSync.exe")
            return
        }
        XCTAssertGreaterThan(bundleLine, buildLine,
            "the DLL-bundling step must run AFTER `swift build -c release` (spec §D.17) — there is nothing to bundle before it")
    }

    /// spec §D.18: a dependency-closure check must run in `windows-build`, after
    /// bundling, using the §0.6 tool (`dependency_runner`/`wldd`, or an
    /// equivalent named in the PR per the findings doc). Keyword-loose on the
    /// tool name for the same reason as the GTK-install test above.
    func testWindowsBuildRunsADependencyClosureCheckAfterBundling() throws {
        let job = try JobBlocks.require("windows-build")
        guard let bundleLine = job.firstLineIndex(matching: #"\.dll"#, caseInsensitive: true) else {
            XCTFail("no DLL-bundling step found to anchor the closure check against")
            return
        }
        guard let checkLine = job.firstLineIndex(matching: #"wldd|dependency_runner|dumpbin"#, caseInsensitive: true) else {
            XCTFail("windows-build has no step referencing a dependency-closure checking tool (wldd/" +
                    "dependency_runner/dumpbin or an equivalent named in the PR) — spec §D.18")
            return
        }
        XCTAssertGreaterThanOrEqual(checkLine, bundleLine,
            "the dependency-closure check must run AFTER the DLL bundle step (spec §D.18) — " +
            "checking before the DLLs are even copied would trivially fail or trivially pass for the wrong reason")
    }

    /// spec §D.18: "Its system allowlist is narrow and written down ... It must
    /// not be padded until the check passes." This can't prove the allowlist is
    /// narrow in general, but it can require the specific named entries the spec
    /// itself calls out, which is the minimum bar for "written down" — a
    /// workflow with no allowlist text at all, or one with just a bare wildcard,
    /// fails this outright.
    func testDependencyClosureAllowlistNamesTheSpecificSystemDLLsNotAWildcard() throws {
        let job = try JobBlocks.require("windows-build")
        let lowered = job.text.lowercased()
        let required = ["kernel32", "user32", "ucrtbase"]
        for name in required {
            XCTAssertTrue(lowered.contains(name),
                "the dependency-closure check's system allowlist must explicitly name `\(name)` " +
                "(spec §D.18's own example list) — an allowlist that can't be grepped for the DLLs " +
                "it permits isn't \"narrow and written down\"")
        }
        XCTAssertFalse(job.text.contains("*.dll") || job.text.contains(#"allow.*=\s*\*"#),
            "the allowlist must not contain a blanket `*.dll`-style wildcard — spec §D.18 forbids " +
            "padding the allowlist until the check passes, and a bare wildcard is the degenerate case of that")
    }

    /// spec §D.19: "Prove the check is not vacuous ... Add a CI step that
    /// deliberately removes one bundled GTK DLL, runs the checker, asserts it
    /// **fails**, then restores the DLL and re-runs to confirm it passes."
    /// Structural proxy: the job must both delete a `.dll` and re-provision one
    /// (restore) somewhere after the first, clean closure check, and the
    /// checker tool keyword must appear more than once (the original clean run
    /// plus at least the negative-control's fail-then-pass runs).
    func testNegativeControlRemovesAndRestoresABundledDLLAroundTheChecker() throws {
        let job = try JobBlocks.require("windows-build")
        let toolOccurrences = job.text.lowercased().components(separatedBy: "wldd").count - 1
            + job.text.lowercased().components(separatedBy: "dependency_runner").count - 1
            + job.text.lowercased().components(separatedBy: "dumpbin").count - 1
        XCTAssertGreaterThanOrEqual(toolOccurrences, 2,
            "spec §D.19 requires the checker to run at least twice more beyond a first pass — once " +
            "expected to fail (after removing a DLL) and once expected to pass again (after restoring " +
            "it) — found only \(toolOccurrences) reference(s) to the checking tool in windows-build")

        let removesADll = job.firstLineIndex(matching: #"(Remove-Item|rm |del )[^\n]*\.dll"#, caseInsensitive: true) != nil
        XCTAssertTrue(removesADll,
            "windows-build must contain a step that deliberately deletes one bundled .dll (spec §D.19's negative control)")

        let restoresADll = job.firstLineIndex(matching: #"(Copy-Item|cp )[^\n]*\.dll"#, caseInsensitive: true) != nil
        XCTAssertTrue(restoresADll,
            "windows-build must restore the deleted .dll after the negative control's expected-failure run (spec §D.19)")
    }

    /// spec §C.13's cache-key call-out: "The GTK install is now an input to the
    /// build ... A stale cache that hides a broken GTK install is a silently-
    /// green build." The pre-CUESYNC-6 key (`windows-build-spm-${{
    /// hashFiles('Package.resolved') }}`) hashes only Package.resolved, which
    /// §A.9 predicts (and the findings doc confirms) does NOT change for this
    /// ticket — so an unmodified key would keep serving a pre-GTK cache hit
    /// forever, never actually exercising the new install step in CI.
    func testWindowsBuildCacheKeyAccountsForTheGtkInstallInput() throws {
        let job = try JobBlocks.require("windows-build")
        guard let keyLine = job.lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("key:") }) else {
            XCTFail("windows-build must still declare a cache key: line")
            return
        }
        XCTAssertNotEqual(keyLine.trimmingCharacters(in: .whitespaces),
                          "key: windows-build-spm-${{ hashFiles('Package.resolved') }}",
            "the windows-build cache key must change to account for the GTK 4 install (spec §C.13) — " +
            "Package.resolved itself does not change for this ticket (spec §A.9), so an unmodified key " +
            "would never invalidate on a changed/broken GTK install")
    }
}

// MARK: - CUESYNC-6c: Swift 6.3.3 toolchain bump + install retry
//
// Coverage note: several of spec CUESYNC-6c §3's criteria are CI-log-only and
// deliberately have no test here — they assert what a real GitHub Actions run
// prints or reports (e.g. "the retry step is reported skipped on a green run",
// the negative-control scratch commit, "the vcpkg cache log shows a hit"), and
// per this file's own header rationale `swift test` cannot spin up a runner to
// observe that. What follows covers every criterion checkable against the
// committed YAML text: the toolchain version bump, the retry step shape, the
// cache key extensions, and that unrelated pins/actions were not touched.

private extension JobBlock {
    /// Index (into `lines`) of every `uses: compnerd/gha-setup-swift@...` line,
    /// in file order — one per toolchain-install attempt.
    func toolchainInstallLineIndices() -> [Int] {
        lines.indices.filter {
            lines[$0].range(of: #"uses:\s*compnerd/gha-setup-swift@"#, options: .regularExpression) != nil
        }
    }
}

final class CUESYNC6cToolchainVersionTests: XCTestCase {

    /// spec CUESYNC-6c §3 Toolchain: "contains exactly two compnerd/gha-setup-swift
    /// steps per §0.1's file (four after step 6's retries — two attempts × two
    /// jobs); every one of them requests swift-version: swift-6.3.3-release and
    /// swift-build: 6.3.3-RELEASE."
    func testEachWindowsJobHasExactlyTwoToolchainInstallAttemptsBothRequesting633() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks.require(jobName)
            let installIndices = job.toolchainInstallLineIndices()
            XCTAssertEqual(installIndices.count, 2,
                "\(jobName) must declare exactly two compnerd/gha-setup-swift steps (initial attempt + " +
                "retry) — found \(installIndices.count)")

            for index in installIndices {
                let end = min(job.lines.count, index + 6)
                let window = job.lines[index..<end].joined(separator: "\n")
                XCTAssertTrue(window.contains("swift-version: swift-6.3.3-release"),
                    "\(jobName) toolchain step at line \(index) must request swift-version: swift-6.3.3-release")
                XCTAssertTrue(window.contains("swift-build: 6.3.3-RELEASE"),
                    "\(jobName) toolchain step at line \(index) must request swift-build: 6.3.3-RELEASE")
            }
        }
    }

    /// spec CUESYNC-6c §3 Toolchain: "No occurrence of 6.1-RELEASE or
    /// swift-6.1-release remains in the file."
    func testNoSwift61ToolchainReferenceRemainsInTheWorkflow() throws {
        let src = try WorkflowFile.contents()
        XCTAssertFalse(src.contains("6.1-RELEASE"), "found a stale swift-build: 6.1-RELEASE reference")
        XCTAssertFalse(src.contains("swift-6.1-release"), "found a stale swift-version: swift-6.1-release reference")
    }

    /// spec CUESYNC-6c §3 Toolchain: "Every compnerd/gha-setup-swift reference is
    /// still pinned to @eeda069c5bc95ac8a9ac5cea7d4f588ae5420ca5. No @main, no
    /// @v0.4.0 float."
    func testEveryCompnerdReferenceStaysPinnedToTheAuditedSHA() throws {
        let src = try WorkflowFile.contents().replacingOccurrences(of: "\r\n", with: "\n")
        let usesLines = src.split(separator: "\n").map(String.init)
            .filter { $0.contains("compnerd/gha-setup-swift@") }
        XCTAssertEqual(usesLines.count, 4,
            "expected exactly 4 compnerd/gha-setup-swift references across both Windows jobs " +
            "(2 attempts x 2 jobs), found \(usesLines.count)")
        for line in usesLines {
            XCTAssertTrue(line.contains("compnerd/gha-setup-swift@eeda069c5bc95ac8a9ac5cea7d4f588ae5420ca5"),
                "compnerd/gha-setup-swift must stay pinned to the audited SHA, got: " +
                "\(line.trimmingCharacters(in: .whitespaces))")
        }
        XCTAssertFalse(src.contains("compnerd/gha-setup-swift@main"), "compnerd/gha-setup-swift must not float on @main")
    }

    /// spec CUESYNC-6c §3 Toolchain: "Both Windows jobs' Swift version step
    /// prints a 6.3.3 version string in the CI log." This can only check the
    /// necessary wiring (the step exists and runs after install, so the log
    /// line it produces reflects the newly installed compiler) — the actual
    /// printed string is CI-log-only evidence per spec §2 step 9.
    func testBothWindowsJobsPrintSwiftVersionAfterToolchainInstall() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks.require(jobName)
            guard let installIndex = job.toolchainInstallLineIndices().last else {
                XCTFail("\(jobName) has no toolchain install step to anchor against")
                continue
            }
            guard let versionIndex = job.firstLineIndex(matching: #"run:\s*swift --version"#) else {
                XCTFail("\(jobName) must run `swift --version` so the installed toolchain version is visible in the CI log")
                continue
            }
            XCTAssertGreaterThan(versionIndex, installIndex,
                "\(jobName)'s `swift --version` step must run after the toolchain install so it reports " +
                "the newly installed compiler, not a stale one")
        }
    }
}

final class CUESYNC6cToolchainRetryTests: XCTestCase {

    /// spec CUESYNC-6c §3 Retry: "the first toolchain attempt has an id and
    /// continue-on-error: true."
    func testFirstToolchainAttemptCarriesIdAndContinueOnErrorTrue() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks.require(jobName)
            guard let firstIndex = job.toolchainInstallLineIndices().first else {
                XCTFail("\(jobName) has no toolchain install step")
                continue
            }
            let preceding = job.lines[max(0, firstIndex - 3)..<firstIndex].joined(separator: "\n")
            XCTAssertTrue(preceding.contains("id: swift-install"),
                "\(jobName)'s first toolchain attempt must carry `id: swift-install`")
            XCTAssertTrue(preceding.contains("continue-on-error: true"),
                "\(jobName)'s first toolchain attempt must carry `continue-on-error: true` so a transient " +
                "network blip doesn't fail the job outright")
        }
    }

    /// spec CUESYNC-6c §3 Retry: "the second is guarded by
    /// if: steps.<id>.outcome == 'failure' and does not carry continue-on-error."
    /// The last attempt must fail loud — only the first swallows its failure.
    func testSecondToolchainAttemptIsGuardedByOutcomeFailureAndDoesNotSwallowFailure() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks.require(jobName)
            let indices = job.toolchainInstallLineIndices()
            guard indices.count == 2 else {
                XCTFail("\(jobName) does not have exactly two toolchain install attempts")
                continue
            }
            let secondIndex = indices[1]
            let preceding = job.lines[max(0, secondIndex - 4)..<secondIndex].joined(separator: "\n")
            XCTAssertTrue(preceding.contains("if: steps.swift-install.outcome == 'failure'"),
                "\(jobName)'s retry attempt must be guarded by `if: steps.swift-install.outcome == 'failure'`")

            let retryEnd = min(job.lines.count, secondIndex + 6)
            let retryBlock = job.lines[secondIndex..<retryEnd].joined(separator: "\n")
            XCTAssertFalse(retryBlock.contains("continue-on-error"),
                "\(jobName)'s retry attempt must NOT carry continue-on-error — a total install failure must " +
                "still fail the job loudly instead of surfacing later as a confusing compile error")
        }
    }

    /// spec CUESYNC-6c §3 Retry: "The guard reads .outcome, not .conclusion."
    /// Under continue-on-error a failed step still reports conclusion: success,
    /// so gating on conclusion would mean the retry step could never fire — and
    /// a retry that silently never runs looks exactly like a retry that works.
    func testRetryGuardNeverReadsConclusionInsteadOfOutcome() throws {
        let src = try WorkflowFile.contents()
        XCTAssertFalse(src.contains("steps.swift-install.conclusion"),
            "the retry guard must read steps.swift-install.outcome, never .conclusion")
    }

    /// spec CUESYNC-6c §3 Retry: "No new third-party action is added to the
    /// file." The retry must be a verbatim second invocation of the
    /// already-pinned compnerd action, never a new retry-wrapper dependency
    /// (nick-fields/retry and friends can't wrap a `uses:` step anyway).
    func testNoNewThirdPartyActionIsIntroducedForTheRetry() throws {
        let src = try WorkflowFile.contents().replacingOccurrences(of: "\r\n", with: "\n")
        let usesRefs = Set(
            src.split(separator: "\n").compactMap { line -> String? in
                guard let range = line.range(of: #"uses:\s*[^\s#]+"#, options: .regularExpression) else { return nil }
                return String(line[range])
                    .replacingOccurrences(of: "uses:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: "@").first.map(String.init)
            }
        )
        let expected: Set<String> = [
            "actions/checkout",
            "actions/cache",
            "actions/upload-artifact",
            "seanmiddleditch/gha-setup-vsdevenv",
            "compnerd/gha-setup-swift",
        ]
        XCTAssertEqual(usesRefs, expected,
            "the set of third-party actions referenced by the workflow must not change — found \(usesRefs)")
    }
}

final class CUESYNC6cCacheKeyTests: XCTestCase {

    /// spec CUESYNC-6c §3 Cache: "Both Windows .build cache keys and their
    /// restore-keys prefixes contain 6.3.3." A .swiftmodule tree built by 6.1
    /// cannot be imported by 6.3.3, so an unversioned key would hand the new
    /// compiler a stale-toolchain build on the first run after this change.
    func testWindowsBuildCacheKeyAndRestoreKeysContainSwift633() throws {
        let job = try JobBlocks.require("windows-build")
        guard let keyLine = job.lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("key: windows-build-spm-") }) else {
            XCTFail("windows-build must declare a windows-build-spm- .build cache key")
            return
        }
        XCTAssertTrue(keyLine.contains("swift-6.3.3"),
            "windows-build's .build cache key must include the swift-6.3.3 toolchain version, got: " +
            "\(keyLine.trimmingCharacters(in: .whitespaces))")

        guard let restoreLine = job.lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("windows-build-spm-") }) else {
            XCTFail("windows-build must declare a windows-build-spm- restore-keys prefix")
            return
        }
        XCTAssertTrue(restoreLine.contains("swift-6.3.3"),
            "windows-build's restore-keys prefix must include the swift-6.3.3 toolchain version, got: " +
            "\(restoreLine.trimmingCharacters(in: .whitespaces))")
    }

    func testWindowsTestCacheKeyAndRestoreKeysContainSwift633() throws {
        let job = try JobBlocks.require("windows-test")
        guard let keyLine = job.lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("key: windows-test-spm-") }) else {
            XCTFail("windows-test must declare a windows-test-spm- .build cache key")
            return
        }
        XCTAssertTrue(keyLine.contains("swift-6.3.3"),
            "windows-test's .build cache key must include the swift-6.3.3 toolchain version, got: " +
            "\(keyLine.trimmingCharacters(in: .whitespaces))")

        guard let restoreLine = job.lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("windows-test-spm-") }) else {
            XCTFail("windows-test must declare a windows-test-spm- restore-keys prefix")
            return
        }
        XCTAssertTrue(restoreLine.contains("swift-6.3.3"),
            "windows-test's restore-keys prefix must include the swift-6.3.3 toolchain version, got: " +
            "\(restoreLine.trimmingCharacters(in: .whitespaces))")
    }

    /// spec CUESYNC-6c §3 Cache: "The vcpkg/installed cache key is unchanged."
    /// GTK 4 is built by MSVC, not Swift, so the toolchain bump must not
    /// invalidate it — a cold GTK rebuild costs 45+ minutes.
    func testVcpkgInstalledCacheKeyIsUnchangedByTheToolchainBump() throws {
        let job = try JobBlocks.require("windows-build")
        guard let keyLine = job.lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("key: windows-build-vcpkg-") }) else {
            XCTFail("windows-build must still declare a windows-build-vcpkg-gtk4- cache key")
            return
        }
        XCTAssertEqual(keyLine.trimmingCharacters(in: .whitespaces),
            "key: windows-build-vcpkg-gtk4-52c9e08cdf8580d2d9762f547d22b96fd81e82f2",
            "the vcpkg/installed cache key must stay byte-identical — the Swift toolchain bump must not " +
            "force a cold GTK 4 rebuild")
    }

    /// spec CUESYNC-6c §3 Cache: "The macos-spm- key is unchanged." The macos
    /// job uses the runner's preinstalled toolchain; this ticket does not
    /// touch it, so 6.3.3 lands on Windows only.
    func testMacosCacheKeyIsUnchangedByTheToolchainBump() throws {
        let job = try JobBlocks.require("macos")
        guard let keyLine = job.lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("key:") }) else {
            XCTFail("macos must still declare a .build cache key")
            return
        }
        XCTAssertEqual(keyLine.trimmingCharacters(in: .whitespaces),
            "key: macos-spm-${{ hashFiles('Package.resolved') }}",
            "the macos .build cache key must remain byte-identical to before this ticket")
    }
}

final class CUESYNC6cUnrelatedPinsUntouchedTests: XCTestCase {

    /// spec CUESYNC-6c §2 step 8 / §3 "Nothing else moved": everything besides
    /// the four toolchain steps and the two .build cache keys must stay
    /// byte-for-byte, including every other action pin and the vcpkg/wldd pins
    /// this ticket must not touch. A git-diff-against-another-branch check
    /// would need a ref (`adw/CUESYNC-6`) that a shallow CI checkout doesn't
    /// fetch, so this locks in the specific pins spec §2 step 8 names instead —
    /// deterministic and independent of what refs happen to be present locally.
    func testUnrelatedPinsSurviveTheToolchainBumpUnchanged() throws {
        let src = try WorkflowFile.contents()
        let mustStillContain = [
            "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5", // v4.3.1
            "actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830", // v4.3.0
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02", // v4.6.2
            "seanmiddleditch/gha-setup-vsdevenv@cf96bf5b227cac6af28c04c4a4e69286ea444163", // v5
            "52c9e08cdf8580d2d9762f547d22b96fd81e82f2", // vcpkg commit pin
            "2DFB5102A00D5E6A368F2A5E0F78733B9EFD7D629B4E90952F3759625971D016", // wldd v1.5.0 SHA-256
        ]
        for pin in mustStillContain {
            XCTAssertTrue(src.contains(pin), "the Swift toolchain bump must not touch this unrelated pin, but it is missing: \(pin)")
        }
    }
}

// MARK: - Suite-integrity meta-checks (spec §E.24/§E.25)

final class CUESYNC6TestSuiteIntegrityTests: XCTestCase {

    /// spec §E.24 forbids reaching for the skip mechanism as a quiet way to make
    /// a red test disappear rather than fixing it. Matches call-syntax only
    /// (the skip-family APIs, checked via `skipTokens` below rather than a
    /// regex literal) so a doc comment merely discussing the rule can't trip
    /// it. This file is excluded from its own scan: the check necessarily
    /// spells the forbidden calls out as data (`skipTokens`) to look for them,
    /// and that is not the same thing as this file itself calling them.
    func testNoTestFileUsesXCTSkipAnywhereInTheSuite() throws {
        let dir = RepoPaths.root.appendingPathComponent("Tests/CueSyncCoreTests")
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate Tests/CueSyncCoreTests")
            return
        }
        let skipTokens = ["XCTSkip" + "(", "XCTSkip" + "If(", "XCTSkip" + "Unless("]
        var checked = 0
        for case let file as URL in files
        where file.pathExtension == "swift" && file.lastPathComponent != "CUESYNC6WindowsGtkWorkflowTests.swift" {
            let src = try String(contentsOf: file, encoding: .utf8)
            checked += 1
            for token in skipTokens {
                XCTAssertFalse(src.contains(token),
                    "\(file.lastPathComponent) calls \(token.dropLast())...) — spec §E.24 forbids skipping " +
                    "any test as a way to route around a failure instead of fixing the underlying issue")
            }
        }
        XCTAssertGreaterThan(checked, 0, "expected to scan at least one test file")
    }

    /// spec §E.25: "179 is stale ... The binding requirement: the suite's
    /// passing count must not decrease." 206 is the audited count recorded in
    /// specs/CUESYNC-6-findings.md §0.5 (verified via a real local `swift test`
    /// run) at the point these compliance tests were added — a floor, not a
    /// target, that must be bumped upward (never down) as future tickets add
    /// tests, mirroring how `Audit.resolvedClosure` is maintained deliberately
    /// rather than derived from the very file it audits.
    func testMethodCountAcrossTheSuiteHasNotDroppedBelowTheAuditedBaseline() throws {
        let dir = RepoPaths.root.appendingPathComponent("Tests/CueSyncCoreTests")
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate Tests/CueSyncCoreTests")
            return
        }
        var total = 0
        let pattern = #"\bfunc test[A-Za-z0-9_]*\("#
        for case let file as URL in files where file.pathExtension == "swift" {
            let src = try String(contentsOf: file, encoding: .utf8)
            total += (try? NSRegularExpression(pattern: pattern)
                .numberOfMatches(in: src, range: NSRange(src.startIndex..., in: src))) ?? 0
        }
        XCTAssertGreaterThanOrEqual(total, 206,
            "test method count dropped below the audited CUESYNC-6 baseline of 206 (found \(total)) — " +
            "spec §E.25 requires the passing count never decrease, and no test may be removed or weakened")
    }
}

// MARK: - Helpers

private enum RepoPaths {
    /// Tests/CueSyncCoreTests/<this file> -> Tests/CueSyncCoreTests -> Tests -> repo root
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let packageSwift = root.appendingPathComponent("Package.swift")
    static let packageResolved = root.appendingPathComponent("Package.resolved")
    static let workflow = root.appendingPathComponent(".github/workflows/swift-windows.yml")
}

private enum PackageResolved {
    static func pins() throws -> [[String: Any]] {
        let data = try Data(contentsOf: RepoPaths.packageResolved)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["pins"] as? [[String: Any]])
            ?? ((json?["object"] as? [String: Any])?["pins"] as? [[String: Any]])
            ?? []
    }

    static func identity(of pin: [String: Any]) -> String {
        ((pin["identity"] as? String) ?? (pin["package"] as? String) ?? "<unknown>").lowercased()
    }
}

private enum WorkflowFile {
    static func contents() throws -> String {
        try String(contentsOf: RepoPaths.workflow, encoding: .utf8)
    }
}

/// A single top-level GitHub Actions job's YAML text, isolated so ordering/
/// presence assertions can't accidentally match a step in a *different* job
/// (e.g. a GTK-install step intentionally present in `macos` must not satisfy
/// the `windows-test`-has-none assertion just because they share one file).
private struct JobBlock {
    let text: String
    /// Normalized (CRLF -> LF) line array, so a Windows checkout with
    /// `core.autocrlf` can't dodge a line-exact match on a trailing `\r`.
    let lines: [String]

    /// Index (into `lines`) of the first line matching `pattern`, or nil.
    func firstLineIndex(matching pattern: String, caseInsensitive: Bool = false) -> Int? {
        let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        return lines.firstIndex { $0.range(of: pattern, options: options) != nil }
    }
}

private enum JobBlocks {
    /// Extracts the text of the top-level job named `name` (`  <name>:` at
    /// exactly 2-space indent) up to — but not including — the next 2-space-
    /// indented `key:` line, or end of file. Mirrors the existing repo
    /// convention (AdversarialSupplyChainTests' WorkflowParser) of treating the
    /// YAML as structured text rather than pulling in a YAML parsing dependency
    /// Package.swift does not otherwise need.
    static func require(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> JobBlock {
        let raw = try WorkflowFile.contents()
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let allLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = allLines.firstIndex(of: "  \(name):") else {
            XCTFail("could not locate the top-level `\(name):` job in .github/workflows/swift-windows.yml",
                    file: file, line: line)
            return JobBlock(text: "", lines: [])
        }
        var end = allLines.count
        for i in (start + 1)..<allLines.count {
            if allLines[i].range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil {
                end = i
                break
            }
        }
        let block = Array(allLines[start..<end])
        return JobBlock(text: block.joined(separator: "\n"), lines: block)
    }
}
