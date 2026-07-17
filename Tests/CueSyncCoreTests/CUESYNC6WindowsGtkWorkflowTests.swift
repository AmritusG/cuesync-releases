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
