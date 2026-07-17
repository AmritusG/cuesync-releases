import Foundation
import XCTest

// =============================================================================
// CUESYNC-6d — vcpkg-to-gvsbuild migration acceptance criteria (spec §3) not
// already covered by CUESYNC6WindowsGtkWorkflowTests/AdversarialCUESYNC6Tests.
//
// Those two files already carry most of §C/§D's structural guarantees forward
// (GTK-before-build ordering, allowlist strength, cache-input coverage, the
// checksum-before-extract rule for windows-build). This file closes the gaps
// specific to the vcpkg→gvsbuild swap itself: that vcpkg is *fully* gone (not
// just no longer the active install method), that windows-test gets the exact
// same pinned-download treatment as windows-build (rather than only being
// spot-checked on windows-build), and that the two jobs cannot drift apart
// since each carries its own independent copy of the pin.
//
// Self-contained by the same convention the existing suite already states for
// itself: helpers here are private to this file rather than imported from
// CUESYNC6WindowsGtkWorkflowTests, so a blind spot in a shared helper can't
// quietly hide the same blind spot here.
// =============================================================================

final class CUESYNC6dVcpkgRemovalTests: XCTestCase {

    /// spec CUESYNC-6d §3 "vcpkg is gone": "No occurrence of `vcpkg` remains in
    /// .github/workflows/swift-windows.yml — not in a step, not in a cache key,
    /// not in a comment." Deliberately checks the whole file rather than one
    /// job, since a stray mention in a comment above an unrelated step would
    /// still violate this.
    func testVcpkgIsAbsentEverywhereInTheRealWorkflowFile() throws {
        let src = try WorkflowFile.contents()
        XCTAssertNil(src.range(of: "vcpkg", options: .caseInsensitive),
            "spec CUESYNC-6d §3: no occurrence of `vcpkg` may remain anywhere in " +
            "swift-windows.yml now that gvsbuild has replaced it as the GTK 4 source")
    }

    /// spec CUESYNC-6d §3: "The vcpkg commit pin 52c9e08c...f2 appears nowhere
    /// in the workflow." (This test intentionally does not extend the check
    /// into Tests/ — AdversarialCUESYNC6cTests.swift's occurrences of this pin
    /// are synthetic hostile fixtures that spec §0.4 explicitly names as
    /// gvsbuild-safe and requires be left untouched; a test that failed on
    /// them would contradict that explicit carve-out.)
    func testVcpkgCommitPinIsAbsentFromTheRealWorkflowFile() throws {
        let src = try WorkflowFile.contents()
        XCTAssertFalse(src.contains("52c9e08cdf8580d2d9762f547d22b96fd81e82f2"),
            "spec CUESYNC-6d §3: the vcpkg commit pin must not survive in the real workflow file")
    }

    /// spec CUESYNC-6d §3: "Neither Windows job clones a repository to obtain
    /// GTK." A `git clone`/`git -C ... checkout` was vcpkg's acquisition path;
    /// a pinned release-asset download replaces it entirely, so no clone of
    /// any kind belongs in either job any more.
    func testNeitherWindowsJobClonesARepositoryToAcquireGtk() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks.require(jobName)
            XCTAssertNil(job.firstLineIndex(matching: #"git\s+clone|git\s+-C\b"#, caseInsensitive: true),
                "\(jobName) clones a repository — spec CUESYNC-6d requires GTK 4 come from a pinned " +
                "release-asset download, not a source-tree clone")
        }
    }
}

final class CUESYNC6dGvsbuildPinConsistencyTests: XCTestCase {

    /// spec CUESYNC-6d §3 "gvsbuild is pinned and verified": "Both Windows jobs
    /// download GTK 4 from a releases/download/<tag>/<asset> URL. No
    /// releases/latest, no /latest/download." The existing suite only asserts
    /// this shape against windows-build; windows-test needs its own GTK 4
    /// install (§0.4/step 8) and must satisfy the identical rule.
    func testBothWindowsJobsDownloadGtkFromAPinnedReleaseURLNeverLatest() throws {
        let urlPattern = #"Invoke-WebRequest -Uri "([^"]+)""#
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks.require(jobName)
            guard let downloadLine = job.lines.first(where: { $0.contains("Invoke-WebRequest") && $0.contains("gvsbuild") }),
                  let url = firstCapture(urlPattern, in: downloadLine) else {
                XCTFail("\(jobName) must download GTK 4 via an `Invoke-WebRequest -Uri \"...\"` command line")
                continue
            }
            XCTAssertNotNil(url.range(of: #"releases/download/[^/\s]+/[^/\s"]+\.zip$"#, options: .regularExpression),
                "\(jobName) must download GTK 4 from an exact releases/download/<tag>/<asset> URL " +
                "(spec CUESYNC-6d §3), got: \(url)")
            XCTAssertNil(url.range(of: #"releases/latest|/latest/download"#, options: [.regularExpression, .caseInsensitive]),
                "\(jobName) must never reference a mutable `releases/latest` channel (spec CUESYNC-6d §3/§4), " +
                "got: \(url)")
        }
    }

    /// spec CUESYNC-6d §3: "Both jobs verify the asset's SHA-256 against a
    /// committed literal, and the verify line precedes the extract line in
    /// the file, in each job." `AdversarialCUESYNC6GtkSupplyChainTests` proves
    /// this for windows-build only; windows-test carries its own independent
    /// download/verify/extract sequence (§0.4 step 8) that needs the same
    /// proof, since a copy-paste of the install step without the ordering
    /// would satisfy every windows-build-scoped test while shipping unverified
    /// bytes on the test leg.
    func testBothWindowsJobsVerifyTheGtkChecksumBeforeExtractingTheArchive() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks.require(jobName)
            guard let verifyLine = job.firstLineIndex(matching: "Get-FileHash") else {
                XCTFail("\(jobName) must verify the downloaded GTK 4 archive via Get-FileHash")
                continue
            }
            guard let extractLine = job.firstLineIndex(matching: "Expand-Archive") else {
                XCTFail("\(jobName) must extract the downloaded GTK 4 archive via Expand-Archive")
                continue
            }
            XCTAssertLessThan(verifyLine, extractLine,
                "\(jobName) must verify the GTK 4 archive's SHA-256 BEFORE Expand-Archive (spec " +
                "CUESYNC-6d §3/§4) — checking a hash after unpacking checks it after untrusted bytes " +
                "have already touched the filesystem")
        }
    }

    /// spec CUESYNC-6d step 8: "Apply steps 4, 6 and 7 to windows-test,
    /// identically." Each job carries its own independent copy of the
    /// download URL and SHA-256 literal rather than sharing one definition, so
    /// nothing stops a future edit from updating one job's pin and forgetting
    /// the other — which would make windows-build's artifact and
    /// windows-test's test evidence come from two different GTK binaries
    /// while every single-job test above stays green.
    func testWindowsBuildAndWindowsTestPinTheIdenticalGvsbuildUrlAndSha256() throws {
        let buildText = try JobBlocks.require("windows-build").text
        let testText = try JobBlocks.require("windows-test").text

        let urlPattern = #"Invoke-WebRequest -Uri "(https://github\.com/wingtk/gvsbuild/releases/download/[^"]+)""#
        guard let buildURL = firstCapture(urlPattern, in: buildText),
              let testURL = firstCapture(urlPattern, in: testText) else {
            XCTFail("both windows-build and windows-test must download GTK 4 via Invoke-WebRequest " +
                    "from a wingtk/gvsbuild release URL")
            return
        }
        XCTAssertEqual(buildURL, testURL,
            "windows-build and windows-test must pin the IDENTICAL gvsbuild GTK 4 release asset URL " +
            "(spec CUESYNC-6d step 8) — found a drifted pin between the two jobs")

        let shaPattern = #"\$expectedSha256 = "([0-9A-Fa-f]{64})""#
        guard let buildSha = firstCapture(shaPattern, in: buildText),
              let testSha = firstCapture(shaPattern, in: testText) else {
            XCTFail("both windows-build and windows-test must pin an expected SHA-256 for the GTK 4 download")
            return
        }
        XCTAssertEqual(buildSha, testSha,
            "windows-build and windows-test must pin the IDENTICAL GTK 4 SHA-256 — a drifted pin between " +
            "the two jobs means the build artifact and the test evidence come from different GTK binaries")
    }

    /// spec §4: "Get-FileHash returns uppercase, and a case mismatch that
    /// silently never matches would make the gate unfirable ... string-compare
    /// the hashes case-insensitively." PowerShell's default `-eq`/`-ne` already
    /// do this; the case-SENSITIVE variants (`-ceq`/`-cne`) would silently
    /// break the gate if ever substituted in.
    func testGtkChecksumComparisonNeverUsesACaseSensitiveOperator() throws {
        let src = try WorkflowFile.contents()
        let lowered = src.lowercased()
        XCTAssertFalse(lowered.contains("-ceq") || lowered.contains("-cne"),
            "spec CUESYNC-6d §4: the checksum comparison must use PowerShell's case-insensitive " +
            "-eq/-ne, not the case-sensitive -ceq/-cne — Get-FileHash returns an uppercase hash string, " +
            "and a case-sensitive compare against a differently-cased literal would never match, making " +
            "the gate unfirable")
    }
}

final class CUESYNC6dCacheKeyGvsbuildTests: XCTestCase {

    /// spec CUESYNC-6d §3 "Cache": "Both Windows .build keys and their
    /// restore-keys prefixes contain both swift-6.3.3 and the gvsbuild pin"
    /// and "No windows-*-vcpkg-* cache key or prefix survives." The existing
    /// suite checks the swift-6.3.3 half; this checks the gvsbuild half is
    /// present and the vcpkg half is gone, for both the `key:` line and every
    /// `restore-keys` prefix line, in both jobs.
    func testBothWindowsCacheKeysAndRestoreKeyPrefixesNameGvsbuildAndNeverVcpkg() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks.require(jobName)
            let cacheLines = job.lines.filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("key: \(jobName)-spm-") || trimmed.hasPrefix("\(jobName)-spm-")
            }
            XCTAssertFalse(cacheLines.isEmpty,
                "\(jobName) must declare a \(jobName)-spm- cache key and a matching restore-keys prefix")
            for line in cacheLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(trimmed.contains("gvsbuild"),
                    "\(jobName)'s cache key/restore-keys prefix must name the gvsbuild pin, got: \(trimmed)")
                XCTAssertFalse(trimmed.lowercased().contains("vcpkg"),
                    "\(jobName)'s cache key/restore-keys prefix must not reference vcpkg any more, got: \(trimmed)")
            }
        }
    }
}

final class CUESYNC6dPortabilityTests: XCTestCase {

    /// spec §4 "Portability": "The only paths that may be spelled with
    /// backslashes are Windows-only PowerShell steps that already are" — i.e.
    /// the gvsbuild extraction prefix and its derived PKG_CONFIG_PATH must be
    /// spelled the Windows way throughout, not mixed with forward slashes
    /// that would silently fail to resolve on a case- and separator-sensitive
    /// pkg-config lookup.
    func testGvsbuildPkgConfigPathUsesWindowsBackslashSeparators() throws {
        for jobName in ["windows-build", "windows-test"] {
            let job = try JobBlocks.require(jobName)
            guard let prefixLine = job.lines.first(where: { $0.contains("PKG_CONFIG_PATH") }) else {
                XCTFail("\(jobName) must set PKG_CONFIG_PATH to the gvsbuild extraction prefix")
                continue
            }
            XCTAssertFalse(prefixLine.contains("gtk-build/gtk"),
                "\(jobName)'s PKG_CONFIG_PATH must use Windows backslash separators for the gvsbuild " +
                "prefix, not forward slashes, got: \(prefixLine.trimmingCharacters(in: .whitespaces))")
        }
    }
}

// MARK: - Helpers (deliberately self-contained — see file header)

private func firstCapture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          match.numberOfRanges > 1,
          let captured = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[captured])
}

private enum RepoPaths {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let workflow = root.appendingPathComponent(".github/workflows/swift-windows.yml")
}

private enum WorkflowFile {
    static func contents() throws -> String {
        try String(contentsOf: RepoPaths.workflow, encoding: .utf8)
    }
}

private struct JobBlock {
    let text: String
    let lines: [String]

    func firstLineIndex(matching pattern: String, caseInsensitive: Bool = false) -> Int? {
        let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
        return lines.firstIndex { $0.range(of: pattern, options: options) != nil }
    }
}

private enum JobBlocks {
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
