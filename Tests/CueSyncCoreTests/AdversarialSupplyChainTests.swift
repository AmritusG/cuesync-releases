import Foundation
import XCTest

// =============================================================================
// Red-Team adversarial suite (CUESYNC-5) — supply chain.
//
// CUESYNC-5 adds no parser, no I/O and no user input: spec §4 states plainly
// that "the empty ContentView has no attack surface of its own" and that "the
// entire risk of this ticket is supply chain". So this suite does not attack
// the parsers (AdversarialTests.swift already does that). It attacks the two
// trust boundaries this ticket actually opens —
//
//   1. the swift-cross-ui dependency and its 21-package transitive closure, and
//   2. the CI workflow that fetches a toolchain into the build,
//
// — plus a third the spec did not anticipate: **the compliance tests themselves**.
// Spec §D.15 caught one test that "passed on the strength of a code comment ...
// [it] cannot tell a real pinned dependency from prose about one". That defect
// class is not unique to the test §D.15 fixed. A structural test that cannot
// fail is indistinguishable from no test at all, while still reading as coverage
// in CI — so an assertion that is vacuously true is itself an attack surface,
// and two of them are live in PortComplianceTests today (see §3 and §5 below).
//
// Deterministic, network-free and CLI-free: every check reads a file already
// committed to the repo, located via `#filePath`, so `swift test` behaves
// identically on windows-latest and macos-latest (spec §3).
// =============================================================================

/// Everything here is derived from evidence recorded at audit time (2026-07-16).
/// Each allowlist is deliberately a *hardcoded expectation*, not a value read
/// back out of the file under test — a test that recomputes its expectation from
/// its input can only ever assert "the file equals itself" and would wave through
/// exactly the unaudited change spec §4 requires be "a finding to report, not a
/// detail to wave through".
private enum Audit {

    /// The GitHub orgs whose code is authorized to compile into CUE SYNC, each
    /// established from the resolved closure at audit time.
    ///
    /// `moreSwift` is included on verified evidence, and the verification is the
    /// point of `testSwiftCrossUIIsFetchedOverHTTPSFromAnAuditedOrigin` below.
    /// Spec §0.1 names `github.com/stackotter/swift-cross-ui` as upstream, but the
    /// manifest fetches `github.com/moreSwift/swift-cross-ui` — a different org,
    /// which is the exact shape of a dependency-confusion / typosquat attack. It
    /// is not one. Confirmed at audit time:
    ///
    ///   * `stackotter/swift-cross-ui` HTTP-redirects to `moreSwift/swift-cross-ui`
    ///     (GitHub's API reports `full_name = moreSwift/swift-cross-ui` for the
    ///     stackotter URL) — i.e. the repository was *transferred* to the org, it
    ///     was not re-uploaded. The repo carries the original 2022-01-09 creation
    ///     date and 1627 stars; a squat would have neither.
    ///   * `git ls-remote` against BOTH URLs returns the identical SHA for
    ///     `refs/tags/v0.8.0`: a6d206370812e3b9edba259d167e848892c5013d — which is
    ///     byte-for-byte the revision pinned in Package.resolved.
    ///
    /// So the manifest pins the canonical current location and the *spec* holds the
    /// stale one. Recording that here is the deliverable: distinguishing the
    /// transfer from a squat took five network calls precisely because no test
    /// pinned the origin. This one does, so the next reader spends zero.
    static let trustedOrigins: Set<String> = [
        "github.com/moreSwift",           // swift-cross-ui (transferred from stackotter), swift-winui, AndroidKit
        "github.com/stackotter",          // jpeg, swift-image-formats, swift-java, swift-macro-toolkit, SwiftJavaLang, SwiftKotlin
        "github.com/the-swift-collective", // libpng, libwebp, zlib
        "github.com/swift-android-sdk",   // swift-android-native
        "github.com/apple",               // swift-argument-parser, swift-collections, swift-log, swift-system
        "github.com/swiftlang",           // swift-java-jni-core, swift-subprocess, swift-syntax
        "github.com/swhitty",             // swift-mutex
    ]

    /// The exact resolved closure at audit time. Spec §3 requires "The resolved
    /// dependency tree contains **no** package beyond swift-cross-ui and its own
    /// transitive closure, **each one listed in the PR**". A set-equality assertion
    /// is what makes that criterion enforceable rather than aspirational: a package
    /// appearing OR disappearing breaks the build until a human re-audits and
    /// edits this list.
    static let resolvedClosure: Set<String> = [
        "androidkit", "jpeg", "libpng", "libwebp", "swift-android-native",
        "swift-argument-parser", "swift-collections", "swift-cross-ui",
        "swift-image-formats", "swift-java", "swift-java-jni-core", "swift-log",
        "swift-macro-toolkit", "swift-mutex", "swift-subprocess", "swift-syntax",
        "swift-system", "swift-winui", "swiftjavalang", "swiftkotlin", "zlib",
    ]
}

// MARK: - 1. CI is the second supply chain (spec §4, §E.20)

/// Spec §4: "The `.github/workflows/swift-windows.yml` prerequisite steps (§E.20).
/// ... that fetch is a second supply chain entering CI. Pin those by version too —
/// never `latest`. **Prefer a pinned GitHub Action at a commit SHA** or a versioned
/// installer URL over an unpinned script piped to a shell."
final class AdversarialWorkflowPinningTests: XCTestCase {

    private static let workflowURL = RepoPaths.root
        .appendingPathComponent(".github/workflows/swift-windows.yml")

    /// EXPLOIT — fails today. A git tag is a **mutable pointer**, not a content
    /// address: whoever controls the repo can re-point `v4` at any commit, and
    /// every workflow resolving `@v4` silently executes the new code on the next
    /// run. `actions/checkout@v4` is not "version 4.0.0" — it is a moving major-
    /// version ref that GitHub *deliberately* re-points as each v4.x.y ships, so
    /// the bytes CI runs are by construction not the bytes anyone audited.
    ///
    /// This is not theoretical. In March 2025 `tj-actions/changed-files` had its
    /// tags retroactively re-pointed to a malicious commit that dumped CI runner
    /// memory — including secrets — into build logs, across thousands of repos
    /// that had pinned exactly this way. The runner executing these actions has
    /// the checkout, the toolchain, and `GITHUB_TOKEN`.
    ///
    /// The workflow already knows this — it SHA-pins both third-party actions
    /// (`gha-setup-vsdevenv@cf96bf5b…`, `gha-setup-swift@eeda069c…`) with an
    /// explicit "Pinned to the vN tag's commit, not a floating ref" rationale. The
    /// three `actions/*` steps were simply left on `@v4`. First-party publication
    /// by GitHub lowers the likelihood but does not change the mechanism, and §4
    /// draws no first-party exemption. Uniform SHA pinning is the fix.
    func testEveryGitHubActionIsPinnedToAFullCommitSHANotAMutableTag() throws {
        let src = try String(contentsOf: Self.workflowURL, encoding: .utf8)
        let refs = WorkflowParser.actionRefs(in: src)

        XCTAssertGreaterThanOrEqual(refs.count, 5,
            "expected to find every `uses:` step in swift-windows.yml — found \(refs.count), " +
            "which suggests the parse broke rather than the workflow shrinking")

        for ref in refs {
            XCTAssertTrue(
                ref.ref.count == 40 && ref.ref.allSatisfy(\.isHexDigit),
                "\(ref.action) is pinned to `\(ref.ref)`, a mutable ref — it must be pinned to a " +
                "full 40-char commit SHA (spec §4: a fetch into CI is a second supply chain). " +
                "A tag can be re-pointed at any time by whoever controls the repo; the SHA cannot."
            )
        }
    }

    /// Spec §4: "never `latest`". Belt-and-braces alongside the SHA check above —
    /// a `@latest`/`@main`/`@master` ref is the degenerate case of a mutable tag,
    /// where the workflow is not even nominally pinned to a release.
    func testNoActionTracksLatestOrADefaultBranch() throws {
        let src = try String(contentsOf: Self.workflowURL, encoding: .utf8)
        for ref in WorkflowParser.actionRefs(in: src) {
            for moving in ["latest", "main", "master", "HEAD"] {
                XCTAssertNotEqual(ref.ref.lowercased(), moving.lowercased(),
                    "\(ref.action) tracks the moving ref `\(ref.ref)` — spec §4 forbids it outright")
            }
        }
    }
}

// MARK: - 2. The dependency origin (spec §0.1, §4)

final class AdversarialDependencyOriginTests: XCTestCase {

    /// THE GAP THIS SUITE EXISTS TO CLOSE. `PortComplianceTests` checks the
    /// dependency's *shape* thoroughly — `exact:`/`revision:` present, `branch:`
    /// and `from:` absent, a 40-char hex SHA, exactly one `.package(` entry, every
    /// transitive pin resolved. It never once checks **where the code comes from**.
    ///
    /// So every one of those tests passes unchanged if the URL is swapped to
    /// `github.com/moreSwlft/swift-cross-ui` (homoglyph), to an attacker-controlled
    /// org, to `http://` (MITM-able), or to a `file://` path — as long as the
    /// attacker's fork also carries a tag `0.8.0` and a 40-hex SHA, which costs
    /// them nothing. The pin's whole purpose is to make "the code we audited" and
    /// "the code we build" the same bytes (spec §4); a pin to an unverified origin
    /// pins the wrong bytes precisely, which is worse than not pinning, because the
    /// suite then reports it as compliant.
    ///
    /// The URL is also what SwiftPM asks "which SHA is tag 0.8.0?" whenever
    /// resolution re-runs (`swift package update`, a Package.resolved conflict), so
    /// a hostile origin rewrites the lockfile and the shape checks still pass.
    func testSwiftCrossUIIsFetchedOverHTTPSFromAnAuditedOrigin() throws {
        let manifest = try String(contentsOf: RepoPaths.packageSwift, encoding: .utf8)
        guard let url = manifest.firstMatch(of: #"\.package\(url:\s*"([^"]+)""#) else {
            XCTFail("could not locate the swift-cross-ui .package(url:) entry in Package.swift")
            return
        }
        assertTrustedOrigin(url, what: "the swift-cross-ui dependency URL in Package.swift")
    }

    /// The same blind spot, one hop down. `testPackageResolvedPinsEveryTransitive-
    /// DependencyToAFullRevisionSHA` walks all 21 pins and validates each revision
    /// is 40 hex chars — while never reading the adjacent `location` field. An
    /// attacker who swaps one transitive `location` to a mirror they control keeps
    /// every existing assertion green.
    ///
    /// Content-addressing makes serving *different bytes* at the same SHA
    /// impractical, so the realistic damage here is origin substitution rather than
    /// content substitution: the fetch itself is redirected to an attacker's server
    /// (availability, traffic analysis, and a foothold for the next resolution that
    /// isn't SHA-constrained). `http://`/`git://` locations are the sharper edge —
    /// both are unauthenticated transports where a network attacker chooses the
    /// bytes outright, and neither is checked anywhere today.
    func testEveryResolvedPinIsFetchedOverHTTPSFromAnAuditedOrigin() throws {
        for pin in try PackageResolved.pins() {
            guard let location = pin["location"] as? String else {
                XCTFail("pin \(PackageResolved.identity(of: pin)) has no location field")
                continue
            }
            assertTrustedOrigin(location, what: "transitive pin `\(PackageResolved.identity(of: pin))`")
        }
    }

    /// Spec §3: "The resolved dependency tree contains **no** package beyond
    /// swift-cross-ui and its own transitive closure, **each one listed in the
    /// PR**"; §4: "treat any unexpected transitive package as a finding to report,
    /// not a detail to wave through". Nothing enforces that today — the closure
    /// could grow a 22nd package and the suite would stay green.
    ///
    /// Set equality (not `isSubset`) is deliberate, and it is why this assertion
    /// is worth its maintenance cost: this closure is not small or inert. It pulls
    /// in swift-syntax and swift-macro-toolkit, which means **macro plugins — code
    /// that executes on the developer's machine and in CI at build time**, exactly
    /// the risk §4 names ("via SwiftPM plugins or `cSettings` build tooling"). It
    /// also drags an entire Android/JNI toolchain (AndroidKit, swift-java,
    /// SwiftKotlin, SwiftJavaLang, swift-android-native) into a macOS/Windows DJ
    /// app, because DefaultBackend's package graph is platform-blind. That is a
    /// legitimate consequence of the §0.2 product choice and not a defect — but it
    /// is a large, mostly-unread attack surface that a human agreed to once, at a
    /// known set of revisions. This test makes any change to that agreement stop
    /// the build.
    func testResolvedClosureMatchesTheAuditedAllowlistExactly() throws {
        let actual = Set(try PackageResolved.pins().map { PackageResolved.identity(of: $0) })

        let added = actual.subtracting(Audit.resolvedClosure)
        let removed = Audit.resolvedClosure.subtracting(actual)

        XCTAssertTrue(added.isEmpty,
            "unaudited package(s) entered the dependency closure: \(added.sorted()). " +
            "Spec §4: an unexpected transitive package is a finding to report. Audit each one, " +
            "then add it to Audit.resolvedClosure with its origin recorded in Audit.trustedOrigins.")
        XCTAssertTrue(removed.isEmpty,
            "package(s) left the closure: \(removed.sorted()). Not dangerous, but the audit list " +
            "is now stale — prune it so the next real addition still stands out.")
    }

    private func assertTrustedOrigin(_ location: String, what: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(location.hasPrefix("https://"),
            "\(what) uses a non-HTTPS transport: \(location). An `http://`/`git://`/`file://` " +
            "origin lets a network attacker choose the bytes SwiftPM compiles (spec §4).",
            file: file, line: line)

        let origin = OriginParser.hostAndOrg(of: location)
        XCTAssertTrue(Audit.trustedOrigins.contains(origin),
            "\(what) resolves to the unaudited origin `\(origin)` (\(location)). " +
            "Only these origins are authorized to compile into CUE SYNC: " +
            "\(Audit.trustedOrigins.sorted().joined(separator: ", ")). If this move is legitimate " +
            "(as the stackotter -> moreSwift transfer was), verify it the way Audit.trustedOrigins " +
            "documents — redirect + identical ls-remote SHA — and record the evidence there.",
            file: file, line: line)
    }
}

// MARK: - 3. The vacuous Xcode-project assertion (spec §C.14)

final class AdversarialXcodeProjectIsolationTests: XCTestCase {

    private static let pbxprojURL = RepoPaths.root
        .appendingPathComponent("CueSync/CueSync.xcodeproj/project.pbxproj")

    /// EXPLOIT — a live, vacuously-true assertion, the same defect class spec §D.15
    /// caught and fixed one instance of.
    ///
    /// `PortComplianceTests.testXcodeProjectDoesNotReferenceTheCrossUIShell` enforces
    /// §C.14 ("Do not add `UI/` to the Xcode target") with:
    ///
    ///     XCTAssertFalse(contents.contains("UI/"))
    ///
    /// **A `.pbxproj` never writes a path with a trailing slash.** Directory groups
    /// are serialized `path = App;`, `path = Views;`, `path = Support;` — verified at
    /// audit time: this project file contains *zero* slash-bearing `path =` entries
    /// and zero occurrences of the substring `UI/`. So the assertion cannot fail. It
    /// does not fail today because `UI/` is absent; it would equally not fail if a
    /// `path = UI;` group with both shell files were added to the target tomorrow —
    /// which is the precise regression §C.14 exists to prevent, reported as green.
    ///
    /// This test asserts on the representation the format actually uses. It is
    /// deliberately narrow: it forbids a *group* named `UI`, not the substring
    /// `ContentView.swift`, because `App/CueSyncApp.swift` and `Views/ContentView.swift`
    /// legitimately reuse both file names (the reason the original test reached for a
    /// directory-qualified match in the first place).
    func testXcodeProjectContainsNoGroupForTheCrossUIShellDirectory() throws {
        let contents = try String(contentsOf: Self.pbxprojURL, encoding: .utf8)

        let uiGroup = contents.range(of: #"path = UI\s*;"#, options: .regularExpression) != nil
        XCTAssertFalse(uiGroup,
            "CueSync.xcodeproj declares a `path = UI;` group — spec §C.14 requires the SwiftUI " +
            "build stay completely unaware the swift-cross-ui shell exists")

        let quotedUIGroup = contents.range(of: #"path = "UI"\s*;"#, options: .regularExpression) != nil
        XCTAssertFalse(quotedUIGroup, "CueSync.xcodeproj declares a quoted `path = \"UI\";` group (spec §C.14)")
    }

    /// Pins the *reason* the assertion above replaces `contains("UI/")`, so nobody
    /// "simplifies" it back. If this ever fails, `.pbxproj` has started emitting
    /// slash-bearing paths and the original substring check would have become
    /// meaningful — at which point revisit. Until then it is provably inert.
    func testPbxprojNeverSerializesSlashBearingDirectoryPaths() throws {
        let contents = try String(contentsOf: Self.pbxprojURL, encoding: .utf8)

        XCTAssertTrue(contents.contains("path = App;") && contents.contains("path = Views;"),
            "sanity: the SwiftUI group entries must still be present in the expected `path = X;` form")

        XCTAssertFalse(contents.range(of: #"path = [^";\n]*/[^";\n]*;"#, options: .regularExpression) != nil,
            "a `.pbxproj` directory path now contains a slash — the assumption behind " +
            "testXcodeProjectContainsNoGroupForTheCrossUIShellDirectory needs review")
    }
}

// MARK: - 4. The guard the "fully wrapped" test doesn't actually check (spec §3)

final class AdversarialCrossUIGuardTests: XCTestCase {

    /// EXPLOIT — a bypassable pair of assertions. Spec §3 requires the shell files be
    /// "**fully wrapped** in `#if CUESYNC_CROSSUI`", and `PortComplianceTests` checks
    /// it with two independent string tests: `trimmed.hasPrefix("#if CUESYNC_CROSSUI")`
    /// and `trimmed.hasSuffix("#endif")`.
    ///
    /// Prefix + suffix does not imply "wrapped". This file shape satisfies both and is
    /// not wrapped at all:
    ///
    ///     #if CUESYNC_CROSSUI
    ///     import SwiftCrossUI
    ///     #endif
    ///     @main struct Escaped { static func main() {} }   // <- unguarded, compiles always
    ///     #if CUESYNC_CROSSUI
    ///     struct ContentView: View { var body: some View { Text("CUE SYNC") } }
    ///     #endif
    ///
    /// The suite reports the file as fully wrapped. `testNoFileUnderUIImportsBanned-
    /// AppleFrameworksEvenIfGuarded` would still catch a stray `import AppKit`, but it
    /// only pattern-matches a fixed list of six import lines — it says nothing about
    /// arbitrary *declarations* escaping the flag, which is what the guard is for
    /// (spec §A: "the flag's job is ... to guard the one case the directory split
    /// cannot: a file compiled into both builds").
    ///
    /// Both files are correctly wrapped today; this fails the moment one isn't.
    func testUIShellFilesHaveNoCodeOutsideTheCUESYNCCROSSUIGuard() throws {
        let uiDir = RepoPaths.sourceRoot.appendingPathComponent("UI")
        for fileName in ["CueSyncApp.swift", "ContentView.swift"] {
            let src = try String(contentsOf: uiDir.appendingPathComponent(fileName), encoding: .utf8)
            let escaped = GuardScanner.linesOutsideGuard(src, flag: "CUESYNC_CROSSUI")
            XCTAssertTrue(escaped.isEmpty,
                "UI/\(fileName) has code outside `#if CUESYNC_CROSSUI` at line(s) " +
                "\(escaped.map(\.number)): \(escaped.map(\.text).joined(separator: " | ")). " +
                "Spec §3 requires the file be *fully* wrapped — a prefix `#if` plus a trailing " +
                "`#endif` does not achieve that if the guard closes and reopens in between.")
        }
    }

    /// Proves the scanner above actually detects the bypass, rather than being a
    /// second assertion that cannot fail. Without this, a broken `linesOutsideGuard`
    /// (e.g. one that always returns `[]`) would read exactly like a passing suite —
    /// which is the whole defect this file was written to attack.
    func testGuardScannerDetectsTheMidFileEscapeThePrefixSuffixCheckMisses() {
        let bypass = """
        #if CUESYNC_CROSSUI
        import SwiftCrossUI
        #endif
        @main struct Escaped { static func main() {} }
        #if CUESYNC_CROSSUI
        struct ContentView {}
        #endif
        """
        let trimmed = bypass.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasPrefix("#if CUESYNC_CROSSUI"), "the bypass passes the existing prefix check")
        XCTAssertTrue(trimmed.hasSuffix("#endif"), "the bypass passes the existing suffix check")

        let escaped = GuardScanner.linesOutsideGuard(bypass, flag: "CUESYNC_CROSSUI")
        XCTAssertEqual(escaped.map(\.number), [4],
            "the scanner must flag the unguarded @main on line 4 that both existing checks accept")
    }

    /// The scanner must not fire on the real, correctly-wrapped files' comments and
    /// blank lines — a check that cries wolf gets deleted, and then the bypass above
    /// is live again.
    func testGuardScannerIgnoresCommentsAndBlankLinesOutsideTheGuard() {
        let benign = """
        // Leading licence comment.

        #if CUESYNC_CROSSUI
        struct ContentView {}
        #endif
        """
        XCTAssertTrue(GuardScanner.linesOutsideGuard(benign, flag: "CUESYNC_CROSSUI").isEmpty,
                      "comments and blank lines outside the guard are not code and must not be flagged")
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
    static let sourceRoot = root.appendingPathComponent("CueSync/CueSync")
}

private enum PackageResolved {
    /// Reads the pins array, tolerating both the v2 (`object.pins`) and v3 (`pins`)
    /// lockfile layouts, matching how PortComplianceTests already reads it.
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

private enum OriginParser {
    /// "https://github.com/moreSwift/swift-cross-ui.git" -> "github.com/moreSwift".
    /// Case-preserving on the org (GitHub orgs are case-insensitive but the
    /// allowlist is written in the canonical casing, so compare case-insensitively
    /// via `trustedOrigins` lookup on the normalized form).
    static func hostAndOrg(of location: String) -> String {
        var s = location
        for scheme in ["https://", "http://", "git://", "ssh://", "file://"] {
            if s.hasPrefix(scheme) { s.removeFirst(scheme.count); break }
        }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return s }
        return "\(parts[0])/\(parts[1])"
    }
}

private struct ActionRef {
    let action: String
    let ref: String
}

private enum WorkflowParser {
    /// Extracts every `uses: <action>@<ref>` step, stripping any trailing
    /// `# v5`-style comment so the *pinned* ref is what gets asserted on — a
    /// comment naming a version must never be mistaken for a pin.
    static func actionRefs(in yaml: String) -> [ActionRef] {
        var refs: [ActionRef] = []
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("uses:") || line.hasPrefix("- uses:") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            var spec = String(line[line.index(after: colon)...])
            if let comment = spec.firstIndex(of: "#") { spec = String(spec[..<comment]) }
            spec = spec.trimmingCharacters(in: .whitespaces)
            guard let at = spec.lastIndex(of: "@") else {
                refs.append(ActionRef(action: spec, ref: ""))  // unpinned entirely
                continue
            }
            refs.append(ActionRef(action: String(spec[spec.startIndex..<at]),
                                  ref: String(spec[spec.index(after: at)...])))
        }
        return refs
    }
}

private struct SourceLine {
    let number: Int
    let text: String
}

private enum GuardScanner {
    /// Returns every line of code that sits outside an `#if <flag>` region.
    ///
    /// Tracks conditional nesting with a directive stack, so a guard that closes
    /// and reopens mid-file is caught — the case a prefix/suffix string check
    /// structurally cannot see. Blank lines and `//` comments are not code and are
    /// ignored. Normalizes CRLF first so a Windows checkout with `core.autocrlf`
    /// can't dodge the scan on a trailing `\r`, matching the convention the
    /// existing UI/ import scan already uses.
    static func linesOutsideGuard(_ source: String, flag: String) -> [SourceLine] {
        var stack: [Bool] = []          // per-nesting-level: does this level guard on `flag`?
        var escaped: [SourceLine] = []
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")

        for (index, rawLine) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#if") {
                stack.append(line.contains(flag))
            } else if line.hasPrefix("#elseif") {
                // The #else/#elseif arm of an `#if FLAG` is by definition the
                // NOT-flag branch — code there compiles without the flag.
                if !stack.isEmpty { stack[stack.count - 1] = false }
            } else if line.hasPrefix("#else") {
                if !stack.isEmpty { stack[stack.count - 1] = false }
            } else if line.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
            } else if !line.isEmpty && !line.hasPrefix("//") {
                if !stack.contains(true) {
                    escaped.append(SourceLine(number: index + 1, text: line))
                }
            }
        }
        return escaped
    }
}

private extension String {
    /// First capture group of `pattern`, or nil.
    func firstMatch(of pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
