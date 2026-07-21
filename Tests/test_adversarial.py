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
        % (
            len(lines),
            len(commands),
        )
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
# CUESYNC-9 §0.3 (round 4): a third, distinct root-cause patch against the same
# upstream file (runMainLoop — GSK_RENDERER=cairo for the remote-desktop GL-renderer
# failure), kept in its own reviewable file, disjoint hunk from the other two.
WINDOWS_GSK_PATCH_NAME = "swift-cross-ui-0.8.0-windows-gsk-renderer.patch"

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


def test_dev_script_and_every_ci_leg_apply_the_two_remaining_checked_in_patches():
    """UPDATED for round 9 (specs/CUESYNC-9-findings.md §0.8): round 7's
    windows-input patch — the second of the three patches this test used to
    expect — was reverted as a disproven, non-load-bearing fix per spec step 5.
    Exactly TWO named patches remain checked in against GtkBackend.swift now
    (gesture/interactivity + GSK-renderer); a THIRD file (the reverted patch
    reappearing, or anything else) is a supply-chain regression, so the expected
    set is asserted exactly, and its absence is checked directly by name too."""
    patch_dir = REPO_ROOT / "patches"
    if not patch_dir.is_dir():
        raise unittest.SkipTest("patches/ directory not found")
    gtk_patches = sorted(
        p.name
        for p in patch_dir.glob("*.patch")
        if "Sources/GtkBackend/GtkBackend.swift" in p.read_text(encoding="utf-8")
    )
    expected = sorted([GESTURE_PATCH_NAME, WINDOWS_GSK_PATCH_NAME])
    assert gtk_patches == expected, (
        "spec §4/§0.3/§0.8: expected exactly the two named checked-in patches "
        "touching GtkBackend.swift (" + repr(expected) + ") now that the "
        "windows-input patch is reverted; a THIRD file or a divergent copy of "
        "either is a supply-chain risk. Found: " + repr(gtk_patches)
    )
    assert WINDOWS_INPUT_PATCH_NAME not in gtk_patches, (
        "the reverted windows-input patch must not be a checked-in patch file "
        "touching GtkBackend.swift (specs/CUESYNC-9-findings.md §0.8)"
    )
    dev_script = REPO_ROOT / "scripts" / "patch-swift-cross-ui.sh"
    assert dev_script.is_file(), "scripts/patch-swift-cross-ui.sh must exist (spec §3)"
    dev_code = "\n".join(
        ln
        for ln in dev_script.read_text(encoding="utf-8").splitlines()
        if not ln.lstrip().startswith("#")
    )
    assert GESTURE_PATCH_NAME in dev_code, (
        "scripts/patch-swift-cross-ui.sh must apply the gesture patch in "
        "executable code (not just a comment) — the same file CI applies (spec §3)"
    )
    assert WINDOWS_GSK_PATCH_NAME in dev_code, (
        "scripts/patch-swift-cross-ui.sh must apply the GSK-renderer patch in "
        "executable code too (spec §0.3)"
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


# ===========================================================================
# CUESYNC-9 RED-TEAM — the NEW windows-input patch is a supply-chain surface
# (spec CUESYNC-9 §4: "The patched dependency is a supply-chain surface … it
# must be a checked-in, reviewable `.patch` … no network call, no new
# dependency, no dynamic code load"). The whole existing Python adversarial
# suite above hardens the CUESYNC-8 GESTURE patch (PATCH_TEXT) but never once
# looks at patches/swift-cross-ui-0.8.0-windows-input.patch — so a malicious or
# careless future edit to THAT file (an exec/network/dynamic-load payload, a
# second smuggled `diff --git`, a re-pin, the drain leaking onto macOS/Linux,
# or a blocking drain that freezes the tick) sails past every test here. The
# Swift CUESYNC9WindowsInputDispatchWorkflowTests check some of this, but with a
# short banned-token list and no behavioural `git apply`. These tests attack the
# patch itself, the real application sequence, and the now-live value-handling
# paths the acceptance criteria newly expose.
# ===========================================================================

WINDOWS_INPUT_PATCH_PATH = REPO_ROOT / "patches" / WINDOWS_INPUT_PATCH_NAME
WINDOWS_INPUT_PATCH_TEXT = (
    WINDOWS_INPUT_PATCH_PATH.read_text(encoding="utf-8")
    if WINDOWS_INPUT_PATCH_PATH.is_file()
    else ""
)
WINDOWS_INPUT_STEP_NAME = "Patch swift-cross-ui Windows input dispatch"
RESOLVE_STEP_NAME = "Resolve Swift package dependencies"


def _win_input_or_skip():
    if not WINDOWS_INPUT_PATCH_TEXT:
        raise unittest.SkipTest("%s not found" % WINDOWS_INPUT_PATCH_NAME)
    return WINDOWS_INPUT_PATCH_TEXT


def _win_input_added_lines():
    """Content of every added (`+`) line of the windows-input patch, excluding
    the `+++` header — exactly the bytes `git apply` injects into GtkBackend.
    Comment/header prose (which legitimately names `Package.swift`, `system`,
    `PeekMessage`, …) is NOT an added dependency line and is excluded on purpose."""
    return [
        ln[1:]
        for ln in WINDOWS_INPUT_PATCH_TEXT.splitlines()
        if ln.startswith("+") and not ln.startswith("+++")
    ]


def _apply_patch(git, tree, patch_path, *args):
    return subprocess.run(
        [git, "apply", *args, str(patch_path)], cwd=tree, capture_output=True, text=True
    )


# ---------------------------------------------------------------------------
# ATTACK 48 (SUPPLY CHAIN) — the windows-input patch's ADDED code must be pure
# GLib-drain wiring: no network, no subprocess, no dynamic load, no new import.
# The Swift test bans only {import, dlopen, Process(, URLSession, http/https}
# and scans the whole file; a payload using `system(`/`popen(`/`LoadLibrary`/
# `dlsym`/`Data(contentsOf:`/`FileHandle`/a raw `socket(` slips past it AND past
# every test in this file (none of which look at this patch). This closes that
# hole with the same broad banned list ATTACK 26 applies to the gesture patch,
# scoped to added lines so the rationale comment is not a false positive.
# ---------------------------------------------------------------------------


def test_windows_input_patch_added_lines_are_pure_glib_drain_no_exec_network_or_new_import():
    _win_input_or_skip()
    added = _win_input_added_lines()
    assert added, "the windows-input patch adds no lines at all — nothing to review"

    forbidden = [
        "http://",
        "https://",
        "ftp://",
        "URLSession",
        "getaddrinfo",
        "socket(",  # network
        "Process(",
        "NSTask",
        "posix_spawn",
        "system(",
        "popen(",
        "ShellExecute",
        "execve",
        "execvp",  # process spawn
        "/bin/sh",
        "cmd.exe",
        "Invoke-WebRequest",
        "Invoke-Expression",
        "eval(",  # shells / dynamic eval
        "dlopen",
        "dlsym",
        "LoadLibrary",
        "GetProcAddress",  # dynamic load
        "Data(contentsOf:",
        "FileHandle",
        "fopen(",
        "mmap(",
        "VirtualAlloc",  # arbitrary file/memory I/O
    ]
    for content in added:
        for token in forbidden:
            assert token not in content, (
                "spec CUESYNC-9 §4: the windows-input patch must be pure GLib "
                "main-context drain wiring — no network, subprocess, dynamic load, or "
                "arbitrary file/memory I/O. An added line contains `%s`:\n    %s"
                % (token, content.strip())
            )
        assert not content.strip().startswith("import "), (
            "spec CUESYNC-9 §4 (no new dependency): the windows-input patch must not "
            "add an `import` — the fix uses only GLib's own `g_main_context_iteration`, "
            "already reachable in GtkBackend.swift. Found:\n    %s" % content.strip()
        )


# ---------------------------------------------------------------------------
# ATTACK 49 (SUPPLY CHAIN) — the windows-input patch is a REAL unified diff that
# touches exactly one file and re-pins nothing. A `sed`/`-replace` script, a
# second smuggled `diff --git` (a co-located edit to another dependency file),
# or a hunk that bumps Package.swift/Package.resolved would all keep the pin
# from meaning anything. The header comment legitimately NAMES Package.swift /
# `exact:` in prose, so the re-pin check is scoped to the diff body, not the
# whole text — a distinction no existing test draws.
# ---------------------------------------------------------------------------


def test_windows_input_patch_is_a_real_unified_diff_touching_only_gtkbackend_and_repins_nothing():
    text = _win_input_or_skip()
    assert (
        "diff --git a/Sources/GtkBackend/GtkBackend.swift "
        "b/Sources/GtkBackend/GtkBackend.swift" in text
    ), "expected a real `diff --git` unified-diff header for GtkBackend.swift"

    for tool in ["-replace", "sed -i", "sed 's", "perl -pi", "awk '", "> "]:
        assert tool not in "\n".join(_win_input_added_lines()), (
            'spec CUESYNC-9 §4 ("never sed/-replace"): the checked-in fix must be a '
            "real diff, not a `%s` text-substitution/redirect. Found in an added line."
            % tool
        )

    targets = sorted(set(re.findall(r"diff --git a/(\S+) b/\S+", text)))
    assert targets == ["Sources/GtkBackend/GtkBackend.swift"], (
        "spec CUESYNC-9 acceptance: the windows-input patch must touch ONLY the file "
        "named in specs/CUESYNC-9-findings.md (GtkBackend.swift's mainRunLoopTicklingLoop). "
        "A second `diff --git` is an out-of-scope edit to another dependency file — a "
        "supply-chain smuggling surface. Found targets: %r" % targets
    )

    # No re-pin: the pin stays `exact: "0.8.0"`; the dependency is patched at the
    # checkout, never re-pinned. Assert against the DIFF BODY (added lines), since
    # the rationale comment above the diff legitimately mentions these tokens.
    for repin in ["Package.swift", "Package.resolved", "exact:", ".package(", "from:"]:
        offenders = [c for c in _win_input_added_lines() if repin in c]
        assert not offenders, (
            'spec CUESYNC-9 acceptance: swift-cross-ui stays pinned `exact: "0.8.0"` and '
            "Package.swift/Package.resolved are UNCHANGED — the windows-input diff body "
            "must not touch the manifest or re-pin. An added line contains `%s`:\n    %s"
            % (repin, offenders[0].strip())
        )


# ---------------------------------------------------------------------------
# ATTACK 50 (correctness / blast radius) — the GLib drain must be Windows-only
# AND non-blocking. The Swift test only checks `#if os(Windows)` and
# `g_main_context_iteration` each appear SOMEWHERE in the patch; it never proves
# the drain call sits INSIDE the Windows guard, nor that the iteration is
# non-blocking. If the drain leaked outside `#if os(Windows)` it would run on the
# macOS GtkBackend CI leg (spec §5: that leg must stay green) and change Linux
# behaviour for no reason; if it passed `may_block = TRUE` it would BLOCK the 50 ms
# tickler waiting for an event that may never come — a trivially reachable UI
# freeze that also starves RunLoop.main (regressing PR #141), the opposite of the
# fix. findings §2.5/Fix demand exactly `g_main_context_iteration(nil, 0)`.
#
# Updated for round 7's restructuring: the patch now adds THREE separate
# `#if os(Windows)` guards (the top-of-file `@_silgen_name` declaration, the
# tickler's `#if os(Windows) … #else … #endif`, and the tickler-priority guard),
# not one. A naive "first `#if` … first `#endif` after it" pairing (as this test
# originally did) matches the drain against the WRONG guard's boundaries once a
# second, unrelated guard precedes it in the added-lines stream. The fix below
# walks a directive stack so it finds each guard's OWN enclosing `#if`/`#else`/
# `#endif`, regardless of how many separate Windows guards exist in the file.
# ---------------------------------------------------------------------------


def _enclosing_directive_is_windows_true_branch(added, idx):
    """Whether added[idx] sits in the TRUE branch of its nearest enclosing
    `#if os(Windows)` guard, tracking a stack of #if/#else/#endif directives so
    multiple, sequential (non-nested) Windows guards elsewhere in the same
    added-lines stream cannot cross-contaminate the check."""
    stack = []  # each entry: [is_windows_guard: bool, branch: "if"|"else"]
    for line in added[:idx]:
        if re.search(r"#if\b", line):
            stack.append(["#if os(Windows)" in line, "if"])
        elif re.search(r"#else\b", line):
            if stack:
                stack[-1][1] = "else"
        elif re.search(r"#endif\b", line):
            if stack:
                stack.pop()
    if not stack:
        return False
    is_windows_guard, branch = stack[-1]
    return is_windows_guard and branch == "if"


def test_windows_input_patch_drain_is_scoped_windows_only_and_nonblocking():
    _win_input_or_skip()
    added = _win_input_added_lines()

    assert any("#if os(Windows)" in line for line in added), (
        "the windows-input patch must add a `#if os(Windows)` guard — the "
        "message-queue-ownership race is Windows-only (findings §2.5)"
    )
    drain_idxs = [
        i for i, line in enumerate(added) if "g_main_context_iteration" in line
    ]
    assert drain_idxs, "the patch must add a `g_main_context_iteration` drain call"
    for d in drain_idxs:
        assert _enclosing_directive_is_windows_true_branch(added, d), (
            "spec §5: the `g_main_context_iteration` drain (added line %d) must live "
            "in the TRUE branch of a `#if os(Windows)` guard. Outside it, the drain "
            "runs on the macOS GtkBackend leg (which must stay green) and needlessly "
            "changes Linux behaviour, or (if in an `#else`) runs on every OTHER "
            "platform instead of Windows." % d
        )

    # Non-blocking: every drain call's may_block argument must be 0/false/FALSE.
    calls = re.findall(
        r"g_main_context_iteration\s*\([^,]+,\s*([^)\s]+)\s*\)", "\n".join(added)
    )
    assert calls, "could not parse the g_main_context_iteration(...) call's arguments"
    for arg in calls:
        assert arg in ("0", "false", "FALSE"), (
            "findings §2.5/Fix: the tickler drain must be NON-BLOCKING "
            "(`g_main_context_iteration(nil, 0)`). A blocking drain (may_block=`%s`) "
            "freezes the 50 ms tick waiting on input that may never arrive — a UI hang "
            "that also starves RunLoop.main, regressing PR #141." % arg
        )


# ---------------------------------------------------------------------------
# ATTACK 51 (BEHAVIORAL) — the windows-input patch must apply cleanly IN THE REAL
# CI SEQUENCE (interactivity patch first, then windows-input — the order both the
# workflow and scripts/patch-swift-cross-ui.sh use), and its `--reverse --check`
# idempotency guard must be load-bearing. Every text-only assertion (Swift or
# Python) passes on a patch whose `@@` context has gone stale against the pinned
# commit — or after the CUESYNC-8 hunk shifts line numbers — while CI's real
# `git apply` dies and the whole GtkBackend build fails. NOTHING else applies this
# patch for real. Mirrors ATTACK 22/23 (which only exercise the gesture patch).
# ---------------------------------------------------------------------------


def test_windows_input_patch_applies_cleanly_in_the_real_ci_sequence_and_its_reverse_guard_is_load_bearing():
    _win_input_or_skip()
    git, tree = _pristine_tree_or_skip()

    gesture = _apply_patch(git, tree, PATCH_PATH)
    assert gesture.returncode == 0, (
        "the CUESYNC-8 interactivity patch (applied FIRST in the real CI order) failed "
        "to apply to the pinned checkout:\n" + (gesture.stderr or gesture.stdout)
    )

    check = _apply_patch(git, tree, WINDOWS_INPUT_PATCH_PATH, "--check")
    assert check.returncode == 0, (
        "spec CUESYNC-9 §4: %s must apply cleanly AFTER the interactivity patch (the "
        "real CI/dev-script order) to the pinned v0.8.0 checkout (commit %s). A "
        "text-only test cannot catch a stale hunk offset/context; this reconstructed "
        "the pristine HEAD sources, applied CUESYNC-8, then ran `git apply --check`, "
        "which reported:\n%s"
        % (WINDOWS_INPUT_PATCH_NAME, AUDITED_REVISION, check.stderr or check.stdout)
    )

    first = _apply_patch(git, tree, WINDOWS_INPUT_PATCH_PATH)
    assert first.returncode == 0, (
        "forward apply of the windows-input patch failed:\n" + (first.stderr or "")
    )

    reverse = _apply_patch(git, tree, WINDOWS_INPUT_PATCH_PATH, "--reverse", "--check")
    assert reverse.returncode == 0, (
        "spec §4 idempotency: on an already-patched tree `git apply --reverse --check` "
        "(the workflow's / dev-script's own no-op guard for this patch) MUST report "
        "success so the step skips. It returned %d:\n%s"
        % (reverse.returncode, reverse.stderr or reverse.stdout)
    )

    second = _apply_patch(git, tree, WINDOWS_INPUT_PATCH_PATH)
    assert second.returncode != 0, (
        "a SECOND unguarded forward `git apply` of the windows-input patch must FAIL on "
        "an already-patched tree — this is exactly why the `--reverse --check` guard is "
        "load-bearing, not decorative. It unexpectedly succeeded, meaning the patch is a "
        "silent no-op or duplicates content (spec §4)."
    )


# ---------------------------------------------------------------------------
# ATTACK 52 (BEHAVIORAL) — after applying both patches, on Windows the tickler
# must drain GLib's own context and service libdispatch DIRECTLY — and must
# NEVER pump `RunLoop.main` at all. findings §3/§Fix (round 7) is explicit that
# `RunLoop.main.limitDate` is itself the race: swift-corelibs-foundation binds
# it to the SAME Win32 message queue GDK needs for input, so calling it on
# Windows AT ALL — even after a drain — reopens the theft the whole patch exists
# to end. `RunLoop.main.limitDate` may only run in the `#else` (non-Windows)
# branch. If a future edit moved it back outside the `#else`, or dropped the
# drain/libdispatch calls out of the Windows branch, every text-only test still
# passes but the fix is reverted in substance. Verified against the real
# applied bytes of mainRunLoopTicklingLoop.
#
# (Originally written for round 5/6's shape — drain-then-unconditional-tick —
# which round 7 deliberately superseded; updated to match the round-7 fix this
# ticket's own patch header and findings document.)
# ---------------------------------------------------------------------------


def test_windows_input_patch_drains_glib_before_ticking_runloop_on_windows():
    _win_input_or_skip()
    git, tree = _pristine_tree_or_skip()
    assert _apply_patch(git, tree, PATCH_PATH).returncode == 0, "gesture apply failed"
    assert _apply_patch(git, tree, WINDOWS_INPUT_PATCH_PATH).returncode == 0, (
        "windows-input apply failed"
    )

    backend = (Path(tree) / "Sources/GtkBackend/GtkBackend.swift").read_text(
        encoding="utf-8"
    )
    idx = backend.find("func mainRunLoopTicklingLoop")
    assert idx != -1, (
        "mainRunLoopTicklingLoop vanished from GtkBackend.swift after apply"
    )
    # The whole tickler body is small; a generous window stays inside it (the next
    # `func ` bounds it) and never reaches an unrelated later function.
    nxt = backend.find("\n    private ", idx + 40)
    region = backend[idx : nxt if nxt != -1 else idx + 2500]

    pos_if = region.find("#if os(Windows)")
    pos_drain = region.find("g_main_context_iteration")
    pos_dispatch = region.find("scui_dispatchMainQueueCallback4CF")
    pos_else = region.find("#else", pos_if if pos_if != -1 else 0)
    pos_endif = region.find(
        "#endif", pos_else if pos_else != -1 else (pos_if if pos_if != -1 else 0)
    )
    # Anchor on the real code token, not bare "limitDate" — the patch's rationale
    # comment mentions "`limitDate` below" ABOVE the drain, which would otherwise
    # match first and invert the ordering check.
    pos_limit = region.find("RunLoop.main.limitDate")

    positions = {
        "#if os(Windows)": pos_if,
        "g_main_context_iteration": pos_drain,
        "scui_dispatchMainQueueCallback4CF": pos_dispatch,
        "#else": pos_else,
        "#endif": pos_endif,
        "RunLoop.main.limitDate": pos_limit,
    }
    missing = [name for name, pos in positions.items() if pos == -1]
    assert not missing, "mainRunLoopTicklingLoop after apply is missing %r:\n%s" % (
        missing,
        region,
    )
    assert pos_if < pos_drain < pos_else, (
        "findings §3/§Fix (round 7): the GLib drain (`g_main_context_iteration`) must "
        "sit in the TRUE branch of `#if os(Windows)` — BEFORE the `#else` — within the "
        "applied mainRunLoopTicklingLoop body"
    )
    assert pos_drain < pos_dispatch < pos_else, (
        "round 7: the GLib drain must run BEFORE servicing libdispatch's main queue "
        "(`scui_dispatchMainQueueCallback4CF`), and both must stay inside the Windows "
        "branch — PR #141's actual requirement (@MainActor/DispatchQueue.main work) "
        "is met by the libdispatch call, not by pumping RunLoop.main"
    )
    assert pos_else < pos_limit < pos_endif, (
        "findings §3/§Fix (round 7): on Windows, `RunLoop.main` must NEVER be pumped — "
        "swift-corelibs-foundation binds it to the SAME Win32 message queue GDK needs "
        "for mouse/keyboard/close input, so `RunLoop.main.limitDate` running on Windows "
        "at all (even after a drain) reopens the message-queue race this patch exists "
        "to end. `RunLoop.main.limitDate` must live ONLY in the `#else` (non-Windows) "
        "branch — found at offset %d, expected strictly between `#else` (%d) and "
        "`#endif` (%d)." % (pos_limit, pos_else, pos_endif)
    )


# ---------------------------------------------------------------------------
# ATTACK 53 (SUPPLY CHAIN / placement) — on the Windows legs the windows-input
# patch step must run AFTER `swift package resolve`, AFTER the swift-java symlink
# repair, AND after the gesture patch. The Swift tests order it only against the
# gesture step and build/test; nothing pins it against resolve or the reparse-point
# repair. Patching a checkout that has not been resolved (no .build/checkouts) or
# whose symlinked layers are still broken reparse points fails the `cd`/`git apply`
# on precisely the platform this ticket targets.
# ---------------------------------------------------------------------------


def test_windows_input_patch_step_is_absent_and_gsk_patch_still_runs_after_resolve_and_java_repair_on_windows_legs():
    """UPDATED for round 9 (specs/CUESYNC-9-findings.md §0.8): the windows-input
    patch step this test used to order against resolve/repair/gesture was
    reverted — a disproven, non-load-bearing patch per spec step 5. This is now a
    regression lock (the step must be ABSENT) PLUS a repurposed ordering check on
    the GSK-renderer patch step, which now occupies the slot immediately after the
    gesture step and must still land after resolve and the swift-java symlink
    repair — the same failure mode (patching an unresolved / still-broken checkout)
    the original test guarded against, now pinned to the patch that actually runs
    there."""
    for job in ("windows-build", "windows-test"):
        assert job in JOBS, "missing job " + job
        start, end = JOBS[job]
        resolve_idx = repair_idx = gesture_idx = win_input_idx = gsk_idx = None
        for k in range(start, end):
            m = STEP_NAME_RE.match(LINES[k])
            if not m:
                continue
            name = m.group(1)
            if name.startswith(RESOLVE_STEP_NAME):
                resolve_idx = k
            if name.startswith(REPAIR_STEP_NAME):
                repair_idx = k
            if GESTURE_STEP_NAME in name:
                gesture_idx = k
            if WINDOWS_INPUT_STEP_NAME in name:
                win_input_idx = k
            if WINDOWS_GSK_STEP_NAME in name:
                gsk_idx = k
        assert win_input_idx is None, (
            job + ": the windows-input patch step must be ABSENT — reverted in round 9 "
            "(specs/CUESYNC-9-findings.md §0.8); its reappearance is a regression to a "
            "disproven, non-load-bearing patch"
        )
        assert gsk_idx is not None, job + ": no GSK-renderer patch step found"
        for label, other in (
            (RESOLVE_STEP_NAME, resolve_idx),
            (REPAIR_STEP_NAME, repair_idx),
            (GESTURE_STEP_NAME, gesture_idx),
        ):
            assert other is not None, (
                "%s: the `%s` step is missing — the GSK-renderer patch step must run "
                "AFTER it, so its absence breaks the ordering premise" % (job, label)
            )
            assert other < gsk_idx, (
                "%s: the GSK-renderer patch step (line %d) must run AFTER `%s` (line %d) "
                "now that it is the step immediately following the gesture patch (the "
                "windows-input step that used to sit between them was reverted in round "
                "9). Patching an unresolved or still-broken-reparse-point checkout fails "
                "`git apply` on the Windows legs this patch exists to fix."
                % (job, gsk_idx, label, other)
            )


# ---------------------------------------------------------------------------
# ATTACK 54 (§4 runtime trust boundary) — the "+ Add Cue Point" button is a
# NOW-LIVE entry point (acceptance criteria list it explicitly). Its handler,
# ConfigureSectionView.addCueAtPosition(), parses `Double(newCueSec) ?? 0` /
# `Double(newCueMs) ?? 0` — and `Double("nan")`/`Double("inf")` PARSE, so `?? 0`
# does NOT catch them; a hand-typed `nan` reaches AppState.addCuePoint(at:), where
# `min(max(nan, 0), trackDuration)` stays NaN (Swift Comparable min/max propagate
# NaN). This path does NOT go through StepperField's isFinite guard (the only
# now-live guard ATTACK 36 pins), so the ONE thing standing between a typed `nan`
# and `cue.start` → the envelope Path/curve math is `.sanitized()` inside
# addCuePoint. spec §4: "a hand-typed nan/inf in a cue position … must never reach
# cue.start." This pins that backstop for the Add-Cue path specifically.
# ---------------------------------------------------------------------------


def _ui_src_or_skip(rel):
    p = REPO_ROOT / "CueSync" / "CueSync" / rel
    if not p.is_file():
        raise unittest.SkipTest("%s not found" % rel)
    return p.read_text(encoding="utf-8")


def _func_body(src, signature_needle, bound_needle="\n    func "):
    """Slice a Swift method body from its signature to the next method (or a
    generous window). Used for text-level guard assertions, not parsing."""
    i = src.find(signature_needle)
    if i == -1:
        return None
    j = src.find(bound_needle, i + len(signature_needle))
    return src[i : j if j != -1 else i + 1500]


def test_add_cue_point_now_live_path_sanitises_nonfinite_before_the_model():
    appstate = _ui_src_or_skip("UI/State/AppState.swift")
    body = _func_body(appstate, "func addCuePoint(")
    assert body is not None, "AppState.addCuePoint not found"
    assert ".sanitized()" in body, (
        "spec CUESYNC-9 §4: the NOW-LIVE `+ Add Cue Point` path parses "
        "`Double(newCueSec) ?? 0` (nan/inf survive `?? 0`) and does NOT use "
        "StepperField's isFinite guard, so AppState.addCuePoint(at:) MUST route the "
        "constructed cue through `.sanitized()` — the only backstop stopping a typed "
        "`nan` from landing in cue.start and reaching the envelope Path/curve math. "
        "That call is missing from addCuePoint."
    )
    # The wiring is real: the acceptance-criteria button funnels into addCuePoint.
    cfg = _ui_src_or_skip("UI/Sections/ConfigureSectionView.swift")
    assert "func addCueAtPosition" in cfg and "state.addCuePoint(" in cfg, (
        "ConfigureSectionView.addCueAtPosition() must still be the `+ Add Cue Point` "
        "handler that calls state.addCuePoint(at:) — if this rewiring changed, "
        "re-verify the now-live nan/inf entry point before trusting the guard above."
    )


# ---------------------------------------------------------------------------
# ATTACK 55 (§4 runtime trust boundary) — CuePoint.sanitized() is the model-layer
# backstop every now-live edit path (Add Cue, cue-table StepperField edits,
# duplicate-with-offset, imported tracks) leans on. It must neutralise a
# non-finite `start` AND a non-finite `yValue`, and clamp `curve` into 1...23.
# If a refactor dropped the isFinite check on either coordinate, NaN geometry
# reaches the canvas and the Resolume/ShowKontrol exporters. Nothing in this file
# pins the sanitiser itself — ATTACK 36 pins only the StepperField producer.
# ---------------------------------------------------------------------------


def test_cuepoint_sanitized_neutralises_nonfinite_start_and_yvalue_and_clamps_curve():
    src = _ui_src_or_skip("Models/CuePoint.swift")
    body = _func_body(src, "func sanitized(", bound_needle="\n    }")
    assert body is not None, "CuePoint.sanitized() not found"
    start_guarded = re.search(r"start\b[^\n]*\bisFinite\b", body) is not None
    yvalue_guarded = re.search(r"yValue\b[^\n]*\bisFinite\b", body) is not None
    curve_clamped = ("1...23" in body) or ("(1...23)" in body)
    assert start_guarded, (
        "spec §4: CuePoint.sanitized() must guard `start` with `isFinite` — otherwise a "
        "typed/imported NaN start survives into the envelope Path/curve math and export."
    )
    assert yvalue_guarded, (
        "spec §4: CuePoint.sanitized() must guard `yValue` with `isFinite` — a NaN "
        "y-value reaches the canvas draw and the exporter's 0..1 normalisation."
    )
    assert curve_clamped, (
        "spec §4: CuePoint.sanitized() must clamp `curve` into 1...23 (the 23 valid "
        "Resolume curve types) — an out-of-range curve index is hostile-input geometry."
    )


# ---------------------------------------------------------------------------
# ATTACK 56 (§4 runtime trust boundary) — the duration modal is now live (its
# Cancel/Import must respond per acceptance criteria). Its handler,
# ProjectSectionView.confirmDurationImport(), builds `totalSeconds` from
# `Double(durationMinutes) ?? 0` … (nan/inf survive `?? 0`) and feeds it to the
# track duration. The ONLY guard is AppState.safeDuration()'s isFinite check —
# and every branch (ShowKontrol direct, Resolume via loadResolumeEnvelope) must
# route the typed duration through it, or a NaN trackDuration reaches the
# `Int(duration …)` conversions AppState.safeDuration exists to keep from
# overflowing. spec §4 threat model calls out exactly these now-reachable paths.
# ---------------------------------------------------------------------------


def test_duration_modal_now_live_path_routes_typed_duration_through_safeduration_isfinite_guard():
    appstate = _ui_src_or_skip("UI/State/AppState.swift")
    safe_body = _func_body(appstate, "func safeDuration(", bound_needle="\n    }")
    assert safe_body is not None, "AppState.safeDuration not found"
    assert "isFinite" in safe_body, (
        "spec §4: AppState.safeDuration() must guard `isFinite` — it is the sole barrier "
        "between a typed `nan`/`inf` duration and the model's `Int(duration …)` math."
    )

    load_body = _func_body(appstate, "func loadResolumeEnvelope(")
    assert load_body is not None, "AppState.loadResolumeEnvelope not found"
    assert "safeDuration(" in load_body, (
        "spec §4: the Resolume branch of the duration modal calls loadResolumeEnvelope, "
        "which MUST pass the user-supplied `duration` through safeDuration() — otherwise "
        "a typed `nan` duration sets trackDuration non-finite and scales every cue."
    )

    cfg = _ui_src_or_skip("UI/Sections/ProjectSectionView.swift")
    confirm = _func_body(cfg, "func confirmDurationImport(")
    assert confirm is not None, "ProjectSectionView.confirmDurationImport not found"
    assert "safeDuration(" in confirm or "loadResolumeEnvelope(" in confirm, (
        "spec §4: confirmDurationImport() must not write trackDuration from a raw "
        "`Double(text) ?? 0` — every branch routes the typed duration through "
        "safeDuration() (directly for ShowKontrol, via loadResolumeEnvelope for Resolume)."
    )


# ===========================================================================
# CUESYNC-9 windows-input PATCH STEP hardening (ATTACK 57–62)
#
# The windows-input PATCH FILE is thoroughly attacked above (ATTACK 48–53) and by
# the Swift CUESYNC9WindowsInputDispatchWorkflowTests. What neither suite hardens
# is the windows-input STEP the way the gesture step is hardened (ATTACK 30/31/32/
# 44): the Swift step tests assert only that a token (`IsReadOnly`, `--reverse
# --check`) appears SOMEWHERE in the block — never its ORDER against the apply, the
# STRICTNESS of the forward `git apply`, byte-parity across the two Windows legs, or
# fail-loud on a bad apply. Those are exactly the properties a supply-chain-minded
# adversary edits to defeat the pin while leaving every existing test green. These
# six close that asymmetry, mirroring the gesture-step attacks one-for-one.
# ===========================================================================


def _win_input_step_blocks():
    """(job, name_line_idx, block_text) for every windows-input patch step, one per
    job. A block runs from its `- name:` line up to (excluding) the next step."""
    blocks = []
    for job, (jstart, jend) in JOBS.items():
        i = jstart
        while i < jend:
            m = STEP_NAME_RE.match(LINES[i])
            if m and m.group(1).startswith(WINDOWS_INPUT_STEP_NAME):
                j = i + 1
                while j < jend and not STEP_NAME_RE.match(LINES[j]):
                    j += 1
                blocks.append((job, i, "\n".join(LINES[i:j])))
                i = j
            else:
                i += 1
    return blocks


WINDOWS_INPUT_BLOCKS = _win_input_step_blocks()


def _win_input_bodies():
    """job -> de-indented `run: |` script body of that job's windows-input patch
    step. Reuses `_gesture_run_body`, which trims the trailing comment block that
    the windows-test leg carries and the windows-build leg does not — so two
    byte-identical scripts do not read as divergent purely by that comment."""
    return {job: _gesture_run_body(block) for job, _i, block in WINDOWS_INPUT_BLOCKS}


# ---------------------------------------------------------------------------
# ATTACK 57 (SUPPLY CHAIN) — every forward `git apply` of the windows-input patch
# must be STRICT (bare), on all three legs. ATTACK 44 pins this for the GESTURE
# patch only: `_all_forward_git_apply_lines()` scans the gesture step bodies (plus
# the whole dev script), never the windows-input WORKFLOW steps. So a future edit
# that added `--3way`, `--whitespace=fix`, `--reject`, `--unidiff-zero`, or a
# `-C<n>` fuzz flag to the windows-input `git apply` would let that patch land on
# DRIFTED context — a bumped pin or a tampered checkout — silently defeating the
# "audited == built" guarantee (spec CUESYNC-9 §4) for the windows-input patch
# specifically, and no Swift or Python test would notice.
# ---------------------------------------------------------------------------


def _all_windows_input_git_apply_lines():
    """(where, command) for every `git apply` of the windows-input patch across the
    three windows-input step bodies AND the dev script, comment-stripped. Includes
    the `--reverse --check` guard lines — a fuzzed reverse check would wrongly
    report 'already applied' and skip a needed apply, so strictness must hold there
    too."""
    out = []
    for job, body in _win_input_bodies().items():
        for ln in body.splitlines():
            code = ln.split("#", 1)[0]
            if "git apply" in code:
                out.append(("workflow:" + job, code.strip()))
    if DEV_PATCH_SCRIPT.is_file():
        for ln in _dev_script_code_or_skip().splitlines():
            code = ln.split("#", 1)[0]
            if "git apply" in code and "WINDOWS_INPUT" in code:
                out.append(("scripts/patch-swift-cross-ui.sh", code.strip()))
    return out


def test_every_git_apply_of_the_windows_input_patch_is_strict_not_fuzzy():
    invocations = _all_windows_input_git_apply_lines()
    if not invocations:
        raise unittest.SkipTest("no windows-input `git apply` invocation found")
    banned_substrings = [
        "--ignore-whitespace",
        "--whitespace",  # =fix mutates; =nowarn/=error still signal intent to coerce
        "--unidiff-zero",
        "--3way",
        "--reject",
        "--inaccurate-eof",
    ]
    fuzz_re = re.compile(r"(?:^|\s)-C\d")  # -C<n> relaxes required context (fuzz)
    for where, cmd in invocations:
        tail = cmd[cmd.index("git apply") + len("git apply") :]
        for flag in banned_substrings:
            assert flag not in tail, (
                "spec CUESYNC-9 §4 (audited==built): the windows-input `git apply` in "
                "%s carries `%s`, a leniency/partial-apply flag. `git apply` is strict "
                "by default; that strictness is the ONLY thing forcing the patch to "
                "match the audited v0.8.0 bytes exactly. With `%s` the patch applies to "
                "DRIFTED context (a bumped pin, a tampered checkout), silently defeating "
                "the pin. Invocation: %r" % (where, flag, flag, cmd)
            )
        assert not fuzz_re.search(tail), (
            "spec CUESYNC-9 §4: the windows-input `git apply` in %s carries a `-C<n>` "
            "fuzz flag that relaxes context matching, letting the patch land on code "
            "that has drifted from the audited commit. Keep it strict (bare). "
            "Invocation: %r" % (where, cmd)
        )


# ---------------------------------------------------------------------------
# ATTACK 58 (SPLIT-BRAIN) — the windows-build and windows-test windows-input step
# bodies must be BYTE-IDENTICAL. ATTACK 30 pins this for the gesture step; nothing
# pins it for windows-input. If the two Windows legs' input-patch steps drift, the
# build leg and the test leg compile differently-patched swift-cross-ui checkouts —
# the exact split-brain CUESYNC-6d suffered, where `swift build` and `swift test`
# disagree about what source they built. A green build then hides a test-leg break
# (or vice-versa) that only surfaces on the clean PC.
# ---------------------------------------------------------------------------


def test_windows_input_patch_step_absent_and_both_remaining_windows_patches_stay_byte_identical():
    """UPDATED for round 9 (specs/CUESYNC-9-findings.md §0.8): the windows-input
    patch step this test used to compare across legs was reverted, so there is
    nothing left to compare — that half is now a regression lock (no such step on
    either Windows leg). Repurposed to close a real, previously-unguarded gap
    instead: ATTACK 2 pins byte-identity for the swift-java repair step and
    ATTACK 30 for the gesture step, but nothing pinned it for the GSK-renderer
    patch step (the one that now runs immediately after gesture on every leg) —
    if it drifted between windows-build and windows-test, build and test would
    compile differently-patched checkouts, the exact split-brain CUESYNC-6d
    suffered."""
    win_input_bodies = _win_input_bodies()
    assert (
        "windows-build" not in win_input_bodies
        and "windows-test" not in win_input_bodies
    ), (
        "the windows-input patch step must be ABSENT on both Windows legs — "
        "reverted in round 9 (specs/CUESYNC-9-findings.md §0.8): "
        + repr(sorted(win_input_bodies))
    )

    gsk_bodies = _gsk_bodies()
    a, b = gsk_bodies.get("windows-build"), gsk_bodies.get("windows-test")
    assert a is not None and b is not None, (
        "GSK-renderer patch step missing on a Windows leg: " + repr(sorted(gsk_bodies))
    )
    assert a == b, (
        "spec CUESYNC-9 §4: the windows-build and windows-test GSK-renderer patch "
        "step bodies must not drift — a divergence means build and test compile "
        "differently-patched checkouts (the split-brain CUESYNC-6d suffered).\n"
        "--- windows-build ---\n" + a + "\n--- windows-test ---\n" + b
    )


# ---------------------------------------------------------------------------
# ATTACK 59 (ORDERING) — on both Windows legs the read-only clear must run BEFORE
# the forward `git apply`, and on EXACTLY the file the patch modifies. The Swift
# test (testWindowsInputPatchStepClearsWindowsReadOnlyFlagOnBothWindowsLegs) only
# asserts `IsReadOnly` appears SOMEWHERE in the block — a clear that ran AFTER the
# apply, or that named the wrong file, still contains the token yet is a live
# break: `git apply` hits a read-only dependency source and dies before the clear
# ever executes. Dependency sources check out read-only on Windows (the reason the
# gulong/gsize and gesture steps clear it too).
# ---------------------------------------------------------------------------


def test_windows_input_patch_absent_and_gsk_renderer_clears_read_only_before_apply_on_exactly_gtkbackend():
    """UPDATED for round 9 (specs/CUESYNC-9-findings.md §0.8): the windows-input
    step this test used to check ordering for was reverted — regression-locked
    below (no such step on either Windows leg). Repurposed onto a real,
    previously-unguarded gap in the GSK-renderer patch step (which now runs where
    windows-input used to): ATTACK D
    (test_gsk_renderer_patch_step_clears_read_only_on_exactly_gtkbackend_on_both_windows_legs)
    only asserts the read-only clear names the right file SOMEWHERE in the step —
    it never checks the clear runs BEFORE the forward `git apply`. A clear that ran
    after the apply still contains the token yet is a live break: `git apply` hits
    a read-only dependency source and dies before the clear ever executes."""
    win_input_bodies = _win_input_bodies()
    for job in ("windows-build", "windows-test"):
        assert job not in win_input_bodies, (
            job + ": the windows-input patch step must be ABSENT — reverted in round 9 "
            "(specs/CUESYNC-9-findings.md §0.8)"
        )

        body = _gsk_bodies()[job]
        apply_idx = body.find("git apply $patch")
        assert apply_idx != -1, (
            job + ": no forward `git apply $patch` in the GSK-renderer step"
        )
        ro_positions = [m.start() for m in re.finditer(r"IsReadOnly", body)]
        assert ro_positions, (
            job + ": GSK-renderer step never clears the Windows read-only flag"
        )
        assert all(p < apply_idx for p in ro_positions), (
            job + ": a `Set-ItemProperty … -Name IsReadOnly -Value $false` clear runs "
            "AFTER the forward `git apply` in the GSK-renderer step — the apply hits a "
            "read-only dependency source and fails before the clear ever executes "
            "(spec CUESYNC-9 §4)"
        )
        cleared = set()
        for _var, path in re.findall(r'\$(\w+)\s*=\s*"([^"]+)"', body):
            if path.endswith(".swift"):
                cleared.add(
                    path.replace("\\", "/").replace(
                        ".build/checkouts/swift-cross-ui/", ""
                    )
                )
        assert cleared == {"Sources/GtkBackend/GtkBackend.swift"}, (
            job + ": the GSK-renderer read-only clear targets %r, but the patch "
            "modifies ONLY GtkBackend.swift — clearing the wrong (or an extra) file "
            "leaves the real target read-only, or needlessly clears a file this patch "
            "does not touch (spec CUESYNC-9 §4: 'exactly the file(s) it patches')"
            % sorted(cleared)
        )


# ---------------------------------------------------------------------------
# ATTACK 60 (FAIL-LOUD) — a failed windows-input `git apply` must fail the job
# LOUD, on every leg. ATTACK 32 pins this for the gesture step only. A swallowed
# apply failure is the worst possible outcome: the build proceeds against a
# checkout still missing the message-queue-drain fix and ships the dead-on-click UI
# while CI stays green — precisely the "every gate green, nothing clickable"
# failure this whole ticket exists to end. macOS relies on `set -euo pipefail` so
# the bare forward `git apply "$PATCH"` aborts; the Windows legs check
# `$LASTEXITCODE -ne 0` and `exit 1` explicitly.
# ---------------------------------------------------------------------------


def test_windows_input_patch_step_is_absent_on_every_leg_including_macos():
    """REGRESSION LOCK (round 9, specs/CUESYNC-9-findings.md §0.8): the
    windows-input patch step must not exist on ANY of the three GtkBackend-
    compiling legs — including macos, which the other windows-input regression
    locks in this file do not separately check (they focus on the two Windows
    legs). Was: "the step must fail loud on a bad apply on every leg" — a check
    that presupposed a step that no longer exists. Its fail-loud INTENT survives
    unweakened: ATTACK 32 already pins fail-loud for the gesture patch step and
    ATTACK E (test_gsk_renderer_patch_step_is_reverse_guarded_and_fails_loud_on_every_leg)
    already pins it for the GSK-renderer patch step on all three legs, so nothing
    that patches GtkBackend.swift today ships un-checked for a swallowed `git
    apply` failure."""
    bodies = _win_input_bodies()
    for job in ("macos", "windows-build", "windows-test"):
        assert job not in bodies, (
            job + ": the windows-input patch step must be ABSENT — reverted in round 9 "
            "(specs/CUESYNC-9-findings.md §0.8); its reappearance is a regression to a "
            "disproven, non-load-bearing patch"
        )


# ---------------------------------------------------------------------------
# ATTACK 61 (correctness) — the GLib drain must be a LOOP that empties the context,
# not a single pass. findings §Fix is explicit: drain "in a loop until nothing is
# pending" so GDK gets first refusal on ALL queued input every tick. ATTACK 50
# pins only that the drain is Windows-only and non-blocking (may_block=0); a future
# edit collapsing `while g_main_context_iteration(nil, 0) != 0 {}` to a single
# `g_main_context_iteration(nil, 0)` call would pass ATTACK 50 (still `#if
# os(Windows)`, still may_block=0) yet drain at most ONE event per 50 ms tick,
# leaving a backlog of mouse/keyboard events for Foundation's competing PeekMessage
# to eat — the race the fix exists to end, back in slow motion.
# ---------------------------------------------------------------------------


def test_windows_input_patch_drain_loops_until_the_context_is_empty():
    _win_input_or_skip()
    added = _win_input_added_lines()
    drain_lines = [c for c in added if "g_main_context_iteration" in c]
    assert drain_lines, "the patch adds no `g_main_context_iteration` drain at all"
    joined = "\n".join(added)
    loop_re = re.compile(
        r"while\s*\(?\s*g_main_context_iteration\s*\([^)]*\)\s*!=\s*0", re.S
    )
    assert loop_re.search(joined), (
        "findings §Fix: the drain must repeat WHILE `g_main_context_iteration(nil, 0)` "
        "keeps returning non-zero (i.e. drain the context until it is empty), not run "
        "a single pass per tick. A one-shot drain leaves a per-tick backlog for "
        "Foundation's PeekMessage to consume — the ownership race, merely slowed. "
        "Added drain lines:\n    " + "\n    ".join(drain_lines)
    )


# ---------------------------------------------------------------------------
# ATTACK 62 (NO-REGRESSION, behavioral) — after applying BOTH patches in the real
# CI order (gesture first, windows-input second), the CUESYNC-8 `can-target` hunk
# must SURVIVE alongside the CUESYNC-9 drain, in the fully-patched bytes. ATTACK 24
# checks can-target on a gesture-ONLY tree; ATTACK 52 checks the drain on the
# both-applied tree but never re-checks can-target there. So a future windows-input
# patch that widened its hunk to overlap/clobber `createPathWidget` (or that a
# rebase silently mangled) would leave the fully-patched tree missing
# `canTarget = false` while passing every existing test — a silent CUESYNC-8
# regression the spec forbids ("the can-target hunk intact", "CUESYNC-8 tests stay
# green"). This asserts both fixes coexist in the exact bytes CI compiles.
# ---------------------------------------------------------------------------


def test_both_patches_applied_preserve_can_target_and_add_the_glib_drain():
    _win_input_or_skip()
    git, tree = _pristine_tree_or_skip()
    assert _apply_patch(git, tree, PATCH_PATH).returncode == 0, "gesture apply failed"
    assert _apply_patch(git, tree, WINDOWS_INPUT_PATCH_PATH).returncode == 0, (
        "windows-input apply (second, real CI order) failed"
    )

    backend = (Path(tree) / "Sources/GtkBackend/GtkBackend.swift").read_text(
        encoding="utf-8"
    )
    widget = (Path(tree) / "Sources/Gtk/Widgets/Widget.swift").read_text(
        encoding="utf-8"
    )

    idx = backend.find("createPathWidget")
    assert idx != -1, (
        "createPathWidget vanished from the fully-patched GtkBackend.swift"
    )
    nxt = backend.find("public func ", idx + len("public func createPathWidget"))
    factory_body = backend[idx:nxt] if nxt != -1 else backend[idx:]
    assert "canTarget = false" in factory_body, (
        "spec CUESYNC-9 no-regression: after BOTH patches apply, CUESYNC-8's "
        "`canTarget = false` in createPathWidget must still be present — the "
        "windows-input patch must not clobber the gesture hunk. It is missing from the "
        "fully-patched bytes."
    )
    assert '"can-target"' in widget and "canTarget" in widget, (
        "spec CUESYNC-9 no-regression: CUESYNC-8's `can-target` GObject-property "
        "wrapper on the Gtk Widget base class must survive the full patch sequence."
    )
    assert "g_main_context_iteration" in backend, (
        "spec CUESYNC-9: the windows-input GLib drain must be present in the "
        "fully-patched bytes CI compiles — both fixes must coexist."
    )


# ===========================================================================
# ATTACKS 63-66 — the round-4 GSK-renderer patch
# (patches/swift-cross-ui-0.8.0-windows-gsk-renderer.patch) has NO Python
# coverage at all before this section: it is named only as one of the three
# "expected" GtkBackend-touching files (test_dev_script_and_every_ci_leg_apply_
# the_one_checked_in_patch). Its own Swift compliance suite
# (CUESYNC9WindowsGskRendererWorkflowTests) scans the WHOLE patch text for a
# short banned-token list rather than just its added lines — the same class of
# bug ATTACK 48 closed for the windows-input patch (fixed alongside this suite).
# These attacks give the GSK patch the same supply-chain/behavioral floor the
# other two patches already have, scoped to what a single `g_setenv` hunk
# actually needs (no drain-loop/blocking concerns apply here).
# ---------------------------------------------------------------------------

WINDOWS_GSK_PATCH_PATH = REPO_ROOT / "patches" / WINDOWS_GSK_PATCH_NAME
WINDOWS_GSK_PATCH_TEXT = (
    WINDOWS_GSK_PATCH_PATH.read_text(encoding="utf-8")
    if WINDOWS_GSK_PATCH_PATH.is_file()
    else ""
)


def _gsk_or_skip():
    if not WINDOWS_GSK_PATCH_TEXT:
        raise unittest.SkipTest("%s not found" % WINDOWS_GSK_PATCH_NAME)
    return WINDOWS_GSK_PATCH_TEXT


def _gsk_added_lines():
    """Content of every added (`+`) line of the GSK-renderer patch, excluding the
    `+++` header — exactly the bytes `git apply` injects into GtkBackend. Mirrors
    _win_input_added_lines() for the same reason: header/comment prose legitimately
    names things (`Package.swift`, `RustDesk`, …) that are not added dependency
    lines."""
    return [
        ln[1:]
        for ln in WINDOWS_GSK_PATCH_TEXT.splitlines()
        if ln.startswith("+") and not ln.startswith("+++")
    ]


def test_gsk_patch_added_lines_are_pure_glib_setenv_no_exec_network_or_new_import():
    _gsk_or_skip()
    added = _gsk_added_lines()
    assert added, "the GSK-renderer patch adds no lines at all — nothing to review"

    forbidden = [
        "http://",
        "https://",
        "ftp://",
        "URLSession",
        "getaddrinfo",
        "socket(",
        "Process(",
        "NSTask",
        "posix_spawn",
        "system(",
        "popen(",
        "ShellExecute",
        "execve",
        "execvp",
        "/bin/sh",
        "cmd.exe",
        "Invoke-WebRequest",
        "Invoke-Expression",
        "eval(",
        "dlopen",
        "dlsym",
        "LoadLibrary",
        "GetProcAddress",
        "Data(contentsOf:",
        "FileHandle",
        "fopen(",
        "mmap(",
        "VirtualAlloc",
    ]
    for content in added:
        for token in forbidden:
            assert token not in content, (
                "spec CUESYNC-9 §4/§0.3: the GSK-renderer patch must be a pure "
                "GLib g_setenv call — no network, subprocess, dynamic load, or "
                "arbitrary file/memory I/O. An added line contains `%s`:\n    %s"
                % (token, content.strip())
            )
        assert not content.strip().startswith("import "), (
            "spec CUESYNC-9 §4 (no new dependency): the GSK-renderer patch must not "
            "add an `import` — the fix uses only GLib's own `g_setenv`, already "
            "reachable in GtkBackend.swift. Found:\n    %s" % content.strip()
        )


def test_gsk_patch_is_a_real_unified_diff_touching_only_gtkbackend_and_repins_nothing():
    text = _gsk_or_skip()
    assert (
        "diff --git a/Sources/GtkBackend/GtkBackend.swift "
        "b/Sources/GtkBackend/GtkBackend.swift" in text
    ), "expected a real `diff --git` unified-diff header for GtkBackend.swift"

    added = _gsk_added_lines()
    joined = "\n".join(added)
    for tool in ["-replace", "sed -i", "sed 's", "perl -pi", "awk '"]:
        assert tool not in joined, (
            'spec CUESYNC-9 §4 ("never sed/-replace"): the checked-in fix must be a '
            "real diff, not a `%s` text-substitution script. Found in an added line."
            % tool
        )
    # A bare shell redirect (`command > file`), NOT the `->` call-chain arrow the
    # patch's own rationale comment legitimately uses (e.g. "g_application_run ->
    # activate -> window realize") to describe GTK's init sequence.
    redirect = re.search(r"(?<!-)>\s", joined)
    assert redirect is None, (
        'spec CUESYNC-9 §4 ("never sed/-replace"): the checked-in fix must be a real '
        "diff, not a shell-redirect text-substitution. Found in an added line: %r"
        % joined[max(0, redirect.start() - 20) : redirect.start() + 20]
    )

    targets = sorted(set(re.findall(r"diff --git a/(\S+) b/\S+", text)))
    assert targets == ["Sources/GtkBackend/GtkBackend.swift"], (
        "spec CUESYNC-9 acceptance: the GSK-renderer patch must touch ONLY "
        "GtkBackend.swift (runMainLoop) — a second `diff --git` is an out-of-scope "
        "edit to another dependency file, a supply-chain smuggling surface. Found "
        "targets: %r" % targets
    )

    for repin in ["Package.swift", "Package.resolved", "exact:", ".package(", "from:"]:
        offenders = [c for c in added if repin in c]
        assert not offenders, (
            'spec CUESYNC-9 acceptance: swift-cross-ui stays pinned `exact: "0.8.0"` '
            "and Package.swift/Package.resolved are UNCHANGED — the GSK-renderer diff "
            "body must not touch the manifest or re-pin. An added line contains "
            "`%s`:\n    %s" % (repin, offenders[0].strip())
        )


def test_gsk_patch_setenv_call_is_scoped_inside_the_windows_only_guard():
    """The Swift compliance test only checks that `#if os(Windows)` and
    `g_setenv` each appear SOMEWHERE in the patch, never that the call sits
    INSIDE the guard. If `g_setenv("GSK_RENDERER", "cairo", 1)` leaked outside
    `#if os(Windows) ... #endif` it would force the software renderer on
    macOS/Linux too — the macOS GtkBackend CI leg must stay green with its
    working default renderer (spec §5)."""
    text = _gsk_or_skip()
    guard_start = text.find("#if os(Windows)")
    assert guard_start != -1, "no #if os(Windows) guard found in the GSK patch"
    guard_end = text.find("#endif", guard_start)
    assert guard_end != -1, "no matching #endif found for the GSK patch's Windows guard"
    setenv_pos = text.find("g_setenv(", guard_start)
    assert setenv_pos != -1, "no g_setenv( call found after the Windows guard opens"
    assert setenv_pos < guard_end, (
        'spec CUESYNC-9 §5: the g_setenv("GSK_RENDERER", "cairo", ...) call must '
        "sit INSIDE the #if os(Windows) ... #endif guard, not after it closes — "
        "otherwise it would force the software renderer on macOS/Linux too"
    )


# ---------------------------------------------------------------------------
# ATTACK 64 (BEHAVIORAL) — all three patches must apply cleanly IN SEQUENCE
# against the real pinned checkout, in the exact order CI/the dev script use
# (gesture, then windows-input, then GSK). Every text-only test above can pass
# on a GSK patch whose `@@` hunk offsets have gone stale relative to the
# ALREADY-patched tree (the state it actually applies against in CI), while
# `git apply` fails for real and the whole GtkBackend build dies. Skips (never
# errors) if no git toolchain / resolved checkout at the audited commit is
# present, mirroring ATTACK 22/51/62.
# ---------------------------------------------------------------------------


def test_all_three_patches_apply_cleanly_in_the_real_ci_sequence_gesture_then_input_then_gsk():
    _gsk_or_skip()
    _win_input_or_skip()
    git, tree = _pristine_tree_or_skip()
    assert _apply_patch(git, tree, PATCH_PATH).returncode == 0, (
        "gesture (CUESYNC-8) apply failed against the pristine checkout"
    )
    assert _apply_patch(git, tree, WINDOWS_INPUT_PATCH_PATH).returncode == 0, (
        "windows-input (CUESYNC-9) apply failed after the gesture patch"
    )
    r = _apply_patch(git, tree, WINDOWS_GSK_PATCH_PATH)
    assert r.returncode == 0, (
        "spec CUESYNC-9 §0.3/acceptance: the GSK-renderer patch must apply "
        "cleanly via `git apply` after the gesture and windows-input patches, "
        "the exact real CI/dev-script order. stderr:\n%s" % r.stderr
    )

    backend = (Path(tree) / "Sources/GtkBackend/GtkBackend.swift").read_text(
        encoding="utf-8"
    )
    assert "GSK_RENDERER" in backend and "g_main_context_iteration" in backend, (
        "spec CUESYNC-9: after all three patches apply, the fully-patched "
        "GtkBackend.swift must contain both the GSK_RENDERER=cairo fix and the "
        "windows-input GLib drain — all three fixes must coexist in the exact "
        "bytes CI compiles"
    )


# =============================================================================
# CUESYNC-9 Red-Team — the now-LIVE untrusted VALUE paths (exporters + XML import)
#
# Spec CUESYNC-9 §4 threat model: "making the *whole* UI live means value-handling
# paths that were previously unreachable on Windows now actually run, so their
# existing guards matter *more*." The suite above locks the FILENAME boundary
# (slugify) and the scalar field guards (StepperField.isFinite, CuePoint.sanitized).
# These attacks target the two trust boundaries that had ZERO Python-runtime
# coverage: the bytes the exporters EMIT from an untrusted cue/preset name
# (Resolume XML, ShowKontrol .cue) and the bytes the Resolume XML importer INGESTS.
# Every one of those values originates from a hostile file the §4 model enumerates
# (Rekordbox XML, Serato GEOB, Engine DJ SQLite, ShowKontrol/Resolume) or from a
# text field that CUESYNC-8/9 just made typeable on Windows.
#
# Each test compiles the REAL shared source (CuePoint + ParseError + the two
# Exporters + ResolumeParser) into a batched driver and drives adversarial input
# through it — the logic under test is never mocked. Tests that PASS are durable
# regression locks on a §4 guarantee; tests that FAIL reproduce a live, un-mitigated
# gap (per repo rule §E.24: fix the code or retarget the test, never weaken it).
# Skips (never hard-errors) when no Swift toolchain / source is present.
# =============================================================================

import xml.etree.ElementTree as ET  # noqa: E402  (section-local, stdlib)

_CS_SOURCE_RELPATHS = [
    ("CueSync", "CueSync", "Models", "CuePoint.swift"),
    ("CueSync", "CueSync", "Models", "ParseError.swift"),
    ("CueSync", "CueSync", "Exporters", "ResolumeExporter.swift"),
    ("CueSync", "CueSync", "Exporters", "ShowKontrolExporter.swift"),
    ("CueSync", "CueSync", "Parsers", "ResolumeParser.swift"),
]

# ShowKontrol row: formatted , compact , ms , name , TAG , then 6 trailing empties.
_SK_FIELD_COUNT = 11
_TC_RE = re.compile(r"^\d{2}:\d{2}:\d{2}:\d{2}$")
_PLAIN_DECIMAL_RE = re.compile(r"^-?\d+(?:\.\d+)?$")

# Batched driver compiled against the real exporters/parser. One command per line,
# one base64'd result line each (base64 both ways keeps the framing intact even when
# a hostile name contains newlines / NULs / the field separator itself):
#   sk    <b64name> <startStr>                         -> b64(ShowKontrol .cue text)
#   res   <b64presetName> <startStr> <curveStr> <durStr> -> b64(Resolume XML)
#   parse <b64xml>                                       -> b64("OK\t<name>\t<n>" | "THREW\t<e>")
_CS_HARNESS_MAIN = r"""
import Foundation

func b64dec(_ s: String) -> String {
    guard let d = Data(base64Encoded: s) else { return "" }
    return String(decoding: d, as: UTF8.self)
}
func b64enc(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

func makeCue(name: String, start: Double, curve: Int) -> CuePoint {
    CuePoint(id: "cue", start: start, name: name, color: "#1ed760",
             yValue: 50, curve: curve, enabled: true)
}

while let line = readLine(strippingNewline: true) {
    let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    switch f[0] {
    case "sk":
        let name = b64dec(f[1])
        let start = Double(f[2]) ?? 0
        let cue = makeCue(name: name, start: start, curve: 1)
        print(b64enc(ShowKontrolExporter.generate(cuePoints: [cue]) ?? "<nil>"))
    case "res":
        let presetName = b64dec(f[1])
        let start = Double(f[2]) ?? 0
        let curve = Int(f[3]) ?? 1
        let dur = Double(f[4]) ?? 10
        let cue = makeCue(name: "pt", start: start, curve: curve)
        print(b64enc(ResolumeExporter.generate(cuePoints: [cue], trackDuration: dur,
                                               presetName: presetName) ?? "<nil>"))
    case "parse":
        let xml = b64dec(f[1])
        do {
            let r = try ResolumeParser.parse(xml: xml)
            print(b64enc("OK\t\(r.presetName)\t\(r.points.count)"))
        } catch {
            print(b64enc("THREW\t\(error)"))
        }
    default:
        print(b64enc("ERR"))
    }
}
"""

_CS_HARNESS = {"built": False, "bin": None, "err": None}


def _cs_sources_or_none():
    srcs = []
    for parts in _CS_SOURCE_RELPATHS:
        p = REPO_ROOT.joinpath(*parts)
        if not p.is_file():
            return None
        srcs.append(str(p))
    return srcs


def _cs_harness_binary():
    """Compile CuePoint + ParseError + both exporters + ResolumeParser + driver once.

    Raises unittest.SkipTest (never a hard error) when no Swift toolchain / source is
    available, so the pure-Python suite is unaffected.
    """
    st = _CS_HARNESS
    if st["built"]:
        if st["bin"] is None:
            raise unittest.SkipTest(st["err"])
        return st["bin"]
    st["built"] = True
    srcs = _cs_sources_or_none()
    if srcs is None:
        st["err"] = (
            "CueSyncCore exporter/parser sources not found — cannot exercise them"
        )
        raise unittest.SkipTest(st["err"])
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        st["err"] = "swiftc not on PATH — skipping Swift-execution red-team tests"
        raise unittest.SkipTest(st["err"])
    workdir = tempfile.mkdtemp(prefix="cuesync9_value_redteam_")
    atexit.register(shutil.rmtree, workdir, True)
    main_swift = os.path.join(workdir, "main.swift")
    with open(main_swift, "w", encoding="utf-8") as fh:
        fh.write(_CS_HARNESS_MAIN)
    binpath = os.path.join(workdir, "harness")
    proc = subprocess.run(
        [swiftc, *srcs, main_swift, "-o", binpath],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not os.path.exists(binpath):
        st["err"] = "value-path harness build failed:\n" + proc.stderr
        raise unittest.SkipTest(st["err"])
    st["bin"] = binpath
    return binpath


def _run_cs_batch(commands):
    """Feed driver commands via stdin; return exactly one decoded output line each."""
    binpath = _cs_harness_binary()
    proc = subprocess.run(
        [binpath],
        input="\n".join(commands) + "\n",
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, "value-path harness runtime error:\n" + proc.stderr
    lines = proc.stdout.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    assert len(lines) == len(commands), (
        "value-path harness returned %d lines for %d commands (framing broke)"
        % (
            len(lines),
            len(commands),
        )
    )
    return [base64.b64decode(o).decode("utf-8") for o in lines]


def _numarg(v):
    """A space-free numeric token for the line protocol. A str is passed verbatim to
    Swift's `Double(_:)` (so callers can send "nan"/"inf"/"-inf"/"1e308"); a number
    is repr'd."""
    s = v if isinstance(v, str) else repr(v)
    assert " " not in s, "numeric protocol arg must be space-free, got %r" % (s,)
    return s


def _strip_swift_line_comments(src):
    """Drop `// …` tails so a "// should disable X" note can't green a source guard."""
    out = []
    for ln in src.splitlines():
        i = ln.find("//")
        out.append(ln[:i] if i >= 0 else ln)
    return "\n".join(out)


def _cs_read_source_or_skip(*parts):
    p = REPO_ROOT.joinpath(*parts)
    if not p.is_file():
        raise unittest.SkipTest("source not found: %s" % p)
    return p.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# ATTACK 60 (LOCK) — ShowKontrol .cue is a comma/CR delimited record format. A
# hostile cue name (from a parsed file or a now-typeable field) must not be able
# to inject an extra COLUMN (a comma) or an extra ROW (the format's own CR record
# separator, or a LF). ShowKontrolExporter.swift's own comment promises exactly
# this. spec §4 (untrusted values now reach the exporter window-wide on Windows).
# ---------------------------------------------------------------------------


def test_showkontrol_export_cannot_inject_rows_or_columns_from_a_hostile_cue_name():
    attacks = [
        "clean name",
        "a,b,c,EXTRA,COLUMN",  # comma = field separator
        "row1\rrow2",  # CR = the .cue record separator
        "row1\nrow2",  # LF
        "row1\r\nrow2",  # CRLF
        "x,\r00:00:00:00,00000000,0,FORGED,TAG,,,,,,",  # a full forged trailing record
        ",,,,,,,,,,",  # nothing but separators
    ]
    outs = _run_cs_batch(["sk %s 1.0" % _b64(a) for a in attacks])
    for a, out in zip(attacks, outs):
        assert out != "<nil>", "one enabled cue must still export (name %r)" % a
        assert "\r" not in out, (
            "spec §4: ShowKontrolExporter split a single cue into %d records — name %r "
            "injected a CR record separator into the .cue output"
            % (out.count("\r") + 1, a)
        )
        assert "\n" not in out, "name %r leaked a LF into the .cue output" % a
        fields = out.split(",")
        assert len(fields) == _SK_FIELD_COUNT, (
            "ShowKontrol row is %d comma-fields; name %r produced %d — a comma in the "
            "name injected extra columns" % (_SK_FIELD_COUNT, a, len(fields))
        )


# ---------------------------------------------------------------------------
# ATTACK 61 (LIVE FINDING — expected to FAIL until hardened) — the anti-row-
# injection strip in ShowKontrolExporter removes only ',', CR and LF. But CR and
# LF are two of at least SEVEN characters that Unicode line-breaking (UAX #14) and
# Swift's own CharacterSet.newlines classify as MANDATORY line boundaries:
#   U+000B VT, U+000C FF, U+0085 NEL, U+2028 LS, U+2029 PS (+ CR, LF).
# The project ALREADY treats this whole set as newlines — ShowKontrolParser trims
# `.whitespacesAndNewlines` (which is exactly this set) off every field. So any
# consumer that splits records with the standard newline set — including an
# idiomatic `.components(separatedBy: .newlines)` re-import — reads a cue name that
# embeds U+2028 as TWO rows. The exporter's "a cue name can't inject extra rows"
# guarantee (its own comment) is incomplete: it denylists 2 of the 7 separators.
# Fix: normalise the full newline class, not just CR/LF.
# ---------------------------------------------------------------------------


def test_showkontrol_export_neutralises_every_record_separator_not_just_cr_and_lf():
    seps = {
        "U+000B VT": "",
        "U+000C FF": "",
        "U+0085 NEL": "",
        "U+2028 LS": " ",
        "U+2029 PS": " ",
    }
    labels = list(seps.keys())
    names = ["evil%sINJECTED" % seps[k] for k in labels]
    outs = _run_cs_batch(["sk %s 1.0" % _b64(n) for n in names])
    survived = [labels[i] for i, out in enumerate(outs) if seps[labels[i]] in out]
    assert not survived, (
        "spec §4 (record injection): ShowKontrolExporter's name sanitiser strips only "
        "',', CR and LF, so these Unicode/UAX-14 line separators survive verbatim into "
        "the .cue output and split one cue into multiple records for any consumer using "
        "the standard newline set — the SAME set the project's own ShowKontrolParser "
        "trims with `.whitespacesAndNewlines`: %s. Fix: normalise the full newline "
        "class in the exporter, not just CR/LF." % ", ".join(survived)
    )


# ---------------------------------------------------------------------------
# ATTACK 62 (LOCK) — a hostile cue `start` (NaN/Inf/negative/overflow from a
# corrupt project or parser) must never reach the .cue timecode as "nan"/"inf" or
# an out-of-range/overflowing value. secondsToTimecode clamps to [0, 359999];
# this pins that the emitted record is always a well-formed, bounded timecode.
# ---------------------------------------------------------------------------


def test_showkontrol_timecode_is_bounded_and_wellformed_for_hostile_start_values():
    attacks = ["nan", "inf", "-inf", "-5", "1e18", "1e308", "359999", "0"]
    outs = _run_cs_batch(["sk %s %s" % (_b64("Cue"), _numarg(s)) for s in attacks])
    for s, out in zip(attacks, outs):
        assert out != "<nil>"
        fields = out.split(",")
        assert len(fields) == _SK_FIELD_COUNT
        formatted, compact, ms = fields[0], fields[1], fields[2]
        numeric = (formatted + " " + compact + " " + ms).lower()
        assert "nan" not in numeric and "inf" not in numeric, (
            "hostile start %r leaked a non-finite token into the .cue timecode: %r"
            % (
                s,
                out,
            )
        )
        assert _TC_RE.fullmatch(formatted), (
            "timecode %r is not HH:MM:SS:FF for start %r" % (formatted, s)
        )
        assert 0 <= int(formatted[:2]) <= 99, "hours out of range for start %r" % (s,)
        assert compact.isdigit() and len(compact) == 8, (
            "compact timecode %r malformed for start %r" % (compact, s)
        )
        assert ms.isdigit(), (
            "milliseconds field %r is not a non-negative integer (start %r)" % (ms, s)
        )
        assert 0 <= int(ms) <= 359_999_000, (
            "milliseconds %s exceeds the 100h clamp (start %r)" % (ms, s)
        )


# ---------------------------------------------------------------------------
# ATTACK 63 (LOCK) — Resolume export is XML: the untrusted preset name lands in an
# attribute value. An injection attempt (quote/element/CDATA/entity breakout) must
# be neutralised to plain data, and the document must stay well-formed. We parse
# the REAL output with a strict XML parser and require the name to round-trip
# exactly — proving markup was escaped, not interpreted. spec §4.
# ---------------------------------------------------------------------------


def test_resolume_export_neutralises_xml_injection_in_the_preset_name():
    attacks = [
        "plain",
        '"/><Malicious a="',  # attribute/quote breakout
        "']]>",  # CDATA close
        "A&B<C>D\"E'F",  # all five metacharacters
        'x"/><point x="9" y="9" curve="9"/><Preset name="',  # element injection
        "&xxe; &amp; &#x41;",  # entity-looking text
        "emoji\U0001f39b️ accént",  # legal non-ASCII passes through
    ]
    outs = _run_cs_batch(["res %s 1.0 1 10" % _b64(a) for a in attacks])
    for a, out in zip(attacks, outs):
        assert out != "<nil>"
        try:
            root = ET.fromstring(out)
        except ET.ParseError as e:
            raise AssertionError(
                "ResolumeExporter emitted MALFORMED XML for preset name %r: %s\n%s"
                % (a, e, out[:200])
            )
        assert root.tag == "Preset"
        assert root.attrib.get("name") == a, (
            "spec §4: preset name did not round-trip — emitted %r, expected %r. The "
            "escaper mangled or under-escaped the untrusted name."
            % (root.attrib.get("name"), a)
        )
        curves = [p.attrib.get("curve") for p in root.iter("point")]
        assert all(c == "1" for c in curves), (
            "injected markup created rogue <point> elements (curves=%s) for name %r"
            % (
                curves,
                a,
            )
        )


# ---------------------------------------------------------------------------
# ATTACK 64 (LOCK) — XML 1.0 forbids most C0 control bytes outright (no character
# reference exists), so a control scalar in the untrusted preset name would make
# ResolumeParser (and Resolume itself) reject the file. stripIllegalXmlScalars must
# drop them while keeping the legal tab/newline/CR. spec §4.
# ---------------------------------------------------------------------------


def test_resolume_export_strips_c0_control_scalars_xml_forbids():
    controls = "".join(chr(c) for c in [0x00, 0x01, 0x02, 0x08, 0x0B, 0x0C, 0x0E, 0x1F])
    name = "a" + controls + "b"
    out = _run_cs_batch(["res %s 1.0 1 10" % _b64(name)])[0]
    assert out != "<nil>"
    root = ET.fromstring(out)  # must be well-formed
    assert root.attrib.get("name") == "ab", (
        "spec §4: XML-illegal C0 control scalars survived into the Resolume name "
        "attribute (%r) — the emitted preset would be rejected by a strict XML reader"
        % root.attrib.get("name")
    )


# ---------------------------------------------------------------------------
# ATTACK 65 (LOCK) — a hostile `curve` (out of 1..23) or non-finite `start` from a
# corrupt cue must never reach the Resolume XML as an out-of-range curve id or a
# "nan"/"inf"/scientific coordinate a strict Resolume parser would reject. Pins the
# curve clamp and the formatDouble/normalized coordinate guards. spec §4.
# ---------------------------------------------------------------------------


def test_resolume_export_clamps_hostile_curve_and_neutralises_nonfinite_position():
    curves = [0, -1, 24, 999, -2147483648, 2147483647]
    starts = ["nan", "inf", "-inf", "1e308", "-5"]
    cmds, keys = [], []
    for c in curves:
        for s in starts:
            cmds.append("res %s %s %d 10" % (_b64("pt"), _numarg(s), c))
            keys.append((c, s))
    outs = _run_cs_batch(cmds)
    for (c, s), out in zip(keys, outs):
        assert out != "<nil>", "curve=%d start=%r produced nil" % (c, s)
        root = ET.fromstring(out)
        # Check the attribute VALUES precisely (a whole-document substring scan would
        # false-match the "versionInfo" boilerplate) — a leaked NaN/Inf shows up as a
        # coordinate that fails the finite-plain-decimal regex or a curve out of range.
        for p in root.iter("point"):
            cv = int(p.attrib["curve"])
            assert 1 <= cv <= 23, "curve %d not clamped to 1..23 (hostile curve=%d)" % (
                cv,
                c,
            )
            for axis in ("x", "y"):
                v = p.attrib[axis]
                assert _PLAIN_DECIMAL_RE.fullmatch(v), (
                    "non-finite/scientific coordinate %s=%r leaked into Resolume XML "
                    "(hostile start=%r)" % (axis, v, s)
                )
                assert 0.0 <= float(v) <= 1.0, (
                    "coordinate %s=%s outside [0,1] (start=%r)" % (axis, v, s)
                )


# ---------------------------------------------------------------------------
# ATTACK 66 (LOCK on Darwin) — the Resolume XML importer must not resolve an
# external SYSTEM entity (classic XXE file-read/SSRF). We craft a DOCTYPE with a
# SYSTEM entity pointing at a runtime-created secret file (§4: no hardcoded paths),
# reference it in the preset name, and require the secret to NOT appear in the
# parse result. On Darwin the default is safe; this pins that it stays safe. The
# Linux/Windows FoundationXML path — the port's actual target — is guarded by the
# explicit-disable finding below (ATTACK 67), since it can't be exercised here.
# ---------------------------------------------------------------------------


def test_resolume_parser_does_not_resolve_external_entities_into_the_preset_name():
    secret_dir = tempfile.mkdtemp(prefix="cuesync9_xxe_")
    atexit.register(shutil.rmtree, secret_dir, True)
    secret_path = os.path.join(secret_dir, "secret.txt")
    token = "TOPSECRET_XXE_LEAK_9f3ac1"
    with open(secret_path, "w", encoding="utf-8") as fh:
        fh.write(token)
    uri = "file://" + secret_path.replace("\\", "/")
    xxe = (
        '<?xml version="1.0"?>\n'
        '<!DOCTYPE Preset [ <!ENTITY xxe SYSTEM "%s"> ]>\n'
        '<Preset name="&xxe;"><point x="0" y="0" curve="1"/>'
        '<point x="1" y="0" curve="1"/></Preset>' % uri
    )
    out = _run_cs_batch(["parse %s" % _b64(xxe)])[0]
    assert token not in out, (
        "XXE: ResolumeParser resolved an external SYSTEM entity and leaked local file "
        "contents into the parsed preset name: %r" % out
    )


# ---------------------------------------------------------------------------
# ATTACK 67 (LIVE FINDING — expected to FAIL until hardened) — both XML importers
# construct `XMLParser(data:)` and never set `shouldResolveExternalEntities = false`,
# relying on an undocumented parser default. OWASP's XXE Prevention Cheat Sheet is
# explicit: do NOT rely on the default; disable it. This matters most on exactly the
# platform this whole port targets: RekordboxParser's OWN comment already warns that
# "XMLParser's Linux/Windows implementation (libxml2 via FoundationXML) does not
# reliably [behave] the way Darwin's Foundation does". A resolved SYSTEM entity there
# is an XXE local-file read / SSRF against an untrusted Rekordbox/Resolume file. The
# one-line fix (`parser.shouldResolveExternalEntities = false`) is defence-in-depth
# against parser-default drift on the divergent path the code itself flags.
# ---------------------------------------------------------------------------


def test_xml_parsers_explicitly_disable_external_entity_resolution():
    subjects = [
        ("Parsers", "ResolumeParser.swift"),
        ("Parsers", "RekordboxParser.swift"),
    ]
    pat = re.compile(r"shouldResolveExternalEntities\s*=\s*false")
    missing = []
    for sub in subjects:
        code = _strip_swift_line_comments(
            _cs_read_source_or_skip("CueSync", "CueSync", *sub)
        )
        assert "XMLParser(" in code, (
            "%s no longer constructs an XMLParser — re-locate the XML trust boundary "
            "before trusting this test" % sub[-1]
        )
        if not pat.search(code):
            missing.append(sub[-1])
    assert not missing, (
        "XXE hardening (spec §4 — untrusted XML crosses a trust boundary): these XML "
        "importers construct XMLParser but never set `shouldResolveExternalEntities = "
        "false`, relying on an undocumented default. OWASP XXE Prevention: never rely on "
        "the parser default. RekordboxParser's own comment already flags that the "
        "Linux/Windows FoundationXML (libxml2) path diverges from Darwin — the exact "
        "platform this port targets and where a resolved SYSTEM entity is an XXE "
        "file-read/SSRF. Set it explicitly on: %s" % ", ".join(missing)
    )


# ---------------------------------------------------------------------------
# ATTACK 68 (platform quirk / no-regression) — EVERY checked-in swift-cross-ui
# patch, not just the two CUESYNC-9 added, must be LF-only. The Swift suite
# added a `contains(0x0D)` CRLF guard for the windows-input and
# windows-gsk-renderer patches (CUESYNC9PatchFilePlatformQuirkTests /
# CUESYNC9GskRendererPatchFileTests) because `git apply` is sensitive to
# line-ending corruption and both patches apply on the Windows runners this
# ticket targets. Neither that suite nor this one ever wrote the same guard for
# the FIRST patch in the apply order — the CUESYNC-8 gtk-interactivity patch —
# even though it applies on the identical two Windows legs, ahead of the other
# two (scripts/patch-swift-cross-ui.sh and swift-windows.yml both apply
# interactivity -> windows-input -> gsk-renderer). A CRLF-corrupted
# interactivity patch (e.g. from a careless checkout/editor `autocrlf` setting)
# would fail `git apply` before the other two patches are even attempted,
# breaking all three Windows-touching legs — a gap this ticket's own
# no-regression requirement ("CUESYNC-8 interactivity patch is unchanged")
# should have caught. Parametrised over all three patch files (pytest style)
# instead of one test per file, since the assertion and rationale are identical.
# ---------------------------------------------------------------------------


def test_every_checked_in_swift_cross_ui_patch_is_lf_only():
    patches = {
        GESTURE_PATCH_NAME: PATCH_PATH,
        WINDOWS_INPUT_PATCH_NAME: WINDOWS_INPUT_PATCH_PATH,
        WINDOWS_GSK_PATCH_NAME: WINDOWS_GSK_PATCH_PATH,
    }
    offenders = []
    for name, path in patches.items():
        if not path.is_file():
            raise unittest.SkipTest("%s not present in this checkout" % name)
        if b"\r" in path.read_bytes():
            offenders.append(name)
    assert not offenders, (
        "these checked-in swift-cross-ui patch(es) contain a carriage return "
        "(CRLF-corrupted): %s. Every patch here is applied via `git apply` on "
        "windows-build/windows-test — a CRLF-rewritten LF patch fails to apply "
        "on exactly the platform these patches exist to fix." % ", ".join(offenders)
    )


# =============================================================================
# Red-Team adversarial suite — CUESYNC-9 §4 value-CHAIN attacks
#
# Everything above pins single functions or the workflow text. This block attacks
# the *chained* value paths a hostile file actually traverses end-to-end — the legs
# the existing Swift-execution harness (`_CS_HARNESS`: sk-export / res-export /
# res-parse only) never wires. Here we RE-PARSE exported ShowKontrol back through the
# real `ShowKontrolParser`, drive the Serato-GEOB and Rekordbox importers at runtime,
# and feed one parser's output straight into another's exporter. CUESYNC-9 is what
# makes every one of these live on Windows (§4: "value-handling paths that were
# previously unreachable on Windows now actually run, so their existing guards matter
# *more*").
#
# A hostile cue name / coordinate crossing TWO trust boundaries (import -> export, or
# export -> re-import) is exactly where a single-function guard can look fine yet the
# composed pipeline still injects a record, shifts a column, or leaks a file. Each
# test compiles the REAL parsers + exporters into one driver and runs the whole chain;
# a PASS is a durable regression lock on the *composed* guarantee, a FAIL reproduces a
# live chained gap (repo rule §E.24: fix the code or retarget the test, never weaken
# it). Skips (never hard-errors) when no Swift toolchain / source is present, so the
# pure-Python suite is unaffected.
#
# Framing: the driver base64-encodes its whole tab-joined result line (so a hostile
# name carrying tabs/newlines/NULs can never break the one-line-per-command framing),
# and any free-form field inside it (export text, XML, a parsed name) is itself
# base64'd — decode the outer line, split on TAB, `_rt_inner()` the nested fields.
# =============================================================================

_RT_SOURCE_RELPATHS = [
    ("CueSync", "CueSync", "Models", "CuePoint.swift"),
    ("CueSync", "CueSync", "Models", "ParseError.swift"),
    ("CueSync", "CueSync", "Models", "Track.swift"),
    ("CueSync", "CueSync", "Models", "Playlist.swift"),
    ("CueSync", "CueSync", "Models", "CurveType.swift"),
    ("CueSync", "CueSync", "Parsers", "ResolumeParser.swift"),
    ("CueSync", "CueSync", "Parsers", "RekordboxParser.swift"),
    ("CueSync", "CueSync", "Parsers", "SeratoParser.swift"),
    ("CueSync", "CueSync", "Parsers", "ShowKontrolParser.swift"),
    ("CueSync", "CueSync", "Exporters", "ShowKontrolExporter.swift"),
    ("CueSync", "CueSync", "Exporters", "ResolumeExporter.swift"),
]

# Driver compiled against the real parsers + exporters. One command per line:
#   skrt <b64name> <startStr>  -> b64("records\treCount\tfields\thasCR\thasLF\tmaxMs\t<b64 sk-text>")
#         export one cue(name,start) with ShowKontrolExporter, then RE-PARSE the text
#         through ShowKontrolParser. records = #\r-split records; fields = #comma-columns
#         of the first record; reCount/maxMs describe the cues the parser reads BACK.
#   sersk <b64name>            -> b64("cueCount\t<b64 sk-text>")
#         decode a Serato Markers2 GEOB whose CUE name = <name>, then ShowKontrol-export it.
#   rbres <b64xml>             -> b64("OK\tcueCount\t<b64 resolume-xml>" | "THREW\t<b64 err>")
#         Rekordbox-import the XML, then Resolume-export the first track's cues (dur 60).
#   rbparse <b64xml>           -> b64("OK\ttrackCount\tcueCount\t<b64 firstTrackName>" | "THREW\t<b64 err>")
_RT_HARNESS_MAIN = r"""
import Foundation

func b64dec(_ s: String) -> String { guard let d = Data(base64Encoded: s) else { return "" }; return String(decoding: d, as: UTF8.self) }
func b64enc(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

// Build a minimal well-formed Serato Markers2 payload carrying exactly one CUE entry
// whose null-terminated UTF-8 name is `name` (position fixed at 5000 ms).
func seratoBlob(name: String, ms: UInt32 = 5000, index: UInt8 = 1) -> Data {
    var payload: [UInt8] = [0x00, index,
        UInt8((ms >> 24) & 0xFF), UInt8((ms >> 16) & 0xFF), UInt8((ms >> 8) & 0xFF), UInt8(ms & 0xFF),
        0x00, 0xCC, 0x00, 0x00, 0x00]
    payload += Array(name.utf8); payload.append(0)
    var s: [UInt8] = [0x01, 0x01]
    s += Array("CUE".utf8); s.append(0)
    let len = UInt32(payload.count)
    s += [UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
    s += payload
    return Data(s)
}

while let line = readLine(strippingNewline: true) {
    let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    switch f[0] {
    case "skrt":
        let name = b64dec(f[1]); let start = Double(f[2]) ?? 0
        let cue = CuePoint(id: "c", start: start, name: name, color: "#fff", yValue: 0, curve: 1, enabled: true)
        let out = ShowKontrolExporter.generate(cuePoints: [cue]) ?? "<nil>"
        if out == "<nil>" { print(b64enc("NIL")); break }
        let records = out.components(separatedBy: "\r")
        let fields = records[0].components(separatedBy: ",").count
        let hasCR = out.contains("\r") ? "1" : "0"
        let hasLF = out.contains("\n") ? "1" : "0"
        let parsed = try? ShowKontrolParser.parse(content: out)
        let reCount = parsed?.cuePoints.count ?? -1
        let reStarts = parsed?.cuePoints.map { $0.start } ?? []
        let maxStart = reStarts.max() ?? -0.001
        let maxStartMs = Int((maxStart * 1000).rounded())
        print(b64enc("\(records.count)\t\(reCount)\t\(fields)\t\(hasCR)\t\(hasLF)\t\(maxStartMs)\t\(b64enc(out))"))
    case "sersk":
        let name = b64dec(f[1])
        let cues = SeratoParser.parseSeratoMarkers2(data: seratoBlob(name: name))
        guard let c = cues.first else { print(b64enc("0\t")); break }
        let out = ShowKontrolExporter.generate(cuePoints: [c]) ?? "<nil>"
        print(b64enc("\(cues.count)\t\(b64enc(out))"))
    case "rbres":
        let xml = b64dec(f[1])
        do {
            let r = try RekordboxParser.parse(xml: xml)
            let cues = r.tracks.first?.cuePoints ?? []
            let out = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: "n") ?? "<nil>"
            print(b64enc("OK\t\(cues.count)\t\(b64enc(out))"))
        } catch { print(b64enc("THREW\t\(b64enc("\(error)"))")) }
    case "rbparse":
        let xml = b64dec(f[1])
        do {
            let r = try RekordboxParser.parse(xml: xml)
            let nm = r.tracks.first?.name ?? ""
            let cc = r.tracks.first?.cuePoints.count ?? 0
            print(b64enc("OK\t\(r.tracks.count)\t\(cc)\t\(b64enc(nm))"))
        } catch { print(b64enc("THREW\t\(b64enc("\(error)"))")) }
    default: print(b64enc("ERR"))
    }
}
"""

_RT_HARNESS = {"built": False, "bin": None, "err": None}


def _rt_sources_or_none():
    srcs = []
    for parts in _RT_SOURCE_RELPATHS:
        p = REPO_ROOT.joinpath(*parts)
        if not p.is_file():
            return None
        srcs.append(str(p))
    return srcs


def _rt_harness_binary():
    """Compile the real parsers + exporters + driver once. SkipTest (never a hard
    error) when no Swift toolchain / source is available."""
    st = _RT_HARNESS
    if st["built"]:
        if st["bin"] is None:
            raise unittest.SkipTest(st["err"])
        return st["bin"]
    st["built"] = True
    srcs = _rt_sources_or_none()
    if srcs is None:
        st["err"] = (
            "CueSyncCore parser/exporter sources not found — cannot exercise chains"
        )
        raise unittest.SkipTest(st["err"])
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        st["err"] = "swiftc not on PATH — skipping Swift value-chain red-team tests"
        raise unittest.SkipTest(st["err"])
    workdir = tempfile.mkdtemp(prefix="cuesync9_valuechain_")
    atexit.register(shutil.rmtree, workdir, True)
    main_swift = os.path.join(workdir, "main.swift")
    with open(main_swift, "w", encoding="utf-8") as fh:
        fh.write(_RT_HARNESS_MAIN)
    binpath = os.path.join(workdir, "chain")
    proc = subprocess.run(
        [swiftc, *srcs, main_swift, "-o", binpath], capture_output=True, text=True
    )
    if proc.returncode != 0 or not os.path.exists(binpath):
        st["err"] = "value-chain harness build failed:\n" + proc.stderr
        raise unittest.SkipTest(st["err"])
    st["bin"] = binpath
    return binpath


def _run_rt_batch(commands):
    """Feed driver commands via stdin; return exactly one decoded (outer) line each."""
    binpath = _rt_harness_binary()
    proc = subprocess.run(
        [binpath], input="\n".join(commands) + "\n", capture_output=True, text=True
    )
    assert proc.returncode == 0, "value-chain harness runtime error:\n" + proc.stderr
    lines = proc.stdout.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    assert len(lines) == len(commands), (
        "value-chain harness returned %d lines for %d commands (framing broke)"
        % (
            len(lines),
            len(commands),
        )
    )
    return [base64.b64decode(o).decode("utf-8") for o in lines]


def _rt_inner(field):
    """Decode a nested-base64 field (export text / XML / parsed name)."""
    return base64.b64decode(field).decode("utf-8")


# A cue name is untrusted (Rekordbox/Serato/Engine DJ/ShowKontrol/Resolume, or a
# now-typeable Windows field). Every one of these tries to inject a ShowKontrol .cue
# COLUMN (a comma) or ROW (any newline/record separator the format or a re-importer
# honours), including the full UAX-14 / CharacterSet.newlines class the project treats
# as newlines on import.
_RT_HOSTILE_NAMES = [
    "clean name",
    "a,b,c,EXTRA",  # comma = ShowKontrol field separator
    "row1\rrow2",  # CR = the .cue record separator
    "row1\nrow2",  # LF
    "row1\r\nrow2",  # CRLF
    "x,\r00:00:05:00,00000500,5000,FORGED,TAG,,,,,,",  # a whole forged trailing record
    "vt\x0bff\x0c",  # U+000B VT / U+000C FF (both in CharacterSet.newlines)
    "nel\x85ls ps ",  # U+0085 NEL / U+2028 LS / U+2029 PS
    ",,,,,,,,,,",  # nothing but separators
]


# ---------------------------------------------------------------------------
# ATTACK 69 (LOCK) — ShowKontrol EXPORT -> real RE-IMPORT round trip. A hostile cue
# name must survive `ShowKontrolExporter.generate` AND a subsequent
# `ShowKontrolParser.parse` without ever spawning a phantom record (a row the
# re-importer reads as an extra cue) or shifting the numeric timecode out of its
# column. Single-function tests above pin the exporter TEXT; this pins the composed
# export->reparse guarantee against the actual parser. spec §4.
# ---------------------------------------------------------------------------


def test_showkontrol_export_reimport_roundtrip_cannot_inject_records_or_shift_columns():
    outs = _run_rt_batch(["skrt %s 5.0" % _b64(n) for n in _RT_HOSTILE_NAMES])
    for name, out in zip(_RT_HOSTILE_NAMES, outs):
        assert out != "NIL", "one enabled cue must still export (name %r)" % name
        records, re_count, fields, has_cr, has_lf, max_ms, _sk = out.split("\t")
        assert records == "1", (
            "spec §4: a single exported cue split into %s CR-records — name %r injected "
            "a record separator that the .cue format's own CR/LF re-import honours"
            % (records, name)
        )
        assert has_cr == "0" and has_lf == "0", (
            "name %r leaked a CR/LF into the exported .cue (hasCR=%s hasLF=%s)"
            % (
                name,
                has_cr,
                has_lf,
            )
        )
        assert int(fields) == _SK_FIELD_COUNT, (
            "ShowKontrol row is %d comma-columns; name %r produced %s — a comma survived "
            "into the name field and injected extra columns"
            % (_SK_FIELD_COUNT, name, fields)
        )
        assert re_count == "2", (
            "spec §4: re-parsing the exported .cue yielded %s cues (expected 2 = the one "
            "data cue + the auto-inserted Start cue). name %r injected a phantom cue on "
            "real re-import." % (re_count, name)
        )
        assert max_ms == "5000", (
            "spec §4: the cue's 5.000 s position did not round-trip (re-parsed max start "
            "= %s ms, expected 5000). name %r shifted the numeric timecode into another "
            "column." % (max_ms, name)
        )


# ---------------------------------------------------------------------------
# ATTACK 70 (LOCK) — cross-parser chain: a CUE name decoded from an untrusted Serato
# Markers2 GEOB flows straight into `ShowKontrolExporter`. The name is raw
# null-terminated UTF-8 from the file — it can carry a comma or any record separator.
# The exporter's sanitiser must neutralise it no matter which importer sourced the
# name. spec §4 (Serato GEOB is an enumerated untrusted source).
# ---------------------------------------------------------------------------


def test_serato_geob_cue_name_cannot_inject_into_showkontrol_export():
    attacks = [
        "nasty,cue\r\nINJECT",
        "a b c",
        "x,\r00:00:00:00,00000000,0,FORGED,TAG,,,,,,",
        "plain",
    ]
    outs = _run_rt_batch(["sersk %s" % _b64(a) for a in attacks])
    for a, out in zip(attacks, outs):
        count, sk_b64 = out.split("\t", 1)
        assert count == "1", (
            "the crafted Serato GEOB must decode to exactly one cue (name %r) — got %s"
            % (a, count)
        )
        sk = _rt_inner(sk_b64)
        assert "\r" not in sk, (
            "spec §4: a Serato cue name injected a CR record separator into the ShowKontrol "
            "export (name %r): %r" % (a, sk)
        )
        assert "\n" not in sk, "Serato cue name %r leaked a LF into the .cue export" % a
        assert len(sk.split(",")) == _SK_FIELD_COUNT, (
            "Serato cue name %r injected extra columns into the .cue export (%d fields)"
            % (a, len(sk.split(",")))
        )


# ---------------------------------------------------------------------------
# ATTACK 71 (LOCK) — cross-parser chain: hostile POSITION_MARK coordinates from an
# untrusted Rekordbox XML flow into `ResolumeExporter`. A NaN/Inf/overflow `Start` or
# an out-of-range colour must never reach the Resolume XML as a non-finite/scientific
# coordinate or an out-of-1..23 curve. We check the point ATTRIBUTE VALUES precisely
# (never a whole-document substring scan — "versionInfo" contains "inf"). spec §4.
# ---------------------------------------------------------------------------


def test_rekordbox_import_to_resolume_export_never_emits_nonfinite_coords():
    marks = "".join(
        '<POSITION_MARK Name="m%d" Start="%s" Red="%s" Green="%s" Blue="%s"/>'
        % (i, s, r, g, b)
        for i, (s, r, g, b) in enumerate(
            [
                ("nan", "99999", "-40", "abc"),
                ("inf", "255", "0", "0"),
                ("1e400", "0", "999", "0"),
                ("-99", "0", "0", "0"),
                ("1e18", "0", "0", "0"),
            ]
        )
    )
    xml_in = (
        '<?xml version="1.0"?><DJ_PLAYLISTS><COLLECTION>'
        '<TRACK TrackID="1" Name="t">' + marks + "</TRACK></COLLECTION></DJ_PLAYLISTS>"
    )
    out = _run_rt_batch(["rbres %s" % _b64(xml_in)])[0]
    assert out.startswith("OK\t"), (
        "Rekordbox import chain unexpectedly failed: %r" % out[:120]
    )
    _ok, count, xml_b64 = out.split("\t")
    assert count == "5", "expected 5 imported cues, got %s" % count
    root = ET.fromstring(_rt_inner(xml_b64))
    points = list(root.iter("point"))
    assert points, "Resolume export produced no <point> elements"
    for p in points:
        cv = int(p.attrib["curve"])
        assert 1 <= cv <= 23, (
            "curve %d escaped the 1..23 clamp on the import->export chain" % cv
        )
        for axis in ("x", "y"):
            v = p.attrib[axis]
            assert _PLAIN_DECIMAL_RE.fullmatch(v), (
                "spec §4: a hostile Rekordbox Start leaked a non-finite/scientific %s=%r into "
                "the Resolume XML across the import->export chain" % (axis, v)
            )
            assert 0.0 <= float(v) <= 1.0, (
                "coordinate %s=%s outside [0,1] after the chain" % (axis, v)
            )


# ---------------------------------------------------------------------------
# ATTACK 72 (LOCK on Darwin) — the Rekordbox XML importer (the port's PRIMARY hostile
# XML source) must not resolve an external SYSTEM entity (XXE local-file read / SSRF).
# ATTACK 66 exercised this for ResolumeParser at runtime; this runs the identical
# probe through the SECOND, larger XML parser. A runtime-created secret referenced via
# a SYSTEM entity in a TRACK Name must never surface in the parsed track name. The
# source-grep ATTACK 67 pins that `shouldResolveExternalEntities = false` is set on
# both; this proves the runtime behaviour. spec §4 (§4: Rekordbox XML is untrusted).
# ---------------------------------------------------------------------------


def test_rekordbox_xml_importer_does_not_resolve_external_entities():
    secret_dir = tempfile.mkdtemp(prefix="cuesync9_rbxxe_")
    atexit.register(shutil.rmtree, secret_dir, True)
    secret_path = os.path.join(secret_dir, "secret.txt")
    token = "TOPSECRET_RB_XXE_5c1d9a"
    with open(secret_path, "w", encoding="utf-8") as fh:
        fh.write(token)
    uri = "file://" + secret_path.replace("\\", "/")
    xxe = (
        '<?xml version="1.0"?>\n'
        '<!DOCTYPE DJ_PLAYLISTS [ <!ENTITY xxe SYSTEM "%s"> ]>\n'
        '<DJ_PLAYLISTS><COLLECTION><TRACK TrackID="1" Name="&xxe;"/></COLLECTION></DJ_PLAYLISTS>'
        % uri
    )
    out = _run_rt_batch(["rbparse %s" % _b64(xxe)])[0]
    # Safe either way: the parser rejects the DTD outright, OR it parses but leaves the
    # external entity unresolved. What it must NOT do is inline the file's contents.
    if out.startswith("OK\t"):
        _ok, _tc, _cc, name_b64 = out.split("\t")
        name = _rt_inner(name_b64)
        assert token not in name, (
            "XXE: RekordboxParser resolved an external SYSTEM entity and leaked local file "
            "contents into the parsed track name: %r" % name
        )
    else:
        assert out.startswith("THREW\t"), "unexpected rbparse result: %r" % out[:120]


# ---------------------------------------------------------------------------
# ATTACK 73 (LOCK on Darwin) — internal-entity expansion bomb ("billion laughs").
# `shouldResolveExternalEntities = false` disables EXTERNAL entities only; it does NOT
# bound INTERNAL general-entity expansion, a distinct DoS. Both XML importers must
# refuse to expand a nested-entity bomb into a multi-megabyte value — either reject the
# document or leave the reference unexpanded — never inline the exponential blow-up.
# Bounded to ~1e7 chars if unprotected so the test itself can't OOM. spec §4
# (resource exhaustion / unbounded input on the divergent libxml2 path this port targets).
# ---------------------------------------------------------------------------


def test_xml_importers_do_not_expand_internal_entity_bombs():
    ents = '<!ENTITY a0 "AAAAAAAAAA">'
    for i in range(1, 8):
        ents += '<!ENTITY a%d "%s">' % (i, ("&a%d;" % (i - 1)) * 10)
    big_run = "A" * 5000  # a genuine expansion would contain a run far longer than this

    rb_bomb = (
        '<?xml version="1.0"?><!DOCTYPE DJ_PLAYLISTS [ %s ]>'
        '<DJ_PLAYLISTS><COLLECTION><TRACK TrackID="1" Name="&a7;"/></COLLECTION></DJ_PLAYLISTS>'
        % ents
    )
    rb_out = _run_rt_batch(["rbparse %s" % _b64(rb_bomb)])[0]
    if rb_out.startswith("OK\t"):
        name = _rt_inner(rb_out.split("\t")[3])
        assert big_run not in name and len(name) < 200_000, (
            "billion-laughs: RekordboxParser expanded a nested internal entity into a "
            "%d-char track name — an unbounded-expansion DoS" % len(name)
        )
    else:
        assert rb_out.startswith("THREW\t"), (
            "unexpected rbparse result: %r" % rb_out[:120]
        )

    # Resolume importer via the existing value-path harness (its `parse` returns the
    # presetName): the same bomb targeted at the preset name attribute.
    res_bomb = (
        '<?xml version="1.0"?><!DOCTYPE Preset [ %s ]>'
        '<Preset name="&a7;"><point x="0" y="0" curve="1"/><point x="1" y="0" curve="1"/></Preset>'
        % ents
    )
    res_out = _run_cs_batch(["parse %s" % _b64(res_bomb)])[0]
    assert big_run not in res_out and len(res_out) < 200_000, (
        "billion-laughs: ResolumeParser expanded a nested internal entity into a "
        "%d-char result — an unbounded-expansion DoS" % len(res_out)
    )


# ---------------------------------------------------------------------------
# ATTACK 74 (LOCK) — ShowKontrol EXPORT -> real RE-IMPORT with a hostile NUMERIC start
# (NaN / Inf / overflow / negative from a corrupt project or parser). The exported
# timecode must be finite and well-formed, AND the value the re-importer reads back
# must stay finite, non-negative, and inside the exporter's 100-hour clamp. This
# composes `secondsToTimecode` with `ShowKontrolParser` — the round trip, not just the
# emitted text (ATTACK 62 pins the text alone). spec §4.
# ---------------------------------------------------------------------------


def test_showkontrol_export_reimport_roundtrip_bounds_hostile_numeric_start():
    starts = [
        "nan",
        "inf",
        "-inf",
        "1e308",
        "1e400",
        "1e18",
        "-5",
        "359999",
        "5.0",
        "0",
    ]
    outs = _run_rt_batch(["skrt %s %s" % (_b64("nm"), _numarg(s)) for s in starts])
    for s, out in zip(starts, outs):
        assert out != "NIL", "one enabled cue must still export (start %r)" % s
        records, re_count, fields, has_cr, has_lf, max_ms, sk_b64 = out.split("\t")
        # Re-import stays finite / non-negative / within the 100h clamp.
        assert 0 <= int(max_ms) <= 359_999_000, (
            "spec §4: hostile start %r round-tripped to %s ms on re-import — outside the "
            "[0, 359_999_000] clamp (a non-finite/overflowing start escaped)"
            % (s, max_ms)
        )
        assert 1 <= int(re_count) <= 2, (
            "hostile start %r yielded %s re-parsed cues (expected 1 or 2)"
            % (
                s,
                re_count,
            )
        )
        # The emitted timecode is well-formed and never a nan/inf token.
        sk = _rt_inner(sk_b64)
        timecode = sk.split(",")[0]
        assert _TC_RE.fullmatch(timecode), (
            "start %r produced a malformed .cue timecode %r" % (s, timecode)
        )
        low = sk.lower()
        assert "nan" not in low and "inf" not in low, (
            "start %r leaked a non-finite token into the round-tripped .cue: %r"
            % (
                s,
                sk,
            )
        )
        assert has_cr == "0" and has_lf == "0", (
            "start %r perturbed the record framing" % s
        )


# =============================================================================
# Red-Team adversarial suite — CUESYNC-9 §4 UNCOVERED untrusted-value surfaces
#
# Everything above pins the exporters (ShowKontrol/Resolume), the two XML importers'
# XXE/entity behaviour, `slugify`, `generateToken`, and the workflow/patch structure.
# Three §4 trust boundaries had ZERO adversarial coverage before this block:
#
#   (A) `AudioDuration` — a hand-rolled WAV/AIFF (RIFF/FORM) binary HEADER parser that
#       runs on every "Load Audio" of an untrusted file. It computes a duration from
#       attacker-controlled chunk sizes, a 32-bit byte/sample-rate, and an 80-bit IEEE
#       extended sample rate — every one of which can drive an `Int(...)`/division to a
#       trap, a non-finite value, a negative value, or an unbounded scan. §5 lists it as
#       the port's cross-platform duration path; §4 says untrusted-file values matter more
#       now the whole Windows UI is live. These lock its finite/non-negative/terminating
#       guarantees so a future refactor that drops `finiteOrNil`, the `rate > 0` guard, or
#       the chunk-advance invariant turns red.
#
#   (B) Resolume PARSE -> convertToCuePoints -> Resolume EXPORT — the round trip a user
#       drives by importing a Resolume envelope and re-exporting it. The single-function
#       tests pin the exporter (ATTACK 63-65) and the parser (ATTACK 66) separately; this
#       pins the COMPOSITION, where a preset name the parser DECODED (entities un-escaped)
#       must be RE-escaped on export, and hostile point coordinates must survive the whole
#       chain as bounded plain decimals. spec §4.
#
#   (C) RekordboxParser `Location` — a LIVE finding. The parser deliberately rejects a raw
#       NUL up front (its own comment: libxml2 "can crash instead of returning a parse
#       error"), then percent-DECODES the `Location` attribute — which re-materialises a
#       `%00` into a real NUL AFTER that guard has run. The explicit NUL-safety invariant
#       the parser sets for itself is bypassed. Expected to FAIL until the decoded location
#       is re-checked (repo rule §E.24: fix the code, or retarget — never weaken — the test).
#
# Self-contained: crafts the binary/XML inputs in pure stdlib, compiles the REAL Swift
# sources into one driver, runs the whole path. SkipTest (never a hard error) when no
# Swift toolchain / source is present, so the pure-Python suite is unaffected.
# =============================================================================

import math  # noqa: E402  (section-local, stdlib)
import struct  # noqa: E402  (section-local, stdlib)

_AV_SOURCE_RELPATHS = [
    ("CueSync", "CueSync", "Models", "CuePoint.swift"),
    ("CueSync", "CueSync", "Models", "ParseError.swift"),
    ("CueSync", "CueSync", "Models", "Track.swift"),
    ("CueSync", "CueSync", "Models", "Playlist.swift"),
    ("CueSync", "CueSync", "Models", "CurveType.swift"),
    ("CueSync", "CueSync", "Parsers", "ResolumeParser.swift"),
    ("CueSync", "CueSync", "Parsers", "RekordboxParser.swift"),
    ("CueSync", "CueSync", "Exporters", "ResolumeExporter.swift"),
    ("CueSync", "CueSync", "Support", "AudioDuration.swift"),
]

# Driver compiled against the real AudioDuration + ResolumeParser/Exporter + RekordboxParser.
#   dur   <b64path>  -> b64("NIL" | "VAL\t<finite01>\t<nonneg01>")
#         AudioDuration.duration(of:) on a crafted WAV/AIFF file at <path>.
#   rbloc <b64xml>   -> b64("OK\t<b64 location-utf8-bytes>" | "NOTRACK" | "THREW")
#         Rekordbox-import <xml>; report the first track's `location` as raw UTF-8 bytes
#         (base64'd so an embedded NUL / control byte survives the line protocol intact).
#   resx  <b64xml>   -> b64("OK\t<b64 parsedPresetName>\t<b64 resolume-xml>" | "THREW")
#         Resolume-parse <xml>, convertToCuePoints(dur 60), then Resolume-EXPORT with the
#         parser's own decoded preset name — the full import->export composition.
_AV_HARNESS_MAIN = r"""
import Foundation

func b64dec(_ s: String) -> String { guard let d = Data(base64Encoded: s) else { return "" }; return String(decoding: d, as: UTF8.self) }
func b64enc(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
func b64encBytes(_ b: [UInt8]) -> String { Data(b).base64EncodedString() }

while let line = readLine(strippingNewline: true) {
    let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    switch f[0] {
    case "dur":
        let path = b64dec(f[1])
        if let d = AudioDuration.duration(of: URL(fileURLWithPath: path)) {
            print(b64enc("VAL\t\(d.isFinite ? 1 : 0)\t\(d >= 0 ? 1 : 0)"))
        } else {
            print(b64enc("NIL"))
        }
    case "rbloc":
        let xml = b64dec(f[1])
        do {
            let r = try RekordboxParser.parse(xml: xml)
            guard let t = r.tracks.first else { print(b64enc("NOTRACK")); break }
            print(b64enc("OK\t\(b64encBytes(Array(t.location.utf8)))"))
        } catch { print(b64enc("THREW")) }
    case "resx":
        let xml = b64dec(f[1])
        do {
            let r = try ResolumeParser.parse(xml: xml)
            let cues = ResolumeParser.convertToCuePoints(points: r.points, duration: 60)
            let out = ResolumeExporter.generate(cuePoints: cues, trackDuration: 60, presetName: r.presetName) ?? "<nil>"
            print(b64enc("OK\t\(b64enc(r.presetName))\t\(b64enc(out))"))
        } catch { print(b64enc("THREW")) }
    default: print(b64enc("ERR"))
    }
}
"""

_AV_HARNESS = {"built": False, "bin": None, "err": None}
_AV_TMPDIR = {"path": None}


def _av_sources_or_none():
    srcs = []
    for parts in _AV_SOURCE_RELPATHS:
        p = REPO_ROOT.joinpath(*parts)
        if not p.is_file():
            return None
        srcs.append(str(p))
    return srcs


def _av_harness_binary():
    """Compile AudioDuration + Resolume(parse/convert/export) + RekordboxParser + driver
    once. SkipTest (never a hard error) when no Swift toolchain / source is available.
    """
    st = _AV_HARNESS
    if st["built"]:
        if st["bin"] is None:
            raise unittest.SkipTest(st["err"])
        return st["bin"]
    st["built"] = True
    srcs = _av_sources_or_none()
    if srcs is None:
        st["err"] = (
            "AudioDuration/Resolume/Rekordbox sources not found — cannot exercise them"
        )
        raise unittest.SkipTest(st["err"])
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        st["err"] = "swiftc not on PATH — skipping Swift untrusted-value red-team tests"
        raise unittest.SkipTest(st["err"])
    workdir = tempfile.mkdtemp(prefix="cuesync9_uncovered_")
    atexit.register(shutil.rmtree, workdir, True)
    main_swift = os.path.join(workdir, "main.swift")
    with open(main_swift, "w", encoding="utf-8") as fh:
        fh.write(_AV_HARNESS_MAIN)
    binpath = os.path.join(workdir, "uncovered")
    proc = subprocess.run(
        [swiftc, *srcs, main_swift, "-o", binpath], capture_output=True, text=True
    )
    if proc.returncode != 0 or not os.path.exists(binpath):
        st["err"] = "uncovered-surface harness build failed:\n" + proc.stderr
        raise unittest.SkipTest(st["err"])
    st["bin"] = binpath
    return binpath


def _run_av_batch(commands, timeout=180):
    """Feed driver commands via stdin; return exactly one decoded (outer) line each. A
    `timeout` bound turns an infinite parse loop into a test failure, not a hung CI job.
    """
    binpath = _av_harness_binary()
    try:
        proc = subprocess.run(
            [binpath],
            input="\n".join(commands) + "\n",
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise AssertionError(
            "uncovered-surface harness did not terminate within %ss on %d commands — a "
            "crafted header drove a parser into an unbounded loop (resource exhaustion)."
            % (timeout, len(commands))
        )
    assert proc.returncode == 0, (
        "uncovered-surface harness runtime error (a crafted input trapped a parser "
        "instead of failing closed):\n" + proc.stderr
    )
    lines = proc.stdout.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    assert len(lines) == len(commands), (
        "uncovered-surface harness returned %d lines for %d commands (framing broke)"
        % (len(lines), len(commands))
    )
    return [base64.b64decode(o).decode("utf-8") for o in lines]


# ---- Crafted RIFF/WAVE + FORM/AIFF header builders (stdlib only) ----------


def _av_tmpdir():
    if _AV_TMPDIR["path"] is None:
        d = tempfile.mkdtemp(prefix="cuesync9_audio_")
        atexit.register(shutil.rmtree, d, True)
        _AV_TMPDIR["path"] = d
    return _AV_TMPDIR["path"]


def _av_write(name, suffix, data):
    p = os.path.join(_av_tmpdir(), name + suffix)
    with open(p, "wb") as fh:
        fh.write(data)
    return p


def _riff_wav(chunks):
    body = b"WAVE" + chunks
    return b"RIFF" + struct.pack("<I", len(body) & 0xFFFFFFFF) + body


def _wav_fmt(byte_rate, fmt_len=16):
    # PCM fmt: audioFormat, numChannels, sampleRate, byteRate, blockAlign, bitsPerSample.
    # AudioDuration reads byteRate at fmt-data offset +8 (this field).
    data = struct.pack("<HHIIHH", 1, 2, 44100, byte_rate & 0xFFFFFFFF, 4, 16)[:fmt_len]
    return b"fmt " + struct.pack("<I", len(data)) + data


def _wav_data(declared_size, actual_len=0):
    return (
        b"data" + struct.pack("<I", declared_size & 0xFFFFFFFF) + (b"\x00" * actual_len)
    )


def _wav_junk(declared_size, actual_len=0):
    return (
        b"JUNK" + struct.pack("<I", declared_size & 0xFFFFFFFF) + (b"\x00" * actual_len)
    )


def _ext80_raw(sign, raw_exp, mantissa):
    """Craft a raw 80-bit IEEE extended (AIFF COMM sample-rate) from its fields."""
    hi = ((sign & 1) << 15) | (raw_exp & 0x7FFF)
    return bytes([(hi >> 8) & 0xFF, hi & 0xFF]) + (mantissa & ((1 << 64) - 1)).to_bytes(
        8, "big"
    )


def _ext80(value):
    """Encode a finite Python float as an 80-bit extended (integer-bit-explicit)."""
    if value == 0:
        return b"\x00" * 10
    sign = 1 if value < 0 else 0
    m, e = math.frexp(abs(value))  # abs = m * 2**e, 0.5 <= m < 1
    mant = int(round(m * (1 << 64)))
    if mant >> 64:
        mant >>= 1
        e += 1
    return _ext80_raw(sign, e + 16382, mant)


def _form_aiff(comm_data, form_type=b"AIFF"):
    chunk = b"COMM" + struct.pack(">I", len(comm_data) & 0xFFFFFFFF) + comm_data
    body = form_type + chunk
    return b"FORM" + struct.pack(">I", len(body) & 0xFFFFFFFF) + body


def _aiff_comm(num_frames, sr_bytes, comm_len=18):
    # numChannels(2), numSampleFrames(4 BE), sampleSize(2), sampleRate(10 = 80-bit ext).
    data = struct.pack(">HIH", 2, num_frames & 0xFFFFFFFF, 16) + sr_bytes
    return data[:comm_len]


def _assert_duration_ok(label, out):
    """Every crafted header must fail closed to `nil` OR yield a finite, non-negative
    duration — never NaN/Inf (would trap a downstream `Int(...)`) or a negative value.
    """
    if out == "NIL":
        return False
    assert out.startswith("VAL\t"), "unexpected duration harness result for %s: %r" % (
        label,
        out,
    )
    _v, finite, nonneg = out.split("\t")
    assert finite == "1", (
        "spec §4/§5: AudioDuration returned a NON-FINITE duration for crafted header %r — "
        "a NaN/Inf escaped `finiteOrNil` and would trap a downstream Int(...) conversion"
        % label
    )
    assert nonneg == "1", (
        "spec §4/§5: AudioDuration returned a NEGATIVE duration for crafted header %r — a "
        "negative sample/byte-rate escaped the `rate > 0` guard" % label
    )
    return True


# ---------------------------------------------------------------------------
# ATTACK 75 (LOCK) — WAV (RIFF) header parsing on untrusted bytes. Attacker-chosen
# chunk sizes and a 32-bit byteRate must never drive the duration to a non-finite or
# negative value, and the chunk scan must terminate. Covers: a 4-GiB declared `data`
# size over byteRate 1, a zero byteRate, byteRate/data both maxed, missing/truncated
# `fmt `, a declared size far larger than the file, and a huge byteRate. spec §4/§5.
# ---------------------------------------------------------------------------


def test_audio_duration_wav_header_never_yields_nonfinite_or_negative():
    cases = [
        ("valid_10s", _riff_wav(_wav_fmt(176400) + _wav_data(1764000, 16))),
        ("data_4gib_over_rate_1", _riff_wav(_wav_fmt(1) + _wav_data(0xFFFFFFFF))),
        ("byterate_zero", _riff_wav(_wav_fmt(0) + _wav_data(1000, 1000))),
        (
            "byterate_and_data_maxed",
            _riff_wav(_wav_fmt(0xFFFFFFFF) + _wav_data(0xFFFFFFFF)),
        ),
        ("no_data_chunk", _riff_wav(_wav_fmt(176400))),
        ("no_fmt_chunk", _riff_wav(_wav_data(1000, 1000))),
        (
            "fmt_truncated_below_16",
            _riff_wav(_wav_fmt(176400, fmt_len=10) + _wav_data(1000, 1000)),
        ),
        (
            "declared_data_huge_actual_tiny",
            _riff_wav(_wav_fmt(1000) + _wav_data(0xFFFFFFFF, 8)),
        ),
        (
            "byterate_maxed_data_maxed",
            _riff_wav(_wav_fmt(0xFFFFFFFF) + _wav_data(0xFFFFFFFF, 0)),
        ),
    ]
    cmds = [
        "dur %s" % _b64(_av_write("wav_%s" % lbl, ".wav", data)) for lbl, data in cases
    ]
    outs = _run_av_batch(cmds)
    produced_a_value = False
    for (label, _d), out in zip(cases, outs):
        produced_a_value |= _assert_duration_ok(label, out)
    assert produced_a_value, (
        "no crafted WAV produced a finite duration — the parser path was never exercised "
        "(the lock would be vacuous)"
    )


# ---------------------------------------------------------------------------
# ATTACK 76 (LOCK) — AIFF/AIFC `COMM` parsing, focused on the 80-bit IEEE extended
# sample rate `parseExtended80` decodes by hand. A crafted exponent/mantissa can make
# the rate +Inf (which still passes `> 0`), a tiny denormal, negative, or exactly zero;
# combined with a maxed `numSampleFrames`, the quotient can overflow. None may surface a
# non-finite or negative duration — each must be `nil` or finite & >= 0. spec §4/§5.
# ---------------------------------------------------------------------------


def test_audio_duration_aiff_extended_sample_rate_never_yields_nonfinite_or_negative():
    cases = [
        ("valid_10s_44100", _form_aiff(_aiff_comm(441000, _ext80(44100.0)))),
        (
            "rate_plus_inf_exponent",
            _form_aiff(_aiff_comm(1000, _ext80_raw(0, 0x7FFF, (1 << 64) - 1))),
        ),
        (
            "rate_near_max_exponent",
            _form_aiff(_aiff_comm(0xFFFFFFFF, _ext80_raw(0, 0x7FFE, (1 << 64) - 1))),
        ),
        ("rate_zero_mantissa", _form_aiff(_aiff_comm(1000, b"\x00" * 10))),
        ("rate_negative", _form_aiff(_aiff_comm(441000, _ext80(-44100.0)))),
        ("tiny_rate_frames_maxed", _form_aiff(_aiff_comm(0xFFFFFFFF, _ext80(1e-300)))),
        ("frames_maxed_rate_1", _form_aiff(_aiff_comm(0xFFFFFFFF, _ext80(1.0)))),
        (
            "aifc_variant_48000",
            _form_aiff(_aiff_comm(441000, _ext80(48000.0)), form_type=b"AIFC"),
        ),
    ]
    cmds = [
        "dur %s" % _b64(_av_write("aiff_%s" % lbl, ".aiff", data))
        for lbl, data in cases
    ]
    outs = _run_av_batch(cmds)
    produced_a_value = False
    for (label, _d), out in zip(cases, outs):
        produced_a_value |= _assert_duration_ok(label, out)
    assert produced_a_value, (
        "no crafted AIFF produced a finite duration — the COMM/extended80 path was never "
        "exercised (the lock would be vacuous)"
    )


# ---------------------------------------------------------------------------
# ATTACK 77 (LOCK) — chunk-scan TERMINATION. RIFF/FORM chunk walking advances by a
# size field the file controls; a naive scanner that trusts a zero size (no forward
# progress) or an unchecked size (backward jump) loops forever on hostile geometry.
# The scan must always make progress. We pack many zero-size junk chunks, a size
# larger than the whole file, and a truncated trailing chunk, and require the whole
# battery to finish inside the runner's timeout. spec §4 (resource exhaustion).
# ---------------------------------------------------------------------------


def test_audio_duration_chunk_scan_terminates_on_adversarial_geometry():
    zero_junk = _wav_junk(0) * 4000  # 4000 zero-size chunks before any usable chunk
    cases = [
        (
            "wav_many_zero_size_chunks",
            ".wav",
            _riff_wav(zero_junk + _wav_fmt(176400) + _wav_data(1000)),
        ),
        (
            "wav_chunk_size_exceeds_file",
            ".wav",
            _riff_wav(_wav_junk(0xFFFFFFF0) + _wav_fmt(176400) + _wav_data(1000)),
        ),
        (
            "wav_truncated_trailing_size",
            ".wav",
            _riff_wav(
                _wav_fmt(176400) + b"data" + struct.pack("<I", 0xFFFFFFFF) + b"\x00\x00"
            ),
        ),
        (
            "aiff_many_zero_size_chunks",
            ".aiff",
            _form_aiff(
                b"JUNK\x00\x00\x00\x00" * 4000 + _aiff_comm(441000, _ext80(44100.0))
            ),
        ),
        (
            "aiff_size_exceeds_file",
            ".aiff",
            _form_aiff(
                b"JUNK"
                + struct.pack(">I", 0xFFFFFFF0)
                + _aiff_comm(441000, _ext80(44100.0))
            ),
        ),
    ]
    cmds = ["dur %s" % _b64(_av_write(lbl, sfx, data)) for lbl, sfx, data in cases]
    # A short, explicit bound: if any header drives an unbounded loop this fails fast
    # with the resource-exhaustion message rather than hanging CI.
    outs = _run_av_batch(cmds, timeout=60)
    for (label, _s, _d), out in zip(cases, outs):
        _assert_duration_ok(label, out)  # terminated AND stayed finite/non-negative


# ---------------------------------------------------------------------------
# ATTACK 78 (LOCK) — Resolume PARSE -> convert -> EXPORT preset-name round trip. The
# parser DECODES XML entities in the `Preset@name`, so a name that arrived as escaped
# markup becomes raw `<`/`&`/`"` in memory; re-exporting MUST re-escape it. We feed
# hostile names (attribute breakout, element injection, CDATA close, all five
# metacharacters), then strict-parse the re-exported XML and require the name to
# round-trip as DATA with no injected element and a stable point count. spec §4.
# ---------------------------------------------------------------------------


def _xml_attr_escape(s):
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def test_resolume_parse_to_export_preset_name_roundtrip_neutralises_injection():
    payloads = [
        "plain envelope",
        '"/><Malicious a="',  # attribute/quote breakout
        "']]>",  # CDATA close
        "A&B<C>D\"E'F",  # all five XML metacharacters
        'x"/><point x="9" y="9" curve="9"/><Preset name="',  # element injection
        "&xxe; &amp; &#x41;",  # entity-looking text (must survive as literal data)
    ]
    xmls = [
        '<?xml version="1.0"?><Preset name="%s">'
        '<point x="0" y="0" curve="1"/><point x="1" y="0" curve="1"/></Preset>'
        % _xml_attr_escape(p)
        for p in payloads
    ]
    outs = _run_av_batch(["resx %s" % _b64(x) for x in xmls])
    for payload, out in zip(payloads, outs):
        assert out.startswith("OK\t"), (
            "Resolume parse->export chain failed for payload %r: %r"
            % (
                payload,
                out[:80],
            )
        )
        _ok, parsed_b64, xml_b64 = out.split("\t")
        parsed_name = base64.b64decode(parsed_b64).decode("utf-8")
        exported = base64.b64decode(xml_b64).decode("utf-8")
        # Must stay well-formed and re-escape the decoded name back to plain data.
        root = ET.fromstring(exported)
        assert root.attrib.get("name") == parsed_name, (
            "spec §4: the parser-decoded preset name %r did not round-trip through export "
            "as data — payload %r broke out of the attribute (exported name %r)"
            % (parsed_name, payload, root.attrib.get("name"))
        )
        # Injection would add elements or extra points; the input carried exactly two.
        assert root.tag.endswith("Preset"), "unexpected root element %r" % root.tag
        assert len(list(root.iter("point"))) == 2, (
            "spec §4: preset-name payload %r injected extra <point> elements into the "
            "re-exported Resolume XML (%d found, expected 2)"
            % (payload, len(list(root.iter("point"))))
        )
        assert not list(root.iter("Malicious")), (
            "spec §4: preset-name payload %r injected a <Malicious> element on re-export"
            % payload
        )


# ---------------------------------------------------------------------------
# ATTACK 79 (LOCK) — Resolume PARSE -> convert -> EXPORT coordinate round trip. The
# parser reads `x`/`y`/`curve` with unclamped `Double(...)`/`Int(...)`; a hostile
# envelope can carry NaN/Inf/scientific/negative/out-of-1..23 there. `convertToCuePoints`
# runs `.sanitized()` and the exporter clamps to [0,1] — so the RE-EXPORTED XML must
# only ever hold plain-decimal x/y in [0,1] and curve in 1..23, never a `nan`/`inf`/
# `1e-05` coordinate a strict Resolume reader would reject. spec §4 (import->export chain).
# ---------------------------------------------------------------------------


def test_resolume_parse_convert_export_never_emits_nonfinite_or_out_of_range_coords():
    hostile_points = [
        ("nan", "0", "1"),
        ("inf", "1", "1"),
        ("1e400", "-5", "0"),
        ("-0.5", "2", "999"),
        ("0.5", "0.5", "12"),
        ("1e18", "1e18", "-3"),
    ]
    xml_in = (
        '<?xml version="1.0"?><Preset name="p">'
        + "".join('<point x="%s" y="%s" curve="%s"/>' % pt for pt in hostile_points)
        + "</Preset>"
    )
    out = _run_av_batch(["resx %s" % _b64(xml_in)])[0]
    assert out.startswith("OK\t"), "Resolume parse->export chain failed: %r" % out[:80]
    exported = base64.b64decode(out.split("\t")[2]).decode("utf-8")
    root = ET.fromstring(exported)
    points = list(root.iter("point"))
    assert points, "Resolume export produced no <point> elements"
    for p in points:
        cv = int(p.attrib["curve"])
        assert 1 <= cv <= 23, (
            "spec §4: curve %d escaped the 1..23 clamp across the Resolume import->export chain"
            % cv
        )
        for axis in ("x", "y"):
            v = p.attrib[axis]
            assert _PLAIN_DECIMAL_RE.fullmatch(v), (
                "spec §4: a hostile Resolume %s coordinate leaked as %r (non-finite/scientific) "
                "through the parse->convert->export chain" % (axis, v)
            )
            assert 0.0 <= float(v) <= 1.0, (
                "coordinate %s=%s left [0,1] after the Resolume import->export chain"
                % (axis, v)
            )


# ---------------------------------------------------------------------------
# ATTACK 80 (LIVE FINDING — expected to FAIL until hardened) — RekordboxParser rejects a
# raw NUL byte in its XML up front (line ~24), its own comment explaining that the
# Windows/Linux libxml2 path "can crash instead of returning a parse error" on a NUL.
# But `parseCollectionTrack` then runs `location.removingPercentEncoding` on the
# `Location` attribute — so a percent-encoded `%00` sails past the up-front guard and is
# DECODED back into a real NUL byte inside `track.location`. The parser's own NUL-safety
# invariant is defeated by its second decode. A hostile Rekordbox XML thus lands a NUL in
# a parsed field (poison-NUL: truncates any later C-string path use, and re-crosses the
# very libxml2 crash surface on a project round-trip). Fix: strip/reject NUL (and control
# bytes) from the decoded location, or re-run the NUL guard after percent-decoding.
# spec §4 (Rekordbox XML is an enumerated untrusted source; NUL handling on the divergent
# libxml2 path is called out explicitly).
# ---------------------------------------------------------------------------


def test_rekordbox_location_percent_encoding_cannot_smuggle_a_nul_byte_past_the_guard():
    xml_in = (
        '<?xml version="1.0"?><DJ_PLAYLISTS><COLLECTION>'
        '<TRACK TrackID="1" Name="t" Location="file://localhost/a%00b.wav"/>'
        "</COLLECTION></DJ_PLAYLISTS>"
    )
    out = _run_av_batch(["rbloc %s" % _b64(xml_in)])[0]
    assert out.startswith("OK\t"), (
        "Rekordbox import unexpectedly produced no track for a %%00-in-Location XML: %r"
        % out[:80]
    )
    location_bytes = base64.b64decode(out.split("\t", 1)[1])
    assert b"\x00" not in location_bytes, (
        "spec §4: a percent-encoded %%00 in a Rekordbox `Location` was decoded into a real "
        "NUL byte inside track.location (bytes=%r), bypassing the parser's own up-front "
        "NUL-rejection guard — the guard runs before removingPercentEncoding re-creates the "
        "NUL. Poison-NUL: truncates any later C-string path use and re-crosses the libxml2 "
        "crash surface on a project round-trip. Fix the decode, don't weaken this test."
        % location_bytes
    )


# ===========================================================================
# CUESYNC-9 (input-death spec, specs/CUESYNC-9.md) — RED-TEAM ADDITIONS
#
# The suite above is deep on the *mechanics* of each swift-cross-ui patch (real
# diff, disjoint hunks, read-only clears, reverse-guard, purity). These attacks
# go after the *acceptance criteria and the root-cause logic* of the input-death
# ticket itself — the places the spec's own §2 (plan step 5), §3, and §4 threat
# model are violated or under-guarded even though every existing test is green.
#
# Two of these are LIVE FINDINGS (expected to FAIL today, reproducing a real
# un-mitigated gap); three are durable regression LOCKS on an acceptance
# criterion no prior test pins. Each cites the spec clause it defends so a
# maintainer who trips one knows to fix the artifact, never the test.
# ===========================================================================

FINDINGS_9_PATH = REPO_ROOT / "specs" / "CUESYNC-9-findings.md"
FINDINGS_9_TEXT = (
    FINDINGS_9_PATH.read_text(encoding="utf-8") if FINDINGS_9_PATH.is_file() else ""
)

WINDOWS_GSK_STEP_NAME = "Patch swift-cross-ui Windows GSK renderer"


def _gsk_step_blocks():
    """(job, name_line_idx, block_text) for every gsk-renderer patch step — one
    per GtkBackend-compiling leg. Mirrors `_win_input_step_blocks`."""
    blocks = []
    for job, (jstart, jend) in JOBS.items():
        i = jstart
        while i < jend:
            m = STEP_NAME_RE.match(LINES[i])
            if m and m.group(1).startswith(WINDOWS_GSK_STEP_NAME):
                j = i + 1
                while j < jend and not STEP_NAME_RE.match(LINES[j]):
                    j += 1
                blocks.append((job, i, "\n".join(LINES[i:j])))
                i = j
            else:
                i += 1
    return blocks


GSK_BLOCKS = _gsk_step_blocks()


def _gsk_bodies():
    """job -> de-indented `run:` script body of that job's gsk-renderer step."""
    return {job: _gesture_run_body(block) for job, _i, block in GSK_BLOCKS}


def _findings_paragraphs():
    return re.split(r"\n\s*\n", FINDINGS_9_TEXT)


def _windows_input_patch_marked_disproven_non_mover():
    """The findings paragraph (if any) that names `windows-input.patch` AND marks
    its root-cause premise disproven AND treats it as a non-mover / candidate
    revert. Returns the paragraph text, or None. This is exactly the round-8
    (§0.7) disposition of round 7's patch."""
    for para in _findings_paragraphs():
        if "windows-input.patch" not in para:
            continue
        low = para.lower()
        disproven = "disprove" in low  # "disproven" / "disproves"
        non_mover = ("candidate revert" in low) or (
            "load-bearing" in low and "not" in low
        )
        if disproven and non_mover:
            return para.strip()
    return None


# ---------------------------------------------------------------------------
# ATTACK A (LIVE FINDING — expected to FAIL) — a disproven-premise patch is
# still mutating the pinned dependency on every leg.
#
# spec CUESYNC-9 §2 step 5: "Apply ONE suspect per round: if a round's fix does
# not move the probe, REVERT that hunk before trying the next suspect — never
# stack speculative patches." spec §4 (supply chain): every byte-change to the
# pinned dependency must be a justified, audited patch so "the code we audited"
# and "the code we build" stay identical.
#
# Round 8 (specs/CUESYNC-9-findings.md §0.7) proved, from the app's own auditable
# Windows stderr, that the input death is an unsatisfiable-window-minimum
# relayout loop — NOT the Win32-message-queue starvation that round 7's
# `windows-input.patch` rewrites `mainRunLoopTicklingLoop` to fix. The findings
# doc itself records the patch's "premise is now disproven … candidate revert …
# do not treat it as load-bearing." Yet that patch is STILL git-applied on all
# three GtkBackend legs and by the dev script — a speculative, disproven
# modification of a pinned dependency left stacked, precisely what step 5 forbids.
#
# Satisfiable either way: revert the patch from the apply set, OR re-confirm it as
# load-bearing in the findings (removing the disproven / candidate-revert
# language). It must not ship as a disproven mutation of an audited dependency.
# ---------------------------------------------------------------------------


def test_windows_input_patch_premise_is_disproven_yet_it_is_still_applied_on_every_leg():
    legs = sorted(job for job, _i, _b in WINDOWS_INPUT_BLOCKS)
    still_in_ci = legs == ["macos", "windows-build", "windows-test"]

    dev = (
        DEV_PATCH_SCRIPT.read_text(encoding="utf-8")
        if DEV_PATCH_SCRIPT.is_file()
        else ""
    )
    still_in_dev = WINDOWS_INPUT_PATCH_NAME in dev and "git apply" in dev

    if not (still_in_ci or still_in_dev):
        return  # patch was reverted per step 5 — nothing left to flag

    if not FINDINGS_9_TEXT:
        raise unittest.SkipTest("specs/CUESYNC-9-findings.md not found")

    marked = _windows_input_patch_marked_disproven_non_mover()
    assert marked is None, (
        "spec CUESYNC-9 §2 step 5 / §4: `%s` still mutates the pinned "
        "swift-cross-ui checkout on legs %r (dev script: %s), but the findings doc "
        "records its root-cause premise as DISPROVEN and the patch as a non-mover / "
        "candidate revert. Step 5 requires reverting a non-mover, not leaving a "
        "speculative, disproven patch stacked on the audited dependency (§4: "
        "'the code we audited' must equal 'the code we build', justified). Resolve "
        "by reverting the patch from every apply site, or re-confirm it as "
        "load-bearing in the findings. Offending disposition:\n\n%s"
        % (WINDOWS_INPUT_PATCH_NAME, legs, bool(still_in_dev), marked)
    )


# ---------------------------------------------------------------------------
# ATTACK B (LIVE FINDING — expected to FAIL) — the input patch reaches outside
# the sanctioned toolkit API into an undocumented private libdispatch symbol.
#
# spec CUESYNC-9 §2 step 4 / §3 / §4: the fix must use "GTK/GLib's own APIs …
# no new dependency, no network, no dynamic load." The windows-input patch binds
# `@_silgen_name("_dispatch_main_queue_callback_4CF")` — a raw linker binding to
# an UNDOCUMENTED, leading-underscore libdispatch↔CoreFoundation bridge internal
# (`_4CF`), which is neither GTK nor GLib and carries no stable-ABI guarantee.
# `@_silgen_name` bypasses Swift's import visibility entirely; if a future Swift
# toolchain renames or drops that private symbol, the whole Windows build fails
# to LINK — the exact supply-chain fragility the "GTK/GLib's own APIs" constraint
# exists to prevent. The existing purity test (ATTACK 48) bans dlopen/import but
# never inspects `@_silgen_name`, so nothing catches this.
# ---------------------------------------------------------------------------


def test_windows_input_patch_binds_no_undocumented_private_symbol_via_silgen_name():
    _win_input_or_skip()
    added = "\n".join(_win_input_added_lines())
    symbols = re.findall(r'@_silgen_name\(\s*"([^"]+)"\s*\)', added)
    assert not symbols, (
        "spec CUESYNC-9 §3/§4 (fix uses GTK/GLib's own APIs, no fragile external "
        "coupling): the windows-input patch adds `@_silgen_name` binding(s) to %r — "
        "a raw linker binding to a non-GTK/GLib symbol. `_dispatch_main_queue_"
        "callback_4CF` is an undocumented, underscore-prefixed libdispatch/CF-bridge "
        "internal with no stable-ABI guarantee; a Swift-toolchain rename/removal "
        "breaks the Windows link. Service DispatchQueue.main via a public/supported "
        "mechanism, or drop the hook with the (disproven-premise) patch it belongs to."
        % symbols
    )


# ---------------------------------------------------------------------------
# ATTACK C (REGRESSION LOCK) — the layout-thrash guard is axis-incomplete; the
# WIDTH axis of the root cause is unguarded on the window-content root.
#
# spec CUESYNC-9 §3 no-regression: round 8's root cause is a hard
# `.frame(minWidth: 1200, minHeight: 700)` on the WindowGroup content becoming
# swift-cross-ui's `minimumWindowSize` (findings §0.7). The resolved checkout's
# `WindowReference.update` clamps BOTH axes symmetrically —
# `max(minimumWindowSize.width, proposed.x)` and `max(…height, proposed.y)`, one
# restart on ANY disagreement — so a chrome-level `.frame(minWidth: N)` drives the
# identical infinite relayout loop on the width axis whenever the display grants
# less than N (a narrow remote-desktop/headless session).
#
# But the durable guards only cover the HEIGHT axis on ContentView.swift (the
# actual WindowGroup content): CUESYNC9WindowMinimumSizeRegressionTests scans
# top-level UI files for `minHeight:` only, and PortComplianceTests' `.frame(min`
# scan is scoped to CueSyncApp.swift, not its sibling ContentView.swift. A
# chrome-level `minWidth:` re-added to ContentView's outer VStack (outside the
# ScrollView, which absorbs only in-flow overflow) would be caught by nothing.
#
# This lock closes that gap: no `.frame(min…)` on ContentView's window chrome —
# on EITHER axis — outside the ScrollView (the two `.frame(minWidth: 500)` on the
# side-by-side columns live INSIDE the ScrollView and are correctly excluded).
# ---------------------------------------------------------------------------

CONTENTVIEW_PATH = REPO_ROOT / "CueSync" / "CueSync" / "UI" / "ContentView.swift"


def _lines_inside_scrollview(lines):
    """0-based indices of source lines that sit inside a `ScrollView { … }` block,
    by brace-depth counting from each `ScrollView {` opener."""
    inside = set()
    i = 0
    while i < len(lines):
        if re.search(r"\bScrollView\b", lines[i]) and "{" in lines[i]:
            depth = lines[i].count("{") - lines[i].count("}")
            j = i + 1
            while j < len(lines) and depth > 0:
                inside.add(j)
                depth += lines[j].count("{") - lines[j].count("}")
                j += 1
            i = j
        else:
            i += 1
    return inside


def test_contentview_window_chrome_imposes_no_hard_minimum_on_either_axis():
    if not CONTENTVIEW_PATH.is_file():
        raise unittest.SkipTest("CueSync/CueSync/UI/ContentView.swift not found")
    lines = CONTENTVIEW_PATH.read_text(encoding="utf-8").split("\n")
    inside = _lines_inside_scrollview(lines)
    offenders = [
        (idx + 1, ln.strip())
        for idx, ln in enumerate(lines)
        if ".frame(min" in ln and not ln.strip().startswith("//") and idx not in inside
    ]
    assert not offenders, (
        "spec CUESYNC-9 §3 / findings §0.7: ContentView.swift is the WindowGroup "
        "content; a hard `.frame(min…)` on its chrome (outside the ScrollView) "
        "becomes swift-cross-ui's `minimumWindowSize`. WindowReference clamps width "
        "AND height symmetrically, so a chrome `minWidth:` reproduces the round-8 "
        "infinite-relayout input death on the width axis when the display grants "
        "less — a case NO existing guard covers (the round-8 scan is minHeight-only; "
        "PortComplianceTests' scan is CueSyncApp.swift-only). Express size via "
        "`.defaultSize`/`.frame(maxWidth:)` and let the ScrollView absorb overflow. "
        "Chrome min-frame(s): %r" % offenders
    )


# ---------------------------------------------------------------------------
# ATTACK D (REGRESSION LOCK) — the gsk-renderer patch is a full supply-chain
# surface but its CI-step hygiene is thinner than the input/gesture patches.
#
# spec CUESYNC-9 §4: each patch's `git apply` step clears the Windows read-only
# flag on EXACTLY the file(s) it patches (same rationale as the gulong/gsize
# step). The gsk-renderer patch touches only GtkBackend.swift, so each Windows
# leg must clear read-only on that one file and must NOT reach into
# Widget.swift (the CUESYNC-8 interactivity file) — clearing a sibling's flag
# signals scope creep across patch boundaries. No prior test pins this for gsk.
# ---------------------------------------------------------------------------


def test_gsk_renderer_patch_step_clears_read_only_on_exactly_gtkbackend_on_both_windows_legs():
    bodies = _gsk_bodies()
    for job in ("windows-build", "windows-test"):
        assert job in bodies, (
            "spec §3: the gsk-renderer patch step is missing on %s" % job
        )
        body = bodies[job]
        ro = [
            ln
            for ln in body.splitlines()
            if "Set-ItemProperty" in ln and "IsReadOnly" in ln
        ]
        assert len(ro) == 1, (
            "spec CUESYNC-9 §4: the gsk-renderer patch modifies only "
            "GtkBackend.swift, so its %s step must clear the Windows read-only flag "
            "on exactly ONE file; found %d IsReadOnly clear(s):\n%s"
            % (job, len(ro), "\n".join(ro) or "(none)")
        )
        assert "GtkBackend.swift" in body and (
            "$gtkBackend" in ro[0] or "GtkBackend.swift" in ro[0]
        ), (
            "spec §4: the gsk-renderer %s step must clear read-only on "
            "GtkBackend.swift specifically; got: %s" % (job, ro[0].strip())
        )
        assert "Widget.swift" not in body, (
            "spec §4 / invariants: the gsk-renderer %s step references Widget.swift "
            "— it must stay confined to GtkBackend.swift and never touch the "
            "CUESYNC-8 interactivity file's flag or bytes." % job
        )


# ---------------------------------------------------------------------------
# ATTACK E (REGRESSION LOCK) — the gsk-renderer patch step must be idempotent
# and fail LOUD on every GtkBackend-compiling leg, exactly like the input/gesture
# patch steps. A silent `git apply` failure would build/test/ship against an
# UNPATCHED dependency — the Windows window would never paint (the very defect
# §0.3 fixes) while CI stays green. spec §3 (idempotency) / §4 (fail-loud posture).
# ---------------------------------------------------------------------------


def test_gsk_renderer_patch_step_is_reverse_guarded_and_fails_loud_on_every_leg():
    bodies = _gsk_bodies()
    legs = sorted(bodies)
    assert legs == ["macos", "windows-build", "windows-test"], (
        "spec CUESYNC-9 §3: the gsk-renderer patch step must exist on all three "
        "GtkBackend-compiling legs (it applies before build on each); found: %r" % legs
    )
    for job, body in bodies.items():
        assert "--reverse --check" in body, (
            "spec §3 idempotency: the gsk-renderer %s step must guard "
            "re-application with `git apply --reverse --check`" % job
        )
        if job == "macos":
            assert "set -e" in body, (
                "the macos gsk-renderer step must fail loud on a bad `git apply` "
                "(`set -euo pipefail`), not continue with an unpatched dependency"
            )
        else:
            assert "Write-Error" in body and "exit 1" in body, (
                "the %s gsk-renderer step must fail loud on a bad `git apply` "
                "(Write-Error + exit 1) — a silent failure ships an unpatched, "
                "never-painting Windows window while CI stays green (§4)" % job
            )


# =============================================================================
# Red-Team adversarial suite — CUESYNC-9 (untrusted-binary decode boundaries)
#
# Making the whole Windows UI live (this ticket) means the value-handling paths
# that were previously unreachable on Windows now actually run — spec §4 says so
# in as many words ("value-handling paths that were previously unreachable on
# Windows now actually run, so their existing guards matter *more*"). Two of
# those guards had **zero** behavioral coverage before this block:
#
#   * `Support/Zlib.swift` — the raw-DEFLATE inflate that feeds the Engine DJ
#     `quickCues` blob. Spec §4/Zlib.swift doc: "the blob is untrusted, and its
#     declared uncompressed size must never drive an unbounded allocation" — the
#     `cap` argument is the decompression-bomb backstop.
#   * `Parsers/EngineDJParser.swift` — the full untrusted-`.db` → cue-point path,
#     including the `< 1_000_000` declared-size sanity gate, the `cap` handed to
#     `Zlib.inflate`, and the `CuePoint.sanitized()` clamp on a raw-float64 cue
#     position that may be NaN/Inf/negative.
#   * `Support/Hex.swift` — `parseCSSColor`, the dependency-free color parser the
#     swift-cross-ui re-host calls; its doc promises "always finite" components so
#     a later `Int(component)` conversion in the renderer can never trap on
#     NaN/Inf (`Int(.nan)` is a hard trap in Swift).
#
# Like the CUESYNC-7 block above, these attack the *real, shipped Swift* (they
# compile the actual sources with a tiny driver and push adversarial bytes
# through), and follow the same LIVE-FINDING / REGRESSION-LOCK convention. If no
# Swift toolchain (or, for the Engine DJ path, no stdlib `sqlite3`) is present,
# they skip rather than error, so the pure-stdlib suite is unaffected; on the
# ticket's macOS CI leg (`swift` installed, `import SQLite3`/`import Compression`
# available) they run and bite.
# =============================================================================


def _find_source(*rel_parts):
    """Locate a CueSync source file (under CueSync/CueSync/...) by walking up."""
    here = Path(__file__).resolve()
    for base in [here.parent] + list(here.parents):
        candidate = base.joinpath("CueSync", "CueSync", *rel_parts)
        if candidate.is_file():
            return candidate
    return None


def _build_swift_harness(state, rel_sources, driver_src, prefix):
    """Compile the given real sources + a driver once; process-cache the binary.

    Raises unittest.SkipTest (never a hard error) when no usable Swift toolchain
    or a source file is missing, mirroring `_harness_binary()` above.
    """
    if state["built"]:
        if state["bin"] is None:
            raise unittest.SkipTest(state["err"])
        return state["bin"]
    state["built"] = True
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        state["err"] = "swiftc not on PATH — skipping Swift-execution red-team test"
        raise unittest.SkipTest(state["err"])
    srcs = []
    for rel in rel_sources:
        p = _find_source(*rel)
        if p is None:
            state["err"] = "source not found: CueSync/CueSync/" + "/".join(rel)
            raise unittest.SkipTest(state["err"])
        srcs.append(str(p))
    workdir = tempfile.mkdtemp(prefix=prefix)
    atexit.register(shutil.rmtree, workdir, True)
    main_swift = os.path.join(workdir, "main.swift")
    with open(main_swift, "w", encoding="utf-8") as fh:
        fh.write(driver_src)
    binpath = os.path.join(workdir, "harness")
    proc = subprocess.run(
        [swiftc, *srcs, main_swift, "-o", binpath],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not os.path.exists(binpath):
        state["err"] = "harness build failed:\n" + proc.stderr
        raise unittest.SkipTest(state["err"])
    state["bin"] = binpath
    return binpath


def _raw_deflate(payload):
    """Raw DEFLATE (no zlib/gzip wrapper) — exactly what Zlib.inflate expects."""
    import zlib

    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(payload) + c.flush()


# ---------------------------------------------------------------------------
# Zlib.inflate — the decompression-bomb backstop that guards every Engine DJ
# import. Driver protocol: one `inflate <cap> <b64src>` line in, one line out:
#   `OK <decodedLen> <b64out>`  or  `NIL`.
# ---------------------------------------------------------------------------

_ZLIB_STATE = {"built": False, "bin": None, "err": None}

_ZLIB_DRIVER = r"""
import Foundation

while let line = readLine(strippingNewline: true) {
    let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    if f[0] == "inflate" {
        let cap = Int(f[1]) ?? 0
        let src = Data(base64Encoded: f[2]) ?? Data()
        if let out = Zlib.inflate(src, cap: cap) {
            print("OK \(out.count) \(out.base64EncodedString())")
        } else {
            print("NIL")
        }
    } else {
        print("ERR")
    }
}
"""


def _zlib_binary():
    return _build_swift_harness(
        _ZLIB_STATE,
        [("Support", "Zlib.swift")],
        _ZLIB_DRIVER,
        "cuesync9_zlib_",
    )


def _inflate_many(items):
    """items: iterable of (src_bytes, cap) -> list of (decoded_bytes | None)."""
    binpath = _zlib_binary()
    cmds = [
        "inflate %d %s" % (cap, base64.b64encode(src).decode("ascii"))
        for (src, cap) in items
    ]
    proc = subprocess.run(
        [binpath],
        input="\n".join(cmds) + "\n",
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert proc.returncode == 0, "zlib harness runtime error:\n" + proc.stderr
    lines = [ln for ln in proc.stdout.split("\n") if ln != ""]
    assert len(lines) == len(cmds), (
        "zlib harness framing broke: %d lines for %d commands" % (len(lines), len(cmds))
    )
    out = []
    for ln in lines:
        if ln == "NIL":
            out.append(None)
        else:
            parts = ln.split(" ")
            assert parts[0] == "OK", "unexpected harness line: " + ln
            out.append(base64.b64decode(parts[2]) if len(parts) > 2 else b"")
    return out


# ---------------------------------------------------------------------------
# ATTACK (REGRESSION LOCK) — the decompression bomb is bounded by `cap`, never by
# the (attacker-controlled) declared or compressed size. A ~1 MB run of zeros
# raw-deflates to ~1 KB; feeding it with any `cap` below the true output MUST
# return nil, and no returned buffer may ever exceed `cap`. spec §4: "its declared
# uncompressed size must never drive an unbounded allocation."
# ---------------------------------------------------------------------------


def test_zlib_inflate_bounds_a_decompression_bomb_regardless_of_declared_size():
    import os as _os

    zeros = b"\x00" * 1_000_000  # ~1 KB compressed, 1 MB out — a 1000x bomb
    bomb = _raw_deflate(zeros)
    rnd = _os.urandom(50_000)  # incompressible — deflate stays ~50 KB out
    rnd_def = _raw_deflate(rnd)

    items = [
        (bomb, 1),  # cap << output
        (bomb, 1024),
        (bomb, 100_000),
        (bomb, 999_999),  # one short of the true 1 MB output
        (bomb, 1_000_000),  # exactly enough
        (bomb, 4_000_000),  # generous
        (rnd_def, len(rnd) - 1),  # incompressible, one short
        (rnd_def, len(rnd)),  # incompressible, exact
    ]
    results = _inflate_many(items)

    expected_nil = {0, 1, 2, 3, 6}  # every cap strictly below the true output
    for idx, ((src, cap), out) in enumerate(zip(items, results)):
        if idx in expected_nil:
            assert out is None, (
                "spec §4: Zlib.inflate returned %d bytes for cap=%d though the "
                "true output is larger — the decompression-bomb cap is not "
                "enforced (a hostile quickCues blob could drive an unbounded "
                "allocation)." % (0 if out is None else len(out), cap)
            )
        else:
            assert out is not None, (
                "cap=%d is >= the true output yet inflate refused it — the cap "
                "backstop is over-tight and rejects a legitimate blob." % cap
            )
        if out is not None:
            assert len(out) <= cap, (
                "spec §4: Zlib.inflate returned %d bytes with cap=%d — output "
                "MUST never exceed cap, or the bomb backstop is defeated."
                % (len(out), cap)
            )


# ---------------------------------------------------------------------------
# ATTACK (REGRESSION LOCK) — the cap boundary is *exact*, and the one-byte slack
# buffer disambiguates "decoded exactly cap" from "decoded more, got cut off"
# (Zlib.swift appleInflate: `bufferSize = cap + 1`, then `decodedCount <= cap`).
# A stream that decodes to exactly N bytes must be accepted at cap==N (proving the
# slack byte is not mistaken for overflow) and rejected at cap==N-1. If a refactor
# drops the `+1` slack, cap==N becomes ambiguous and this turns red.
# ---------------------------------------------------------------------------


def test_zlib_inflate_cap_boundary_is_exact_and_slack_byte_disambiguates():
    n = 4096
    stream = _raw_deflate(b"A" * n)
    at, under, over = _inflate_many([(stream, n), (stream, n - 1), (stream, n + 1)])

    assert at is not None and len(at) == n, (
        "a stream decoding to exactly %d bytes must be accepted at cap=%d "
        "(the one-byte slack buffer proves it is a genuine cap-sized result, "
        "not a truncated overflow) — got %r" % (n, n, None if at is None else len(at))
    )
    assert under is None, (
        "a stream decoding to %d bytes must be rejected at cap=%d (one over the "
        "limit) — the cap is off-by-one and lets an over-cap blob through." % (n, n - 1)
    )
    assert over is not None and len(over) == n, (
        "cap=%d (one above the true output) must still yield the full %d bytes."
        % (n + 1, n)
    )


# ---------------------------------------------------------------------------
# ATTACK (REGRESSION LOCK) — the two entry guards (`cap > 0` and `!src.isEmpty`)
# hold: an empty source or a non-positive cap returns nil, never a crash or a
# zero-length "success" the caller would misread. On a 32-bit target `cap` is a
# 32-bit Int, so a caller passing 0 or a negative must be refused outright before
# any allocation.
# ---------------------------------------------------------------------------


def test_zlib_inflate_rejects_empty_source_and_nonpositive_cap():
    good = _raw_deflate(b"payload")
    results = _inflate_many(
        [(b"", 1024), (good, 0), (good, -5), (good, len(b"payload"))]
    )
    empty_src, zero_cap, neg_cap, sane = results
    assert empty_src is None, "empty source must return nil (guard `!src.isEmpty`)"
    assert zero_cap is None, "cap=0 must return nil (guard `cap > 0`)"
    assert neg_cap is None, "negative cap must return nil (guard `cap > 0`)"
    assert sane == b"payload", (
        "a well-formed stream with an adequate cap must still round-trip — the "
        "guards must reject only the degenerate inputs, not everything."
    )


# ---------------------------------------------------------------------------
# Engine DJ end-to-end — the real untrusted-`.db` boundary. The driver takes a
# database path on argv and prints, per track:
#   `TRACK <id> <cueCount> <allFinite:0|1> <allNonNeg:0|1>`
# then `OK <n>` (or `THROW <msg>` if parse threw).
# ---------------------------------------------------------------------------

_ENGINE_STATE = {"built": False, "bin": None, "err": None}

_ENGINE_DRIVER = r"""
import Foundation

let path = CommandLine.arguments[1]
do {
    let tracks = try EngineDJParser.parse(databaseURL: URL(fileURLWithPath: path))
    for t in tracks {
        let starts = t.cuePoints.map { $0.start }
        let finite = starts.allSatisfy { $0.isFinite } ? 1 : 0
        let nonneg = starts.allSatisfy { $0 >= 0 } ? 1 : 0
        print("TRACK \(t.id) \(t.cuePoints.count) \(finite) \(nonneg)")
    }
    print("OK \(tracks.count)")
} catch {
    print("THROW \(error)")
}
"""


def _engine_binary():
    return _build_swift_harness(
        _ENGINE_STATE,
        [
            ("Models", "CuePoint.swift"),
            ("Models", "Track.swift"),
            ("Models", "ParseError.swift"),
            ("Support", "Zlib.swift"),
            ("Support", "SQLite.swift"),
            ("Parsers", "EngineDJParser.swift"),
        ],
        _ENGINE_DRIVER,
        "cuesync9_engine_",
    )


def _quickcues_blob(declared_size, payload):
    """Engine DJ quickCues layout: LE-uint32 declared size + raw-DEFLATE body."""
    import struct

    return struct.pack("<I", declared_size & 0xFFFFFFFF) + _raw_deflate(payload)


def _engine_cue_slot(name, position_bits):
    """One cue slot: nameLen(1) + name + big-endian float64 position + 4 pad."""
    import struct

    nb = name.encode("utf-8")
    return bytes([len(nb) & 0xFF]) + nb + struct.pack(">Q", position_bits) + b"\x00" * 4


def _make_engine_db(perf_rows):
    """Build a minimal-but-valid Engine DJ DB. `perf_rows` maps trackId ->
    quickCues blob bytes (or None). Always inserts one Track row per key so the
    parser's non-empty-Track guard passes. Returns a temp path (auto-cleaned)."""
    try:
        import sqlite3
    except ImportError:  # pragma: no cover — stdlib module, effectively always present
        raise unittest.SkipTest("stdlib sqlite3 unavailable")

    fd, path = tempfile.mkstemp(prefix="cuesync9_engine_", suffix=".db")
    os.close(fd)
    os.remove(path)  # sqlite3 wants to create it fresh
    atexit.register(lambda p=path: os.path.exists(p) and os.remove(p))
    con = sqlite3.connect(path)
    try:
        cur = con.cursor()
        cur.execute(
            "CREATE TABLE Track (id INTEGER PRIMARY KEY, title TEXT, artist TEXT, "
            "album TEXT, genre TEXT, length INT, bpmAnalyzed REAL, key INT, "
            "path TEXT, filename TEXT)"
        )
        cur.execute("CREATE TABLE PerformanceData (trackId INTEGER, quickCues BLOB)")
        for tid, blob in perf_rows.items():
            cur.execute(
                "INSERT INTO Track VALUES (?,?,?,?,?,?,?,?,?,?)",
                (tid, "T%d" % tid, "A", "Al", "G", 100, 120.0, 1, "/x/", "f.mp3"),
            )
            cur.execute(
                "INSERT INTO PerformanceData VALUES (?, ?)",
                (tid, sqlite3.Binary(blob) if blob is not None else None),
            )
        con.commit()
    finally:
        con.close()
    return path


def _run_engine(path):
    """Parse `path` through the real EngineDJParser; return ({tid: (n, fin, nn)},
    raw_stdout). Raises AssertionError on a hang (a DoS finding)."""
    binpath = _engine_binary()
    try:
        proc = subprocess.run(
            [binpath, path], capture_output=True, text=True, timeout=60
        )
    except subprocess.TimeoutExpired:
        raise AssertionError(
            "spec §4: EngineDJParser.parse did not terminate within 60s on a "
            "hostile quickCues blob — an unbounded decode/allocation DoS."
        )
    assert proc.returncode == 0, "engine harness crashed:\n" + proc.stderr
    lines = proc.stdout.strip().split("\n")
    tracks = {}
    for ln in lines:
        if ln.startswith("TRACK "):
            _, tid, n, fin, nn = ln.split(" ")
            tracks[tid] = (int(n), fin == "1", nn == "1")
    return tracks, proc.stdout


# ---------------------------------------------------------------------------
# ATTACK (REGRESSION LOCK) — the declared-size sanity gate and the inflate cap
# together bound *every* allocation the Engine DJ importer makes, so a hostile
# quickCues blob can neither lie huge to force a multi-GB buffer nor lie small
# then bomb-expand. Four blobs on four tracks, each chosen so a *removed* guard is
# observable, not silently absorbed:
#   * track 1 (gate lock): declared == 2 MB (> the 1 MB gate) but the body is a
#     genuine 8-slot cue payload padded to 2 MB — WITH the gate it is refused (0
#     cues); DROP the gate and inflate would decode it into 8 real cues. So the
#     0-cue assertion turns red the moment the `< 1_000_000` gate is loosened.
#   * track 2 (cap lock): declared == 500 but the body decompresses to 5 MB ->
#     cap=756 -> inflate nil -> 0 cues. Turns red if the inflate cap is loosened.
#   * track 3 (no-OOM lock): declared == UINT32_MAX with a 16-byte body — the gate
#     refuses it up front; without the gate the appleInflate buffer is ~4 GB, so
#     this pins that a hostile declared size never drives that allocation (the
#     parse must still finish within the timeout).
#   * track 4 (bounded legit path): declared == 999_999 of zeros -> decodes but is
#     bounded and yields 0 cues (all-empty slots) rather than hanging.
# Every track must end with 0 cues, and the whole parse must finish.
# ---------------------------------------------------------------------------


def test_enginedj_quickcues_declared_size_gate_and_cap_bound_every_allocation():
    import struct

    # A real 8-cue payload (each cue at 1s = 44100 samples), padded past the 1 MB
    # gate so the gate — not the cap — is the only thing that can refuse it.
    slots = b"".join(
        _engine_cue_slot(
            "cue%d" % i, struct.unpack(">Q", struct.pack(">d", 44100.0))[0]
        )
        for i in range(8)
    )
    real_payload = b"\x00" * 8 + slots
    real_payload += b"\x00" * (2_000_000 - len(real_payload))  # pad to 2 MB

    rows = {
        1: _quickcues_blob(len(real_payload), real_payload),  # 2 MB -> gate refuses
        2: _quickcues_blob(500, b"\x00" * 5_000_000),  # lie small, bomb body
        3: _quickcues_blob(0xFFFFFFFF, b"\x00" * 16),  # lie huge (4 GB) -> gate
        4: _quickcues_blob(999_999, b"\x00" * 999_999),  # legit-ish, bounded
    }
    db = _make_engine_db(rows)
    tracks, raw = _run_engine(db)

    assert "THROW" not in raw, "parse threw on a hostile-blob DB:\n" + raw
    for tid in ("engine-1", "engine-2", "engine-3", "engine-4"):
        assert tid in tracks, "expected %s in parse output:\n%s" % (tid, raw)
        n, fin, nn = tracks[tid]
        assert n == 0, (
            "spec §4: %s should yield 0 cues — its quickCues blob is hostile "
            "(oversized-declared / bomb / cap-exceeding). Got %d cues, which "
            "means an allocation guard (the `< 1_000_000` declared-size gate or "
            "the inflate `cap`) is not holding." % (tid, n)
        )


# ---------------------------------------------------------------------------
# ATTACK (REGRESSION LOCK) — a cue position is read straight from raw float64
# bits (`readBigEndianFloat64`), so a hostile blob can plant NaN / +Inf / -Inf /
# a huge negative there. `CuePoint.sanitized()` MUST clamp every one to a finite,
# non-negative `start` before it can reach the envelope canvas (`Int(.nan)` trap)
# or the exporters (timecode overflow / `nan` in XML). spec §4 (a).
# ---------------------------------------------------------------------------


def test_enginedj_quickcues_nonfinite_positions_sanitise_to_finite_nonnegative():
    nan = 0x7FF8000000000000
    pos_inf = 0x7FF0000000000000
    neg_inf = 0xFFF0000000000000
    neg_big = 0xC1CDCD6500000000  # ~ -1e9 samples
    pos_huge = 0x7FE0000000000000  # ~ 1e308, finite but astronomically large
    header = b"\x00" * 8
    payload = (
        header
        + _engine_cue_slot("NanCue", nan)
        + _engine_cue_slot("PosInf", pos_inf)
        + _engine_cue_slot("NegInf", neg_inf)
        + _engine_cue_slot("NegBig", neg_big)
        + _engine_cue_slot("PosHuge", pos_huge)
    )
    db = _make_engine_db({7: _quickcues_blob(len(payload), payload)})
    tracks, raw = _run_engine(db)

    assert "THROW" not in raw, "parse threw on non-finite cue positions:\n" + raw
    assert "engine-7" in tracks, "expected engine-7 in output:\n" + raw
    n, fin, nn = tracks["engine-7"]
    assert n == 5, (
        "expected all 5 planted cue slots to parse; got %d — the fixture or the "
        "slot walker changed:\n%s" % (n, raw)
    )
    assert fin, (
        "spec §4(a): a NaN/Inf cue position survived into `start` unsanitised — "
        "CuePoint.sanitized() must map every non-finite bit pattern to a finite "
        "value before it reaches the canvas (`Int(.nan)` traps) or the exporters."
    )
    assert nn, (
        "spec §4(a): a negative cue position survived into `start` — sanitized() "
        "must clamp start to >= 0 so timecode/normalisation math stays well-formed."
    )


# ---------------------------------------------------------------------------
# Hex / CSS color parser — Support/Hex.swift `parseCSSColor`. Driver protocol:
# one `color <b64string>` line in, one `r g b` line out (finite decimals).
# ---------------------------------------------------------------------------

_HEX_STATE = {"built": False, "bin": None, "err": None}

_HEX_DRIVER = r"""
import Foundation

while let line = readLine(strippingNewline: true) {
    let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    if f[0] == "color" {
        let s = String(decoding: Data(base64Encoded: f[1]) ?? Data(), as: UTF8.self)
        let c = Hex.parseCSSColor(s)
        print("\(c.r) \(c.g) \(c.b)")
    } else {
        print("ERR")
    }
}
"""


def _hex_binary():
    return _build_swift_harness(
        _HEX_STATE,
        [("Support", "Hex.swift")],
        _HEX_DRIVER,
        "cuesync9_hex_",
    )


def _parse_colors(strings):
    binpath = _hex_binary()
    cmds = [
        "color " + base64.b64encode(s.encode("utf-8")).decode("ascii") for s in strings
    ]
    proc = subprocess.run(
        [binpath],
        input="\n".join(cmds) + "\n",
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert proc.returncode == 0, "hex harness runtime error:\n" + proc.stderr
    lines = [ln for ln in proc.stdout.split("\n") if ln != ""]
    assert len(lines) == len(cmds), "hex harness framing broke"
    return [tuple(float(x) for x in ln.split(" ")) for ln in lines]


# ---------------------------------------------------------------------------
# ATTACK (REGRESSION LOCK) — parseCSSColor's doc promises "The returned components
# are always finite." Push NaN / Inf / overflowing-literal / garbage color strings
# (values that reach the parser from untrusted files via the re-hosted
# `Color(cssString:)`) through the real parser and demand every component is a
# finite number in [0, 1]. A non-finite escape would trap a later `Int(component)`
# in the renderer.
# ---------------------------------------------------------------------------


def test_css_color_parser_always_returns_finite_clamped_components_for_hostile_input():
    hostile = [
        "rgb(nan, nan, nan)",
        "rgb(inf, inf, inf)",
        "rgb(-inf, -inf, -inf)",
        "rgb(1e400, 1e400, 1e400)",  # overflows Double to +inf
        "rgb(-1e400, 0, 0)",  # overflows to -inf
        "rgb(999999999, -999999999, 128)",
        "rgb(NaN,Inf,-Inf)",
        "#nan",
        "#ffffff",
        "#000",
        "rgb( , , )",
        "rgb()",
        "",
        "garbage",
        "#" + "f" * 4096,  # oversized hex must not parse to something non-finite
        "rgb(" + "9" * 400 + ",0,0)",  # gigantic literal -> inf -> clamp
    ]
    for s, (r, g, b) in zip(hostile, _parse_colors(hostile)):
        for name, v in (("r", r), ("g", g), ("b", b)):
            assert v == v, (
                "parseCSSColor(%r) returned a NaN %s component — the doc promises "
                "finite output; a later Int(%s) in the renderer would trap."
                % (s, name, name)
            )
            assert v not in (float("inf"), float("-inf")), (
                "parseCSSColor(%r) returned a non-finite %s component." % (s, name)
            )
            assert 0.0 <= v <= 1.0, (
                "parseCSSColor(%r) returned %s=%r outside [0,1] — sanitize() must "
                "clamp every component." % (s, name, v)
            )


# =============================================================================
# CUESYNC-9 Red-Team — composition & encoding-trick locks
#
# The suite above hardens each trust boundary in isolation. These four attacks
# target the seams the earlier tests leave open:
#   * slugify() is only ever tested with LITERAL ascii reserved names ("con") and
#     literal separators ("/"). A real adversary who knows those are blocked reaches
#     for Unicode look-alikes (fullwidth Latin, math-alphanumerics, circled/superscript
#     digits, fraction/division/fullwidth slashes) hoping a normalization or
#     transliteration step folds them back to the dangerous ascii token.
#   * slugify()'s reserved-name escape runs AFTER truncation and then RE-truncates
#     the "_"-prefixed result — an edge only exercised here across EVERY reserved
#     name at EVERY length budget, plus the degenerate maxLength<=0 / Int.max ends.
#   * ResolumeExporter's XML escaping is only ever checked by string-scanning its own
#     output. The stronger proof is to feed that output straight back through the REAL
#     ResolumeParser and show a hostile preset name re-ingests as inert DATA — never
#     an injected element, attribute, or envelope point.
#   * The Rekordbox importer and slugify() are each proven safe alone, but never as a
#     CHAIN. XMLParser decodes numeric character references (`&#x2f;` -> "/", `&#x5c;`
#     -> "\") INSIDE a track name, so the only thing standing between a hostile
#     Rekordbox `Name=` and a traversal filename is slugify(). This locks that seam.
#
# Every test drives the REAL compiled Swift (TextTools / the exporters+parsers), so a
# regression that weakens any guarantee turns it red. Skips (never hard-errors) when
# no Swift toolchain / source is present, exactly like the harnesses they reuse.
# =============================================================================

_SAFE_SLUG_BODY_RE = re.compile(r"[a-z0-9-]+")


def _assert_safe_slug(inp, slug):
    """The real slugify() contract as a single reusable predicate: a non-empty single
    path component, no separator / traversal / NUL / control byte, and NEVER a bare
    Windows reserved device name. The reserved-name escape legitimately prepends one
    leading '_', so tolerate exactly that; everything else is drawn from [a-z0-9-]."""
    assert slug, "slug for %r is empty — the non-empty fallback must apply" % (inp,)
    assert "/" not in slug and "\\" not in slug, (
        "slug %r for %r contains a path separator" % (slug, inp)
    )
    assert ".." not in slug and slug not in (".", ".."), (
        "slug %r for %r is a traversal token" % (slug, inp)
    )
    assert "\x00" not in slug, "slug %r for %r contains a NUL" % (slug, inp)
    for ch in slug:
        assert ord(ch) >= 0x20, "control char survived in slug %r for %r" % (slug, inp)
    body = slug[1:] if slug.startswith("_") else slug
    assert _SAFE_SLUG_BODY_RE.fullmatch(body), (
        "slug %r for %r has characters outside the safe [a-z0-9-] set" % (slug, inp)
    )
    assert slug.lower() not in RESERVED_SET, (
        "slug %r for %r IS a bare Windows reserved device name — a real filename "
        "collision on Windows" % (slug, inp)
    )


# ---------------------------------------------------------------------------
# ATTACK 80 (LOCK) — Unicode homoglyphs must never reconstruct a reserved device
# name or a real path separator. slugify() keeps ONLY ascii [a-z0-9] and performs
# NO Unicode compatibility normalization / transliteration, so a fullwidth / math /
# circled look-alike of a reserved name strips entirely to the fallback (never the
# ascii token, never its "_"-escaped form), and a slash look-alike collapses to the
# "-" separator (never a literal "/" or "\"). spec §4/§5 (untrusted names become
# filenames; case folding is Locale-free precisely to stay deterministic here).
# ---------------------------------------------------------------------------


def test_slugify_unicode_homoglyphs_never_reconstruct_a_reserved_name_or_separator():
    # Fullwidth Latin (U+FF00 block), math-bold (U+1D400 block), circled (U+2460)
    # and superscript (U+00B2/B3) look-alikes of Windows reserved device names.
    reserved_homoglyphs = [
        "ＣＯＮ",  # CON  (fullwidth)
        "ｃｏｎ",  # con  (fullwidth)
        "ＮＵＬ",  # NUL  (fullwidth)
        "ＰＲＮ",  # PRN  (fullwidth)
        "ＡＵＸ",  # AUX  (fullwidth)
        "Ｃｏｍ１",  # Com1 (fullwidth)
        "ＬＰＴ９",  # LPT9 (fullwidth)
        "①②③",  # (1)(2)(3) circled digits
        "²³",  # superscript 2 3
        "\U0001d402\U0001d428\U0001d427",  # CON  (mathematical bold)
    ]
    slugs = _slugify_many([(h, 80, "untitled") for h in reserved_homoglyphs])
    for inp, slug in zip(reserved_homoglyphs, slugs):
        _assert_safe_slug(inp, slug)
        assert slug == "untitled", (
            "spec §4/§5: the Unicode look-alike %r of a reserved device name folded "
            "to %r instead of being stripped to the fallback — slugify() must not "
            "transliterate homoglyphs back into ascii tokens" % (inp, slug)
        )
    # Control: the *ascii* reserved name still escapes to "_con". This proves the
    # reserved-name defense is LIVE, so the "untitled" outcomes above are genuine
    # stripping — not an escape that has been silently disabled.
    assert _slugify("con") == "_con", (
        "ascii 'con' must still escape to '_con' — otherwise the homoglyph results "
        "are meaningless (the escape itself is broken)"
    )

    # Unicode slash look-alikes must collapse to the '-' separator, never smuggle a
    # real '/' or '\\' into the single component.
    separator_homoglyphs = {
        "a／b": "a-b",  # U+FF0F FULLWIDTH SOLIDUS
        "a∕b": "a-b",  # U+2215 DIVISION SLASH
        "a＼b": "a-b",  # U+FF3C FULLWIDTH REVERSE SOLIDUS
        "a⁄b": "a-b",  # U+2044 FRACTION SLASH
        "a⧸b": "a-b",  # U+29F8 BIG SOLIDUS
        "a∖b": "a-b",  # U+2216 SET MINUS
    }
    slugs = _slugify_many([(k, 80, "untitled") for k in separator_homoglyphs])
    for (inp, expected), slug in zip(separator_homoglyphs.items(), slugs):
        _assert_safe_slug(inp, slug)
        assert slug == expected, (
            "spec §4: Unicode separator look-alike in %r produced %r, not %r — a "
            "slash homoglyph must be dropped like any other non-[a-z0-9] byte, never "
            "reconstructed into a path separator" % (inp, slug, expected)
        )


# ---------------------------------------------------------------------------
# ATTACK 81 (LOCK) — the reserved-name escape re-truncates its own "_"-prefixed
# result, an edge the earlier reserved-name tests only touch at maxLength 3/4 for
# LONGER inputs. Exercise EVERY reserved name at len-1 / len / len+1 (where the
# whole input *is* the reserved token at the exact budget) and the degenerate
# maxLength ends (0, negative, Int.max): the output is never a bare reserved name,
# never crashes, and is always a safe single component. spec §2/§3.
# ---------------------------------------------------------------------------


def test_slugify_reserved_name_at_every_length_budget_and_degenerate_maxlength_stay_safe():
    budget_items = []
    for name in RESERVED_DEVICE_NAMES:
        for ml in (len(name) - 1, len(name), len(name) + 1):
            budget_items.append((name, ml))
    slugs = _slugify_many([(n, ml, "untitled") for n, ml in budget_items])
    for (name, ml), slug in zip(budget_items, slugs):
        _assert_safe_slug(name, slug)
        if ml > 0:
            assert len(slug) <= max(ml, len("_") + ml), slug  # escape may add one '_'
        assert slug.lower() not in RESERVED_SET, (
            "spec §2/§3: slugify(%r, maxLength=%d) = %r is a bare reserved device "
            "name — the escape-then-retruncate path re-created it at the budget edge"
            % (name, ml, slug)
        )

    # Degenerate maxLength must fail safe to the fallback (never crash, never empty),
    # and an enormous maxLength must not overflow the prefix/count arithmetic.
    INT_MAX = 9223372036854775807
    degenerate = [
        ("HelloWorld", 0),
        ("HelloWorld", -1),
        ("HelloWorld", -100000),
        ("../../etc/passwd", 0),
        ("con", -1),
        ("HelloWorld", INT_MAX),
        ("con", INT_MAX),
    ]
    slugs = _slugify_many([(s, ml, "untitled") for s, ml in degenerate])
    for (s, ml), slug in zip(degenerate, slugs):
        _assert_safe_slug(s, slug)
        if ml <= 0:
            assert slug == "untitled", (
                "slugify(%r, maxLength=%d) must fall back to the safe fallback for a "
                "non-positive budget, got %r" % (s, ml, slug)
            )
    # Int.max budget: the plain input is unchanged, the reserved one still escapes.
    big = _slugify_many([("HelloWorld", INT_MAX, "untitled"), ("con", INT_MAX, "untitled")])
    assert big[0] == "helloworld", big[0]
    assert big[1] == "_con", big[1]


# ---------------------------------------------------------------------------
# ATTACK 82 (LOCK) — export→re-ingest closure. The earlier Resolume tests scan the
# exporter's OWN output for injection; this feeds that output straight back through
# the REAL ResolumeParser. A hostile preset name (quote/angle-bracket breakout, a
# fully-formed <point>/<Preset> injection, DOCTYPE, the five XML metacharacters)
# must re-parse as WELL-FORMED XML in which the name is inert DATA: the round-tripped
# name equals the original byte-for-byte, no extra envelope point appears (still the
# 3 the single cue + auto start/end yield), and no second Preset is created. spec §4.
# ---------------------------------------------------------------------------


def test_resolume_export_output_reingests_as_inert_data_with_no_markup_injection():
    payloads = [
        'plain preset',
        'A"/><Inject x="1',  # attribute breakout + new element
        'B"/><point x="9" y="9" curve="7"/><q z="',  # forged envelope point
        'C"/></points></ModifierEnvelope></Preset><Preset name="evil',  # 2nd Preset
        'D&<>"\'',  # every XML metacharacter at once
        ']]>E<!DOCTYPE x [<!ENTITY y "z">]>',  # CDATA close + DOCTYPE/entity
        'F" default="1" className="Injected',  # forged attributes on the Preset
    ]
    xmls = _run_cs_batch(["res %s 0.5 1 10" % _b64(p) for p in payloads])
    reparsed = _run_cs_batch(["parse %s" % _b64(x) for x in xmls])
    for payload, xml, r in zip(payloads, xmls, reparsed):
        assert xml != "<nil>", "one enabled cue must still export (name %r)" % payload
        # Structural: the exporter emitted exactly one Preset and exactly the 3 points
        # (auto x=0, the cue at x=0.05, auto x=1) — the name never became markup.
        assert xml.count("<Preset ") == 1, (
            "preset name %r injected a second <Preset> element into the XML" % payload
        )
        assert xml.count("<point x=") == 3, (
            "preset name %r injected %d extra <point> element(s) into the envelope"
            % (payload, xml.count("<point x=") - 3)
        )
        # Behavioural: the REAL parser re-ingests it, sees 3 points, and recovers the
        # name as inert data identical to the original (ascii payloads carry no XML-
        # illegal scalars, so stripIllegalXmlScalars is a no-op here).
        parts = r.split("\t")
        assert parts[0] == "OK", (
            "spec §4: ResolumeParser could not re-parse the exporter's own output for "
            "preset name %r (%r) — the name broke XML well-formedness" % (payload, r)
        )
        n = int(parts[-1])
        name = "\t".join(parts[1:-1])
        assert n == 3, (
            "spec §4: re-parsing the exported XML yielded %d envelope points for preset "
            "name %r (expected 3) — the name injected phantom points" % (n, payload)
        )
        assert name == payload, (
            "spec §4: the preset name did not round-trip as inert data — sent %r, the "
            "parser read back %r (markup or escaping corrupted the value)"
            % (payload, name)
        )


# ---------------------------------------------------------------------------
# ATTACK 83 (LOCK) — full untrusted-file → filename chain. XMLParser resolves
# numeric character references inside a Rekordbox `Name=` attribute (`&#x2f;` -> "/",
# `&#x5c;` -> "\", `&#x2e;` -> "."), so an attacker can smuggle real path separators
# and traversal into the parsed track name WITHOUT a literal separator ever appearing
# in the file. slugify() is the sole boundary before that name becomes an export
# filename. This locks the composition end-to-end: hostile Rekordbox XML -> real
# parsed name -> slugify -> a single traversal-free component. spec §4.
# ---------------------------------------------------------------------------


def _rb_collection_xml(name_attr_value):
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<DJ_PLAYLISTS Version="1.0.0"><COLLECTION Entries="1">'
        '<TRACK TrackID="1" Name="%s" Location="file://localhost/x.mp3"/>'
        "</COLLECTION></DJ_PLAYLISTS>"
    ) % name_attr_value


def test_rekordbox_xml_name_to_filename_slug_is_traversal_free_end_to_end():
    # attr value (as it literally appears in the XML)  ->  expected filename slug
    cases = {
        "&#x2e;&#x2e;&#x2f;&#x2e;&#x2e;&#x2f;etc&#x2f;passwd": "etc-passwd",
        "&#x2e;&#x2e;&#x5c;win.ini": "win-ini",  # entity-encoded ..\ traversal
        "CON": "_con",  # literal reserved name
        "&#x43;&#x4f;&#x4e;": "_con",  # entity-encoded "CON" still escapes
        "ｃｏｎ": "untitled",  # fullwidth homoglyph strips out
        "a &amp; b &lt;x&gt;": "a-b-x",
        "\\\\server\\share": "server-share",  # UNC path
        "...hidden": "hidden",  # leading dots
    }
    attr_values = list(cases.keys())
    parsed = _run_rt_batch(["rbparse %s" % _b64(_rb_collection_xml(v)) for v in attr_values])
    decoded_names = []
    for attr, r in zip(attr_values, parsed):
        parts = r.split("\t")
        assert parts[0] == "OK", (
            "the crafted Rekordbox XML for attr %r failed to parse: %r" % (attr, r)
        )
        assert parts[1] == "1", (
            "attr %r produced %s tracks, expected exactly 1 — the name field broke the "
            "XML structure" % (attr, parts[1])
        )
        decoded_names.append(_rt_inner(parts[3]))

    slugs = _slugify_many([(nm, 80, "untitled") for nm in decoded_names])
    for attr, name, slug in zip(attr_values, decoded_names, slugs):
        _assert_safe_slug(name, slug)
        expected = cases[attr]
        assert slug == expected, (
            "spec §4: Rekordbox Name=%r decoded to %r and slugified to %r, expected %r "
            "— the parser+slugify chain must neutralise every decoded separator / "
            "traversal / reserved-name into a safe single component" % (attr, name, slug, expected)
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
