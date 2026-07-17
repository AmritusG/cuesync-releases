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

import re
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
    passed = failed = 0
    for name, fn in tests:
        try:
            fn()
            print("PASS", name)
            passed += 1
        except AssertionError as e:
            print("FAIL", name)
            print("     " + str(e).replace("\n", "\n     "))
            failed += 1
        except Exception:
            print("ERROR", name)
            traceback.print_exc()
            failed += 1
    print("\n%d passed, %d failed, %d total" % (passed, failed, len(tests)))
    raise SystemExit(1 if failed else 0)
