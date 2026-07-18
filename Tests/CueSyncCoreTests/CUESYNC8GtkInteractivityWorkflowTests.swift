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
