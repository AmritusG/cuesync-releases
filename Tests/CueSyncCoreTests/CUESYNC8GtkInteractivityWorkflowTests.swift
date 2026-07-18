import Foundation
import XCTest

// =============================================================================
// CUESYNC-8 §3/§6 compliance — the GtkBackend gesture/interactivity patch: its
// presence, placement, and idempotency across all three GtkBackend-compiling CI
// legs (macos, windows-build, windows-test), and the checked-in `.patch` file
// itself.
//
// Same style and rationale as CUESYNC6WindowsGtkWorkflowTests: `swift test` is
// deterministic and network-free, so it cannot itself spin up a GitHub Actions
// run to prove the patched controls actually click on a real GTE machine — what
// it CAN verify is that the workflow declares the patch step the spec requires,
// in the order the spec requires, without the vacuous-green shapes earlier
// findings docs warn about. The small YAML-scoping helpers below intentionally
// duplicate (rather than import) CUESYNC6WindowsGtkWorkflowTests' equivalents —
// mirrors the existing repo convention (AdversarialSupplyChainTests'
// WorkflowParser, and CUESYNC6WindowsGtkWorkflowTests' own JobBlock/JobBlocks)
// of keeping each compliance-test file's YAML-parsing helpers self-contained
// rather than sharing `private` (file-scoped) types across files.
// =============================================================================

private let auditedRevision = "a6d206370812e3b9edba259d167e848892c5013d"
private let patchRelativePath = "patches/swift-cross-ui-0.8.0-gtk-interactivity.patch"

final class CUESYNC8GtkGesturePatchStepPlacementTests: XCTestCase {

    /// spec CUESYNC-8 §3: the gesture patch step must exist on all three legs
    /// that compile GtkBackend (macos, windows-build, windows-test), named so a
    /// reader scanning CI logs can find it.
    func testGesturePatchStepExistsOnAllThreeGtkBackendCompilingLegs() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks8.require(jobName)
            XCTAssertNotNil(
                job.firstLineIndex(matching: #"name:\s*Patch swift-cross-ui GTK interactivity"#),
                "\(jobName) must declare a 'Patch swift-cross-ui GTK interactivity' step (spec CUESYNC-8 §3)")
        }
    }

    /// spec CUESYNC-8 §3: "Apply it ... after swift package resolve / the
    /// swift-java symlink repair and before swift build / swift test." The two
    /// Windows jobs have an explicit `Resolve Swift package dependencies` step
    /// to order against; the macos job resolves on demand inside the patch step
    /// itself (no separate resolve step exists there), so it is checked instead
    /// against the build invocation it must precede.
    func testGesturePatchStepRunsAfterResolveOnBothWindowsLegs() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks8.require(jobName)
            guard let resolveLine = job.firstLineIndex(matching: #"run:\s*swift package resolve"#) else {
                XCTFail("\(jobName) must still invoke `swift package resolve`")
                continue
            }
            guard let patchLine = job.firstLineIndex(matching: #"name:\s*Patch swift-cross-ui GTK interactivity"#) else {
                XCTFail("\(jobName) has no gesture-patch step to order against resolve")
                continue
            }
            XCTAssertGreaterThan(patchLine, resolveLine,
                "\(jobName)'s gesture-patch step must run AFTER `swift package resolve` — the checkout " +
                "it patches does not exist before that")
        }
    }

    /// spec CUESYNC-8 §3: the patch must land before `swift build`/`swift test`
    /// actually compiles GtkBackend, on every leg.
    func testGesturePatchStepRunsBeforeBuildOrTestOnEveryLeg() throws {
        let expectations: [(job: String, pattern: String)] = [
            ("macos", #"run:\s*swift build -c release"#),
            ("windows-build", #"run:\s*swift build -c release"#),
            ("windows-test", #"swift test -c release"#),
        ]
        for (jobName, invocationPattern) in expectations {
            let job = try JobBlocks8.require(jobName)
            guard let patchLine = job.firstLineIndex(matching: #"name:\s*Patch swift-cross-ui GTK interactivity"#) else {
                XCTFail("\(jobName) has no gesture-patch step to order against build/test")
                continue
            }
            guard let invocationLine = job.firstLineIndex(matching: invocationPattern) else {
                XCTFail("\(jobName) must still invoke the expected build/test command")
                continue
            }
            XCTAssertLessThan(patchLine, invocationLine,
                "\(jobName)'s gesture-patch step must run BEFORE the build/test step that actually " +
                "compiles GtkBackend (spec CUESYNC-8 §3)")
        }
    }
}

final class CUESYNC8GtkGesturePatchIdempotencyAndPinTests: XCTestCase {

    /// spec CUESYNC-8 §3: "idempotent (guard with git apply --reverse --check
    /// so a second run is a no-op)."
    func testGesturePatchStepIsGuardedByReverseApplyCheckOnEveryLeg() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks8.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui GTK interactivity"#)
            XCTAssertTrue(block.contains("git apply --reverse --check"),
                "\(jobName)'s gesture-patch step must guard re-application with " +
                "`git apply --reverse --check` (spec CUESYNC-8 §3) so a second run is a no-op")
        }
    }

    /// spec CUESYNC-8 §3: "clear the read-only flag first on Windows (dependency
    /// sources check out read-only)." Windows-only requirement; the macos step
    /// needs no such clearing (its runner does not check dependency sources out
    /// read-only), so this deliberately only covers the two Windows legs.
    func testGesturePatchStepClearsWindowsReadOnlyFlagOnBothWindowsLegs() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks8.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui GTK interactivity"#)
            XCTAssertTrue(block.contains("IsReadOnly"),
                "\(jobName)'s gesture-patch step must clear the Windows read-only flag " +
                "(Set-ItemProperty ... -Name IsReadOnly -Value $false) before patching, same rationale " +
                "as the existing gulong/gsize patch step immediately above it")
        }
    }

    /// spec CUESYNC-8 §3: "pinned to the v0.8.0 tag in a comment naming the
    /// audited commit."
    func testGesturePatchStepNamesTheAuditedV080CommitOnEveryLeg() throws {
        for jobName in ["macos", "windows-build", "windows-test"] {
            let job = try JobBlocks8.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui GTK interactivity"#, includingPrecedingComments: true)
            XCTAssertTrue(block.contains(auditedRevision),
                "\(jobName)'s gesture-patch step (or its immediately preceding comment) must name the " +
                "audited v0.8.0 commit \(auditedRevision) (spec CUESYNC-8 §3)")
        }
    }

    /// spec CUESYNC-8 §3: the pin stays exact: "0.8.0"; Package.resolved is
    /// untouched by this ticket. Re-asserted here (CUESYNC6ManifestPinLockTests
    /// already covers the general shape) so this file stands on its own as a
    /// record of CUESYNC-8's acceptance criteria.
    func testSwiftCrossUIPinIsUnchangedByThisTicket() throws {
        let manifest = try String(contentsOf: RepoPaths8.packageSwift, encoding: .utf8)
        XCTAssertTrue(manifest.contains(#"exact: "0.8.0""#),
            "Package.swift must keep swift-cross-ui pinned to exact: \"0.8.0\"")

        let resolvedData = try Data(contentsOf: RepoPaths8.packageResolved)
        let json = try JSONSerialization.jsonObject(with: resolvedData) as? [String: Any]
        let pins = (json?["pins"] as? [[String: Any]])
            ?? ((json?["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
        for pin in pins {
            let identity = ((pin["identity"] as? String) ?? (pin["package"] as? String) ?? "").lowercased()
            guard identity == "swift-cross-ui" else { continue }
            let revision = (pin["state"] as? [String: Any])?["revision"] as? String
            XCTAssertEqual(revision, auditedRevision,
                "Package.resolved's swift-cross-ui pin must stay exactly the audited revision")
            return
        }
        XCTFail("Package.resolved contains no swift-cross-ui pin at all")
    }
}

final class CUESYNC8PatchFileTests: XCTestCase {

    /// spec CUESYNC-8 §3: "Author a checked-in patch under patches/ ... whose
    /// content depends on step 2."
    func testGesturePatchFileExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: RepoPaths8.patch.path),
            "\(patchRelativePath) must exist — spec CUESYNC-8 §3 requires the fix be a checked-in, " +
            "reviewable patch, not an in-place dependency edit")
    }

    /// spec CUESYNC-8 §3/step 2: the patch must target the exact GtkBackend/Gtk
    /// files named in the audit (specs/CUESYNC-8-findings.md §2.3) — the `Shape`
    /// widget factory and the `Widget` base class it needs a new property on.
    func testGesturePatchTargetsTheAuditedGtkBackendAndGtkFiles() throws {
        let patch = try String(contentsOf: RepoPaths8.patch, encoding: .utf8)
        XCTAssertTrue(patch.contains("Sources/Gtk/Widgets/Widget.swift"),
            "the patch must touch Sources/Gtk/Widgets/Widget.swift (adds the can-target property)")
        XCTAssertTrue(patch.contains("Sources/GtkBackend/GtkBackend.swift"),
            "the patch must touch Sources/GtkBackend/GtkBackend.swift (createPathWidget, the audited " +
            "root cause per specs/CUESYNC-8-findings.md §2.3)")
    }

    /// spec CUESYNC-8 §3 (H2 path): "make a decorative overlay/background child
    /// that carries no interactive handler be created with can-target = false."
    /// This is the structural guard for the H2 fix itself: the patch must
    /// actually introduce GTK's can-target hit-test-transparency mechanism
    /// (confirmed absent from the checkout entirely — findings §2.2 — before
    /// this patch) and apply it to the `createPathWidget()` factory that backs
    /// every decorative `Shape` (findings §2.3).
    func testGesturePatchIntroducesCanTargetHitTestTransparencyOnPathWidgets() throws {
        let patch = try String(contentsOf: RepoPaths8.patch, encoding: .utf8)
        XCTAssertTrue(patch.contains(#""can-target""#),
            "the patch must add a `can-target` GObject property wrapper (GTK's `.allowsHitTesting(false)` " +
            "analogue) — findings §2.2 confirms this property is never used anywhere in the pinned checkout")
        XCTAssertTrue(patch.contains("canTarget = false"),
            "the patch must set canTarget = false on the widget createPathWidget() returns — every " +
            "`Shape` in CueSync's UI/ is decorative (findings §2.3), so excluding Shapes from GTK's hit-test " +
            "picking is what lets a click fall through to the sibling that actually owns the gesture")
        XCTAssertTrue(patch.contains("createPathWidget"),
            "the can-target fix must be anchored at createPathWidget() — the single factory every Shape " +
            "(RoundedRectangle/Rectangle/Circle stroke and fill) funnels through")
    }

    /// spec CUESYNC-8 §3: "never an unpinned sed/-replace against a moving
    /// target" — the patch is a real unified diff `git apply` consumes, not a
    /// text-substitution script. A cheap structural proxy: it must carry
    /// `diff --git` hunks, not a `-replace`/`sed` invocation.
    func testGesturePatchFileIsARealUnifiedDiffNotATextSubstitutionScript() throws {
        let patch = try String(contentsOf: RepoPaths8.patch, encoding: .utf8)
        XCTAssertTrue(patch.contains("diff --git a/Sources/Gtk/Widgets/Widget.swift b/Sources/Gtk/Widgets/Widget.swift"),
            "expected a real `diff --git` unified-diff header for Widget.swift")
        XCTAssertTrue(patch.contains("diff --git a/Sources/GtkBackend/GtkBackend.swift b/Sources/GtkBackend/GtkBackend.swift"),
            "expected a real `diff --git` unified-diff header for GtkBackend.swift")
        XCTAssertFalse(patch.contains("-replace") || patch.contains("sed -i") || patch.contains("sed 's"),
            "the checked-in patch must be a real diff, not a -replace/sed text-substitution script " +
            "(spec CUESYNC-8 §4: \"never an unpinned sed/-replace against a moving target\")")
    }
}

final class CUESYNC8NoDecorativeShapeEverBecomesInteractiveTests: XCTestCase {

    /// The can-target = false fix (testGesturePatchIntroducesCanTargetHitTest...
    /// above) is only safe because no `Shape` in this app is ever itself a tap
    /// target — findings §2.3 confirms this by grep at audit time. This locks
    /// that invariant in as a regression guard: if a future change attaches
    /// `.onTapGesture`/`.onHover` directly to a `RoundedRectangle`/`Rectangle`/
    /// `Circle`, the patch would silently make that specific control
    /// unclickable again, the same failure mode this ticket fixes.
    func testNoShapeUnderUIHasATapOrHoverGestureAttachedDirectly() throws {
        let dir = RepoPaths8.root.appendingPathComponent("CueSync/CueSync/UI")
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate CueSync/CueSync/UI")
            return
        }
        let shapeGestureLine = try NSRegularExpression(
            pattern: #"(RoundedRectangle|Rectangle|Circle|Ellipse|Capsule)\([^)]*\)\s*\n?\s*\.(onTapGesture|onHover)"#)
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let src = try String(contentsOf: file, encoding: .utf8)
            checked += 1
            let matches = shapeGestureLine.numberOfMatches(in: src, range: NSRange(src.startIndex..., in: src))
            XCTAssertEqual(matches, 0,
                "\(file.lastPathComponent) attaches .onTapGesture/.onHover directly to a Shape — the " +
                "CUESYNC-8 GtkBackend patch sets can-target = false on every Shape-backed widget " +
                "(they are decorative-only everywhere today, findings §2.3), so a Shape with its own " +
                "gesture would now silently never receive it")
        }
        XCTAssertGreaterThan(checked, 0, "expected to scan at least one file under CueSync/CueSync/UI")
    }
}

final class CUESYNC8NoGtkFixedOrAbsolutePositioningIntroducedTests: XCTestCase {

    /// spec CUESYNC-8 §3 acceptance: "no GtkFixed/absolute-position API is
    /// introduced anywhere." `Gtk.Fixed` is pre-existing framework internals
    /// (findings §2.2/§2.3) this ticket reads but never adds a new usage of —
    /// neither the patch nor CueSync's own UI/ app code may reference it.
    func testNeitherThePatchNorAppCodeReferencesGtkFixed() throws {
        let patch = try String(contentsOf: RepoPaths8.patch, encoding: .utf8)
        XCTAssertFalse(patch.contains("Fixed("),
            "the gesture-interactivity patch must not introduce a new Gtk.Fixed/absolute-positioning " +
            "usage (spec CUESYNC-8 §3 acceptance criteria)")

        let dir = RepoPaths8.root.appendingPathComponent("CueSync/CueSync/UI")
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("could not enumerate CueSync/CueSync/UI")
            return
        }
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let src = try String(contentsOf: file, encoding: .utf8)
            checked += 1
            // Comment lines legitimately document *why* GtkFixed/absolute positioning
            // was rejected (e.g. EnvelopeCanvasView.swift, ContentView.swift) — only
            // actual code usage must fail, same convention as the workflow's own
            // AppKit/NS-prefixed-symbol grep guard.
            let codeLines = src.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for line in codeLines {
                XCTAssertFalse(line.contains("GtkFixed"),
                    "\(file.lastPathComponent) references GtkFixed outside a comment — app code must " +
                    "stay on SwiftCrossUI's declarative layout modifiers: \(line)")
            }
        }
        XCTAssertGreaterThan(checked, 0, "expected to scan at least one file under CueSync/CueSync/UI")
    }
}

final class CUESYNC8AgentsLessonFileTests: XCTestCase {

    /// spec CUESYNC-8 §7/§3 acceptance: "agents/uiux.md exists and states the
    /// hit-test/interactivity lesson with the concrete CueSync instance."
    func testAgentsUiuxLessonFileExistsAndStatesTheGeneralizedRuleAndTheConcreteInstance() throws {
        let path = RepoPaths8.root.appendingPathComponent("agents/uiux.md")
        guard FileManager.default.fileExists(atPath: path.path) else {
            XCTFail("agents/uiux.md must exist (spec CUESYNC-8 §7)")
            return
        }
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(text.lowercased().contains("can-target") || text.lowercased().contains("cantarget"),
            "agents/uiux.md must state the generalized can-target/hit-test-transparency rule (spec §7)")
        XCTAssertTrue(text.contains("CueSync"),
            "agents/uiux.md must ground the generalized rule in the concrete CueSync instance (spec §7)")
    }
}

final class CUESYNC8GesturePatchHunkPlacementTests: XCTestCase {

    /// spec CUESYNC-8 §3/findings §2.2/§2.3: the fix "mirrors the existing `sensitive`
    /// property at line 135." A test that only checks the patch mentions the right
    /// FILE (testGesturePatchTargetsTheAuditedGtkBackendAndGtkFiles, above) would still
    /// pass a patch that adds `canTarget` somewhere unrelated in that same large file —
    /// this pins the hunk's own context line so the property is proven adjacent to the
    /// established `sensitive` property, not just present somewhere in Widget.swift.
    func testGesturePatchAddsCanTargetImmediatelyAfterTheExistingSensitiveProperty() throws {
        let patch = try String(contentsOf: RepoPaths8.patch, encoding: .utf8)
        XCTAssertTrue(
            patch.contains(#"@GObjectProperty(named: "sensitive") public var sensitive: Bool"#),
            "the patch's Widget.swift hunk must retain the existing `sensitive` property as " +
            "context — without it, there's no proof of *where* canTarget lands")
        guard let sensitiveRange = patch.range(of: #"@GObjectProperty(named: "sensitive") public var sensitive: Bool"#),
              let canTargetRange = patch.range(of: #"@GObjectProperty(named: "can-target") public var canTarget: Bool"#)
        else {
            XCTFail("expected both the sensitive and can-target property declarations in the patch")
            return
        }
        XCTAssertTrue(sensitiveRange.upperBound < canTargetRange.lowerBound,
            "canTarget must be declared AFTER sensitive in the same hunk (mirroring it, per findings §2.2) — " +
            "not merely present anywhere in the file")
        // "Immediately after" is checked structurally, not by a character-count guess (a
        // loose count threshold is exactly the kind of fudge-able assertion that would
        // still pass with another unrelated @GObjectProperty inserted between them): no
        // OTHER @GObjectProperty declaration may appear between sensitive and canTarget.
        let between = patch[sensitiveRange.upperBound..<canTargetRange.lowerBound]
        XCTAssertFalse(between.contains("@GObjectProperty(named:"),
            "canTarget must be declared immediately after sensitive with no other @GObjectProperty " +
            "declaration between them — findings §2.2 says the fix 'mirrors the existing sensitive " +
            "property', not 'appears somewhere later in the same file'")
    }
}

final class CUESYNC8DevScriptMirrorsCIPatchStepTests: XCTestCase {

    /// spec CUESYNC-8 §3: "Add scripts/patch-swift-cross-ui.sh (invoked by the dev /
    /// ci-local loop) applying the same patch locally so the build agent can iterate
    /// without GitHub CI." This is a named deliverable of its own, not just a detail of
    /// the CI workflow step — it must exist and actually be a shell script.
    func testDevPatchScriptExistsAndIsAShellScript() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: RepoPaths8.devScript.path),
            "scripts/patch-swift-cross-ui.sh must exist (spec CUESYNC-8 §3)")
        let text = try String(contentsOf: RepoPaths8.devScript, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("#!/usr/bin/env bash") || text.hasPrefix("#!/bin/bash") || text.hasPrefix("#!/bin/sh"),
            "scripts/patch-swift-cross-ui.sh must start with a shell shebang")
    }

    /// spec CUESYNC-8 §3: "applying the SAME patch locally" — must reference the one
    /// checked-in `.patch` file, never a second, divergent copy, in code that actually
    /// runs (not merely described in a comment).
    func testDevPatchScriptReferencesTheCheckedInPatchFile() throws {
        XCTAssertTrue(try codeOnlyDevScript().contains(patchRelativePath),
            "scripts/patch-swift-cross-ui.sh must apply patches/swift-cross-ui-0.8.0-gtk-interactivity.patch " +
            "in executable code — the same file the CI workflow step applies, not a separate copy, and not " +
            "just named in a header comment")
    }

    /// spec CUESYNC-8 §3's idempotency requirement ("git apply --reverse --check so a
    /// second run is a no-op") is stated once for "the established workflow-patch
    /// mechanism" as a whole; the dev script is that same mechanism run locally, so it
    /// must honor it too — and must actually apply the patch, not merely check it.
    func testDevPatchScriptIsIdempotentAndActuallyAppliesThePatch() throws {
        let codeOnly = try codeOnlyDevScript()
        XCTAssertTrue(codeOnly.contains("git apply --reverse --check"),
            "scripts/patch-swift-cross-ui.sh must guard re-application with `git apply --reverse --check` " +
            "in executable code (not just a comment) — the same idempotency mechanism as the CI workflow " +
            "step (spec CUESYNC-8 §3)")
        // Strip the guard-check invocation itself so this can't be satisfied by that
        // same line alone — a real, separate `git apply "$PATCH"` application call must
        // also exist for the script to do anything on a fresh, unpatched checkout.
        let withoutGuardCheck = codeOnly.replacingOccurrences(of: "git apply --reverse --check", with: "")
        XCTAssertTrue(withoutGuardCheck.contains("git apply"),
            "scripts/patch-swift-cross-ui.sh must contain a plain `git apply` call in executable code, " +
            "distinct from the `--reverse --check` guard and from any comment — otherwise the script only " +
            "ever checks and never patches")
    }

    /// Shell-script quality/behavior guard: the script must fail fast rather than
    /// silently continuing past a broken resolve/chmod/apply step, matching the
    /// convention every other script in scripts/ follows.
    func testDevPatchScriptFailsFastOnAnyError() throws {
        let codeOnly = try codeOnlyDevScript()
        XCTAssertTrue(codeOnly.contains("set -euo pipefail") || codeOnly.contains("set -eu") || codeOnly.contains("set -e"),
            "scripts/patch-swift-cross-ui.sh must set fail-fast shell options (set -euo pipefail) in " +
            "executable code, not merely describe doing so in a comment")
    }

    /// Strips full-line `#` comments from the dev script — the script's own header
    /// prose mentions "the `git apply` step" and other implementation details in
    /// comments, which would otherwise satisfy a raw substring search on their own (the
    /// exact "comment vacuity" trap `AdversarialCUESYNC6CommentVacuityTests` documents
    /// for the YAML workflow tests; a shell script needs the same treatment). Only
    /// executable lines should count towards any of the assertions in this class.
    private func codeOnlyDevScript() throws -> String {
        let text = try String(contentsOf: RepoPaths8.devScript, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }
}

final class CUESYNC8WindowsReadOnlyClearPathsMatchThePatchFilePathsTests: XCTestCase {

    /// Platform-quirk regression guard: the two Windows legs clear the read-only flag
    /// using backslash-separated PowerShell paths
    /// (`.build\checkouts\swift-cross-ui\Sources\Gtk\Widgets\Widget.swift`), while the
    /// checked-in patch's unified-diff headers always use forward slashes
    /// (`git apply` requires this — see testGesturePatchFileIsARealUnifiedDiffNotATextSubstitutionScript).
    /// A copy-paste typo in either path would silently clear the read-only flag on the
    /// WRONG file, so `git apply` fails downstream with a confusing "file is read-only"
    /// error instead of the real problem being obvious. This normalizes both path
    /// styles and asserts they name the exact same two files.
    func testEachWindowsLegClearsReadOnlyOnExactlyThePatchedFiles() throws {
        let patch = try String(contentsOf: RepoPaths8.patch, encoding: .utf8)
        let patchedRelativePaths = Set(
            try patchTargetPaths(from: patch).map { $0.replacingOccurrences(of: "\\", with: "/") }
        )
        XCTAssertEqual(patchedRelativePaths, ["Sources/Gtk/Widgets/Widget.swift", "Sources/GtkBackend/GtkBackend.swift"],
            "expected exactly the two audited files as the patch's diff targets (findings §2.3/§2.4)")

        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks8.require(jobName)
            let block = try job.stepBlock(named: #"Patch swift-cross-ui GTK interactivity"#)
            let assignedPaths = try windowsVariableAssignedPaths(in: block)
            XCTAssertFalse(assignedPaths.isEmpty,
                "\(jobName)'s gesture-patch step must assign at least one PowerShell path variable " +
                "for the files whose read-only flag it clears")
            for assigned in assignedPaths {
                let normalized = assigned
                    .replacingOccurrences(of: "\\", with: "/")
                    .replacingOccurrences(of: ".build/checkouts/swift-cross-ui/", with: "")
                XCTAssertTrue(patchedRelativePaths.contains(normalized),
                    "\(jobName) clears the read-only flag on '\(assigned)' (normalized: '\(normalized)'), which " +
                    "is not one of the files the patch actually targets \(patchedRelativePaths) — a path typo " +
                    "here means the real target stays read-only and `git apply` fails downstream")
            }
        }
    }

    /// Extracts the `b/<path>` side of every `diff --git a/<path> b/<path>` header.
    private func patchTargetPaths(from patch: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"diff --git a/(\S+) b/\S+"#)
        let ns = patch as NSString
        let matches = regex.matches(in: patch, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Extracts the string literal assigned to a `$widget =` / `$gtkBackend =` -style
    /// PowerShell variable inside a step block.
    private func windowsVariableAssignedPaths(in block: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"\$\w+\s*=\s*"([^"]+)""#)
        let ns = block as NSString
        let matches = regex.matches(in: block, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range(at: 1)) }
    }
}

final class CUESYNC8EnvelopeCanvasStep5CalloutTests: XCTestCase {

    /// spec CUESYNC-8 §3/§5 acceptance: "Envelope canvas: ... either click-to-select /
    /// drag-to-move responds, or the callout is documented and the table/toolbar editor
    /// is confirmed fully functional." findings §2.4 concludes 0.8.0 exposes no
    /// location-aware tap/drag primitive even after the gesture patch, so this must be
    /// the documented-callout branch — asserted here so a silent regression (someone
    /// deletes the callout without actually implementing drag support) is caught.
    func testEnvelopeCanvasViewDocumentsTheCUESYNC8CannotReproduceFaithfullyCallout() throws {
        let src = try String(contentsOf: RepoPaths8.envelopeCanvasView, encoding: .utf8)
        XCTAssertTrue(src.contains("CUESYNC-8"),
            "EnvelopeCanvasView.swift must document that its drag/pointer-location gap was " +
            "re-verified for CUESYNC-8 (spec §5), not left as a stale pre-CUESYNC-8 note only")

        // Several of the phrases below are word-wrapped across comment line breaks in the
        // source (e.g. "cannot-reproduce-\n// faithfully", "no pointer\n// location on
        // tap"). Strip comment markers and reflow: a line ending in "-" continues the word
        // with no separator, everything else rejoins with a single space — so a literal
        // search survives the wrap regardless of whether it split mid-word or between words.
        var joined = ""
        for rawLine in src.split(separator: "\n", omittingEmptySubsequences: false) {
            var trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") {
                trimmed.removeFirst(2)
                trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            }
            guard !trimmed.isEmpty else { continue }
            if joined.isEmpty || joined.hasSuffix("-") {
                joined += trimmed
            } else {
                joined += " " + trimmed
            }
        }

        XCTAssertTrue(joined.contains(patchRelativePath),
            "the CUESYNC-8 callout must cite the gesture patch it re-verified against, so a reader " +
            "can see the re-check happened AFTER delivery was fixed, not before")
        XCTAssertTrue(joined.contains("cannot-reproduce-faithfully"),
            "EnvelopeCanvasView.swift must explicitly conclude 'cannot-reproduce-faithfully' for the " +
            "drag/pointer-location gap (spec §5/findings §2.4), not just gesture at the topic")

        // The pre-existing honest disclosure this callout re-verifies (not replaces) must
        // still be present — findings §2.4 re-checked it, it did not delete it.
        XCTAssertTrue(joined.contains("no pointer location on tap") && joined.contains("`DragGesture`"),
            "the original PORT disclosure ('no pointer location on tap, no DragGesture') must survive " +
            "the CUESYNC-8 re-verification, not be removed")
        XCTAssertTrue(joined.contains("toolbar and cue table") && joined.contains("complete editor"),
            "the callout's required fallback — 'the toolbar/table stay the complete editor' (spec §5) " +
            "— must be documented in EnvelopeCanvasView.swift")
    }

    /// Companion to the callout above: since the conclusion is "cannot reproduce," the
    /// actual code must match that conclusion — no dead/half-wired drag code should
    /// exist. Comment-stripped so the PORT prose citing these names for documentation
    /// doesn't trip a false positive on itself.
    func testEnvelopeCanvasViewCodeIntroducesNoDragGestureOrPointerLocationAPI() throws {
        let src = try String(contentsOf: RepoPaths8.envelopeCanvasView, encoding: .utf8)
        let codeOnly = src.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let commentStart = line.range(of: "//") { return line[line.startIndex..<commentStart.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        for banned in ["DragGesture", "onDrag", "onPointer", "PointerEvent", "GtkFixed"] {
            XCTAssertFalse(codeOnly.contains(banned),
                "EnvelopeCanvasView.swift must not introduce '\(banned)' in actual code — findings §2.4 " +
                "confirms no such primitive exists at the pinned 0.8.0 revision even after the gesture patch")
        }
    }
}

// MARK: - Helpers (deliberately file-local — see the file header rationale)

private enum RepoPaths8 {
    /// Tests/CueSyncCoreTests/<this file> -> Tests/CueSyncCoreTests -> Tests -> repo root
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let packageSwift = root.appendingPathComponent("Package.swift")
    static let packageResolved = root.appendingPathComponent("Package.resolved")
    static let workflow = root.appendingPathComponent(".github/workflows/swift-windows.yml")
    static let patch = root.appendingPathComponent(patchRelativePath)
    static let devScript = root.appendingPathComponent("scripts/patch-swift-cross-ui.sh")
    static let envelopeCanvasView = root.appendingPathComponent("CueSync/CueSync/UI/Sections/EnvelopeCanvasView.swift")
}

private enum WorkflowFile8 {
    static func contents() throws -> String {
        try String(contentsOf: RepoPaths8.workflow, encoding: .utf8)
    }
}

/// A single top-level GitHub Actions job's YAML text. Mirrors
/// CUESYNC6WindowsGtkWorkflowTests' `JobBlock`/`JobBlocks` (kept file-local
/// rather than shared — see file header).
private struct JobBlock8 {
    let text: String
    let lines: [String]

    func firstLineIndex(matching pattern: String, caseInsensitive: Bool = false) -> Int? {
        let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        return lines.firstIndex { $0.range(of: pattern, options: options) != nil }
    }

    /// Text of one `- name: <matching namePattern>` step, from its `name:` line
    /// up to (not including) the next `- name:`/`- uses:` step at the same
    /// indent, or end of job. `includingPrecedingComments` widens the start to
    /// also capture the contiguous `#`-comment block immediately above the
    /// step (where this workflow's convention puts rationale/pin citations).
    func stepBlock(named namePattern: String, includingPrecedingComments: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let nameIndex = firstLineIndex(matching: #"name:\s*"# + namePattern) else {
            XCTFail("no step matching '\(namePattern)' found in job", file: file, line: line)
            return ""
        }
        var start = nameIndex
        if includingPrecedingComments {
            var cursor = nameIndex - 1
            while cursor >= 0, lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                start = cursor
                cursor -= 1
            }
        } else {
            // Back up to the owning `- name:` line itself (nameIndex already IS it).
            start = nameIndex
        }
        var end = lines.count
        for i in (nameIndex + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- name:") || trimmed.hasPrefix("- uses:") {
                end = i
                break
            }
        }
        return lines[start..<end].joined(separator: "\n")
    }
}

private enum JobBlocks8 {
    static func require(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> JobBlock8 {
        let raw = try WorkflowFile8.contents()
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let allLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = allLines.firstIndex(of: "  \(name):") else {
            XCTFail("could not locate the top-level `\(name):` job in .github/workflows/swift-windows.yml",
                    file: file, line: line)
            return JobBlock8(text: "", lines: [])
        }
        var end = allLines.count
        for i in (start + 1)..<allLines.count {
            if allLines[i].range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil {
                end = i
                break
            }
        }
        let block = Array(allLines[start..<end])
        return JobBlock8(text: block.joined(separator: "\n"), lines: block)
    }
}
