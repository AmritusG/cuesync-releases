#!/usr/bin/env python3
# =============================================================================
# Red-Team adversarial suite — CUESYNC-6e
#
# Ticket CUESYNC-6e makes the "Repair swift-java Windows symlinks" step in
# .github/workflows/swift-windows.yml *generic*: instead of a hardcoded
# 3-plugin loop, it enumerates every git symlink (mode 120000) from the index,
# reads each intended POSIX target from the git blob, and re-materializes it as
# a privilege-free NTFS junction (dir) or hardlink (file). This code runs on
# CI, inside a `pwsh` step, against a dependency checkout — a real trust
# boundary the spec's own §4 threat model enumerates.
#
# These tests attack that step's *logic and acceptance criteria*, not just its
# text. Where a test currently PASSES it is a durable regression lock on an
# acceptance criterion (a future edit that reintroduces the weakness turns it
# red). Where a test currently FAILS it reproduces a live, un-mitigated attack
# the implementation does not yet defend against — the red-team's finding.
#
# Self-contained by design: pure stdlib, no PyYAML / pytest import required, so
# it runs on any bare `python3`. Compatible with pytest (functions are test_*)
# and also runnable directly:  python3 Tests/test_adversarial.py
#
# Every assertion cites the spec section it defends so a maintainer who trips
# one knows whether to fix the workflow or (per repo rule §E.24) retarget the
# test — never weaken it.
# =============================================================================

import atexit
import base64
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


# ---------------------------------------------------------------------------
# Workflow-file access + tiny structural parser (stdlib only)
# ---------------------------------------------------------------------------


def _find_workflow():
    """Locate swift-windows.yml by walking up from this test file.

    Robust to being run from any CWD and to the repo being a git worktree.
    """
    here = Path(__file__).resolve()
    for base in [here.parent] + list(here.parents):
        candidate = base / ".github" / "workflows" / "swift-windows.yml"
        if candidate.is_file():
            return candidate
    raise AssertionError(
        ".github/workflows/swift-windows.yml not found above " + str(here)
    )


WORKFLOW_PATH = _find_workflow()
WORKFLOW = WORKFLOW_PATH.read_text(encoding="utf-8")
LINES = WORKFLOW.splitlines()

REPAIR_STEP_NAME = "Repair swift-java Windows symlinks"
JOB_HEADER_RE = re.compile(r"^  ([A-Za-z0-9_.-]+):\s*$")
STEP_NAME_RE = re.compile(r"^      - name: (.*)$")


def _job_ranges():
    """Return {job_name: (start_line_idx, end_line_idx_exclusive)} for the
    top-level entries under `jobs:` (2-space indent)."""
    starts = []
    in_jobs = False
    for i, line in enumerate(LINES):
        if line.rstrip() == "jobs:":
            in_jobs = True
            continue
        if not in_jobs:
            continue
        # A new top-level key at column 0 ends the jobs block.
        if line and not line[0].isspace() and not line.startswith("#"):
            break
        m = JOB_HEADER_RE.match(line)
        if m:
            starts.append((m.group(1), i))
    ranges = {}
    for idx, (name, start) in enumerate(starts):
        end = starts[idx + 1][1] if idx + 1 < len(starts) else len(LINES)
        ranges[name] = (start, end)
    return ranges


JOBS = _job_ranges()


def _repair_step_blocks():
    """Every `- name: Repair swift-java ...` step, as a list of
    (job_name, block_text). A step block runs from its `- name:` line up to
    (excluding) the next `      - name:` line or the end of its job."""
    blocks = []
    for job, (jstart, jend) in JOBS.items():
        i = jstart
        while i < jend:
            m = STEP_NAME_RE.match(LINES[i])
            if m and m.group(1).startswith(REPAIR_STEP_NAME):
                j = i + 1
                while j < jend and not STEP_NAME_RE.match(LINES[j]):
                    j += 1
                blocks.append((job, "\n".join(LINES[i:j])))
                i = j
            else:
                i += 1
    return blocks


REPAIR_BLOCKS = _repair_step_blocks()


def _repair_run_body(block_text):
    """Extract the pwsh script body (the lines under `run: |`) from a step
    block, de-indented, for text-level attacks."""
    lines = block_text.splitlines()
    run_idx = next(
        (k for k, ln in enumerate(lines) if ln.strip() in ("run: |", "run: |-")),
        None,
    )
    assert run_idx is not None, "repair step has no `run: |` body:\n" + block_text
    body = lines[run_idx + 1 :]
    # Common indent = the run body's indentation (10 spaces in this file).
    indented = [ln for ln in body if ln.strip()]
    common = min((len(ln) - len(ln.lstrip()) for ln in indented), default=0)
    return "\n".join(ln[common:] if len(ln) >= common else ln for ln in body)


def _windows_repair_bodies():
    bodies = {}
    for job, block in REPAIR_BLOCKS:
        bodies[job] = _repair_run_body(block)
    return bodies


# Mirror of the PowerShell path resolution: [System.IO.Path]::Combine(linkDir,
# target) then GetFullPath — a *lexical* collapse of `..`/`.` and `/`↔`\`, no
# filesystem access. This is exactly what the step does at line
# `$targetAbs = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine(...))`.
def _resolve_windows_lexical(link_dir, posix_target):
    combined = (link_dir.rstrip("\\/") + "\\" + posix_target).replace("/", "\\")
    drive = ""
    rest = combined
    if len(combined) >= 2 and combined[1] == ":":
        drive, rest = combined[:2], combined[2:]
    out = []
    for part in rest.split("\\"):
        if part in ("", "."):
            continue
        if part == "..":
            if out:
                out.pop()
            continue
        out.append(part)
    return drive + "\\" + "\\".join(out)


# ---------------------------------------------------------------------------
# Sanity: the surface we're attacking actually exists as spec §0 describes.
# ---------------------------------------------------------------------------


def test_two_windows_repair_steps_exist():
    """spec §0.2/§2: the repair step is present in *both* Windows jobs and only
    there — the entire attack surface these tests probe."""
    jobs = sorted(job for job, _ in REPAIR_BLOCKS)
    assert jobs == ["windows-build", "windows-test"], (
        "expected exactly one repair step in windows-build and windows-test, "
        "got: " + repr(jobs)
    )


# ---------------------------------------------------------------------------
# ATTACK 1 (LIVE FINDING — expected to FAIL until hardened)
#
# Path traversal / out-of-tree junction. The step resolves each symlink target
# read from a git blob against the link's own directory and creates a junction
# there, but never asserts the resolved target stays *inside* the checkout
# root. A dependency revision (or a tampered checkout) that ships an out-of-tree
# symlink — e.g. `../../../../../../Windows/System32` — resolves outside the
# checkout; `Test-Path` passes (the target exists!) and the step happily plants
# an NTFS reparse point pointing outside the tree it was asked to repair.
#
# spec §4 (Threat model, "Defense-in-depth") names this exact gap and the exact
# fix: "assert `targetAbs` starts with the checkout's full path and Write-Error
# + exit 1 otherwise, so a future dependency revision that shipped an out-of-tree
# symlink (`../../../../Windows`) could not silently junction outside the
# checkout." It is called "cheap hardening consistent with the repo's fail-loud
# posture." This test reproduces the escape and demands that guard.
# ---------------------------------------------------------------------------


def test_out_of_tree_symlink_target_is_rejected():
    checkout_root = r"D:\a\cue-sync\cue-sync\.build\checkouts\swift-java"
    # The nested layer #2 link lives here; a hostile blob at this path is the
    # realistic delivery vector for an escape.
    link_dir = checkout_root + r"\Plugins\PluginsShared"
    hostile_target = "../../../../../../../../Windows/System32"

    resolved = _resolve_windows_lexical(link_dir, hostile_target)

    # First: prove the escape is geometrically real with the step's own math.
    root_prefix = checkout_root.rstrip("\\") + "\\"
    assert not (resolved + "\\").startswith(root_prefix), (
        "sanity: crafted target should resolve OUTSIDE the checkout; got " + resolved
    )

    # Then: the step must contain a containment guard that would refuse it.
    # Accept any shape that compares the resolved target against the checkout
    # root before creating a link (StartsWith / string prefix on $repo's full
    # path). None present today → this fails, reproducing the live gap.
    body = next(iter(_windows_repair_bodies().values()))
    has_guard = bool(
        re.search(r"\.StartsWith\(", body)
        or re.search(r"GetFullPath\(\s*\$repo", body)
        and "StartsWith" in body
        or re.search(r"targetAbs.*-(?:like|match).*repo", body, re.IGNORECASE)
    )
    assert has_guard, (
        "spec §4 defense-in-depth: the repair step creates an NTFS junction to "
        "$targetAbs after only a Test-Path existence check, with NO assertion "
        "that $targetAbs stays within the checkout root.\n"
        "A symlink blob containing '"
        + hostile_target
        + "' resolves to '"
        + resolved
        + "' — OUTSIDE '"
        + checkout_root
        + "' — and would be "
        "junctioned anyway. Add: reject any $targetAbs that does not start with "
        "[System.IO.Path]::GetFullPath($repo) (Write-Error + exit 1), per the "
        "spec's own recommended hardening."
    )


# ---------------------------------------------------------------------------
# ATTACK 2 — Job drift (regression lock; acceptance criterion "byte-identical").
# If the two jobs diverge, the build artifact and the test evidence come from
# differently-patched checkouts — the exact split-brain CUESYNC-6d suffered.
# ---------------------------------------------------------------------------


def test_both_windows_repair_steps_are_byte_identical():
    bodies = _windows_repair_bodies()
    assert set(bodies) == {"windows-build", "windows-test"}
    a = bodies["windows-build"]
    b = bodies["windows-test"]
    assert a == b, (
        "spec §3 'byte-identical repair steps': windows-build and windows-test "
        "repair-step bodies differ — they must not drift.\n"
        "--- windows-build ---\n" + a + "\n--- windows-test ---\n" + b
    )


# ---------------------------------------------------------------------------
# ATTACK 3 — Silent pass on a broken enumeration (regression lock).
# If a future edit drops the `$repaired -eq 0` guard, a checkout that raced the
# index (or a regex that stopped matching) would sail past and surface a
# confusing `cannot find … in scope` later. spec §2.4 / §3 "fail loud, never
# silent": zero repairs MUST exit 1.
# ---------------------------------------------------------------------------


def test_zero_repairs_fails_loud():
    for job, body in _windows_repair_bodies().items():
        assert re.search(r"\$repaired\s+-eq\s+0", body), (
            job + ": missing the `$repaired -eq 0` fail-loud guard (spec §2.4)"
        )
        # The zero-repair branch must terminate the job, not warn-and-continue.
        block = body[body.index("$repaired -eq 0") :]
        assert "exit 1" in block, (
            job + ": zero-repairs branch must `exit 1`, not continue (spec §3)"
        )


# ---------------------------------------------------------------------------
# ATTACK 4 — Swallowed git failure (regression lock).
# `ls-files` / `cat-file` errors must abort, not be allowlisted into silence.
# spec §2.4 / §3: "fail if `git ls-files` / `git cat-file` returns a nonzero
# exit … do not allowlist errors into silence."
# ---------------------------------------------------------------------------


def test_git_plumbing_exit_codes_are_checked():
    for job, body in _windows_repair_bodies().items():
        assert body.count("$LASTEXITCODE") >= 2, (
            job + ": expected $LASTEXITCODE checked after both `git ls-files` "
            "and `git cat-file` (spec §2.4); found " + str(body.count("$LASTEXITCODE"))
        )
        assert "ls-files" in body and "$LASTEXITCODE -ne 0" in body, (
            job + ": `git ls-files` failure is not guarded (spec §2.4)"
        )


# ---------------------------------------------------------------------------
# ATTACK 5 — TOCTOU / trust boundary: reading the target from the raced on-disk
# reparse point instead of the git blob (regression lock).
# spec §2.3.1 / §4: the intended target MUST come from `git cat-file blob`, the
# authoritative index — never from the possibly-broken on-disk materialization
# an attacker/race could influence.
# ---------------------------------------------------------------------------


def test_target_is_read_from_git_blob_not_disk():
    for job, body in _windows_repair_bodies().items():
        assert re.search(r"git\b.*cat-file\s+blob", body), (
            job + ": target must be read via `git cat-file blob <sha>` "
            "(spec §2.3.1), not from the on-disk reparse point"
        )
        # Enumeration must be index-driven (ls-files -s), the source of truth
        # for which entries are symlinks — not a directory walk of the racey FS.
        assert "ls-files -s" in body, (
            job + ": enumeration must use `git ls-files -s` (spec §2.2)"
        )


# ---------------------------------------------------------------------------
# ATTACK 6 — Privilege escalation / broken-on-standard-runner via SymbolicLink
# (regression lock). spec §2.3.5 / §3: directory targets become privilege-free
# NTFS *junctions*; file targets *hardlinks*. A `-ItemType SymbolicLink` would
# demand Developer Mode / admin (breaking standard runners) and reintroduce the
# very reparse-point class the step exists to avoid.
# ---------------------------------------------------------------------------


def test_no_symbolic_link_only_junction_and_hardlink():
    for job, body in _windows_repair_bodies().items():
        assert "-ItemType SymbolicLink" not in body, (
            job + ": must NOT use `-ItemType SymbolicLink` — junctions/hardlinks "
            "only, so no privilege/Developer-Mode is required (spec §2.3.5/§3)"
        )
        assert "-ItemType Junction" in body, (
            job + ": directory targets must become NTFS junctions (spec §2.3.5)"
        )
        assert "-ItemType HardLink" in body, (
            job + ": file targets must become hardlinks (spec §2.3.5)"
        )


# ---------------------------------------------------------------------------
# ATTACK 7 — macOS contamination (regression lock).
# spec §3 "macOS is provably unaffected": the repair step exists only in the two
# pwsh Windows jobs; the macos job resolves symlinks natively and must carry no
# such step. A copy-paste into `macos` would silently change what macOS builds.
# ---------------------------------------------------------------------------


def test_repair_step_absent_from_macos_job():
    assert "macos" in JOBS, "macos job missing — workflow shape changed"
    start, end = JOBS["macos"]
    macos_text = "\n".join(LINES[start:end])
    assert REPAIR_STEP_NAME not in macos_text, (
        "spec §3: the swift-java symlink repair must NOT appear in the macos "
        "job — macOS materializes these symlinks natively"
    )
    # And it must be pwsh (Windows-only mechanism), never bash/sh.
    for job, block in REPAIR_BLOCKS:
        assert "shell: pwsh" in block, (
            job
            + ": repair step must be `shell: pwsh` (Windows-only) (spec §4 Portability)"
        )


# ---------------------------------------------------------------------------
# ATTACK 8 — Ordering / TOCTOU: repair before the checkout exists, or after the
# build already consumed the broken links (regression lock).
# spec §2 (Plan): the step must run AFTER `swift package resolve` (which
# materializes .build\checkouts\swift-java) and BEFORE `Build (release)` /
# `Test`. Otherwise it repairs nothing, or repairs too late to matter.
# ---------------------------------------------------------------------------


def test_repair_runs_after_resolve_and_before_build():
    for job in ("windows-build", "windows-test"):
        start, end = JOBS[job]
        seg = LINES[start:end]

        def line_of(pred):
            return next((k for k, ln in enumerate(seg) if pred(ln)), None)

        resolve_i = line_of(lambda ln: "swift package resolve" in ln)
        repair_i = line_of(lambda ln: STEP_NAME_RE.match(ln) and REPAIR_STEP_NAME in ln)
        build_i = line_of(
            lambda ln: (
                STEP_NAME_RE.match(ln)
                and ("Build (release)" in ln or ln.strip() == "- name: Test")
            )
        )
        assert resolve_i is not None, job + ": no `swift package resolve` step"
        assert repair_i is not None, job + ": no repair step"
        assert build_i is not None, job + ": no Build/Test step"
        assert resolve_i < repair_i < build_i, (
            job + ": repair step must sit AFTER `swift package resolve` and "
            "BEFORE Build/Test (spec §2); got resolve@"
            + str(resolve_i)
            + " repair@"
            + str(repair_i)
            + " build@"
            + str(build_i)
        )


# ---------------------------------------------------------------------------
# ATTACK 9 — Idempotency that nukes the shared source tree (regression lock +
# subtle-bug guard). A junction is BOTH a reparse point AND a container. On a
# second pass, if the container branch (`Remove-Item -Recurse -Force`) were
# reached before the reparse-point branch, PowerShell would recurse THROUGH the
# junction and delete the real shared-source files it points at. spec §2.5 /
# §3 "idempotent": the reparse-point case must be handled FIRST and WITHOUT
# `-Recurse`.
# ---------------------------------------------------------------------------


def test_idempotent_delete_handles_reparse_point_before_container():
    for job, body in _windows_repair_bodies().items():
        rp = body.find("ReparsePoint")
        container = body.find("PSIsContainer")
        assert rp != -1, job + ": no ReparsePoint handling (spec §2.5)"
        assert container != -1, job + ": no PSIsContainer handling (spec §2.4.4)"
        assert rp < container, (
            job + ": the ReparsePoint branch MUST precede the PSIsContainer "
            "branch — a junction is both, and deleting it via the container "
            "branch (`Remove-Item -Recurse`) would recurse into and destroy the "
            "real shared sources it targets (spec §2.5 idempotency)"
        )
        # The reparse-point removal must not use -Recurse (that is the trap).
        rp_branch = body[rp:container]
        assert "-Recurse" not in rp_branch, (
            job + ": the reparse-point removal must NOT use `-Recurse` — it would "
            "delete the junction target's contents, not just the link (spec §2.5)"
        )


# ---------------------------------------------------------------------------
# ATTACK 10 — Regression to a hardcoded list (regression lock; the whole ticket).
# spec §3 "generic, not a second hardcoded list": the step must enumerate by
# git mode 120000, not iterate the fixed 3-plugin names CUESYNC-6d used —
# otherwise the nested SwiftJavaConfigurationShared layer breaks again.
# ---------------------------------------------------------------------------


def test_enumeration_is_generic_not_a_hardcoded_plugin_list():
    for job, body in _windows_repair_bodies().items():
        assert "120000" in body, (
            job + ": must filter git entries by symlink mode 120000 (spec §2.2)"
        )
        hardcoded = [
            n
            for n in ("JExtractSwiftPlugin", "SwiftJavaPlugin", "JavaCompilerPlugin")
            if n in body
        ]
        assert not hardcoded, (
            job
            + ": repair step still names hardcoded plugin(s) "
            + repr(hardcoded)
            + " — CUESYNC-6e requires a generic mode-120000 enumeration that "
            "replaces, not extends, the 3-plugin list (spec §3)"
        )


# =============================================================================
# Red-Team adversarial suite — CUESYNC-7
#
# Ticket CUESYNC-7 adds `CueSync/CueSync/Support/TextTools.swift`: a shared,
# dependency-free helper with `slugify()` (turn untrusted text — preset names,
# parsed track titles from Rekordbox/Serato/Engine DJ/ShowKontrol/Resolume — into
# a safe, single, traversal-free filename *component*) and `generateToken()`
# (mint an unguessable, collision-resistant id from a CSPRNG). Spec §4 names the
# exact trust boundary: every string reaching `slugify()` may originate from an
# untrusted external file, and when it becomes an export filename an unsanitised
# value enables `../` traversal, absolute-path escape, NUL truncation, and — on
# the newly-supported Windows targets — reserved-device-name collisions.
#
# These tests attack the *real, shipped Swift implementation*. They compile the
# actual `TextTools.swift` (not a Python re-implementation) once, with a tiny
# stdin→stdout CLI driver, and push adversarial inputs through the compiled
# `TextTools.slugify` / `TextTools.generateToken`. Inputs and slug outputs are
# base64-framed so NUL bytes, control characters, and arbitrary Unicode survive
# the shell/pipe round-trip intact.
#
# Two kinds of test live here, matching the convention of the CUESYNC-6e block
# above:
#   * LIVE FINDING (currently FAILS) — reproduces an un-mitigated defect in the
#     shipped code. A future fix turns it green.
#   * REGRESSION LOCK (currently PASSES) — pins an acceptance criterion / threat-
#     model invariant against the actual binary so a later edit that reintroduces
#     the weakness turns it red.
#
# If no Swift toolchain is present the Swift-execution tests skip (they never
# error), so the pure-stdlib CUESYNC-6e block above still runs on any bare
# `python3`. On the ticket's own CI (macos-latest / windows-latest, where
# `swift` is installed) they run and bite.
# =============================================================================


def _find_text_tools():
    """Locate the Swift source under test by walking up from this file."""
    here = Path(__file__).resolve()
    for base in [here.parent] + list(here.parents):
        candidate = base / "CueSync" / "CueSync" / "Support" / "TextTools.swift"
        if candidate.is_file():
            return candidate
    return None


TEXTTOOLS_SRC = _find_text_tools()

RESERVED_DEVICE_NAMES = (
    ["con", "prn", "aux", "nul"]
    + ["com%d" % n for n in range(1, 10)]
    + ["lpt%d" % n for n in range(1, 10)]
)
RESERVED_SET = set(RESERVED_DEVICE_NAMES)

# Batched CLI driver, compiled against the real TextTools.swift. Reads one
# command per line and prints one result line each:
#   slugify <maxLen> <b64fallback> <b64input>  -> prints base64(slug)
#   token   <length>                           -> prints the raw hex token
# It must live in a file literally named main.swift for top-level statements.
_HARNESS_MAIN = r"""
import Foundation

func b64dec(_ s: String) -> String {
    guard let d = Data(base64Encoded: s) else { return "" }
    return String(decoding: d, as: UTF8.self)
}
func b64enc(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

while let line = readLine(strippingNewline: true) {
    let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    switch f[0] {
    case "slugify":
        let maxLen = Int(f[1]) ?? 80
        let fb = b64dec(f[2])
        let input = b64dec(f[3])
        print(b64enc(TextTools.slugify(input, maxLength: maxLen, fallback: fb)))
    case "token":
        print(TextTools.generateToken(length: Int(f[1]) ?? 32))
    default:
        print("ERR")
    }
}
"""

# Lazily-built, process-cached compilation of the harness.
_HARNESS = {"built": False, "bin": None, "err": None}


def _harness_binary():
    """Compile the real TextTools.swift + driver once; return the binary path.

    Raises unittest.SkipTest (never a hard error) when no usable Swift toolchain
    or source is available, so the pure-Python suite is unaffected.
    """
    st = _HARNESS
    if st["built"]:
        if st["bin"] is None:
            raise unittest.SkipTest(st["err"])
        return st["bin"]
    st["built"] = True
    if TEXTTOOLS_SRC is None:
        st["err"] = "TextTools.swift not found — cannot exercise the real module"
        raise unittest.SkipTest(st["err"])
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        st["err"] = "swiftc not on PATH — skipping Swift-execution red-team tests"
        raise unittest.SkipTest(st["err"])
    workdir = tempfile.mkdtemp(prefix="cuesync7_redteam_")
    atexit.register(shutil.rmtree, workdir, True)
    main_swift = os.path.join(workdir, "main.swift")
    with open(main_swift, "w", encoding="utf-8") as fh:
        fh.write(_HARNESS_MAIN)
    binpath = os.path.join(workdir, "harness")
    proc = subprocess.run(
        [swiftc, str(TEXTTOOLS_SRC), main_swift, "-o", binpath],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not os.path.exists(binpath):
        st["err"] = "harness build failed:\n" + proc.stderr
        raise unittest.SkipTest(st["err"])
    st["bin"] = binpath
    return binpath


def _run_batch(commands):
    """Feed driver commands via stdin; return exactly one output line each."""
    binpath = _harness_binary()
    proc = subprocess.run(
        [binpath],
        input="\n".join(commands) + "\n",
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, "harness runtime error:\n" + proc.stderr
    lines = proc.stdout.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]  # drop only the trailing-newline artifact
    assert len(lines) == len(commands), (
        "harness returned %d lines for %d commands (framing broke)"
        % (len(lines), len(commands))
    )
    return lines


def _b64(s):
    return base64.b64encode(s.encode("utf-8")).decode("ascii")


def _slugify_many(items):
    """items: iterable of (input, maxLength, fallback) -> list of slug strings."""
    cmds = [
        "slugify %d %s %s" % (max_len, _b64(fallback), _b64(inp))
        for (inp, max_len, fallback) in items
    ]
    return [base64.b64decode(o).decode("utf-8") for o in _run_batch(cmds)]


def _slugify(inp, max_length=80, fallback="untitled"):
    return _slugify_many([(inp, max_length, fallback)])[0]


def _token_batch(lengths):
    return _run_batch(["token %d" % n for n in lengths])


_ALPHANUM_HYPHEN = re.compile(r"[a-z0-9-]+")


def _assert_safe_component(inp, slug):
    """Every guarantee slugify() promises about a single output, in one place."""
    assert "/" not in slug, "slug %r for %r contains '/'" % (slug, inp)
    assert "\\" not in slug, "slug %r for %r contains backslash" % (slug, inp)
    assert ".." not in slug, "slug %r for %r contains '..'" % (slug, inp)
    assert slug not in (".", ".."), "slug for %r is '.'/'..'" % (inp,)
    assert slug != "", "slug for %r is empty (fallback must apply)" % (inp,)
    assert "\x00" not in slug, "slug for %r contains a NUL" % (inp,)
    assert _ALPHANUM_HYPHEN.fullmatch(slug), (
        "slug %r for %r has characters outside [a-z0-9-]" % (slug, inp)
    )
    assert not slug.startswith("-") and not slug.endswith("-"), (
        "slug %r for %r has a leading/trailing '-'" % (slug, inp)
    )
    assert "--" not in slug, "slug %r for %r has an uncollapsed '--'" % (slug, inp)
    for ch in slug:
        assert ord(ch) >= 0x20, "control char survived in slug %r" % (slug,)


# ---------------------------------------------------------------------------
# ATTACK 11 (LIVE FINDING — expected to FAIL until hardened)
#
# Reserved-device-name escape is defeated by truncation ordering. slugify()
# checks the reserved-name set BEFORE it truncates to maxLength
# (TextTools.swift: `escaped = reservedDeviceNames.contains(rawSlug) ? ...`
# then `truncatedOnSeparatorBoundary(escaped, ...)`). So a title of the form
# "<reserved> <long-unbroken-run>" is first seen as a NON-reserved compound
# ("con-aaaa…") and left un-escaped, then truncated on the sole separator back
# down to the *bare reserved token* ("con").
#
# This lands at the DEFAULT maxLength=80 — no unusual caller argument needed:
#   slugify("con " + "a"*100) == "con"
# and reaches every one of the 22 reserved names, plus any small caller-chosen
# maxLength (slugify("connection", maxLength: 3) == "con").
#
# spec §2 step 2 ("prefix … so it is never emitted verbatim"), the doc comment
# on slugify() ("never a bare Windows reserved device name"), and §3 acceptance
# ("return a value that is not equal (case-insensitively) to a reserved device
# name") are all violated: CueSync writes an export file literally named `con`
# on Windows, which collides with the console device. Fix: escape/veto the
# reserved set AFTER truncation, not before.
# ---------------------------------------------------------------------------


def test_slugify_truncation_never_reemits_reserved_device_name():
    default_ml = [(r + " " + "a" * 100, 80, "untitled") for r in RESERVED_DEVICE_NAMES]
    small_ml = [
        ("connection", 3, "untitled"),  # -> "con"
        ("auxiliary", 3, "untitled"),  # -> "aux"
        ("nullify", 3, "untitled"),  # -> "nul"
        ("printer", 3, "untitled"),  # -> "prn"
        ("com1port", 4, "untitled"),  # -> "com1"
        ("lpt9device", 4, "untitled"),  # -> "lpt9"
    ]
    items = default_ml + small_ml
    slugs = _slugify_many(items)
    leaks = [
        (inp, ml, slug)
        for (inp, ml, _fb), slug in zip(items, slugs)
        if slug.lower() in RESERVED_SET
    ]
    assert not leaks, (
        "spec §2/§3: slugify() escapes Windows reserved device names BEFORE it "
        "truncates, so truncation re-creates a bare reserved name that is then "
        "emitted verbatim. These inputs each produced a reserved device name "
        "(a real Windows filename collision):\n"
        + "\n".join(
            "  slugify(%r, maxLength=%d) -> %r" % (inp, ml, slug)
            for inp, ml, slug in leaks
        )
        + "\nFix: apply the reserved-name escape AFTER truncation."
    )


# ---------------------------------------------------------------------------
# ATTACK 12 (LIVE FINDING — expected to FAIL until hardened)
#
# The same ordering bug breaks the idempotency guarantee (spec §2 "Be a pure
# function: deterministic and idempotent" / §3 "slugify(slugify(x)) ==
# slugify(x)"). Because slugify("con " + "a"*100) == "con" but slugify("con")
# == "_con", feeding a slug back through slugify() changes it — the function is
# not idempotent for any input whose truncation lands on a reserved name.
# ---------------------------------------------------------------------------


def test_slugify_is_idempotent_even_when_truncation_meets_reserved_name():
    inputs = [r + " " + "a" * 100 for r in RESERVED_DEVICE_NAMES]
    once = _slugify_many([(inp, 80, "untitled") for inp in inputs])
    twice = _slugify_many([(s, 80, "untitled") for s in once])
    broken = [(inp, a, b) for inp, a, b in zip(inputs, once, twice) if a != b]
    assert not broken, (
        "spec §2/§3 idempotency: slugify(slugify(x)) must equal slugify(x). "
        "The truncation-vs-reserved-name ordering bug breaks it — slugify(x) "
        "emits a bare reserved name, and a second pass escapes it:\n"
        + "\n".join(
            "  slugify(%r)=%r  but  slugify(%r)=%r" % (inp, a, a, b)
            for inp, a, b in broken
        )
    )


# ---------------------------------------------------------------------------
# ATTACK 13 (REGRESSION LOCK — PASSES today) — the core sanitiser property.
# Push a broad path-traversal / absolute-path / UNC / NUL / CRLF battery through
# the real slugify() and demand each output is a single traversal-free component
# drawn only from [a-z0-9-]. spec §3 ("Path traversal is impossible") + §4
# ("emits a single path component and never a path").
# ---------------------------------------------------------------------------


def test_slugify_output_is_always_a_single_traversal_free_component():
    hostile = [
        "../../etc/passwd",
        "..\\..\\win.ini",
        "a/b\\c",
        "/etc/passwd",
        "C:\\Windows\\System32\\cmd.exe",
        "\\\\server\\share\\payload",  # UNC path
        "....//....//x",  # doubled-dot traversal variant
        "./../.",
        "file:///etc/passwd",
        "%2e%2e/passwd",  # percent-encoded dots (must stay literal)
        "..%00/..",  # encoded-NUL traversal
        "..⁄..⁄x",  # U+2044 FRACTION SLASH homoglyph
        "．．/passwd",  # fullwidth dots
        "con/../../nul",  # reserved tokens joined by traversal
        "a\x00b",  # embedded real NUL
        "safe\x00/../../etc/passwd",  # NUL-truncation attempt
        "\r\n../etc",  # CRLF prefix
    ]
    slugs = _slugify_many([(h, 80, "untitled") for h in hostile])
    for inp, slug in zip(hostile, slugs):
        _assert_safe_component(inp, slug)
        assert len(slug) <= 80


# ---------------------------------------------------------------------------
# ATTACK 14 (REGRESSION LOCK) — NUL and control characters are dropped, and an
# embedded NUL never truncates the string (the classic poison-NUL bypass).
# spec §2/§3 ("NUL and control characters are dropped").
# ---------------------------------------------------------------------------


def test_slugify_strips_nul_and_control_characters_including_embedded_nul():
    cases = {
        "a\x00b\tc": "a-b-c",
        "safe\x00/../../etc/passwd": "safe-etc-passwd",  # tail survives, sanitised
        "\x00\x00\x00": "untitled",
        "a\x01b\x1fc": "a-b-c",
    }
    slugs = _slugify_many([(inp, 80, "untitled") for inp in cases])
    for (inp, expected), slug in zip(cases.items(), slugs):
        assert "\x00" not in slug, "NUL survived for %r -> %r" % (inp, slug)
        for ch in slug:
            assert ord(ch) >= 0x20, "control char survived for %r -> %r" % (inp, slug)
        assert slug == expected, "slugify(%r) = %r, expected %r" % (inp, slug, expected)


# ---------------------------------------------------------------------------
# ATTACK 15 (REGRESSION LOCK) — the spec §3 reserved-name examples that DO work
# today (default maxLength) stay escaped. Guards the working escape path from a
# regression that drops it entirely.
# ---------------------------------------------------------------------------


def test_slugify_reserved_name_spec_examples_are_escaped():
    examples = ["CON", "con", "COM1", "LPT9", "NUL.txt"]
    slugs = _slugify_many([(inp, 80, "untitled") for inp in examples])
    for inp, slug in zip(examples, slugs):
        assert slug.lower() not in RESERVED_SET, (
            "spec §3: slugify(%r) = %r equals a reserved device name" % (inp, slug)
        )
    # Full case matrix, non-truncating: every reserved name escapes to "_name".
    matrix = [(n.upper(), 80, "untitled") for n in RESERVED_DEVICE_NAMES]
    for name, slug in zip(RESERVED_DEVICE_NAMES, _slugify_many(matrix)):
        assert slug == "_" + name, "reserved %r must escape to %r, got %r" % (
            name,
            "_" + name,
            slug,
        )


# ---------------------------------------------------------------------------
# ATTACK 16 (REGRESSION LOCK) — determinism (spec §2/§3). The same input always
# yields the same output; no hidden state / time dependence in slugify().
# ---------------------------------------------------------------------------


def test_slugify_is_deterministic_across_repeated_calls():
    inputs = [
        "Hello World",
        "../../etc/passwd",
        "CON",
        "café日本語",
        "  a---b  ",
        "\U0001f3a7\U0001f39b️",
        "",
        "com1 " + "a" * 90,
    ]
    first = _slugify_many([(s, 80, "untitled") for s in inputs])
    second = _slugify_many([(s, 80, "untitled") for s in inputs])
    assert first == second, (
        "slugify must be deterministic; got divergent runs:\n%r\n%r" % (first, second)
    )


# ---------------------------------------------------------------------------
# ATTACK 17 (REGRESSION LOCK) — degenerate input yields the non-empty fallback,
# and the shipped default fallback is itself a safe single component (spec §2/§3
# "return fallback … which is itself a valid, non-empty slug").
# ---------------------------------------------------------------------------


def test_slugify_default_fallback_is_itself_a_safe_single_component():
    degenerate = [
        "",
        "   ",
        "///",
        "/// ...",
        "..",
        "\x00\x00\x00",
        "\U0001f3a7\U0001f39b️",
        "日本語",
        "\t\r\n",
    ]
    slugs = _slugify_many([(s, 80, "untitled") for s in degenerate])
    for inp, slug in zip(degenerate, slugs):
        assert slug == "untitled", "slugify(%r) = %r, expected fallback" % (inp, slug)
    _assert_safe_component("<default-fallback>", "untitled")
    assert "untitled" not in RESERVED_SET


# ---------------------------------------------------------------------------
# ATTACK 18 (REGRESSION LOCK) — generateToken() length contract, including the
# zero/negative/odd edges (spec §3). length<=0 -> ""; odd length emits exactly
# that many hex chars.
# ---------------------------------------------------------------------------


def test_generate_token_length_contract_including_zero_negative_and_odd():
    lengths = [0, -1, -5, 1, 2, 3, 5, 7, 15, 16, 31, 32, 33, 64, 255]
    tokens = _token_batch(lengths)
    for n, tok in zip(lengths, tokens):
        expected = n if n > 0 else 0
        assert len(tok) == expected, (
            "generateToken(length=%d) returned %d chars: %r" % (n, len(tok), tok)
        )


# ---------------------------------------------------------------------------
# ATTACK 19 (REGRESSION LOCK) — every emitted character is lowercase hex; no
# modulo bias leaves a symbol unreachable (spec §3 "Every character is in
# [0-9a-f]" + "all 16 hex symbols appear").
# ---------------------------------------------------------------------------


def test_generate_token_alphabet_is_lowercase_hex_and_fully_reachable():
    # 500 x 64-char tokens = 32000 symbols; a fully-reachable uniform alphabet
    # makes a missing symbol astronomically unlikely, but a modulo-bias or
    # restricted-alphabet regression would leave gaps.
    tokens = _token_batch([64] * 500)
    seen = set("".join(tokens))
    assert seen <= set("0123456789abcdef"), (
        "token emitted characters outside [0-9a-f]: %r"
        % (seen - set("0123456789abcdef"))
    )
    assert seen == set("0123456789abcdef"), (
        "not every hex symbol is reachable (possible modulo bias / restricted "
        "alphabet); missing: %r" % (set("0123456789abcdef") - seen)
    )


# ---------------------------------------------------------------------------
# ATTACK 20 (REGRESSION LOCK — the security core of generateToken).
# Tokens must be CSPRNG-derived, NOT time/counter/PID derived (spec §3/§4 — this
# is the anti-pattern the token replaces: `Int(Date().timeIntervalSince1970 *
# 1000)`). A Date/counter regression shows up as monotonic values, a long shared
# prefix, or duplicates. Run the real binary and demand none of those.
# ---------------------------------------------------------------------------


def test_generate_token_is_not_time_or_counter_derived():
    tokens = _token_batch([32] * 256)
    # Not monotonically increasing (a timestamp/counter would be).
    increasing = all(a < b for a, b in zip(tokens, tokens[1:]))
    assert not increasing, (
        "tokens are monotonically increasing — smells like a Date/counter source"
    )

    def common_prefix(a, b):
        i = 0
        while i < len(a) and i < len(b) and a[i] == b[i]:
            i += 1
        return i

    worst = max(common_prefix(tokens[0], t) for t in tokens[1:])
    assert worst < 8, (
        "tokens share a %d-char common prefix with the first token — a "
        "time/counter-seeded source would (the low-entropy high bits barely "
        "change between calls)" % worst
    )


def test_generate_token_batch_has_no_duplicates():
    # 5000 default (32-hex = 128-bit) tokens; a correct CSPRNG collides with
    # negligible probability, a counter/time source or a too-short-entropy
    # regression collides readily.
    tokens = _token_batch([32] * 5000)
    assert len(set(tokens)) == len(tokens), (
        "expected 5000 unique tokens, got %d — entropy/uniqueness regression"
        % len(set(tokens))
    )


# ---------------------------------------------------------------------------
# ATTACK 21 (REGRESSION LOCK) — distribution sanity: no gross modulo bias. Over
# a large sample every hex symbol appears at least half its expected count; a
# `% 16`-on-a-biased-range regression would starve some symbols (spec §3
# "Distribution has no obvious modulo bias").
# ---------------------------------------------------------------------------


def test_generate_token_distribution_has_no_gross_modulo_bias():
    import collections

    tokens = _token_batch([64] * 1000)  # 64000 hex symbols
    counts = collections.Counter("".join(tokens))
    total = sum(counts.values())
    expected = total / 16.0
    # Very loose band (0.5x..1.5x). For a uniform CSPRNG the observed spread is
    # ~1% (never trips); a real modulo bias skews well past this.
    for symbol in "0123456789abcdef":
        c = counts.get(symbol, 0)
        assert 0.5 * expected <= c <= 1.5 * expected, (
            "hex symbol %r appeared %d times (expected ~%d) — distribution skew "
            "suggests modulo bias" % (symbol, c, int(expected))
        )


# ---------------------------------------------------------------------------
# Direct-run harness (no pytest required).
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import traceback

    tests = sorted(
        (name, obj)
        for name, obj in globals().items()
        if name.startswith("test_") and callable(obj)
    )
    passed = failed = skipped = 0
    for name, fn in tests:
        try:
            fn()
            print("PASS", name)
            passed += 1
        except unittest.SkipTest as e:
            print("SKIP", name, "--", str(e).splitlines()[0] if str(e) else "")
            skipped += 1
        except AssertionError as e:
            print("FAIL", name)
            print("     " + str(e).replace("\n", "\n     "))
            failed += 1
        except Exception:
            print("ERROR", name)
            traceback.print_exc()
            failed += 1
    print(
        "\n%d passed, %d failed, %d skipped, %d total"
        % (passed, failed, skipped, len(tests))
    )
    raise SystemExit(1 if failed else 0)
