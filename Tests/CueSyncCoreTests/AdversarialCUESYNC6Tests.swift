import Foundation
import XCTest

// =============================================================================
// CUESYNC-6 red-team suite — attacks on the ACCEPTANCE CRITERIA, not the code.
//
// `CUESYNC6WindowsGtkWorkflowTests` already asserts that the §C/§D workflow
// declares a GTK install, a DLL bundle step, a closure check and a negative
// control. This file exists because every one of those assertions can be
// satisfied by an implementation that ships nothing of value. Each test below
// is a specific, reproducible way to turn that file green while leaving the
// ticket's actual guarantee — "a binary whose runtime dependencies are
// enumerated, bundled, and checked" — completely unmet.
//
// The through-line is spec §E.21's own rule, which the ticket states twice and
// attributes to the §D.15 lesson from CUESYNC-5:
//
//     "Assert on the target block's structure, not on a substring of the whole
//      manifest — a comment mentioning DefaultBackend ... must not be able to
//      fail or pass it."
//
// `PortComplianceTests` obeys that rule for `Package.swift`. The CUESYNC-6
// workflow tests do not: they grep raw YAML line-by-line, and the workflow they
// grep is roughly 40% prose comments. Attack #1 below is that gap, and it is
// not theoretical — a single `# TODO: install gtk4, bundle the dlls, run wldd`
// placed above `swift build` satisfies FOUR separate assertions at once.
//
// STRUCTURE. Spec §D.19 demands the DLL checker be proven non-vacuous before
// its green means anything, and that demand applies to this file too: several
// rules here are contingent ("IF you download an archive, hash it first") and
// would pass today against a workflow that simply hasn't wired §C/§D yet. A
// contingent rule that has never been watched to fire is an unfalsified claim.
// So every rule is a pure function returning violations (`Rules`), each is run
// twice — once against the real workflow, once against a hostile fixture built
// to trip it (`...NegativeControlTests`) — and the fixture run asserts it FIRES.
// If a rule ever stops being able to fail, its negative control goes red first.
//
// Like the file they harden, the non-contingent tests are expected to fail until
// the §C/§D CI-wiring pass lands. That is the point: they fail with an itemized
// contract rather than letting §C/§D ship a vacuous green.
// =============================================================================

// MARK: - Attack 1 — a comment is not a build step

/// The workflow tests in `CUESYNC6WindowsGtkWorkflowTests` match against raw
/// lines. YAML comments are raw lines. So is PowerShell comment text inside a
/// `run: |` block. Every "is the step there?" assertion in that file is
/// therefore satisfiable with prose, which is precisely the failure mode spec
/// §0.4 names as "the single most likely way this ticket ships something
/// worthless".
///
/// These tests re-assert the same §C/§D requirements against **comment-stripped**
/// YAML, so only executable step text can satisfy them.
final class AdversarialCUESYNC6CommentVacuityTests: XCTestCase {

    /// Proves the stripper works before anything relies on it — and, in the same
    /// breath, demonstrates the exploit is real rather than asserted. The
    /// synthetic job below contains NO GTK install, NO bundle step and NO checker
    /// invocation; it contains a comment mentioning all three. The raw grep the
    /// existing tests use accepts it. The stripped grep rejects it.
    func testCommentStripperIsWhatSeparatesAProseTodoFromARealStep() {
        let job = Job(name: "windows-build", from: Fixtures.proseTodoOnly)

        // The raw-line grep — the shape every existing §C/§D presence assertion
        // uses — is fooled by the comment.
        XCTAssertNotNil(job.firstRawLineIndex(matching: "gtk4"),
            "precondition: this fixture's comment must be visible to a raw grep — otherwise it " +
            "isn't a reproduction of the exploit")
        XCTAssertNotNil(job.firstRawLineIndex(matching: #"\.dll"#),
            "precondition: the comment mentions .dll and a raw grep must see it")
        XCTAssertNotNil(job.firstRawLineIndex(matching: "wldd"),
            "precondition: the comment mentions wldd and a raw grep must see it")

        // The stripped grep is not.
        XCTAssertNil(job.firstCodeLineIndex(matching: "gtk4"),
            "the comment stripper must blank `# TODO: install gtk4 ...` — if this fires, every " +
            "comment-proof assertion in this file is itself vacuous and must be fixed first")
        XCTAssertNil(job.firstCodeLineIndex(matching: #"\.dll"#),
            "the comment stripper must blank .dll mentions that appear only in prose")
        XCTAssertNil(job.firstCodeLineIndex(matching: "wldd"),
            "the comment stripper must blank checker-tool mentions that appear only in prose")

        // ...and it must not over-strip: real step text on the same fixture survives.
        XCTAssertNotNil(job.firstCodeLineIndex(matching: #"run:\s*swift build -c release"#),
            "the stripper must preserve executable step text — a stripper that blanks everything " +
            "would make these tests pass for the wrong reason")
    }

    /// A `#` inside a quoted YAML scalar is data, not a comment. If the stripper
    /// blanked it, a legitimate workflow could be failed by this suite for text
    /// it genuinely executes — the false-positive mirror of the exploit above.
    func testCommentStripperDoesNotBlankAHashInsideAQuotedScalarOrMidToken() {
        XCTAssertEqual(Yaml.blankingComments(#"    run: echo "gtk4 #1 build" # a real comment"#),
                       #"    run: echo "gtk4 #1 build" "#,
            "a `#` inside quotes is data; only an unquoted, whitespace-preceded `#` starts a comment")
        XCTAssertEqual(Yaml.blankingComments("    key: windows-build-spm-v2#gtk"),
                       "    key: windows-build-spm-v2#gtk",
            "a mid-token `#` is not a comment start in YAML and must survive stripping")
    }

    /// spec §C.13 — the GTK 4 install must be a real step, not a promise of one.
    ///
    /// Two exploits closed here: (1) the prose TODO above, and (2) a step whose
    /// `name:` says "Install GTK 4" while its `run:` does nothing — a non-comment
    /// line mentioning GTK that installs nothing. So the surviving GTK mention
    /// must be on a line that is neither a comment nor a bare `name:` label.
    func testWindowsBuildGtkInstallSurvivesCommentStrippingAndIsNotJustAStepLabel() throws {
        let job = try Job.require("windows-build")
        guard let buildLine = job.firstCodeLineIndex(matching: #"run:\s*swift build -c release"#) else {
            XCTFail("windows-build must still invoke `swift build -c release`")
            return
        }
        let gtkLines = job.codeLineIndices(matching: Patterns.gtkMention)
        XCTAssertFalse(gtkLines.isEmpty,
            "windows-build has no NON-COMMENT line referencing GTK 4 — spec §C.13 requires an actual " +
            "install step. A `# TODO: install gtk4` comment satisfies the existing raw-line grep in " +
            "CUESYNC6WindowsGtkWorkflowTests but installs nothing, which is the §E.21/§D.15 lesson " +
            "this ticket restates: a comment must not be able to satisfy an assertion.")

        let substantive = gtkLines.filter { !job.code[$0].isBareNameLabel }
        XCTAssertFalse(substantive.isEmpty,
            "every non-comment GTK mention in windows-build is a step `name:` label — a step called " +
            "\"Install GTK 4\" whose body installs nothing is the same vacuous green in a different " +
            "costume (spec §C.13)")

        if let firstReal = substantive.first {
            XCTAssertLessThan(firstReal, buildLine,
                "the GTK 4 install must execute BEFORE `swift build -c release` (spec §C.13) — " +
                "GtkBackend needs headers and libs to link against")
        }
    }

    /// spec §D.17 — same attack, applied to the bundle step. The existing test
    /// anchors on `#"\.dll"#` matched against raw lines, so a comment saying
    /// "copy the .dll files here" passes it while the artifact ships bare.
    func testWindowsBuildDllBundleStepSurvivesCommentStripping() throws {
        let job = try Job.require("windows-build")
        guard let buildLine = job.firstCodeLineIndex(matching: #"run:\s*swift build -c release"#) else {
            XCTFail("windows-build must still invoke `swift build -c release`")
            return
        }
        let copyLines = job.codeLineIndices(matching: Patterns.copyVerbWithDll)
        XCTAssertFalse(copyLines.isEmpty,
            "windows-build has no NON-COMMENT step that actually copies a .dll — spec §D.17 requires " +
            "the GTK 4 runtime be copied next to CueSync.exe so the artifact is self-contained. A raw " +
            "grep for `.dll` matches prose; this one requires a copy verb on executable step text.")

        if let firstCopy = copyLines.first {
            XCTAssertGreaterThan(firstCopy, buildLine,
                "the DLL-bundling step must run AFTER `swift build -c release` (spec §D.17) — " +
                "there is nothing to bundle next to an executable that does not exist yet")
        }
    }

    /// spec §D.19 — the negative control's existing guard counts occurrences of
    /// the checker's name in the job's **raw text**:
    ///
    ///     let toolOccurrences = job.text.lowercased().components(separatedBy: "wldd").count - 1 + ...
    ///     XCTAssertGreaterThanOrEqual(toolOccurrences, 2, ...)
    ///
    /// A single real invocation plus one explanatory comment mentioning `wldd`
    /// reaches 2. So does a comment mentioning it twice, with no invocation at
    /// all. The count must be over executable text.
    func testNegativeControlCheckerInvocationsAreRealStepsNotCommentaryAboutThem() throws {
        let job = try Job.require("windows-build")
        let invocations = job.codeLineIndices(matching: Patterns.checkerTool).count
        XCTAssertGreaterThanOrEqual(invocations, 2,
            "found \(invocations) NON-COMMENT line(s) invoking the dependency checker in windows-build. " +
            "spec §D.19 requires the checker run again after a DLL is deliberately removed (expected to " +
            "fail) and once more after it is restored (expected to pass). The existing occurrence count " +
            "in CUESYNC6WindowsGtkWorkflowTests counts raw substrings, so prose about the checker — or " +
            "the spec rationale quoted in a comment — reaches its threshold of 2 without the checker " +
            "ever running twice.")
    }
}

// MARK: - Attack 2 — the allowlist is where this ticket gets quietly gutted

/// spec §D.18 is unusually direct about the failure it fears: "A permissive
/// allowlist converts this check into exactly the vacuous-green assertion §0.4
/// warns about, and it is the single most likely way this ticket ships something
/// worthless."
///
/// The existing guard requires the strings `kernel32`, `user32` and `ucrtbase`
/// to appear, and rejects a literal `*.dll`. Neither constrains what else the
/// allowlist contains, and the wildcard half does not work at all (see
/// `AdversarialCUESYNC6NegativeControlTests`).
final class AdversarialCUESYNC6AllowlistTests: XCTestCase {

    /// spec §D.18, verbatim: "The Swift runtime DLLs (swiftCore.dll,
    /// Foundation.dll, dispatch.dll, BlocksRuntime.dll, …) are redistributables,
    /// not system DLLs. On the CI runner they resolve via the toolchain's PATH;
    /// on a DJ's machine they will not exist. Do not allowlist them into silence.
    /// Either bundle them alongside the GTK DLLs, or leave them genuinely out of
    /// scope for this ticket and report the gap explicitly in the PR ... the
    /// forbidden third option is a broad allowlist that makes the gap invisible."
    ///
    /// The allowlist route is the path of least resistance: the check goes green
    /// on the runner (where the toolchain is on PATH), the artifact ships without
    /// them, and the DJ gets a missing-DLL dialog before `main` runs. Every
    /// existing §D.18 assertion stays green throughout.
    ///
    /// Contract: the two sanctioned options are distinguishable in the workflow.
    /// "Bundle them" means the DLL name appears on a copy verb. "Report the gap
    /// in the PR" means the name does not appear in the workflow at all. Naming
    /// one anywhere else — an allowlist array, an `-Exclude`, an ignore list — is
    /// the forbidden third option.
    func testSwiftRuntimeRedistributablesAreBundledOrAbsentButNeverAllowlisted() throws {
        let violations = Rules.swiftRuntimeAllowlisted(in: try Job.require("windows-build"))
        let detail: String = violations.joined(separator: "\n")
        let rationale: String = """
            spec §D.18 permits exactly two treatments — bundle it alongside the GTK DLLs, or omit it \
            and report the gap in the PR. Allowlisting it makes the check pass on a runner whose PATH \
            has the toolchain, while the DJ's machine has no swiftCore.dll at all.
            """
        XCTAssertTrue(violations.isEmpty,
            "windows-build names a Swift runtime redistributable outside any copy/bundle step:\n\(detail)\n\(rationale)")
    }

    /// The existing wildcard guard is dead code (proven in the negative controls
    /// below). Its only live half rejects the exact literal `*.dll`; `'*'`, `.*`,
    /// `-Exclude *` and `gtk*` all sail through.
    ///
    /// Contract: a wildcard allowlist entry must be anchored by a meaningful
    /// literal prefix. §D.18 explicitly sanctions `api-ms-win-*` (an 11-char
    /// prefix naming a real OS DLL family), so the rule is a prefix long enough
    /// to identify a family — not the absence of wildcards.
    func testAllowlistWildcardsAreAnchoredByARealPrefixNotABlanketStar() throws {
        let violations = Rules.unanchoredWildcards(in: try Job.require("windows-build"))
        let detail: String = violations.joined(separator: "\n")
        let rationale: String = """
            spec §D.18 requires the system allowlist be "narrow and written down" and forbids padding \
            it until the check passes. `api-ms-win-*` is sanctioned because its prefix names a real OS \
            DLL family; a bare `*`, `*.dll` or `.*` swallows every real miss — including the \
            DLL-planting hole §4 says a vacuous check actively certifies as clean.
            """
        XCTAssertTrue(violations.isEmpty, "windows-build contains an unanchored wildcard:\n\(detail)\n\(rationale)")
    }

    /// spec §D.18: the check "fails the job if any required DLL is unresolved".
    ///
    /// Nothing in the existing suite requires the checker step to have any failure
    /// semantics. `dumpbin /dependents CueSync.exe` prints its findings and exits
    /// 0 — always. So does `wldd CueSync.exe` on a tool whose exit code nobody
    /// inspects. Such a step satisfies the ordering assertion, the tool-name
    /// assertion and the allowlist-mentions assertion, produces a
    /// plausible-looking log, and can never fail the build.
    func testClosureCheckHasFailureSemanticsRatherThanOnlyPrintingItsFindings() throws {
        let job = try Job.require("windows-build")
        guard !job.codeLineIndices(matching: Patterns.checkerTool).isEmpty else {
            XCTFail("windows-build invokes no dependency checker on any non-comment line (spec §D.18)")
            return
        }
        XCTAssertFalse(Rules.hasFailureSemantics(in: job) == false,
            "windows-build invokes a dependency checker but contains no failure semantics — no `exit 1`, " +
            "`Write-Error`, `throw`, or `$LASTEXITCODE` inspection anywhere. spec §D.18 requires the check " +
            "FAIL THE JOB on an unresolved DLL. A checker whose exit code nobody reads is a log line, not " +
            "a gate: it satisfies every existing structural assertion while certifying nothing.")
    }
}

// MARK: - Attack 3 — the cache serves yesterday's build and calls it proof

/// spec §C.13: "A stale cache that hides a broken GTK install is a silently-green
/// build."
final class AdversarialCUESYNC6CacheKeyTests: XCTestCase {

    /// The existing guard asserts only that the key is not byte-for-byte the old
    /// literal:
    ///
    ///     XCTAssertNotEqual(keyLine, "key: windows-build-spm-${{ hashFiles('Package.resolved') }}")
    ///
    /// `key: windows-build-spm-v2-${{ hashFiles('Package.resolved') }}` passes it
    /// and changes nothing that matters: the GTK version is still not an input, so
    /// a changed or broken GTK install still hits a cache saved before it. §A.9
    /// predicts — and the findings doc confirms — `Package.resolved` does not
    /// change for this ticket, so hashing it alone can never invalidate on GTK.
    func testWindowsBuildCacheKeyActuallyHashesTheGtkInstallNotJustADifferentConstant() throws {
        let job = try Job.require("windows-build")
        guard let keyLine = job.code.first(where: { $0.trimmed.hasPrefix("key:") }) else {
            XCTFail("windows-build must still declare a cache `key:` line")
            return
        }
        XCTAssertNotNil(keyLine.range(of: Patterns.gtkCacheInput, options: [.regularExpression, .caseInsensitive]),
            "the windows-build cache key does not reference any GTK input:\n    \(keyLine.trimmed)\n" +
            "spec §C.13 requires the GTK install be an input to the key. Bumping the key to a new constant " +
            "(`-v2-`) satisfies the existing not-equal-to-the-old-literal check while leaving the GTK " +
            "version uncached-against — Package.resolved does not change for this ticket (§A.9), so it " +
            "cannot carry the invalidation. Hash the manifest that pins GTK (e.g. vcpkg.json) or embed " +
            "the pinned version literal.")
    }

    /// The sharper half, and one no existing test looks at: `restore-keys`.
    ///
    /// A `restore-keys:` prefix is a *fallback* — on a key miss, Actions restores
    /// the most recent cache whose key starts with that prefix. The current prefix
    /// is `windows-build-spm-`. Even a perfectly GTK-aware `key:` will, on its
    /// first miss, restore a `.build` saved by a pre-CUESYNC-6 run: one built
    /// against `DefaultBackend`, with no GTK anywhere. That is exactly §C.13's
    /// "stale cache that hides a broken GTK install", arriving through the door
    /// the key was locked to keep shut.
    func testWindowsBuildRestoreKeysCannotFallBackOntoAPreGtkCache() throws {
        let violations = Rules.preGtkRestoreKeys(in: try Job.require("windows-build"))
        let detail: String = violations.joined(separator: "\n")
        let rationale: String = """
            spec §C.13: a stale cache that hides a broken GTK install is a silently-green build. \
            Hardening `key:` alone does not close this; the fallback prefix must be GTK-scoped too.
            """
        XCTAssertTrue(violations.isEmpty,
            "windows-build declares restore-key prefix(es) matching caches saved BEFORE GTK 4 existed — "
            + "including every pre-CUESYNC-6 DefaultBackend build:\n\(detail)\n\(rationale)")
    }
}

// MARK: - Attack 4 — the redistribution channel (spec §4's primary new boundary)

/// spec §4: "These DLLs are not compiled from an audited source pin the way
/// swift-cross-ui is; they are someone else's compiled bytes, shipped inside our
/// artifact, running with the user's full privileges. The .build/release/ upload
/// becomes a redistribution channel."
///
/// `AdversarialSupplyChainTests` already proves every `uses:` action is pinned to
/// a 40-char SHA. It says nothing about what a `run:` step downloads, clones or
/// `pacman -S`es — which is the entire GTK acquisition path, whichever of §0.4's
/// routes wins.
final class AdversarialCUESYNC6GtkSupplyChainTests: XCTestCase {

    /// spec §4: "Mandatory: pin the exact source (release asset URL and its
    /// SHA-256, verified before extraction; or an explicit pacman package
    /// version). `latest` is forbidden, and an unpinned `pacman -S` — which is
    /// pacman's default behaviour, so this must be handled, not assumed away —
    /// means the DLLs shipped to DJs are whatever the mirror served that morning."
    ///
    /// `git clone https://github.com/microsoft/vcpkg` (the findings doc's chosen
    /// route, unpinned) is the same defect wearing vcpkg's clothes, and passes
    /// every test in the suite today.
    func testGtkAcquisitionIsPinnedToAnImmutableSourceNotWhateverTheMirrorServesToday() throws {
        let job = try Job.require("windows-build")
        XCTAssertFalse(job.codeLineIndices(matching: Patterns.gtkAcquisition).isEmpty,
            "windows-build contains no non-comment step that acquires GTK 4 (vcpkg/pacman/gvsbuild/" +
            "download) — spec §C.13 requires one, and §4 requires it be pinned")

        XCTAssertTrue(Rules.hasGtkPinEvidence(in: job),
            "windows-build acquires GTK 4 but no non-`uses:` step pins WHAT it acquires — no commit SHA, " +
            "no `builtin-baseline`, no `--branch <tag>`, no `pacman -S pkg=<version>`, no SHA-256. " +
            "spec §4 makes this mandatory: unpinned, the DLLs redistributed inside the cuesync-windows " +
            "artifact are whatever the mirror served that morning, and \"the runtime we audited\" and " +
            "\"the runtime we ship to DJs\" stop being the same bytes.")
    }

    /// spec §4: "`latest` is forbidden". Not covered by
    /// `AdversarialSupplyChainTests.testNoActionTracksLatestOrADefaultBranch`,
    /// which inspects `uses:` refs — a `releases/latest/download/...` URL or a
    /// `vcpkg install gtk` with no baseline lives in `run:` text.
    func testNoInstallStepTracksAMutableLatestChannel() throws {
        let violations = Rules.mutableLatestChannels(in: try Job.require("windows-build"))
        let detail: String = violations.joined(separator: "\n")
        let rationale: String = """
            spec §4 states plainly: "`latest` is forbidden". These bytes end up inside an artifact a \
            DJ downloads and runs with full privileges.
            """
        XCTAssertTrue(violations.isEmpty, "windows-build tracks a mutable `latest` channel:\n\(detail)\n\(rationale)")
    }

    /// spec §4: "Verify the bundle checksum **before** extraction, not after —
    /// checking a hash after unpacking an archive is checking it after the
    /// untrusted bytes have already touched the filesystem."
    ///
    /// Contingent by design, and this is the one place in this file where that is
    /// honest rather than a dodge: §0.4 chose vcpkg, which builds GTK from source
    /// and downloads no archive to hash, so asserting a download must exist would
    /// be asserting against the findings. But §0.6's checker (`wldd`) IS a
    /// downloaded release asset with — per the findings doc — no published
    /// checksums, so if any archive is fetched, this ordering is mandatory. The
    /// negative control below proves the rule still bites when that day comes.
    func testAnyDownloadedArchiveIsChecksumVerifiedBeforeItIsExtracted() throws {
        let violation = Rules.checksumOrdering(in: try Job.require("windows-build"))
        XCTAssertNil(violation, violation ?? "")
    }
}

// MARK: - Attack 5 — weakening the suite without deleting a test

/// spec §E.24: "Do not weaken, skip, XCTSkip, or delete any existing test."
/// spec §E.25: "the suite's passing count must not decrease, and no test may be
/// removed or weakened."
final class AdversarialCUESYNC6SuiteIntegrityTests: XCTestCase {

    /// The baseline guard counts `\bfunc test[A-Za-z0-9_]*\(` against raw Swift
    /// source. Commenting a test out leaves that substring exactly where it was.
    /// So the cheapest way to make a red §C/§D test go away — select the body,
    /// `⌘/` — defeats the count guard AND the XCTSkip guard simultaneously, and
    /// neither fires. Deleting the test would at least trip the count.
    ///
    /// This test counts only live code, so a commented-out test is a removed test.
    func testCommentedOutTestMethodsDoNotCountTowardTheAuditedBaseline() throws {
        var live = 0
        for file in try SwiftSource.testSourceFiles() {
            live += SwiftSource.liveTestMethodCount(in: try String(contentsOf: file, encoding: .utf8))
        }
        XCTAssertGreaterThanOrEqual(live, 206,
            "only \(live) LIVE test methods remain across Tests/CueSyncCoreTests — below the audited " +
            "CUESYNC-6 baseline of 206 (specs/CUESYNC-6-findings.md §0.5). The existing count guard in " +
            "CUESYNC6WindowsGtkWorkflowTests counts raw text, so commenting a test out keeps its " +
            "`func test...(` substring and holds the count up while the test no longer runs. " +
            "spec §E.25: the passing count must not decrease, and no test may be weakened.")
    }

    /// Proves the live counter discriminates — without this, the test above could
    /// be counting raw substrings too and nobody would know.
    func testLiveTestCounterIgnoresCommentedOutAndStringLiteralTestMethods() {
        let source = Fixtures.swiftSourceWithHiddenTestMethods
        XCTAssertEqual(SwiftSource.liveTestMethodCount(in: source), 2,
            "the live counter must see exactly testReal and testAlsoReal — not the line-commented one, " +
            "the block-commented one, or the one named inside a string literal. If this fires, the " +
            "baseline guard above is measuring the wrong thing.")

        // And the naive counter the existing suite uses is fooled by the same
        // input — the exploit, demonstrated rather than asserted.
        let naive = (try? NSRegularExpression(pattern: #"\bfunc test[A-Za-z0-9_]*\("#)
            .numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))) ?? 0
        XCTAssertGreaterThan(naive, 2,
            "precondition: the raw-substring counter must over-count this fixture — if it does not, " +
            "the exploit this test documents is not reproducible and this file should say so")
    }

    /// CRLF regression (CUESYNC-8, found on the Windows build box): Swift's
    /// grapheme clustering makes "\r\n" one Character that never equals "\n",
    /// so an un-normalized stripper loses every //-comment terminator on a
    /// CRLF checkout and eats each file after its first line comment — the
    /// baseline guard saw 36 of 411 live methods. Counting must be identical
    /// for any checkout line-ending convention.
    func testLiveTestCounterIsLineEndingIndependent() {
        let source = Fixtures.swiftSourceWithHiddenTestMethods
        let crlf = source.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(SwiftSource.liveTestMethodCount(in: crlf),
                       SwiftSource.liveTestMethodCount(in: source),
                       "live-method counting must not depend on checkout line endings")

        // The exact bug shape: live methods AFTER a line comment, CRLF file.
        let afterComment = "// header\r\nfunc testA() {}\r\nfunc testB() {}\r\n"
        XCTAssertEqual(SwiftSource.liveTestMethodCount(in: afterComment), 2,
                       "a // comment in a CRLF file must end at its own line, not eat the file")
    }
}

// MARK: - Negative controls (spec §D.19, applied to this file's own rules)

/// "A check that passes tells you nothing until you have watched it fail for the
/// right reason. ... Without this, 'runs clean' is an unfalsified claim."
///
/// The rules in `Rules` are contingent: against today's §C/§D-less workflow,
/// several of them find nothing and pass. Each one is therefore re-run here
/// against a hostile fixture built to trip it. If a rule is ever loosened into
/// uselessness — the way `job.text.contains(#"allow.*=\s*\*"#)` already was —
/// its control here goes red immediately.
final class AdversarialCUESYNC6NegativeControlTests: XCTestCase {

    /// Documents the dead code this file supersedes, so the finding survives in
    /// the suite rather than only in a PR description.
    /// `String.contains(_: String)` is a LITERAL substring test, not a regex
    /// match, so `job.text.contains(#"allow.*=\s*\*"#)` can only fire on a
    /// workflow containing those exact characters. It never has and never will.
    func testTheExistingWildcardGuardIsLiteralSubstringMatchingAndCannotEverFire() {
        let hostile = #"          $allow = @('kernel32.dll', '*')"#

        XCTAssertFalse(hostile.contains(#"allow.*=\s*\*"#),
            "the existing guard's second operand is a regex written for an API that does literal " +
            "matching — it cannot fire on this hostile allowlist, or on any other")
        XCTAssertFalse(hostile.contains("*.dll"),
            "and the guard's first operand only catches the exact literal `*.dll`, which this " +
            "hostile allowlist does not use — so the whole wildcard defence passes it")

        // The replacement rule does fire on the same input.
        let job = Job(name: "windows-build", raw: [hostile])
        XCTAssertFalse(Rules.unanchoredWildcards(in: job).isEmpty,
            "the replacement wildcard rule must reject a bare `*` allowlist entry")
    }

    /// §D.18's sanctioned `api-ms-win-*` must survive, or the rule is unusable and
    /// will be "fixed" by deleting it — the over-strict failure mode that leads
    /// back to a padded allowlist.
    func testWildcardRuleAcceptsTheSpecSanctionedApiMsWinFamily() {
        let job = Job(name: "windows-build", raw: [#"          $allow = @('kernel32.dll', 'api-ms-win-*', 'ucrtbase.dll')"#])
        XCTAssertTrue(Rules.unanchoredWildcards(in: job).isEmpty,
            "spec §D.18 names `api-ms-win-*` as an acceptable narrow allowlist entry — a rule that " +
            "rejects it is over-strict and would push the implementer back toward padding")
    }

    /// The forbidden third option (§D.18), verbatim as an implementer would write it.
    func testSwiftRuntimeRuleFiresOnAnAllowlistThatSwallowsTheRedistributables() {
        let job = Job(name: "windows-build", from: Fixtures.allowlistSwallowingSwiftRuntime)
        let violations = Rules.swiftRuntimeAllowlisted(in: job)
        XCTAssertFalse(violations.isEmpty,
            "the rule must fire on an allowlist naming swiftCore.dll — spec §D.18's explicitly " +
            "forbidden third option")
    }

    /// ...and the sanctioned option (§D.18: "bundle them alongside the GTK DLLs")
    /// must pass, or the rule punishes the correct fix.
    func testSwiftRuntimeRuleAcceptsBundlingTheRedistributablesInstead() {
        let job = Job(name: "windows-build", from: Fixtures.bundlesSwiftRuntime)
        XCTAssertTrue(Rules.swiftRuntimeAllowlisted(in: job).isEmpty,
            "copying swiftCore.dll into the artifact is one of §D.18's two sanctioned treatments — " +
            "a rule that rejects it would force the implementer toward the allowlist it forbids")
    }

    /// The `-v2-` bypass of the existing cache-key guard, and the `restore-keys`
    /// hole that survives even a correct key.
    func testRestoreKeyRuleFiresOnAPrefixThatMatchesAPreGtkCache() {
        let job = Job(name: "windows-build", from: Fixtures.gtkAwareKeyButStaleRestoreKeys)

        // The key itself is GTK-aware — this fixture is the *sophisticated* attack,
        // not the naive one: it passes the existing guard AND this file's key rule.
        let keyLine = job.code.first(where: { $0.trimmed.hasPrefix("key:") })
        XCTAssertNotNil(keyLine?.range(of: Patterns.gtkCacheInput, options: [.regularExpression, .caseInsensitive]),
            "precondition: this fixture's `key:` is deliberately GTK-aware, so only the restore-keys " +
            "rule can catch it")

        let violations = Rules.preGtkRestoreKeys(in: job)
        XCTAssertFalse(violations.isEmpty,
            "the restore-keys rule must fire on the `windows-build-spm-` fallback prefix — it matches " +
            "caches saved before GTK existed, which is §C.13's silently-green build")
    }

    /// The rule must not fire on a correctly GTK-scoped fallback, or it is
    /// unsatisfiable and will be deleted rather than obeyed.
    func testRestoreKeyRuleAcceptsAGtkScopedFallbackPrefix() {
        let job = Job(name: "windows-build", from: Fixtures.gtkScopedRestoreKeys)
        XCTAssertTrue(Rules.preGtkRestoreKeys(in: job).isEmpty,
            "a fallback prefix that is itself GTK-scoped cannot restore a pre-GTK cache and must pass")
    }

    /// The unpinned-vcpkg attack — the exact shape §0.4's findings doc steers the
    /// implementer toward, minus the pin §4 requires.
    func testGtkPinRuleFiresOnAnUnpinnedVcpkgCloneAndPassesOnAPinnedOne() {
        let unpinned = Job(name: "windows-build", from: Fixtures.unpinnedVcpkgClone)
        XCTAssertFalse(Rules.hasGtkPinEvidence(in: unpinned),
            "`git clone https://github.com/microsoft/vcpkg` with no ref pins nothing — spec §4 " +
            "forbids shipping whatever the mirror served that morning")

        let pinned = Job(name: "windows-build", from: Fixtures.pinnedVcpkgClone)
        XCTAssertTrue(Rules.hasGtkPinEvidence(in: pinned),
            "a clone followed by `git checkout <40-hex SHA>` plus a builtin-baseline is pinned and " +
            "must pass — otherwise the rule is unsatisfiable")
    }

    /// `actions/checkout`'s own pinned SHA must not be able to masquerade as
    /// evidence that GTK is pinned. This is the same class of bug as the raw-grep
    /// vacuity: the right string in the wrong place.
    func testGtkPinRuleIgnoresSHAsThatBelongToPinnedActionsRatherThanToGtk() {
        let job = Job(name: "windows-build", from: Fixtures.pinnedActionButUnpinnedGtk)
        XCTAssertFalse(Rules.hasGtkPinEvidence(in: job),
            "the 40-hex SHA in `uses: actions/checkout@<sha>` pins the action, not GTK — counting it " +
            "as GTK pin evidence would let AdversarialSupplyChainTests' existing work vacuously " +
            "satisfy an assertion it says nothing about")
    }

    /// §4's ordering requirement, in both directions.
    func testChecksumRuleFiresWhenAnArchiveIsExtractedBeforeItIsVerified() {
        let bad = Job(name: "windows-build", from: Fixtures.extractThenVerify)
        XCTAssertNotNil(Rules.checksumOrdering(in: bad),
            "extracting before hashing is spec §4's named defect: \"checking a hash after unpacking an " +
            "archive is checking it after the untrusted bytes have already touched the filesystem\"")

        let none = Job(name: "windows-build", from: Fixtures.downloadWithNoVerifyAtAll)
        XCTAssertNotNil(Rules.checksumOrdering(in: none),
            "downloading and extracting with no verification at all must fire too")

        let good = Job(name: "windows-build", from: Fixtures.verifyThenExtract)
        XCTAssertNil(Rules.checksumOrdering(in: good),
            "verify-then-extract is the sanctioned order and must pass")
    }

    /// A checker that only prints, versus one that gates.
    func testFailureSemanticsRuleFiresOnACheckerThatOnlyPrintsItsFindings() {
        let printsOnly = Job(name: "windows-build", from: Fixtures.checkerThatOnlyPrints)
        XCTAssertFalse(Rules.hasFailureSemantics(in: printsOnly),
            "`dumpbin /dependents CueSync.exe` always exits 0 — a log line, not a gate (spec §D.18)")

        let gates = Job(name: "windows-build", from: Fixtures.checkerThatGates)
        XCTAssertTrue(Rules.hasFailureSemantics(in: gates),
            "a checker whose exit code is inspected and turned into `exit 1` must pass")
    }

    /// `latest`, in the forms an implementer actually reaches for.
    func testMutableLatestRuleFiresOnReleaseLatestDownloadURLs() {
        let job = Job(name: "windows-build", raw: [
            "          Invoke-WebRequest https://github.com/marcoesposito1988/dependency_runner/releases/latest/download/wldd.zip -OutFile wldd.zip"
        ])
        XCTAssertFalse(Rules.mutableLatestChannels(in: job).isEmpty,
            "spec §4: \"`latest` is forbidden\" — a releases/latest/download URL is the canonical form")

        let pinned = Job(name: "windows-build", raw: [
            "          Invoke-WebRequest https://github.com/marcoesposito1988/dependency_runner/releases/download/v1.5.0/wldd.zip -OutFile wldd.zip"
        ])
        XCTAssertTrue(Rules.mutableLatestChannels(in: pinned).isEmpty,
            "a tag-pinned asset URL is what §4 asks for and must pass")
    }
}

// MARK: - Rules
//
// Pure functions over a Job, returning violations rather than asserting, so each
// can be exercised twice: against the real workflow, and against a hostile
// fixture that must trip it (spec §D.19's discipline, turned on this file).

private enum Rules {

    static func swiftRuntimeAllowlisted(in job: Job) -> [String] {
        job.code.enumerated().compactMap { index, line in
            guard let dll = Patterns.swiftRuntimeDLLs.first(where: { line.lowercased().contains($0) }) else { return nil }
            guard line.range(of: Patterns.copyVerb, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            return "    line \(index + 1): `\(dll)` in `\(line.trimmed)`"
        }
    }

    static func unanchoredWildcards(in job: Job) -> [String] {
        job.code.enumerated().flatMap { index, line in
            line.wildcardTokens
                .filter { $0.prefix(while: { $0 != "*" }).count < 4 }
                .map { "    line \(index + 1): wildcard `\($0)` in `\(line.trimmed)`" }
        }
    }

    static func preGtkRestoreKeys(in job: Job) -> [String] {
        job.restoreKeyPrefixes
            .filter { $0.range(of: Patterns.gtkCacheInput, options: [.regularExpression, .caseInsensitive]) == nil }
            .map { "    restore-key prefix `\($0)`" }
    }

    static func mutableLatestChannels(in job: Job) -> [String] {
        job.code.enumerated()
            .filter { $0.element.range(of: Patterns.mutableLatest, options: [.regularExpression, .caseInsensitive]) != nil }
            .map { "    line \($0.offset + 1): `\($0.element.trimmed)`" }
    }

    static func hasFailureSemantics(in job: Job) -> Bool {
        !job.codeLineIndices(matching: Patterns.failureSemantics).isEmpty
    }

    /// `uses:` lines are excluded deliberately: `AdversarialSupplyChainTests`
    /// already pins those, and counting their SHAs here would let
    /// actions/checkout's pin vacuously satisfy an assertion about GTK's pin.
    static func hasGtkPinEvidence(in job: Job) -> Bool {
        job.code
            .filter { !$0.trimmed.hasPrefix("uses:") && !$0.trimmed.hasPrefix("- uses:") }
            .contains { $0.range(of: Patterns.pinMechanism, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Returns a description of the violation, or nil when the job either fetches
    /// no archive or verifies it before extracting.
    static func checksumOrdering(in job: Job) -> String? {
        guard let downloadLine = job.firstCodeLineIndex(matching: Patterns.downloadVerb),
              let extractLine = job.firstCodeLineIndex(matching: Patterns.extractVerb) else { return nil }

        guard let verifyLine = job.firstCodeLineIndex(matching: Patterns.checksumVerify) else {
            return "windows-build downloads an archive (line \(downloadLine + 1)) and extracts it " +
                   "(line \(extractLine + 1)) with no SHA-256 verification anywhere. spec §4 makes the " +
                   "checksum the whole basis of trust for bytes we redistribute; the findings doc (§0.6) " +
                   "notes the checker's release assets publish no checksums, so the SHA-256 must be " +
                   "computed once and committed here."
        }
        guard verifyLine < extractLine else {
            return "windows-build verifies a checksum at line \(verifyLine + 1) but has already extracted " +
                   "the archive at line \(extractLine + 1). spec §4: verify BEFORE extraction — \"checking " +
                   "a hash after unpacking an archive is checking it after the untrusted bytes have " +
                   "already touched the filesystem\"."
        }
        return nil
    }
}

// MARK: - Patterns

private enum Patterns {
    static let gtkMention = #"gtk4|gtk-4|gtk 4|libgtk-4|\bgtk\b"#
    static let copyVerb = #"(Copy-Item|copy\s|cp\s|xcopy|robocopy|Move-Item|install\s+-m)"#
    static let copyVerbWithDll = #"(Copy-Item|copy\s|cp\s|xcopy|robocopy|Move-Item)[^\n]*\.dll"#
    static let checkerTool = #"\bwldd\b|dependency_runner|dumpbin"#
    static let failureSemantics = #"exit\s+1|Write-Error|throw\b|LASTEXITCODE|set\s+-e"#
    static let swiftRuntimeDLLs = ["swiftcore.dll", "foundation.dll", "dispatch.dll", "blocksruntime.dll", "swiftwinsdk.dll"]

    /// A cache key/prefix that genuinely varies with the GTK install.
    static let gtkCacheInput = #"gtk|vcpkg|msys2|gvsbuild"#

    static let gtkAcquisition = #"vcpkg|pacman|gvsbuild|msys2|brew\s+install[^\n]*gtk|choco\s+install[^\n]*gtk"#
    static let pinMechanism = #"[0-9a-f]{40}|builtin-baseline|--branch\s+\S|checkout\s+[0-9a-f]{7,}|checkout\s+v?\d+\.\d+|=\d+[\w.:+-]*|sha256|shasum|version:\s*['"]?\d"#
    static let mutableLatest = #"releases/latest|/latest/download|:latest\b|@latest\b|--latest\b"#

    static let downloadVerb = #"Invoke-WebRequest|curl\s|wget\s|iwr\s|Start-BitsTransfer"#
    static let extractVerb = #"Expand-Archive|unzip\s|7z\s+x|tar\s+-?x"#
    static let checksumVerify = #"Get-FileHash|sha256sum|certutil[^\n]*SHA256|shasum"#
}

// MARK: - Fixtures
//
// Hostile workflow snippets. Each is a realistic implementation an author could
// plausibly ship — the point is that every one of these passes the existing
// CUESYNC6WindowsGtkWorkflowTests.

private enum Fixtures {
    static let proseTodoOnly = """
          windows-build:
            steps:
              # TODO: install gtk4 here, copy the .dll files next to the exe,
              # then run wldd to check the closure. Tracked in a follow-up.
              - name: Build (release)
                run: swift build -c release
          windows-test:
        """

    static let allowlistSwallowingSwiftRuntime = """
          windows-build:
            steps:
              - name: Check DLL closure
                run: |
                  $allow = @('kernel32.dll', 'user32.dll', 'ucrtbase.dll',
                             'swiftCore.dll', 'Foundation.dll', 'dispatch.dll')
                  wldd .build/release/CueSync.exe
        """

    static let bundlesSwiftRuntime = """
          windows-build:
            steps:
              - name: Bundle runtime
                run: |
                  Copy-Item "$env:SDKROOT/usr/bin/swiftCore.dll" .build/release/
                  Copy-Item "$env:SDKROOT/usr/bin/Foundation.dll" .build/release/
        """

    static let gtkAwareKeyButStaleRestoreKeys = """
          windows-build:
            steps:
              - name: Cache SwiftPM build
                with:
                  key: windows-build-spm-vcpkg-${{ hashFiles('vcpkg.json') }}
                  restore-keys: |
                    windows-build-spm-
        """

    static let gtkScopedRestoreKeys = """
          windows-build:
            steps:
              - name: Cache SwiftPM build
                with:
                  key: windows-build-spm-vcpkg-${{ hashFiles('vcpkg.json') }}
                  restore-keys: |
                    windows-build-spm-vcpkg-
        """

    static let unpinnedVcpkgClone = """
          windows-build:
            steps:
              - name: Install GTK 4
                run: |
                  git clone https://github.com/microsoft/vcpkg
                  ./vcpkg/bootstrap-vcpkg.bat
                  ./vcpkg/vcpkg install gtk --triplet x64-windows
        """

    static let pinnedVcpkgClone = """
          windows-build:
            steps:
              - name: Install GTK 4
                run: |
                  git clone https://github.com/microsoft/vcpkg
                  git -C vcpkg checkout 8f54ef5453e7e76ff01e15988bf243e7247c5eb5
                  ./vcpkg/bootstrap-vcpkg.bat
                  ./vcpkg/vcpkg install gtk --triplet x64-windows
        """

    static let pinnedActionButUnpinnedGtk = """
          windows-build:
            steps:
              - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
              - name: Install GTK 4
                run: pacman -S --noconfirm mingw-w64-ucrt-x86_64-gtk4
        """

    static let extractThenVerify = """
          windows-build:
            steps:
              - name: Install checker
                run: |
                  Invoke-WebRequest $url -OutFile wldd.zip
                  Expand-Archive wldd.zip -DestinationPath tools
                  if ((Get-FileHash wldd.zip -Algorithm SHA256).Hash -ne $expected) { exit 1 }
        """

    static let downloadWithNoVerifyAtAll = """
          windows-build:
            steps:
              - name: Install checker
                run: |
                  Invoke-WebRequest $url -OutFile wldd.zip
                  Expand-Archive wldd.zip -DestinationPath tools
        """

    static let verifyThenExtract = """
          windows-build:
            steps:
              - name: Install checker
                run: |
                  Invoke-WebRequest $url -OutFile wldd.zip
                  if ((Get-FileHash wldd.zip -Algorithm SHA256).Hash -ne $expected) { exit 1 }
                  Expand-Archive wldd.zip -DestinationPath tools
        """

    static let checkerThatOnlyPrints = """
          windows-build:
            steps:
              - name: Check DLL closure
                run: dumpbin /dependents .build/release/CueSync.exe
        """

    static let checkerThatGates = """
          windows-build:
            steps:
              - name: Check DLL closure
                run: |
                  wldd .build/release/CueSync.exe
                  if ($LASTEXITCODE -ne 0) { exit 1 }
        """

    /// Deliberately assembled from fragments rather than written as one literal:
    /// this file's own live-test counter walks every .swift file in the directory
    /// including this one, and a literal `func testX(` inside a multi-line string
    /// here would be counted or not depending on the very logic under test.
    static let swiftSourceWithHiddenTestMethods = [
        "final class Example: XCTestCase {",
        "    func " + "testReal() {}",
        "    // func " + "testCommentedOut() {}",
        "    /* func " + "testBlockCommented() {} */",
        "    func " + "testAlsoReal() {",
        "        let pattern = \"func " + "testInsideAStringLiteral(\"",
        "        _ = pattern",
        "    }",
        "}",
    ].joined(separator: "\n")
}

// MARK: - Helpers
//
// Deliberately self-contained rather than shared with CUESYNC6WindowsGtkWorkflowTests:
// that file's helpers are `private`, and a red-team check that imported the
// helpers of the suite it audits would inherit the very blind spot it exists to
// cover (its JobBlock has no notion of a comment).

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }

    /// A step label line — `name: Install GTK 4` — carries no execution.
    var isBareNameLabel: Bool {
        let t = trimmed
        return t.hasPrefix("name:") || t.hasPrefix("- name:")
    }

    /// Whitespace/quote-delimited tokens containing a `*`, with surrounding
    /// quotes and list punctuation stripped, so `'*.dll',` yields `*.dll`.
    var wildcardTokens: [String] {
        components(separatedBy: CharacterSet(charactersIn: " \t,()[]{}"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"@;")) }
            .filter { $0.contains("*") }
    }
}

/// One top-level GitHub Actions job, in two parallel views over the SAME line
/// indices: `raw` (verbatim) and `code` (comment text blanked). Keeping the
/// indices aligned is what lets an ordering assertion made on `code` still be
/// reported against a real line number in the file.
private struct Job {
    let name: String
    let raw: [String]
    let code: [String]

    init(name: String, raw: [String]) {
        self.name = name
        self.raw = raw
        self.code = raw.map(Yaml.blankingComments)
    }

    /// Slices `<name>:` .. next 2-space-indented key out of a full line array.
    init(name: String, from source: String) {
        self.init(name: name, from: source.components(separatedBy: "\n"))
    }

    init(name: String, from allLines: [String]) {
        guard let start = allLines.firstIndex(where: { $0 == "  \(name):" }) else {
            self.init(name: name, raw: [])
            return
        }
        var end = allLines.count
        for i in (start + 1)..<allLines.count
        where allLines[i].range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil {
            end = i
            break
        }
        self.init(name: name, raw: Array(allLines[start..<end]))
    }

    static func require(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Job {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/swift-windows.yml")
        let normalized = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        let job = Job(name: name, from: normalized)
        if job.raw.isEmpty {
            XCTFail("could not locate the top-level `\(name):` job in .github/workflows/swift-windows.yml",
                    file: file, line: line)
        }
        return job
    }

    func firstRawLineIndex(matching pattern: String) -> Int? {
        raw.firstIndex { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    func firstCodeLineIndex(matching pattern: String) -> Int? {
        code.firstIndex { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    func codeLineIndices(matching pattern: String) -> [Int] {
        code.enumerated()
            .filter { $0.element.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
            .map(\.offset)
    }

    /// The restore-key prefixes themselves — NOT the `restore-keys:` header, which
    /// carries no prefix and would be a false positive. Handles both the inline
    /// form (`restore-keys: foo-`) and the block form (`restore-keys: |` followed
    /// by more-indented prefix lines), since the prefixes that matter live on the
    /// lines *after* the key in the workflow as written.
    var restoreKeyPrefixes: [String] {
        var prefixes: [String] = []
        var i = 0
        while i < code.count {
            let line = code[i]
            guard line.trimmed.hasPrefix("restore-keys:") else { i += 1; continue }

            let inline = String(line.trimmed.dropFirst("restore-keys:".count)).trimmed
            if !inline.isEmpty && inline != "|" && inline != ">" && inline != "|-" {
                prefixes.append(inline)
                i += 1
                continue
            }
            let headerIndent = line.prefix(while: \.isWhitespace).count
            var j = i + 1
            while j < code.count {
                let candidate = code[j]
                if candidate.trimmed.isEmpty { j += 1; continue }
                guard candidate.prefix(while: \.isWhitespace).count > headerIndent else { break }
                prefixes.append(candidate.trimmed)
                j += 1
            }
            i = j
        }
        return prefixes
    }
}

private enum Yaml {
    /// Blanks YAML/PowerShell comment text, preserving the code prefix so line
    /// numbering and ordering survive. A `#` starts a comment only when it is
    /// unquoted AND at line start or preceded by whitespace — `foo#bar` is a
    /// token, `"a #1"` is data, and `run: swift build # notes` is code + comment.
    static func blankingComments(_ line: String) -> String {
        var out = ""
        var inSingle = false
        var inDouble = false
        var previous: Character?
        for ch in line {
            if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            } else if ch == "#" && !inSingle && !inDouble && (previous == nil || previous!.isWhitespace) {
                break
            }
            out.append(ch)
            previous = ch
        }
        return out
    }
}

private enum SwiftSource {
    static func testSourceFiles() throws -> [URL] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    /// Counts `func test…(` in live code only: line comments, block comments and
    /// string literals (single-line, multi-line and raw) are stripped first.
    static func liveTestMethodCount(in source: String) -> Int {
        // Normalize line endings FIRST: Swift grapheme clustering makes "\r\n"
        // a SINGLE Character that never equals "\n", so on a CRLF checkout
        // (Git-for-Windows core.autocrlf=true) the stripper's skip(until: "\n")
        // for a // comment loses its terminator and swallows the rest of the
        // file — 36 of 411 live methods counted on the CUESYNC-8 build box.
        // Counting must not depend on checkout bytes.
        let live = strippingCommentsAndStringLiterals(
            source.replacingOccurrences(of: "\r\n", with: "\n"))
        return (try? NSRegularExpression(pattern: #"\bfunc\s+test[A-Za-z0-9_]*\("#)
            .numberOfMatches(in: live, range: NSRange(live.startIndex..., in: live))) ?? 0
    }

    /// Single pass, tracking `//`, `/* */` (nested, as Swift allows), `"…"`,
    /// `"""…"""` and `#"…"#`. Newlines inside stripped regions are preserved so a
    /// caller could still map offsets back to lines.
    private static func strippingCommentsAndStringLiterals(_ source: String) -> String {
        let chars = Array(source)
        var out = ""
        var blockDepth = 0
        var i = 0

        func matches(_ literal: String, at index: Int) -> Bool {
            let end = index + literal.count
            guard end <= chars.count else { return false }
            return String(chars[index..<end]) == literal
        }
        /// Advances past a delimited region, keeping newlines for line alignment.
        func skip(until terminator: String, from index: Int) -> Int {
            var j = index
            while j < chars.count && !matches(terminator, at: j) {
                if chars[j] == "\n" { out.append("\n") }
                j += 1
            }
            return min(j + terminator.count, chars.count)
        }

        while i < chars.count {
            let ch = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil

            if blockDepth > 0 {
                if ch == "/" && next == "*" { blockDepth += 1; i += 2; continue }
                if ch == "*" && next == "/" { blockDepth -= 1; i += 2; continue }
                if ch == "\n" { out.append(ch) }
                i += 1
                continue
            }
            if ch == "/" && next == "/" { i = skip(until: "\n", from: i); out.append("\n"); continue }
            if ch == "/" && next == "*" { blockDepth = 1; i += 2; continue }
            if matches("#\"\"\"", at: i) { i = skip(until: "\"\"\"#", from: i + 4); continue }
            if matches("\"\"\"", at: i) { i = skip(until: "\"\"\"", from: i + 3); continue }
            if matches("#\"", at: i) { i = skip(until: "\"#", from: i + 2); continue }
            if ch == "\"" {
                i += 1
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            out.append(ch)
            i += 1
        }
        return out
    }
}
