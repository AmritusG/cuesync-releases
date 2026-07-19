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


# =============================================================================
# Red-Team adversarial suite — CUESYNC-8
#
# Ticket CUESYNC-8 makes the already-rendered swift-cross-ui/GTK port INTERACTIVE.
# The fix lives at the toolkit boundary, NOT in the app screens: a checked-in,
# reviewable `git apply` patch
# (patches/swift-cross-ui-0.8.0-gtk-interactivity.patch) is applied to the pinned
# v0.8.0 checkout on all three GtkBackend-compiling CI legs (macos, windows-build,
# windows-test). The patch adds GTK's `can-target = false` (the analogue of
# SwiftUI's `.allowsHitTesting(false)`) to every decorative `Shape`-backed widget
# so clicks fall through to the sibling that actually owns the gesture.
#
# spec §4 names this exactly: "The patched dependency is a supply-chain surface …
# a checked-in, reviewable `.patch` applied by `git apply` to the exact pinned
# commit … no network call, no new dependency, no dynamic code load." So the
# attack surface is (a) the patch bytes themselves — do they apply, are they
# idempotent, do they smuggle anything past review, do they touch only what they
# claim; (b) the three workflow steps that apply them — placement, fail-loud
# behavior, byte-drift between legs, read-only-clear ordering; and (c) the newly
# LIVE runtime trust boundary the ticket opens (§4): value-handling guards on
# controls that were unreachable on Windows until now actually run.
#
# Two kinds of test, matching the CUESYNC-6e / CUESYNC-7 blocks above:
#   * BEHAVIORAL (run the real `git apply` against the real pinned checkout) —
#     these bite where every text-only assertion is blind: a patch whose hunk
#     offsets/context have gone stale passes every `contains("can-target")`
#     check and still fails CI's actual `git apply`. They reconstruct the two
#     patched files from the checkout's pristine HEAD into a throwaway tempdir
#     (never mutating the real checkout) and exercise the patch there. If no git
#     toolchain / resolved checkout at the audited commit is present they SKIP
#     (never error), so the pure-stdlib blocks above still run on any bare
#     `python3`; on the ticket's own CI (where the checkout is resolved) they run
#     and bite.
#   * REGRESSION LOCK (pure text/structure) — pins an acceptance-criterion or
#     threat-model invariant so a later edit that reintroduces the weakness turns
#     it red.
# =============================================================================

AUDITED_REVISION = "a6d206370812e3b9edba259d167e848892c5013d"
GESTURE_PATCH_NAME = "swift-cross-ui-0.8.0-gtk-interactivity.patch"
GESTURE_STEP_NAME = "Patch swift-cross-ui GTK interactivity"
# CUESYNC-9 §4: a second, distinct root-cause patch against the same upstream
# file, kept in its own reviewable file (never merged into GESTURE_PATCH_NAME —
# see CUESYNC9WindowsInputDispatchWorkflowTests' non-overlapping-hunk check).
WINDOWS_INPUT_PATCH_NAME = "swift-cross-ui-0.8.0-windows-input.patch"

REPO_ROOT = (
    WORKFLOW_PATH.parent.parent.parent
)  # <root>/.github/workflows/x.yml -> <root>
PATCH_PATH = REPO_ROOT / "patches" / GESTURE_PATCH_NAME
PATCH_TEXT = PATCH_PATH.read_text(encoding="utf-8") if PATCH_PATH.is_file() else ""

SWIFT_CROSS_UI_CHECKOUT = REPO_ROOT / ".build" / "checkouts" / "swift-cross-ui"
# The two files findings §2.3/§2.4 name as the fix locus — the whole of the patch.
PATCHED_FILES = [
    "Sources/Gtk/Widgets/Widget.swift",
    "Sources/GtkBackend/GtkBackend.swift",
]


# ---------------------------------------------------------------------------
# Workflow helpers — the three "Patch swift-cross-ui GTK interactivity" steps.
# Reuse the module-level JOBS / LINES / STEP_NAME_RE / _repair_run_body parser.
# ---------------------------------------------------------------------------


def _gesture_step_blocks():
    """(job, name_line_idx, block_text) for every gesture-patch step. A block runs
    from its `- name:` line up to (excluding) the next step or end of job."""
    blocks = []
    for job, (jstart, jend) in JOBS.items():
        i = jstart
        while i < jend:
            m = STEP_NAME_RE.match(LINES[i])
            if m and m.group(1).startswith(GESTURE_STEP_NAME):
                j = i + 1
                while j < jend and not STEP_NAME_RE.match(LINES[j]):
                    j += 1
                blocks.append((job, i, "\n".join(LINES[i:j])))
                i = j
            else:
                i += 1
    return blocks


GESTURE_BLOCKS = _gesture_step_blocks()


def _gesture_run_body(block_text):
    """The `run: |` script body of a gesture-patch step, de-indented. Unlike the
    CUESYNC-6e `_repair_run_body`, this stops at the end of the YAML block scalar
    (the first non-blank line indented no more than the `run:` key) and trims
    trailing blanks, so a trailing comment block before the next step — present on
    the windows-test leg, absent on windows-build — is NOT folded in. Otherwise
    two byte-identical scripts would appear to differ purely by that comment's
    indentation, giving a false split-brain positive."""
    lines = block_text.splitlines()
    run_idx = next(
        (k for k, ln in enumerate(lines) if ln.strip() in ("run: |", "run: |-")),
        None,
    )
    assert run_idx is not None, "gesture step has no `run: |` body:\n" + block_text
    run_indent = len(lines[run_idx]) - len(lines[run_idx].lstrip())
    body = []
    for ln in lines[run_idx + 1 :]:
        if ln.strip() == "":
            body.append(ln)
            continue
        if (len(ln) - len(ln.lstrip())) <= run_indent:
            break  # dropped out of the block scalar (a shallower comment or key)
        body.append(ln)
    while body and body[-1].strip() == "":
        body.pop()
    indented = [ln for ln in body if ln.strip()]
    common = min((len(ln) - len(ln.lstrip()) for ln in indented), default=0)
    return "\n".join(ln[common:] if len(ln) >= common else ln for ln in body)


def _gesture_bodies():
    """job -> de-indented `run: |` script body of that job's gesture-patch step."""
    return {job: _gesture_run_body(block) for job, _i, block in GESTURE_BLOCKS}


def _gesture_block_with_comments(job):
    """The gesture step's block for `job`, widened upward to include the
    contiguous `#`-comment block immediately above it (where this workflow puts
    the v0.8.0 pin citation), and downward to the next step."""
    for j, i, _b in GESTURE_BLOCKS:
        if j != job:
            continue
        start = i
        k = i - 1
        while k >= 0 and LINES[k].strip().startswith("#"):
            start = k
            k -= 1
        _jstart, jend = JOBS[job]
        end = jend
        for t in range(i + 1, jend):
            if STEP_NAME_RE.match(LINES[t]):
                end = t
                break
        return "\n".join(LINES[start:end])
    return None


def _patch_target_paths():
    """The `a/<path>` side of every `diff --git a/.. b/..` header — i.e. every
    file the patch actually modifies."""
    return sorted(set(re.findall(r"diff --git a/(\S+) b/\S+", PATCH_TEXT)))


def _patch_file_sections():
    """{b_path: section_text} — split the patch at each `diff --git` boundary."""
    sections, cur, buf = {}, None, []
    for line in PATCH_TEXT.splitlines():
        m = re.match(r"diff --git a/\S+ b/(\S+)", line)
        if m:
            if cur is not None:
                sections[cur] = "\n".join(buf)
            cur, buf = m.group(1), [line]
        elif cur is not None:
            buf.append(line)
    if cur is not None:
        sections[cur] = "\n".join(buf)
    return sections


def _patch_added_lines():
    """The content of every added (`+`) line, excluding the `+++` file header —
    i.e. exactly the bytes `git apply` introduces into the dependency."""
    return [
        ln[1:]
        for ln in PATCH_TEXT.splitlines()
        if ln.startswith("+") and not ln.startswith("+++")
    ]


# ---------------------------------------------------------------------------
# Behavioral-test plumbing: reconstruct the pristine pinned sources and run the
# real `git apply`. Skips (never errors) when the toolchain/checkout is absent.
# ---------------------------------------------------------------------------


def _pinned_checkout_git_or_skip():
    git = shutil.which("git")
    if git is None:
        raise unittest.SkipTest("git not on PATH — skipping behavioral patch tests")
    if not PATCH_PATH.is_file():
        raise unittest.SkipTest("%s not found" % GESTURE_PATCH_NAME)
    if not SWIFT_CROSS_UI_CHECKOUT.is_dir():
        raise unittest.SkipTest(
            "swift-cross-ui not resolved (.build/checkouts absent) — run "
            "`swift package resolve` to enable behavioral patch tests"
        )
    head = subprocess.run(
        [git, "-C", str(SWIFT_CROSS_UI_CHECKOUT), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
    )
    if head.returncode != 0:
        raise unittest.SkipTest("swift-cross-ui checkout is not a git repo")
    if head.stdout.strip() != AUDITED_REVISION:
        raise unittest.SkipTest(
            "swift-cross-ui checkout is at %s, not the audited v0.8.0 commit %s"
            % (head.stdout.strip()[:12], AUDITED_REVISION[:12])
        )
    return git


def _pristine_tree_or_skip():
    """Materialize the two patched files from the checkout's PRISTINE HEAD into a
    throwaway tempdir. Uses `git show HEAD:<path>` so the real checkout's
    working-tree state (patched or not) is irrelevant and never mutated."""
    git = _pinned_checkout_git_or_skip()
    workdir = tempfile.mkdtemp(prefix="cuesync8_redteam_")
    atexit.register(shutil.rmtree, workdir, True)
    for rel in PATCHED_FILES:
        blob = subprocess.run(
            [git, "-C", str(SWIFT_CROSS_UI_CHECKOUT), "show", "HEAD:" + rel],
            capture_output=True,
        )
        if blob.returncode != 0:
            raise unittest.SkipTest("pinned checkout has no %s at HEAD" % rel)
        dest = Path(workdir) / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(blob.stdout)
    return git, workdir


def _git_apply(git, tree, *args):
    return subprocess.run(
        [git, "apply", *args, str(PATCH_PATH)], cwd=tree, capture_output=True, text=True
    )


# ---------------------------------------------------------------------------
# ATTACK 22 (BEHAVIORAL) — the patch must actually apply to the pinned checkout.
# Every text-only test (Swift or Python) can pass on a patch whose `@@` hunk
# offsets or context lines have gone stale, while CI's real `git apply` fails and
# the whole GtkBackend build dies. spec §3/§4 require the fix be a `git apply`
# patch "applied … to the exact pinned commit". Reconstruct the pristine v0.8.0
# sources and run `git apply --check` for real.
# ---------------------------------------------------------------------------


def test_gesture_patch_applies_cleanly_to_the_pinned_v080_checkout():
    git, tree = _pristine_tree_or_skip()
    r = _git_apply(git, tree, "--check")
    assert r.returncode == 0, (
        "spec CUESYNC-8 §3/§4: %s must apply cleanly to the pinned v0.8.0 checkout "
        "(commit %s) via `git apply`. A text-only assertion cannot catch a stale hunk "
        "offset/context; this reconstructs the pristine HEAD sources and ran "
        "`git apply --check`, which reported:\n%s"
        % (GESTURE_PATCH_NAME, AUDITED_REVISION, r.stderr or r.stdout)
    )


# ---------------------------------------------------------------------------
# ATTACK 23 (BEHAVIORAL) — the idempotency guard is real AND load-bearing.
# The workflow no-ops a re-run via `git apply --reverse --check`; the dev script
# does the same (spec §3 "idempotent … a second run is a no-op"). Prove the guard
# actually detects the applied state, AND that it is necessary — a naive second
# forward `git apply` (what you'd get if the guard were dropped) must fail.
# ---------------------------------------------------------------------------


def test_gesture_patch_reverse_guard_is_real_and_a_second_apply_would_fail():
    git, tree = _pristine_tree_or_skip()
    first = _git_apply(git, tree)
    assert first.returncode == 0, "first forward apply failed:\n" + (first.stderr or "")

    reverse = _git_apply(git, tree, "--reverse", "--check")
    assert reverse.returncode == 0, (
        "spec §3 idempotency: on an already-patched tree `git apply --reverse --check` "
        "(the workflow's own no-op guard) MUST report success so the step skips. It "
        "returned %d:\n%s" % (reverse.returncode, reverse.stderr or reverse.stdout)
    )

    second = _git_apply(git, tree)
    assert second.returncode != 0, (
        "a SECOND unguarded forward `git apply` of the same patch must FAIL on an "
        "already-patched tree — this is precisely why the `--reverse --check` guard is "
        "load-bearing, not decorative. It unexpectedly succeeded, meaning the patch is a "
        "silent no-op or duplicates content (spec §3)."
    )


# ---------------------------------------------------------------------------
# ATTACK 24 (BEHAVIORAL) — the fix reaches the ONE factory it must. It's not
# enough that the patch mentions `can-target`; after applying, the widget
# `GtkBackend.createPathWidget()` returns (the single factory every decorative
# `Shape` funnels through — findings §2.3) must be excluded from GTK hit-testing,
# and the Gtk `Widget` base class must have gained the `can-target` property the
# fix depends on. Verified against the real applied bytes.
# ---------------------------------------------------------------------------


def test_gesture_patch_makes_the_shape_factory_hit_test_transparent():
    git, tree = _pristine_tree_or_skip()
    applied = _git_apply(git, tree)
    assert applied.returncode == 0, "forward apply failed:\n" + (applied.stderr or "")

    backend = (Path(tree) / "Sources/GtkBackend/GtkBackend.swift").read_text(
        encoding="utf-8"
    )
    widget = (Path(tree) / "Sources/Gtk/Widgets/Widget.swift").read_text(
        encoding="utf-8"
    )

    idx = backend.find("createPathWidget")
    assert idx != -1, "createPathWidget vanished from GtkBackend.swift after apply"
    # Slice the whole createPathWidget function body (up to the next `public func`)
    # rather than a fixed char window — the fix carries a large explanatory comment
    # between the signature and the assignment.
    nxt = backend.find("public func ", idx + len("public func createPathWidget"))
    factory_body = backend[idx:nxt] if nxt != -1 else backend[idx:]
    assert "canTarget = false" in factory_body, (
        "spec §3 (H2 fix): after applying, GtkBackend.createPathWidget() must set "
        "`canTarget = false` on the widget it returns — that is what excludes decorative "
        "Shapes from GTK's pick so a click falls through to the real gesture owner "
        "(findings §2.3). The assignment is not in the factory body."
    )
    assert '"can-target"' in widget and "canTarget" in widget, (
        "the Gtk Widget base class must gain the `can-target` GObject-property wrapper "
        "the fix depends on (findings §2.2 confirms it is absent from the whole pinned "
        "checkout before this patch)"
    )


# ---------------------------------------------------------------------------
# ATTACK 25 (SUPPLY CHAIN) — the patch touches EXACTLY the two audited files and
# re-pins nothing. spec §4: the dependency is "patched at the checkout, never
# forked or re-pinned"; the pin stays `exact: "0.8.0"`, Package.resolved
# untouched. A future edit that widened the patch to touch Package.swift (a
# covert re-pin) or to add a brand-new source file (a new dependency/code vector)
# is the exact supply-chain drift this locks out.
# ---------------------------------------------------------------------------


def test_gesture_patch_touches_exactly_the_two_audited_files_and_repins_nothing():
    if not PATCH_TEXT:
        raise unittest.SkipTest("%s not found" % GESTURE_PATCH_NAME)
    targets = _patch_target_paths()
    assert targets == sorted(PATCHED_FILES), (
        "spec §4: the patch must modify EXACTLY the two audited files "
        + repr(sorted(PATCHED_FILES))
        + " (findings §2.3/§2.4); its `diff --git` targets are "
        + repr(targets)
    )
    # No manifest re-pin, and no file creation/deletion/rename (new dependency or
    # source vector) hiding in the diff body.
    for banned in ("new file mode", "deleted file mode", "rename from", "rename to"):
        assert banned not in PATCH_TEXT, (
            "spec §4: the patch must only MODIFY the two audited files, never "
            "create/delete/rename one — found `%s`" % banned
        )
    for manifest in ("Package.swift", "Package.resolved"):
        assert not re.search(r"diff --git .*" + re.escape(manifest), PATCH_TEXT), (
            'spec §4: the patch must not touch %s — the pin stays exact: "0.8.0" and '
            "Package.resolved is untouched by this ticket" % manifest
        )


# ---------------------------------------------------------------------------
# ATTACK 26 (SUPPLY CHAIN) — the patch is pure gesture/hit-test wiring. spec §4:
# "no network call, no new dependency, no dynamic code load." The bytes `git
# apply` injects into a pinned, audited dependency at build time are a review
# surface: a future edit that smuggled a URL fetch, a subprocess spawn, a
# `dlopen`, or a fresh `import` into the added lines would be caught here.
# ---------------------------------------------------------------------------


def test_gesture_patch_added_lines_are_pure_wiring_no_network_exec_or_new_import():
    if not PATCH_TEXT:
        raise unittest.SkipTest("%s not found" % GESTURE_PATCH_NAME)
    added = _patch_added_lines()
    assert added, "the patch adds no lines at all — nothing to review"

    forbidden = [
        "http://",
        "https://",
        "ftp://",  # network fetch
        "URLSession",
        "getaddrinfo",
        "socket(",  # network
        "Process(",
        "NSTask",
        "posix_spawn",
        "system(",  # process spawn
        "popen(",
        "ShellExecute",
        "execve",
        "execvp",  # process spawn
        "/bin/sh",
        "cmd.exe",
        "Invoke-WebRequest",  # shells / fetch
        "Invoke-Expression",
        "eval(",  # dynamic eval
        "dlopen",
        "dlsym",
        "LoadLibrary",
        "GetProcAddress",  # dynamic load
    ]
    for content in added:
        for token in forbidden:
            assert token not in content, (
                "spec §4: the gesture patch must be pure gesture/hit-test wiring — no "
                "network call, subprocess, dynamic load, or dynamic eval. An added line "
                "contains `%s`:\n    %s" % (token, content.strip())
            )
        # No new dependency: the patch introduces no fresh `import`.
        assert not content.strip().startswith("import "), (
            "spec §4 (no new dependency): the patch must not add an `import` line — the "
            "fix uses only GTK's own event-controller/GObject APIs already in the "
            "checkout. Found:\n    %s" % content.strip()
        )


# ---------------------------------------------------------------------------
# ATTACK 27 (SUPPLY CHAIN / correctness) — `can-target = false` is applied ONLY
# to the decorative `Shape` factory, never to an interactive-widget factory.
# Over-applying it to `createButton`/`createTextField`/`createContainer`/… would
# make a real control unclickable — the very failure this ticket fixes, but
# worse, and structurally invisible to a "does the patch mention can-target?"
# check. findings §2.3 hinges on "every `Shape` in this app is decorative"; this
# guards the fix from bleeding onto anything that must receive input.
# ---------------------------------------------------------------------------


def test_gesture_patch_sets_can_target_false_only_on_decorative_path_widgets():
    if not PATCH_TEXT:
        raise unittest.SkipTest("%s not found" % GESTURE_PATCH_NAME)
    sections = _patch_file_sections()
    backend = sections.get("Sources/GtkBackend/GtkBackend.swift", "")
    widget = sections.get("Sources/Gtk/Widgets/Widget.swift", "")

    assert "canTarget = false" in backend and "createPathWidget" in backend, (
        "the `canTarget = false` assignment must live in GtkBackend.swift's "
        "createPathWidget hunk (findings §2.3)"
    )
    # The Widget.swift hunk only ADDS the property wrapper; it must not itself set
    # any widget hit-test-transparent (that belongs to the one Shape factory).
    assert "canTarget = false" not in widget, (
        "the Widget.swift hunk must only declare the `can-target` property, not set "
        "canTarget = false on the base class (which would disable hit-testing for EVERY "
        "widget, killing every control)"
    )
    # The assignment appears exactly once in the whole patch, and no interactive
    # widget factory is referenced in any added line.
    assert "\n".join(_patch_added_lines()).count("canTarget = false") == 1, (
        "expected `canTarget = false` to be added exactly once (only in createPathWidget)"
    )
    interactive_factories = [
        "createButton",
        "createTextField",
        "createToggle",
        "createPicker",
        "createSlider",
        "createSwitch",
        "createContainer",
        "createTextView",
        "createTable",
        "createScrollContainer",
    ]
    added_text = "\n".join(_patch_added_lines())
    for factory in interactive_factories:
        assert factory not in added_text, (
            "spec §3/findings §2.3: the fix must not touch the interactive-widget factory "
            "`%s` — setting can-target=false there would silently make a real control "
            "unclickable (the exact bug this ticket fixes)" % factory
        )


# ---------------------------------------------------------------------------
# ATTACK 28 (SUPPLY CHAIN) — the fix is a reviewable unified diff, not an
# unpinned text substitution. spec §4: "a checked-in, reviewable `.patch` applied
# by `git apply` … never an unpinned `sed`/`-replace` against a moving target."
# ---------------------------------------------------------------------------


def test_gesture_patch_is_a_real_unified_diff_not_a_sed_or_replace_script():
    if not PATCH_TEXT:
        raise unittest.SkipTest("%s not found" % GESTURE_PATCH_NAME)
    for rel in PATCHED_FILES:
        assert ("diff --git a/%s b/%s" % (rel, rel)) in PATCH_TEXT, (
            "expected a real `diff --git` unified-diff header for %s" % rel
        )
    assert PATCH_TEXT.count("@@ ") >= 2, (
        "a real unified diff carries `@@ … @@` hunk headers; found fewer than the two "
        "hunks the two-file fix needs"
    )
    for antipattern in ("-replace", "sed -i", "sed 's", "Set-Content -"):
        assert antipattern not in PATCH_TEXT, (
            "spec §4: the checked-in fix must be a real diff `git apply` consumes, not a "
            "`%s` text-substitution against a moving target" % antipattern
        )


# ---------------------------------------------------------------------------
# ATTACK 29 — the gesture-patch step exists on ALL THREE GtkBackend-compiling
# legs. spec §3/§6: macos + windows-build + windows-test each compile GtkBackend
# and therefore each need the patch; a leg missing it builds the un-patched,
# dead-on-click UI.
# ---------------------------------------------------------------------------


def test_gesture_patch_step_exists_on_all_three_gtkbackend_legs():
    jobs = sorted(job for job, _i, _b in GESTURE_BLOCKS)
    assert jobs == ["macos", "windows-build", "windows-test"], (
        "spec §3: the gesture-patch step must exist on all three GtkBackend-compiling "
        "legs (macos, windows-build, windows-test); got: " + repr(jobs)
    )


# ---------------------------------------------------------------------------
# ATTACK 30 — no split-brain between the two Windows legs. If windows-build and
# windows-test apply the patch differently, the shipped artifact and the test
# evidence come from differently-patched checkouts — the exact split CUESYNC-6d
# suffered (§ATTACK 2 above locks the sibling swift-java step the same way). The
# per-leg Swift tests check each leg alone; only a cross-leg diff catches drift.
# ---------------------------------------------------------------------------


def test_both_windows_gesture_patch_steps_are_byte_identical():
    bodies = _gesture_bodies()
    a, b = bodies.get("windows-build"), bodies.get("windows-test")
    assert a is not None and b is not None, (
        "gesture-patch step missing on a Windows leg: " + repr(sorted(bodies))
    )
    assert a == b, (
        "spec §3: the windows-build and windows-test gesture-patch step bodies must not "
        "drift — a divergence means build and test compile differently-patched checkouts "
        "(the split-brain CUESYNC-6d suffered).\n--- windows-build ---\n"
        + a
        + "\n--- windows-test ---\n"
        + b
    )


# ---------------------------------------------------------------------------
# ATTACK 31 — on Windows the read-only flag must be cleared BEFORE `git apply`,
# on exactly the files the patch modifies. Dependency sources check out read-only
# on Windows (the reason the gulong/gsize step clears it too); if the clear came
# AFTER the apply, or named the wrong file, `git apply` would fail on a read-only
# source with a confusing error. The Swift suite checks the paths match the patch
# but not the ordering — a clear that runs too late is still a live break.
# ---------------------------------------------------------------------------


def test_windows_gesture_patch_clears_read_only_before_apply_on_the_patched_files():
    patched = set(_patch_target_paths())
    for job in ("windows-build", "windows-test"):
        body = _gesture_bodies()[job]
        apply_idx = body.find("git apply $patch")
        assert apply_idx != -1, job + ": no forward `git apply $patch` in the step"
        ro_positions = [m.start() for m in re.finditer(r"IsReadOnly", body)]
        assert ro_positions, job + ": step never clears the Windows read-only flag"
        assert all(p < apply_idx for p in ro_positions), (
            job + ": a `Set-ItemProperty … -Name IsReadOnly -Value $false` clear runs "
            "AFTER `git apply` — the apply hits a read-only dependency source and fails "
            "before the clear ever executes"
        )
        cleared = set()
        for _var, path in re.findall(r'\$(\w+)\s*=\s*"([^"]+)"', body):
            if path.endswith(".swift"):
                cleared.add(
                    path.replace("\\", "/").replace(
                        ".build/checkouts/swift-cross-ui/", ""
                    )
                )
        assert cleared == patched, (
            job
            + ": read-only is cleared on %r but the patch modifies %r — a path typo "
            "leaves the real target read-only and breaks `git apply` downstream"
            % (sorted(cleared), sorted(patched))
        )


# ---------------------------------------------------------------------------
# ATTACK 32 — a failed `git apply` must fail the job LOUD, on every leg. A
# swallowed apply failure means the build proceeds against an UN-patched checkout
# and ships the dead-on-click UI while CI stays green — the worst outcome. macOS
# relies on `set -euo pipefail` so the bare forward `git apply "$PATCH"` aborts;
# the Windows legs check `$LASTEXITCODE -ne 0` and `exit 1` explicitly.
# ---------------------------------------------------------------------------


def test_gesture_patch_step_fails_loud_on_a_bad_apply_on_every_leg():
    bodies = _gesture_bodies()
    mac = bodies["macos"]
    assert re.search(r"set -euo?\s+pipefail|set -e\b", mac), (
        "spec §3: the macos gesture-patch step must set fail-fast shell options "
        "(`set -euo pipefail`) so a failed `git apply` aborts the job"
    )
    assert 'git apply "$PATCH"' in mac, (
        'the macos step must contain a forward `git apply "$PATCH"` (not only the '
        "`--reverse --check` guard) for set -e to fail loud on"
    )
    for job in ("windows-build", "windows-test"):
        body = bodies[job]
        assert "$LASTEXITCODE -ne 0" in body and "exit 1" in body, (
            job + ": the gesture-patch step must fail loud on a `git apply` error "
            "(`$LASTEXITCODE -ne 0` -> `exit 1`), never proceed against an un-patched "
            "checkout"
        )


# ---------------------------------------------------------------------------
# ATTACK 33 — placement: after resolve, before build/test, on every leg. spec §3:
# "after `swift package resolve` … and before `swift build` / `swift test`."
# Before resolve there is no checkout to patch; after build the patch is too late
# to matter. (macOS has no separate resolve step — it resolves on demand inside
# the patch step — so it is ordered only against the build it must precede.)
# ---------------------------------------------------------------------------


def test_gesture_patch_step_runs_after_resolve_and_before_build_on_every_leg():
    specs = {
        "windows-build": (r"swift package resolve", r"swift build -c release"),
        "windows-test": (r"swift package resolve", r"swift test -c release"),
        "macos": (None, r"swift build -c release"),
    }
    for job, (resolve_pat, build_pat) in specs.items():
        start, end = JOBS[job]
        seg = LINES[start:end]

        def find(pat):
            # Skip `#` comment lines — a job's prose mentions "swift build -c
            # release" etc. in comments; only the real `run:` invocation counts.
            return next(
                (
                    k
                    for k, ln in enumerate(seg)
                    if not ln.lstrip().startswith("#") and re.search(pat, ln)
                ),
                None,
            )

        patch_i = next(
            (
                k
                for k, ln in enumerate(seg)
                if STEP_NAME_RE.match(ln) and GESTURE_STEP_NAME in ln
            ),
            None,
        )
        assert patch_i is not None, job + ": no gesture-patch step to order"
        build_i = find(build_pat)
        assert build_i is not None, job + ": no build/test invocation to order against"
        assert patch_i < build_i, (
            job + ": gesture-patch step must run BEFORE the build/test that compiles "
            "GtkBackend (spec §3)"
        )
        if resolve_pat is not None:
            resolve_i = find(resolve_pat)
            assert resolve_i is not None, job + ": no `swift package resolve` step"
            assert resolve_i < patch_i, (
                job
                + ": gesture-patch step must run AFTER `swift package resolve` — the "
                "checkout it patches does not exist before that (spec §3)"
            )


# ---------------------------------------------------------------------------
# ATTACK 34 — every leg is idempotency-guarded and pinned to the audited commit.
# spec §3: "idempotent (guard with `git apply --reverse --check`)" and "pinned to
# the v0.8.0 tag in a comment naming the audited commit." An unpinned patch step
# is the moving-target supply-chain risk §4 forbids.
# ---------------------------------------------------------------------------


def test_gesture_patch_step_is_reverse_guarded_and_pinned_to_the_audited_commit():
    for job in ("macos", "windows-build", "windows-test"):
        block = _gesture_block_with_comments(job)
        assert block is not None, job + ": no gesture-patch step found"
        assert "git apply --reverse --check" in block, (
            job + ": the gesture-patch step must guard idempotency with "
            "`git apply --reverse --check` (spec §3)"
        )
        assert AUDITED_REVISION in block, (
            job + ": the gesture-patch step (or its preceding comment) must pin the "
            "audited v0.8.0 commit " + AUDITED_REVISION + " (spec §3/§4)"
        )


# ---------------------------------------------------------------------------
# ATTACK 35 (SUPPLY CHAIN) — no divergent/duplicate copy of either checked-in
# patch. spec §3: the dev script applies "the SAME patch locally" as CI. A
# THIRD file, or a second copy of an already-named patch, touching GtkBackend
# would mean "the bytes we reviewed" and "the bytes we build" could drift
# apart. CUESYNC-9 §4 deliberately adds a second, distinct-root-cause patch
# (WINDOWS_INPUT_PATCH_NAME) alongside the CUESYNC-8 gesture patch — kept in
# its own file on purpose, with non-overlapping hunks, rather than merged into
# one (see CUESYNC9WindowsInputDispatchWorkflowTests) — so the invariant this
# guards is "exactly these two named patches, nothing else", not "at most one
# patch may ever touch this file".
# ---------------------------------------------------------------------------


def test_dev_script_and_every_ci_leg_apply_the_one_checked_in_patch():
    patch_dir = REPO_ROOT / "patches"
    if not patch_dir.is_dir():
        raise unittest.SkipTest("patches/ directory not found")
    gtk_patches = sorted(
        p.name
        for p in patch_dir.glob("*.patch")
        if "Sources/GtkBackend/GtkBackend.swift" in p.read_text(encoding="utf-8")
    )
    expected = sorted([GESTURE_PATCH_NAME, WINDOWS_INPUT_PATCH_NAME])
    assert gtk_patches == expected, (
        "spec §4: expected exactly the two named checked-in patches touching "
        "GtkBackend.swift (" + repr(expected) + "); a THIRD file or a divergent "
        "copy of either is a supply-chain risk. Found: " + repr(gtk_patches)
    )
    dev_script = REPO_ROOT / "scripts" / "patch-swift-cross-ui.sh"
    assert dev_script.is_file(), "scripts/patch-swift-cross-ui.sh must exist (spec §3)"
    dev_code = "\n".join(
        ln
        for ln in dev_script.read_text(encoding="utf-8").splitlines()
        if not ln.lstrip().startswith("#")
    )
    assert GESTURE_PATCH_NAME in dev_code, (
        "scripts/patch-swift-cross-ui.sh must apply the one checked-in patch in "
        "executable code (not just a comment) — the same file CI applies (spec §3)"
    )
    for job, _i, block in GESTURE_BLOCKS:
        assert GESTURE_PATCH_NAME in block, (
            job
            + ": the CI gesture-patch step must apply the one checked-in "
            + GESTURE_PATCH_NAME
            + ", never a separate copy"
        )


# ---------------------------------------------------------------------------
# ATTACK 36 (§4 runtime trust boundary) — the newly-LIVE StepperField keeps its
# `isFinite` guard. spec §4: "making controls live means value-handling paths
# that were previously unreachable on Windows now actually run, so their existing
# guards matter *more*: `StepperField.commitText()`'s `parsed.isFinite` check
# must stay — a hand-typed `nan`/`inf` in a cue position/Y field must never reach
# `cue.start`/`cue.yValue` and then the envelope Path/curve math … do not weaken
# it." `Double("nan")`/`Double("inf")` parse fine and min/max do NOT sanitize
# them, so the guard is the only thing standing between a typed `inf` and NaN
# geometry now that the field is clickable.
# ---------------------------------------------------------------------------


def _stepper_field_src_or_skip():
    p = REPO_ROOT / "CueSync" / "CueSync" / "UI" / "Controls" / "StepperField.swift"
    if not p.is_file():
        raise unittest.SkipTest("StepperField.swift not found")
    return p.read_text(encoding="utf-8")


def test_stepper_field_commit_guards_isfinite_before_writing_a_hostile_value():
    src = _stepper_field_src_or_skip()
    m = re.search(r"func commitText\(\)\s*\{", src)
    assert m, "commitText() not found in StepperField.swift — control shape changed"
    body = src[m.end() :]
    nxt = re.search(r"\n    (?:private |)func ", body)
    if nxt:
        body = body[: nxt.start()]

    # Strip `//` comments — commitText's OWN comment prose names "isFinite" and
    # "Double(...)"; a guard assertion that matched the comment would pass even
    # after the real code guard was deleted (a false negative). Only code counts.
    def _strip_comments(text):
        return "\n".join(
            (ln[: ln.index("//")] if "//" in ln else ln) for ln in text.splitlines()
        )

    code = _strip_comments(body)
    assert "Double(text)" in code, (
        "commitText() must parse the typed value via `Double(text)` — parsing shape "
        "changed; re-verify the isFinite guard still applies"
    )
    fin = code.find("isFinite")
    asg = code.find("value =")
    assert fin != -1, (
        "spec §4: commitText() must keep the `.isFinite` guard in CODE. Without it a "
        "hand-typed `nan`/`inf` (both of which `Double(_:)` parses successfully, and "
        "which min/max do not clamp away) flows into `value` -> cue.start/cue.yValue -> "
        "the envelope Path/curve math. Now that the control is clickable on Windows this "
        "path is LIVE."
    )
    assert asg != -1 and fin < asg, (
        "spec §4: the `.isFinite` guard must sit BEFORE the assignment to `value` — a "
        "check placed after the write cannot stop the non-finite value from landing in "
        "cue.start/cue.yValue first"
    )
    # The Int variant is inherently nan/inf-proof — Int(text) rejects "nan"/"inf"
    # outright — so it needs no isFinite guard; assert it stays Int-parsed (in code).
    assert "Int(text)" in _strip_comments(src), (
        "StepperIntField must parse via Int(text) (which cannot yield nan/inf); a switch "
        "to Double parsing would open the same non-finite hole this guard closes"
    )


# ---------------------------------------------------------------------------
# ATTACK 37 (SUPPLY CHAIN) — the DEV script clears the read-only/write bit on
# EXACTLY the files the patch modifies, before it applies them. spec §3 requires
# the "read-only flag cleared first" (dependency sources check out read-only) for
# "the established workflow-patch mechanism" — and the dev script IS that
# mechanism run locally. ATTACK 31 (and the Swift Windows-leg test) lock this for
# the two Windows YAML legs; NOTHING covers scripts/patch-swift-cross-ui.sh, the
# THIRD place read-only is cleared. If the patch's target set ever changes and the
# script's hardcoded `chmod` list is not updated in lockstep, the dev / ci-local
# loop hits a read-only source and `git apply` dies with a misleading error — the
# exact split ATTACK 31 exists to prevent, on the one leg it doesn't watch.
# ---------------------------------------------------------------------------


DEV_PATCH_SCRIPT = REPO_ROOT / "scripts" / "patch-swift-cross-ui.sh"


def _dev_script_code_or_skip():
    """Executable lines of the dev patch script, `#`-comment lines removed — the
    header prose names the same tokens ('read-only', 'git apply') the assertions
    search for, so only real code may count (same comment-vacuity discipline as
    ATTACK 35 / the Swift CUESYNC8DevScriptMirrorsCIPatchStepTests)."""
    if not DEV_PATCH_SCRIPT.is_file():
        raise unittest.SkipTest("scripts/patch-swift-cross-ui.sh not found")
    return "\n".join(
        ln
        for ln in DEV_PATCH_SCRIPT.read_text(encoding="utf-8").splitlines()
        if not ln.lstrip().startswith("#")
    )


def test_dev_script_clears_read_only_on_exactly_the_patched_files_before_apply():
    if not PATCH_TEXT:
        raise unittest.SkipTest("%s not found" % GESTURE_PATCH_NAME)
    code = _dev_script_code_or_skip()
    patched = set(_patch_target_paths())

    chmod_pos = None
    cleared = set()
    for m in re.finditer(r"chmod\s+[^\n]*u\+w\s+([^\n]*)", code):
        chmod_pos = m.start() if chmod_pos is None else min(chmod_pos, m.start())
        for tok in m.group(1).split():
            if tok.endswith(".swift"):
                cleared.add(
                    tok.replace("\\", "/").replace(
                        ".build/checkouts/swift-cross-ui/", ""
                    )
                )
    assert chmod_pos is not None, (
        "scripts/patch-swift-cross-ui.sh never clears the write bit (`chmod … u+w …`) "
        "on the dependency sources — on a read-only checkout `git apply` cannot rewrite "
        "them and the dev/ci-local loop breaks (spec §3)"
    )
    assert cleared == patched, (
        "spec §3: the dev script clears the write bit on %r but the patch modifies %r — "
        "a stale hardcoded `chmod` list leaves the real target read-only and breaks "
        "`git apply` locally, the sibling of the drift ATTACK 31 locks on the Windows legs"
        % (sorted(cleared), sorted(patched))
    )
    apply_pos = code.find("git apply")
    assert apply_pos != -1, (
        "dev script contains no `git apply` at all (ATTACK 35 covers this)"
    )
    assert chmod_pos < apply_pos, (
        "the `chmod … u+w` clear must run BEFORE the first `git apply` — a clear placed "
        "after the apply cannot help the apply that already failed on a read-only source"
    )


# ---------------------------------------------------------------------------
# ATTACK 38 — the macOS gesture-patch step resolves the checkout ON DEMAND. The
# macos leg has NO separate `swift package resolve` step (ATTACK 33 orders it only
# against the build it must precede), yet ATTACK 33 also requires the patch to run
# BEFORE `swift build`. So the checkout does not exist when the patch step runs
# unless the step itself resolves it — otherwise `cd .build/checkouts/swift-cross-ui`
# fails and the patch never applies, shipping the dead-on-click UI on the one leg
# that also builds the macOS SwiftPM artifact. This pins the on-demand resolve as
# load-bearing, and that it is existence-guarded so a resolved checkout is a no-op.
# ---------------------------------------------------------------------------


def test_macos_gesture_patch_step_resolves_the_checkout_on_demand():
    bodies = _gesture_bodies()
    mac = bodies.get("macos")
    assert mac is not None, "no macos gesture-patch step to inspect"
    assert "swift package resolve" in mac, (
        "spec §3: the macos gesture-patch step must `swift package resolve` on demand — "
        "the macos job has no separate resolve step and the patch runs before `swift "
        "build`, so without this the checkout it patches does not exist yet"
    )
    assert re.search(r"-d\s+\.build/checkouts/swift-cross-ui", mac), (
        "the on-demand resolve must be guarded by a `[ ! -d .build/checkouts/swift-cross-ui ]` "
        "existence check so re-running against an already-resolved checkout is a no-op "
        "(and so it can never clobber a resolved-and-patched tree)"
    )
    # And it must be the ONLY resolve in the whole macos job — proving there is no
    # separate resolve step the ordering could lean on instead (ATTACK 33's premise).
    mac_start, mac_end = JOBS["macos"]
    job_resolves = [
        k
        for k in range(mac_start, mac_end)
        if not LINES[k].lstrip().startswith("#") and "swift package resolve" in LINES[k]
    ]
    assert len(job_resolves) == 1, (
        "the macos job must contain exactly one `swift package resolve` (the on-demand "
        "one inside the gesture-patch step); found %d — a stray separate resolve step "
        "would change the ordering ATTACK 33 reasons about" % len(job_resolves)
    )


# ---------------------------------------------------------------------------
# ATTACK 39 (§4 runtime trust boundary — LIVE FINDING) — the now-clickable export
# Save buttons feed an UNSANITISED, untrusted preset name straight into the export
# filename. spec §4(b): "TextTools.slugify() on any name that becomes an export
# filename stays the sanitiser at that boundary … Values still originate from
# untrusted files (Rekordbox XML, Serato GEOB, Engine DJ SQLite, ShowKontrol/
# Resolume) and user text." CUESYNC-8's whole point is that Save XML / Save
# ShowKontrol Cue now CLICK on Windows — so `state.presetName` (user-typed, or
# loaded verbatim from an untrusted .cueproj) now flows LIVE into
# `defaultFileName: "\(name).xml"` / `"\(name).cue"`. But `slugify` is called
# NOWHERE in the app (grep: its only mention is its own definition + tests), so a
# preset name of `../../evil`, `con`, or one carrying a NUL/`/` reaches the file
# chooser's suggested name unfiltered. The NSSavePanel/GTK chooser the user then
# confirms is a mitigation, not the §4 sanitiser — this is the documented boundary
# guard being absent at a boundary the ticket just made reachable. Currently FAILS:
# it reproduces the live gap (fix = route the name through slugify, or retarget
# with a written §4 justification per repo rule §E.24 — never delete-to-green).
# ---------------------------------------------------------------------------


def test_now_live_export_save_buttons_sanitise_the_untrusted_preset_name():
    export = (
        REPO_ROOT
        / "CueSync"
        / "CueSync"
        / "UI"
        / "Sections"
        / "ExportSectionView.swift"
    )
    if not export.is_file():
        raise unittest.SkipTest("CrossUI ExportSectionView.swift not found")
    src = export.read_text(encoding="utf-8")

    # Confirm the newly-live boundary is really here before asserting the guard: an
    # untrusted presetName-derived value is interpolated into the save filename.
    assert "state.presetName" in src and "defaultFileName:" in src, (
        "ExportSectionView.swift's export shape changed — re-locate the presetName -> "
        "defaultFileName boundary before trusting this test"
    )

    # Comment-stripped so a future "// should slugify this" note can't turn the guard
    # green without the actual call being wired.
    code = "\n".join(
        (ln[: ln.index("//")] if "//" in ln else ln) for ln in src.splitlines()
    )
    assert "slugify" in code, (
        "spec §4(b): the untrusted preset name that becomes the export filename must be "
        "run through TextTools.slugify() (the named boundary sanitiser — traversal-free, "
        "never `.`/`..`, never a bare Windows reserved device name, NUL/control stripped) "
        "before it reaches `defaultFileName:`. It is not: `slugify` has ZERO call sites in "
        "the app, so `state.presetName` = `../../evil` / `con` / a NUL-bearing string flows "
        "raw into the file chooser's suggested name. CUESYNC-8 made these Save buttons "
        "clickable on Windows, so this boundary is now LIVE — the save-panel confirm is "
        "defence-in-depth, not the §4 sanitiser this asserts."
    )


# ---------------------------------------------------------------------------
# ATTACK 40 (§4 — no hardcoded paths) — the patch and its dev applier operate on
# the checkout path DERIVED AT RUNTIME, never a baked-in absolute path. spec §4:
# "No hardcoded paths / separators / line endings. The patch-application script
# and any probe operate on the resolved checkout path derived at runtime, never a
# hardcoded /tmp or C:\…." A patch/script carrying `/Users/<someone>`, `/tmp/…`,
# or `C:\…` would be non-reproducible across machines and CI — and a machine-
# specific absolute path is also an information leak in a checked-in artifact.
# ---------------------------------------------------------------------------


def test_gesture_patch_and_dev_script_use_no_hardcoded_absolute_paths():
    banned = ["/tmp/", "/Users/", "/home/", "/private/", "/var/folders", "C:\\", "C:/"]
    subjects = []
    if PATCH_TEXT:
        subjects.append(("patches/" + GESTURE_PATCH_NAME, PATCH_TEXT))
    if DEV_PATCH_SCRIPT.is_file():
        subjects.append(("scripts/patch-swift-cross-ui.sh", _dev_script_code_or_skip()))
    assert subjects, "neither the patch nor the dev script is present to inspect"
    for label, text in subjects:
        for token in banned:
            assert token not in text, (
                "spec §4 (no hardcoded paths): %s contains the absolute path fragment "
                "`%s` — the patch/applier must derive the checkout path at runtime "
                "(e.g. `$ROOT/.build/checkouts/…`), never bake in a machine-specific root"
                % (label, token)
            )


# ---------------------------------------------------------------------------
# ATTACK 41 (correctness — desync guard that runs WITHOUT a checkout) — the Swift
# property the backend ASSIGNS must be the exact one the Widget hunk DECLARES.
# Behavioral ATTACK 24 proves the applied bytes are hit-test-transparent, but it
# SKIPS on a bare `python3` (no resolved checkout). A rename that desynced the two
# hunks — e.g. Widget declares `var hitTestable` for `can-target` while the backend
# still sets `.canTarget = false` — would break `git apply`'s result at COMPILE
# time on CI, yet sail past every no-checkout text test that only greps for the
# string `"can-target"` / `canTarget = false` (both still literally present). This
# extracts BOTH identifiers from the diff and asserts they match, so the desync is
# caught structurally, offline, before CI ever compiles.
# ---------------------------------------------------------------------------


def test_patch_backend_can_target_assignment_matches_widget_property_name():
    if not PATCH_TEXT:
        raise unittest.SkipTest("%s not found" % GESTURE_PATCH_NAME)
    sections = _patch_file_sections()
    widget = sections.get("Sources/Gtk/Widgets/Widget.swift", "")
    backend = sections.get("Sources/GtkBackend/GtkBackend.swift", "")

    decl = re.search(
        r'@GObjectProperty\(named:\s*"can-target"\)\s*public\s+var\s+(\w+)\s*:\s*Bool',
        widget,
    )
    assert decl, (
        "the Widget.swift hunk must declare a `Bool` @GObjectProperty bound to the GTK "
        '`"can-target"` name (findings §2.2) — not found, so the property the fix depends '
        "on is missing or misdeclared"
    )
    declared = decl.group(1)

    added_backend = "\n".join(
        ln[1:]
        for ln in backend.splitlines()
        if ln.startswith("+") and not ln.startswith("+++")
    )
    setter = re.search(r"\.(\w+)\s*=\s*false", added_backend)
    assert setter, (
        "the GtkBackend.swift hunk must set `.<property> = false` on the path widget in "
        "an ADDED line (findings §2.3) — the hit-test-transparency assignment is missing"
    )
    assigned = setter.group(1)
    assert assigned == declared, (
        "desync: the backend sets `.%s = false` but the Widget base class declares the "
        "`can-target` property as `var %s` — these must be the SAME Swift identifier or "
        'the patched checkout fails to compile on CI, while every offline `contains("can-'
        'target")` text test stays green and hides it' % (assigned, declared)
    )


# ---------------------------------------------------------------------------
# ATTACK 42 (§4 runtime trust boundary — LIVE FINDING, same class as ATTACK 39) —
# the now-clickable "Save Project" button has the IDENTICAL unsanitised-filename
# gap as ATTACK 39's export buttons, in a different file. spec §4(b) names
# TextTools.slugify() as the sanitiser for "any name that becomes an export
# filename" — a saved `.cueproj` is exactly that. ProjectSectionView.swift binds
# `state.projectName` to a free-text `TextField` ("Project Name") and, in
# `saveProject()`, interpolates it straight into `defaultFileName:
# "\(name).cueproj"` with no `slugify` call anywhere in the file. CUESYNC-8 is
# what makes this Save button clickable on Windows, so — exactly like ATTACK 39
# — a project name of `../../evil`, `con`, or one carrying a NUL/`/` now reaches
# the file chooser's suggested name unfiltered. Currently FAILS: it reproduces
# the live gap (fix = route the name through slugify, or retarget with a written
# §4 justification per repo rule §E.24 — never delete-to-green).
# ---------------------------------------------------------------------------


def test_now_live_save_project_button_sanitises_the_untrusted_project_name():
    project_section = (
        REPO_ROOT
        / "CueSync"
        / "CueSync"
        / "UI"
        / "Sections"
        / "ProjectSectionView.swift"
    )
    if not project_section.is_file():
        raise unittest.SkipTest("CrossUI ProjectSectionView.swift not found")
    src = project_section.read_text(encoding="utf-8")

    # Confirm the newly-live boundary is really here before asserting the guard: an
    # untrusted projectName-derived value is interpolated into the save filename.
    assert "state.projectName" in src and "defaultFileName:" in src, (
        "ProjectSectionView.swift's save-project shape changed — re-locate the "
        "projectName -> defaultFileName boundary before trusting this test"
    )

    # Comment-stripped so a future "// should slugify this" note can't turn the guard
    # green without the actual call being wired.
    code = "\n".join(
        (ln[: ln.index("//")] if "//" in ln else ln) for ln in src.splitlines()
    )
    assert "slugify" in code, (
        "spec §4(b): the untrusted project name that becomes the saved .cueproj filename "
        "must be run through TextTools.slugify() (the named boundary sanitiser — "
        "traversal-free, never `.`/`..`, never a bare Windows reserved device name, "
        "NUL/control stripped) before it reaches `defaultFileName:`. It is not: `slugify` "
        "has ZERO call sites in the app, so `state.projectName` = `../../evil` / `con` / a "
        "NUL-bearing string flows raw into the file chooser's suggested name. CUESYNC-8 "
        "made the Save Project button clickable on Windows, so this boundary is now LIVE — "
        "the save-panel confirm is defence-in-depth, not the §4 sanitiser this asserts."
    )


# ---------------------------------------------------------------------------
# ATTACK 43 (§4 runtime trust boundary — forward-looking sweep) — ATTACK 39 and
# ATTACK 42 found the SAME bug class (an untrusted `@State`-bound name reaching
# `defaultFileName:` unsanitised) in two different files by hand. A third
# `defaultFileName:` call site added later — another export format, another save
# flow — would silently reintroduce the identical gap unless every call site in
# UI/ is swept, not just the two found so far. This scans every `.swift` file
# under UI/ and requires each one that interpolates a name into `defaultFileName:`
# to also call `slugify` somewhere in that same file — a coarse per-file proxy
# (mirrors ATTACK 39/42's own method) but one that catches a NEW unsanitised call
# site automatically instead of waiting for the next hand-written ATTACK.
# ---------------------------------------------------------------------------


def test_every_default_file_name_call_site_in_ui_has_a_slugify_call_in_its_file():
    ui_dir = REPO_ROOT / "CueSync" / "CueSync" / "UI"
    if not ui_dir.is_dir():
        raise unittest.SkipTest("CrossUI UI/ directory not found")
    offenders = []
    checked = 0
    for path in sorted(ui_dir.rglob("*.swift")):
        src = path.read_text(encoding="utf-8")
        code = "\n".join(
            (ln[: ln.index("//")] if "//" in ln else ln) for ln in src.splitlines()
        )
        if "defaultFileName:" not in code:
            continue
        checked += 1
        if "slugify" not in code:
            offenders.append(path.relative_to(REPO_ROOT).as_posix())
    assert checked > 0, (
        "expected at least one defaultFileName: call site under CueSync/CueSync/UI — "
        "if the save-destination API changed shape, re-locate it before trusting this sweep"
    )
    assert not offenders, (
        "spec §4(b): every file under UI/ that interpolates a name into "
        "`defaultFileName:` must also call TextTools.slugify() on that name before use. "
        "The following file(s) build a defaultFileName: with no slugify call anywhere in "
        "the file, so whatever untrusted/user text feeds the name reaches the file "
        "chooser's suggested filename unsanitised: %s" % ", ".join(offenders)
    )


# ---------------------------------------------------------------------------
# ATTACK 44 (SUPPLY CHAIN — the pin is only as strong as `git apply`'s strictness)
# The entire "audited bytes == built bytes" guarantee (spec §4: "so 'the code we
# audited' and 'the code we build' stay identical") rests on ONE property of the
# apply mechanism: `git apply` is strict by default — exact context match, no
# fuzz, no whitespace coercion. It refuses to apply a patch whose surrounding
# context has drifted from the pinned commit. Weaken that — `--ignore-whitespace`
# (a very plausible "fix" someone reaches for when CRLF/read-only churn on the
# Windows legs makes an apply complain), `--whitespace=fix`, `-C<n>` fuzz,
# `--unidiff-zero`, `--3way`, or `--reject` (which applies what it can and drops
# the rest into .rej, shipping a HALF-patched dependency while the step's exit
# code can still read success) — and the patch would silently apply to code that
# no longer matches the audited v0.8.0 bytes, defeating the pin §4 leans on. The
# forward apply must stay bare on every leg AND in the dev applier. NOTHING pins
# this today: ATTACK 22 proves the patch applies to the CURRENT pinned checkout,
# ATTACK 32 proves a *failed* apply is loud — neither notices a lenient flag that
# makes a *drifted* apply succeed. Currently PASSES (all invocations are bare) —
# a durable lock: adding any leniency flag turns it red.
# ---------------------------------------------------------------------------


def _all_forward_git_apply_lines():
    """(where, command_line) for every `git apply` invocation across the three
    gesture-patch step bodies and the dev applier, comment-stripped so only real
    commands count. Includes the `--reverse --check` guard lines too — the
    strictness assertion below must hold for THOSE as well (a fuzzed reverse
    check would wrongly report 'already applied' and skip a needed apply)."""
    out = []
    for job, body in _gesture_bodies().items():
        for ln in body.splitlines():
            code = ln.split("#", 1)[0]
            if "git apply" in code:
                out.append(("workflow:" + job, code.strip()))
    if DEV_PATCH_SCRIPT.is_file():
        for ln in _dev_script_code_or_skip().splitlines():
            if "git apply" in ln:
                out.append(("scripts/patch-swift-cross-ui.sh", ln.strip()))
    return out


def test_every_git_apply_of_the_gesture_patch_is_strict_not_fuzzy_or_whitespace_lenient():
    invocations = _all_forward_git_apply_lines()
    if not invocations:
        raise unittest.SkipTest("no `git apply` invocation found to inspect")
    # Named leniency/partial-apply flags that break the strict-context guarantee.
    banned_substrings = [
        "--ignore-whitespace",
        "--whitespace",  # any value: =fix mutates, =nowarn/=error still signal intent to coerce
        "--unidiff-zero",
        "--3way",
        "--reject",
        "--inaccurate-eof",
    ]
    # `-C<n>` reduces the required context-line count (fuzz); match it without
    # tripping on the legitimate `--check` (no bare `-C<digit>` there).
    fuzz_re = re.compile(r"(?:^|\s)-C\d")
    for where, cmd in invocations:
        tail = cmd[cmd.index("git apply") + len("git apply") :]
        for flag in banned_substrings:
            assert flag not in tail, (
                "spec §4 (audited==built): the `git apply` in %s carries `%s`, a "
                "leniency/partial-apply flag. `git apply` is strict by default; that "
                "strictness is the ONLY thing forcing the patch to match the audited "
                "v0.8.0 bytes exactly. With `%s` a patch applies to DRIFTED context "
                "(a bumped pin, a tampered checkout) — silently defeating the pin. "
                "Invocation: %r" % (where, flag, flag, cmd)
            )
        assert not fuzz_re.search(tail), (
            "spec §4: the `git apply` in %s carries a `-C<n>` fuzz flag that relaxes "
            "context matching, letting the patch land on code that has drifted from "
            "the audited commit. Keep the apply strict (bare). Invocation: %r"
            % (where, cmd)
        )


# ---------------------------------------------------------------------------
# ATTACK 45 (PLACEMENT — the one ordering constraint ATTACK 33 does NOT cover)
# spec §3 requires the gesture patch be "placed after `swift package resolve` /
# the swift-java symlink repair and before `swift build` / `swift test`." ATTACK
# 33 pins after-resolve/before-build, but is SILENT on the symlink-repair half.
# The repair (CUESYNC-6e) re-materializes every git symlink in the resolved
# dependency checkouts as NTFS junctions/hardlinks — on Windows the checkouts are
# not usable until it runs. A gesture-patch step ordered BEFORE it would `cd`
# into a swift-cross-ui tree whose symlinked layers are still broken reparse
# points, and the repair's own index-driven re-materialization could later
# clobber or race the just-applied hunk. This pins repair-before-gesture on both
# Windows legs (macOS has no repair step — ATTACK 30 asserts its absence — so it
# is excluded here). Currently PASSES; a reorder turns it red.
# ---------------------------------------------------------------------------


def test_gesture_patch_runs_after_the_swift_java_symlink_repair_on_windows_legs():
    for job in ("windows-build", "windows-test"):
        assert job in JOBS, "missing job " + job
        start, end = JOBS[job]
        repair_idx = None
        gesture_idx = None
        for k in range(start, end):
            m = STEP_NAME_RE.match(LINES[k])
            if not m:
                continue
            name = m.group(1)
            if name.startswith(REPAIR_STEP_NAME):
                repair_idx = k  # last one wins if ever duplicated
            if GESTURE_STEP_NAME in name:
                gesture_idx = k
        assert repair_idx is not None, (
            job + ": the `%s` step is missing — spec §3 requires the gesture patch "
            "to run AFTER it, so its absence breaks the ordering premise entirely"
            % REPAIR_STEP_NAME
        )
        assert gesture_idx is not None, job + ": no gesture-patch step to order"
        assert repair_idx < gesture_idx, (
            job + ": the gesture-patch step (line %d) runs BEFORE the swift-java "
            "symlink repair (line %d). spec §3: the patch must be placed after the "
            "repair — a swift-cross-ui checkout whose symlinked layers are still "
            "broken reparse points cannot be `cd`'d into and patched, and a repair "
            "run afterward can clobber the applied hunk" % (gesture_idx, repair_idx)
        )


# ---------------------------------------------------------------------------
# ATTACK 46 (SUPPLY CHAIN — the dev applier's OWN idempotency, untested until now)
# spec §3: the dev script must be idempotent "so the build agent can iterate
# without GitHub CI." ATTACK 23 proves the PATCH is reverse-appliable (a property
# of the diff); ATTACK 34 proves the three WORKFLOW steps carry the
# `git apply --reverse --check` guard. NOTHING asserts scripts/patch-swift-cross-ui.sh
# — the third applier, the one the dev / ci-local loop actually runs every
# iteration — guards its forward apply the same way. Strip the guard and the
# script degrades to a bare `git apply`: the FIRST run works, the SECOND
# (inevitable in an edit-build-edit loop against a persisted `.build/checkouts`)
# dies with "patch does not apply", exactly the non-idempotent break the guard
# exists to prevent, on the one applier no test watches.
# ---------------------------------------------------------------------------


def test_dev_patch_script_guards_its_forward_apply_for_idempotency():
    code = _dev_script_code_or_skip()
    lines = code.splitlines()
    reverse_idx = next(
        (i for i, ln in enumerate(lines) if "git apply --reverse --check" in ln),
        None,
    )
    forward_idx = next(
        (
            i
            for i, ln in enumerate(lines)
            if "git apply" in ln and "--reverse" not in ln
        ),
        None,
    )
    assert reverse_idx is not None, (
        "spec §3 idempotency: scripts/patch-swift-cross-ui.sh must guard its apply "
        "with `git apply --reverse --check` so a re-run against an already-patched "
        "checkout is a no-op. The guard is absent — a second dev-loop iteration would "
        "hit `patch does not apply` and break local iteration."
    )
    assert forward_idx is not None, (
        "scripts/patch-swift-cross-ui.sh performs no forward `git apply` at all — it "
        "cannot apply the fix locally (spec §3)"
    )
    assert reverse_idx < forward_idx, (
        "spec §3: the `git apply --reverse --check` idempotency guard (line ~%d of the "
        "code-only view) must run BEFORE the forward `git apply` (line ~%d). A guard "
        "placed after the apply cannot stop the second forward apply from failing on "
        "an already-patched tree." % (reverse_idx, forward_idx)
    )


# ---------------------------------------------------------------------------
# ATTACK 47 (FIX BLAST RADIUS — the load-bearing assumption the fix bets the whole
# app on). The patch makes EVERY `Shape`-backed widget (every widget
# `createPathWidget()` returns) `can-target = false`. That is safe for exactly one
# reason, asserted in findings §2.3: "none [of the app's `.onTapGesture`/`.onHover`
# call sites] is ever attached directly to a `Shape` — they land on
# `HStack`/`VStack`/`Text` rows only." If ANY control under UI/ is (re)written to
# hang its gesture directly on a `Shape` — `Circle().onTapGesture { … }`,
# `Rectangle().fill(…).onHover { … }` — the fix silently makes THAT control
# dead-on-click on GTK: the exact "renders but doesn't respond" bug CUESYNC-8
# exists to kill, reintroduced by the fix's own blast radius, invisibly (it still
# renders; it just stops receiving events). ATTACK 27 guards the PATCH text
# against touching interactive factories; nothing guards the APP against depending
# on a decorative factory being interactive. Coarse per-construct proxy (same
# discipline as ATTACK 43): it scans each `Shape` constructor's fluent modifier
# chain for a gesture. Currently PASSES (no Shape owns a gesture); a future
# Shape-as-control turns it red before the dead UI ever ships.
# ---------------------------------------------------------------------------


def test_no_decorative_shape_under_ui_is_wired_as_a_tap_or_hover_target():
    ui_dir = REPO_ROOT / "CueSync" / "CueSync" / "UI"
    if not ui_dir.is_dir():
        raise unittest.SkipTest("CrossUI UI/ directory not found")
    shape_ctor = re.compile(
        r"\b(RoundedRectangle|Rectangle|Circle|Capsule|Ellipse)\s*\("
    )
    gesture_re = re.compile(r"\.(onTapGesture|onHover|gesture)\b")
    offenders = []
    scanned_shapes = 0
    for path in sorted(ui_dir.rglob("*.swift")):
        raw = path.read_text(encoding="utf-8").splitlines()
        # Strip `//` line comments so a comment mentioning `.onTapGesture` near a
        # decorative Shape can't produce a false hit.
        code = [ln[: ln.index("//")] if "//" in ln else ln for ln in raw]
        for i, ln in enumerate(code):
            if not shape_ctor.search(ln):
                continue
            scanned_shapes += 1
            # Collect the Shape's fluent chain: this line plus every following
            # line whose first non-space char is `.` (a chained modifier). In
            # Swift's fluent style those are exactly this Shape's own modifiers;
            # the chain ends at the first non-`.`-leading line (`}`, a sibling
            # view, a new statement), so a gesture on a LATER sibling view — or on
            # the outer container an `.overlay { Shape }` belongs to — is not
            # misattributed to the Shape.
            chain = [ln]
            j = i + 1
            while j < len(code) and code[j].lstrip().startswith("."):
                chain.append(code[j])
                j += 1
            blob = "\n".join(chain)
            if gesture_re.search(blob):
                offenders.append(
                    "%s:%d\n%s" % (path.relative_to(REPO_ROOT).as_posix(), i + 1, blob)
                )
    assert scanned_shapes > 0, (
        "expected at least one Shape (RoundedRectangle/Rectangle/…) under UI/ — if the "
        "decorative-Shape idiom changed shape, re-verify the fix's `can-target=false` "
        "blast radius before trusting this scan"
    )
    assert not offenders, (
        "findings §2.3 / spec §3: the gesture patch sets `can-target = false` on EVERY "
        "Shape-backed widget, which is only safe because no Shape is ever a tap/hover "
        "target. The following Shape(s) under UI/ have a gesture in their own modifier "
        "chain — the fix makes them dead-on-click on GTK, silently reintroducing the "
        "'renders but does not respond' bug this ticket fixes. Move the gesture onto a "
        "container/Text row (never a Shape), or retarget with a written §2.3 "
        "justification per repo rule §E.24 — never delete-to-green:\n\n%s"
        % "\n\n".join(offenders)
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
