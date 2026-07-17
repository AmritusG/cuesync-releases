import Foundation
import XCTest

// =============================================================================
// CUESYNC-6c red-team — attacking the *guards*, not the YAML.
//
// This ticket has no runtime input surface (spec §4: "adds no runtime input
// handling, no parsing, and no user-facing surface"), so the classic attack
// list — injection, traversal, TOCTOU, encoding tricks, resource exhaustion —
// has nothing to bite on. Its entire threat surface is CI supply chain, and the
// only thing standing between that surface and a vacuous green is
// CUESYNC6WindowsGtkWorkflowTests' structural checks against the committed YAML.
//
// So those checks are the attack target. The committed workflow is correct
// today; every exploit below is a *hostile edit that the existing checks accept*
// — a YAML that ships a broken or silently-degraded Windows CI leg while the
// suite stays green. Each is reproduced against a synthetic job block, run
// through the same parser the real assertions use, and paired with a scanner
// that rejects it. The scanners are then pointed at the real workflow, where
// they pass — and keep passing only while it stays honest.
//
// Style note: this file follows AdversarialSupplyChainTests' GuardScanner
// idiom — a scanner, a proof the scanner catches the bypass the shipped check
// misses, and a proof it does not cry wolf on the real, correct file. A scanner
// asserted only against known-good input is indistinguishable from one that
// always returns "fine".
// =============================================================================

// MARK: - 1. `continue-on-error` smuggled past the narrowed windows-build guard

final class AdversarialCUESYNC6cContinueOnErrorTests: XCTestCase {

    /// EXPLOIT — proximity-matching is not identity-matching.
    ///
    /// CUESYNC-6c narrowed `testWindowsBuildStepIsNeitherSkippedNorContinueOnError-
    /// NorConditional` to admit one legitimate `continue-on-error: true` (the retry
    /// pattern's first toolchain attempt, spec §2 step 6). It implements the
    /// exception as a *text proximity* search: any `continue-on-error: true` is
    /// forgiven when one of the three preceding lines contains `id: swift-install`.
    ///
    /// `job.lines` is raw YAML text — comments included, nothing stripped. So the
    /// exception is claimable by any step willing to write the magic words in a
    /// comment above itself:
    ///
    ///     - name: Build (release)
    ///       # id: swift-install — see the retry pattern above
    ///       continue-on-error: true
    ///       run: swift build -c release
    ///
    /// That is the exact vacuous-green outcome spec §0.4/§C.16 exists to forbid —
    /// GtkBackend fails to compile or link, the job reports green, and the
    /// `cuesync-windows` artifact ships without ever having built. The step's own
    /// `run:` line is untouched, so the sibling `||`-chaining assertion passes too.
    func testCommentClaimingTheRetryExceptionCannotLaunderContinueOnError() {
        let job = JobBlocks.parse("windows-build", in: Fixtures.commentSmuggledContinueOnError)

        XCTAssertTrue(Legacy.windowsBuildContinueOnErrorCheckAccepts(job),
            "precondition: the shipped proximity check must accept this bypass — if it no longer does, " +
            "this exploit is closed and the scanner below can be re-scoped")

        let violations = RetryShape.illegitimateContinueOnErrorSteps(job)
        XCTAssertEqual(violations.map(\.name), ["Build (release)"],
            "a comment reading `id: swift-install` must not let `swift build -c release` swallow its own " +
            "failure — the retry exception belongs to the toolchain-install step itself, not to any step " +
            "that mentions its id nearby")
    }

    /// EXPLOIT — the "retry must not swallow failure" check looks in the wrong direction.
    ///
    /// `testSecondToolchainAttemptIsGuardedByOutcomeFailureAndDoesNotSwallowFailure`
    /// anchors on the retry's `uses:` line and scans the six lines *after* it for
    /// `continue-on-error`. But YAML step keys are unordered, and this workflow's own
    /// first attempt proves the flag reads naturally *above* `uses:`. Placed there on
    /// the retry, it is invisible to the check:
    ///
    ///     - name: Retry Swift toolchain install
    ///       if: steps.swift-install.outcome == 'failure'
    ///       continue-on-error: true        # <- above `uses:`, never scanned
    ///       uses: compnerd/gha-setup-swift@eeda069c...
    ///
    /// Now *both* attempts swallow their failure and spec §2 step 6's load-bearing
    /// property — "the last attempt must NOT be continue-on-error ... fail-loud is
    /// the point" — is gone silently.
    ///
    /// Demonstrated against `windows-test` deliberately: the narrowed
    /// `continue-on-error` scan runs only over `windows-build`, so `windows-test` has
    /// no second line of defence and this bypass clears the entire suite.
    func testRetryAttemptCannotHideContinueOnErrorAboveItsUsesLine() {
        let job = JobBlocks.parse("windows-test", in: Fixtures.retrySwallowsFailureAboveUsesLine)

        XCTAssertTrue(Legacy.retryDoesNotSwallowFailureCheckAccepts(job),
            "precondition: the shipped positional check must accept this bypass — it only scans lines " +
            "after `uses:`")

        let violations = RetryShape.illegitimateContinueOnErrorSteps(job)
        XCTAssertEqual(violations.map(\.name), ["Retry Swift toolchain install"],
            "only the FIRST toolchain attempt may carry continue-on-error (spec §2 step 6) — the retry " +
            "carrying it too means a total install failure falls through to `swift test` and surfaces as " +
            "a confusing compile error instead of an honest install error")
    }

    /// The scanner must not fire on the real workflow, in either Windows job — a
    /// check that cries wolf gets deleted, and then both bypasses above are live.
    /// This is also the durable regression guard: it fails the moment either job
    /// grows a `continue-on-error` anywhere except its first toolchain attempt.
    func testRealWorkflowCarriesContinueOnErrorOnlyOnTheFirstToolchainAttempt() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks.require(jobName)
            let violations = RetryShape.illegitimateContinueOnErrorSteps(job)
            XCTAssertTrue(violations.isEmpty,
                "\(jobName) carries continue-on-error: true on step(s) \(violations.map(\.name)) — spec " +
                "§2 step 6 allows it on the first Swift-toolchain-install attempt and nowhere else")

            let toolchainSteps = WorkflowSteps.parse(job).filter(\.isToolchainInstall)
            XCTAssertEqual(toolchainSteps.count, 2, "\(jobName) must declare exactly two toolchain attempts")
            XCTAssertTrue(toolchainSteps.first?.swallowsFailure == true,
                "\(jobName)'s first toolchain attempt must carry continue-on-error: true, or the retry can never fire")
            XCTAssertFalse(toolchainSteps.last?.swallowsFailure == true,
                "\(jobName)'s retry attempt must NOT carry continue-on-error — fail-loud is the point")
        }
    }
}

// MARK: - 2. Cache poisoning via an extra restore-keys fallback

final class AdversarialCUESYNC6cCachePoisoningTests: XCTestCase {

    /// EXPLOIT — `first(where:)` over a list that is allowed to have more than one entry.
    ///
    /// Spec §2 step 7 exists because `.swiftmodule` files are compiler-version-locked:
    /// a 6.1-built `.build` tree handed to the 6.3.3 compiler is a poisoned cache. The
    /// shipped check (`testWindowsBuildCacheKeyAndRestoreKeysContainSwift633`) takes the
    /// *first* line starting `windows-build-spm-` and asserts it contains `swift-6.3.3`.
    ///
    /// `restore-keys` is a prefix list, tried in order, and nothing stops a second entry:
    ///
    ///     restore-keys: |
    ///       windows-build-spm-swift-6.3.3-vcpkg-
    ///       windows-build-spm-vcpkg-              # <- restores a 6.1 tree
    ///
    /// The first entry satisfies the check; the second reintroduces exactly the
    /// restore the ticket added the version for. It also dodges
    /// `testNoSwift61ToolchainReferenceRemainsInTheWorkflow`, which greps for
    /// `6.1-RELEASE` / `swift-6.1-release` — a version-less prefix names no version.
    func testEveryRestoreKeyFallbackMustPinTheToolchainNotJustTheFirst() {
        let job = JobBlocks.parse("windows-build", in: Fixtures.restoreKeyFallbackToUnversionedPrefix)

        XCTAssertTrue(Legacy.restoreKeysContainToolchainCheckAccepts(job, keyPrefix: "windows-build-spm-"),
            "precondition: the shipped first(where:) check must accept this bypass")

        let unpinned = CacheKeys.restoreKeyEntries(job, keyPrefix: "windows-build-spm-")
            .filter { !$0.contains("swift-6.3.3") }
        XCTAssertEqual(unpinned, ["windows-build-spm-vcpkg-"],
            "every restore-keys fallback must pin the toolchain version — one that doesn't will cheerfully " +
            "hand a 6.1-built .swiftmodule tree to the 6.3.3 compiler (spec §2 step 7)")
    }

    /// Durable guard on the real file: *all* `.build` restore-key fallbacks in both
    /// Windows jobs pin the toolchain, not merely the first one the shipped check reads.
    func testRealWorkflowPinsTheToolchainInEveryWindowsRestoreKeyFallback() throws {
        for (jobName, keyPrefix) in [("windows-build", "windows-build-spm-"), ("windows-test", "windows-test-spm-")] {
            let job = try JobBlocks.require(jobName)
            let entries = CacheKeys.restoreKeyEntries(job, keyPrefix: keyPrefix)
            XCTAssertFalse(entries.isEmpty, "\(jobName) must declare a \(keyPrefix) restore-keys list")
            for entry in entries {
                XCTAssertTrue(entry.contains("swift-6.3.3"),
                    "\(jobName) restore-keys fallback `\(entry)` names no toolchain version — it can restore " +
                    "a .build tree built by a different compiler (spec §2 step 7)")
            }
        }
    }

    /// The toolchain version in the cache keys must be the version actually installed.
    /// Both are literals in the same file with nothing tying them together, so a future
    /// bump that edits the `swift-build:` inputs and forgets the keys (or vice versa)
    /// is a one-line mistake that reads as green — and produces exactly the
    /// cross-compiler `.build` restore spec §2 step 7 forbids.
    func testCacheKeyToolchainVersionMatchesTheVersionActuallyInstalled() throws {
        for (jobName, keyPrefix) in [("windows-build", "windows-build-spm-"), ("windows-test", "windows-test-spm-")] {
            let job = try JobBlocks.require(jobName)
            guard let installed = WorkflowSteps.parse(job).first(where: \.isToolchainInstall)?.requestedSwiftBuild else {
                XCTFail("\(jobName) has no resolvable `swift-build:` input on its first toolchain attempt")
                continue
            }
            // `6.3.3-RELEASE` -> `6.3.3`, the form the cache keys spell.
            let version = installed.replacingOccurrences(of: "-RELEASE", with: "")
            for entry in CacheKeys.restoreKeyEntries(job, keyPrefix: keyPrefix) {
                XCTAssertTrue(entry.contains("swift-\(version)"),
                    "\(jobName) installs Swift \(version) but its restore-keys fallback `\(entry)` pins a " +
                    "different toolchain — the cache key and the installed compiler must move together")
            }
        }
    }
}

// MARK: - 3. The skip-scan's blind spot is the file holding every CI guard

final class AdversarialCUESYNC6cSuiteIntegrityTests: XCTestCase {

    /// EXPLOIT — a self-exclusion that is both unnecessary and load-bearing.
    ///
    /// `testNoTestFileUsesXCTSkipAnywhereInTheSuite` (spec §E.24) enforces "no test
    /// is skipped to route around a failure" across the suite — but excludes
    /// `CUESYNC6WindowsGtkWorkflowTests.swift` from its own scan, reasoning that the
    /// file must name the forbidden tokens as data in order to look for them.
    ///
    /// It doesn't need the exclusion: it already builds the tokens by concatenation
    /// (`"XCTSkip" + "("`) precisely so the literal never appears in its own source.
    /// The exclusion is redundant belt-and-braces — and it carves the hole exactly
    /// where it hurts most, since that file holds *every* structural guard over the
    /// Windows CI legs. A skip added there disables a CI compliance check silently.
    ///
    /// This scan covers the whole suite with no exclusions, using the same
    /// concatenation trick so it doesn't trip over itself either.
    func testSkipScanCoversEveryTestFileIncludingTheOneHoldingTheCIGuards() throws {
        let dir = RepoPaths.root.appendingPathComponent("Tests/CueSyncCoreTests")
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate Tests/CueSyncCoreTests")
            return
        }
        let skipTokens = ["XCTSkip" + "(", "XCTSkip" + "If(", "XCTSkip" + "Unless("]
        var scanned: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let src = try String(contentsOf: file, encoding: .utf8)
            scanned.append(file.lastPathComponent)
            for token in skipTokens {
                XCTAssertFalse(src.contains(token),
                    "\(file.lastPathComponent) calls \(token.dropLast())...) — spec §E.24 forbids skipping a " +
                    "test to route around a failure instead of fixing it")
            }
        }
        XCTAssertTrue(scanned.contains("CUESYNC6WindowsGtkWorkflowTests.swift"),
            "the skip scan must cover the file holding the Windows CI structural guards — the shipped scan " +
            "excludes it by name, which is where a silenced CI check would be least visible")
    }
}

// MARK: - Helpers

private enum RepoPaths {
    /// Tests/CueSyncCoreTests/<this file> -> Tests/CueSyncCoreTests -> Tests -> repo root
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let workflow = root.appendingPathComponent(".github/workflows/swift-windows.yml")
}

/// One `- ...` item under a job's `steps:`, with comments and blank lines removed.
/// Comment-stripping is the point: the shipped proximity check reads raw lines, and
/// a comment is not configuration.
private struct WorkflowStep {
    let firstLineNumber: Int
    let codeLines: [String]

    /// The step's `name:`, or its `id:`, or its `uses:` — whatever identifies it in a
    /// failure message. Steps are not required to carry a name.
    var name: String {
        for key in ["name:", "id:", "uses:"] {
            if let line = codeLines.first(where: { Self.strip($0).hasPrefix(key) }) {
                return String(Self.strip(line).dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return "<line \(firstLineNumber)>"
    }

    var isToolchainInstall: Bool { contains(#"uses:\s*compnerd/gha-setup-swift@"#) }
    var swallowsFailure: Bool { contains(#"continue-on-error:\s*true"#) }

    /// The `swift-build:` input this step requests, if any.
    var requestedSwiftBuild: String? {
        codeLines.first { Self.strip($0).hasPrefix("swift-build:") }
            .map { String(Self.strip($0).dropFirst("swift-build:".count)).trimmingCharacters(in: .whitespaces) }
    }

    func contains(_ pattern: String) -> Bool {
        codeLines.contains { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    /// Leading `- ` (the YAML sequence marker) is not part of the key it precedes.
    private static func strip(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") { s = String(s.dropFirst(2)) }
        return s
    }
}

private enum WorkflowSteps {
    /// Splits a job into its steps. A step starts at a 6-space-indented `- ` line and
    /// runs until the next one or a dedent. Blank lines and whole-line comments are
    /// dropped — they carry no configuration, and treating them as if they did is
    /// precisely the defect this file attacks.
    static func parse(_ job: JobBlock) -> [WorkflowStep] {
        var steps: [WorkflowStep] = []
        var current: [String] = []
        var start = 0

        func flush() {
            if !current.isEmpty { steps.append(WorkflowStep(firstLineNumber: start, codeLines: current)) }
            current = []
        }

        for (index, line) in job.lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if line.range(of: #"^ {6}- "#, options: .regularExpression) != nil {
                flush()
                start = index
                current = [line]
            } else if !current.isEmpty {
                if line.range(of: #"^ {7,}"#, options: .regularExpression) != nil {
                    current.append(line)
                } else {
                    flush()
                }
            }
        }
        flush()
        return steps
    }
}

private enum RetryShape {
    /// Every step carrying `continue-on-error: true` that is not the job's *first*
    /// toolchain-install attempt — i.e. every step spec §2 step 6 does not excuse.
    ///
    /// Keyed on the step's own identity (does its block actually invoke the pinned
    /// compnerd action?) rather than on text near it, which is what makes both the
    /// comment bypass and the key-ordering bypass non-viable.
    static func illegitimateContinueOnErrorSteps(_ job: JobBlock) -> [WorkflowStep] {
        let steps = WorkflowSteps.parse(job)
        let firstAttemptLine = steps.first(where: \.isToolchainInstall)?.firstLineNumber
        return steps.filter { $0.swallowsFailure && $0.firstLineNumber != firstAttemptLine }
    }
}

private enum CacheKeys {
    /// Every entry of the `restore-keys:` block belonging to the cache step whose
    /// `key:` starts with `keyPrefix` — all of them, not just the first.
    static func restoreKeyEntries(_ job: JobBlock, keyPrefix: String) -> [String] {
        for step in WorkflowSteps.parse(job)
        where step.codeLines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("key: \(keyPrefix)") }) {
            guard let restoreIndex = step.codeLines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("restore-keys:")
            }) else { return [] }

            let restoreIndent = indent(step.codeLines[restoreIndex])
            var entries: [String] = []
            for line in step.codeLines[step.codeLines.index(after: restoreIndex)...] {
                guard indent(line) > restoreIndent else { break }
                entries.append(line.trimmingCharacters(in: .whitespaces))
            }
            return entries
        }
        return []
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
}

/// Faithful reproductions of the assertions CUESYNC6WindowsGtkWorkflowTests ships
/// today, used to *prove* each exploit clears them. Without these the tests above
/// would assert only that a new scanner works, never that the shipped one is fooled
/// — which is the entire claim being made.
private enum Legacy {
    /// `testWindowsBuildStepIsNeitherSkippedNorContinueOnErrorNorConditional`'s
    /// narrowed exception: forgive `continue-on-error: true` when one of the three
    /// preceding raw lines contains `id: swift-install`.
    static func windowsBuildContinueOnErrorCheckAccepts(_ job: JobBlock) -> Bool {
        for (index, line) in job.lines.enumerated()
        where line.range(of: #"continue-on-error:\s*true"#, options: .regularExpression) != nil {
            let preceding = job.lines[max(0, index - 3)..<index]
            if !preceding.contains(where: { $0.contains("id: swift-install") }) { return false }
        }
        return true
    }

    /// `testSecondToolchainAttemptIsGuardedByOutcomeFailureAndDoesNotSwallowFailure`'s
    /// swallow check: scan the six lines starting at the retry's `uses:` line.
    static func retryDoesNotSwallowFailureCheckAccepts(_ job: JobBlock) -> Bool {
        let indices = job.lines.indices.filter {
            job.lines[$0].range(of: #"uses:\s*compnerd/gha-setup-swift@"#, options: .regularExpression) != nil
        }
        guard indices.count == 2 else { return false }
        let second = indices[1]
        let end = min(job.lines.count, second + 6)
        return !job.lines[second..<end].joined(separator: "\n").contains("continue-on-error")
    }

    /// `testWindows{Build,Test}CacheKeyAndRestoreKeysContainSwift633`'s restore-keys
    /// half: read the first line starting with the prefix, check it names 6.3.3.
    static func restoreKeysContainToolchainCheckAccepts(_ job: JobBlock, keyPrefix: String) -> Bool {
        guard let line = job.lines.first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(keyPrefix)
        }) else { return false }
        return line.contains("swift-6.3.3")
    }
}

private struct JobBlock {
    let lines: [String]
}

private enum JobBlocks {
    /// Extracts a top-level job's text from `source`. Same rules as
    /// CUESYNC6WindowsGtkWorkflowTests' extractor — `  <name>:` at exactly 2-space
    /// indent, up to the next 2-space-indented bare key — so the exploits below are
    /// demonstrated against the real assertions' view of the file, not a friendlier one.
    static func parse(_ name: String, in source: String) -> JobBlock {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let all = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = all.firstIndex(of: "  \(name):") else { return JobBlock(lines: []) }
        var end = all.count
        for i in (start + 1)..<all.count
        where all[i].range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil {
            end = i
            break
        }
        return JobBlock(lines: Array(all[start..<end]))
    }

    static func require(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> JobBlock {
        let job = parse(name, in: try String(contentsOf: RepoPaths.workflow, encoding: .utf8))
        if job.lines.isEmpty {
            XCTFail("could not locate the top-level `\(name):` job in .github/workflows/swift-windows.yml",
                    file: file, line: line)
        }
        return job
    }
}

// MARK: - Hostile fixtures
//
// Each is a minimal but structurally faithful copy of the real job — same
// indentation, same pinned SHA, same inputs — carrying exactly one hostile edit.

private enum Fixtures {

    /// Attack 1: the build step claims the retry exception in a comment.
    static let commentSmuggledContinueOnError = """
    jobs:
      windows-build:
        name: swift · windows-latest (build)
        runs-on: windows-latest
        steps:
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

          - name: Build (release)
            # id: swift-install — same retry pattern as above
            continue-on-error: true
            run: swift build -c release
    """

    /// Attack 2: the retry swallows its failure via a key placed above `uses:`.
    static let retrySwallowsFailureAboveUsesLine = """
    jobs:
      windows-test:
        name: swift · windows-latest (test)
        runs-on: windows-latest
        steps:
          - id: swift-install
            continue-on-error: true
            uses: compnerd/gha-setup-swift@eeda069c5bc95ac8a9ac5cea7d4f588ae5420ca5 # v0.4.0
            with:
              swift-version: swift-6.3.3-release
              swift-build: 6.3.3-RELEASE

          - name: Retry Swift toolchain install
            if: steps.swift-install.outcome == 'failure'
            continue-on-error: true
            uses: compnerd/gha-setup-swift@eeda069c5bc95ac8a9ac5cea7d4f588ae5420ca5 # v0.4.0
            with:
              swift-version: swift-6.3.3-release
              swift-build: 6.3.3-RELEASE
    """

    /// Attack 3: a second restore-keys entry that names no toolchain version.
    static let restoreKeyFallbackToUnversionedPrefix = """
    jobs:
      windows-build:
        name: swift · windows-latest (build)
        runs-on: windows-latest
        steps:
          - name: Cache SwiftPM build
            uses: actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830 # v4.3.0
            with:
              path: .build
              key: windows-build-spm-swift-6.3.3-vcpkg-52c9e08cdf8580d2d9762f547d22b96fd81e82f2-${{ hashFiles('Package.resolved') }}
              restore-keys: |
                windows-build-spm-swift-6.3.3-vcpkg-
                windows-build-spm-vcpkg-
    """
}
