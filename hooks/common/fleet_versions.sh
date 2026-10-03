#!/bin/sh
# Explicit clean-CI entrypoint; never installs tools or changes hook adoption.
exec "${GIT_GUARD_VERSIONS_PYTHON:-python3}" -I -S -B - "$0" "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


def git(root, *args):
    result = subprocess.run(
        ["git", "--no-optional-locks", "-c", f"safe.directory={root}",
         "-C", str(root), *args],
        capture_output=True, check=False, timeout=60, env=GIT_ENV,
    )
    if result.returncode:
        raise ValueError(f"git {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def resolve_tracked_link(root, name, regular, links):
    """Follow a tracked symlink lexically, one tracked entry at a time.

    Returns the tracked regular file the chain ends at. Refuses an absolute
    link (the pinned tree would mean different bytes at a different path), a
    hop outside the tree or into Git metadata, a hop that is not itself a
    tracked entry, and a cycle or overlong chain.
    """
    current, seen = name, set()
    while current in links:
        if current in seen or len(seen) > 40:
            raise ValueError(f"{root}: symlink cycle or overlong chain at {name}")
        seen.add(current)
        link = os.readlink(root / current)
        if os.path.isabs(link):
            raise ValueError(f"{root}: absolute symlink target is not allowed: {current} -> {link}")
        hop = os.path.normpath(os.path.join(os.path.dirname(current), link)).replace(os.sep, "/")
        if hop in ("..", ".", ".git") or hop.startswith(("../", ".git/")):
            raise ValueError(f"{root}: symlink {current} -> {link} leaves the tracked tree")
        current = hop
    if current not in regular:
        raise ValueError(f"{root}: symlink {name} does not end at a tracked regular file ({current})")
    return current


def verify_tree(path, expected):
    if not re.fullmatch(r"[0-9a-f]{40}", expected):
        raise ValueError("commit pins must be full lowercase 40-character Git SHAs")
    root = path.resolve(strict=True)
    top = Path(os.fsdecode(git(root, "rev-parse", "--show-toplevel")).strip()).resolve()
    if root != top:
        raise ValueError(f"expected repository root, got {root}")
    actual = git(root, "rev-parse", "HEAD").decode().strip()
    if actual != expected:
        raise ValueError(f"{root}: HEAD {actual} does not match pinned {expected}")
    status = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching")
    if status:
        raise ValueError(f"{root}: staged, unstaged, untracked or ignored inputs; use a clean isolated checkout")

    # Status alone trusts assume-unchanged/skip-worktree and filter settings.
    # Check actual bytes against every indexed blob, including imported modules.
    entries = [entry for entry in git(root, "ls-files", "--stage", "-z").split(b"\0") if entry]
    parsed = []
    for entry in entries:
        header, raw_name = entry.split(b"\t", 1)
        mode, blob, stage = header.split()
        parsed.append((entry, mode, blob, stage, os.fsdecode(raw_name)))
    regular = {name for _, mode, _, _, name in parsed if mode in (b"100644", b"100755")}
    links = {name for _, mode, _, _, name in parsed if mode == b"120000"}
    digest = hashlib.sha256()
    tracked = set()
    for entry, mode, blob, stage, name in parsed:
        target = root / name
        if stage != b"0" or mode not in (b"100644", b"100755", b"120000"):
            raise ValueError(f"{root}: unsupported/unmerged entry {name}; submodules require separate validation")
        resolved = target.resolve(strict=True)
        if not resolved.is_relative_to(root):
            raise ValueError(f"{root}: symlink escapes the pinned tree: {name}")
        if mode == b"120000":
            # Every hop of the chain must itself be a tracked entry, ending at a
            # tracked regular file. Otherwise Git metadata (.git/evil.py) or any
            # other untracked path, which neither `status` nor the byte proof
            # covers, could choose or supply the bytes that are executed.
            final = resolve_tracked_link(root, name, regular, links)
            if resolved != root / final:
                raise ValueError(f"{root}: symlink {name} resolves through an untracked path")
            if not target.is_symlink():
                raise ValueError(f"{root}: symlink replaced: {name}")
            content = os.fsencode(os.readlink(target))
        else:
            if target.is_symlink() or not stat.S_ISREG(target.stat().st_mode):
                raise ValueError(f"{root}: expected regular tracked file: {name}")
            if resolved != root / name:
                raise ValueError(f"{root}: tracked file {name} is reached through a symlinked directory")
            content = target.read_bytes()
        actual_blob = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        if actual_blob != blob.decode():
            raise ValueError(f"{root}: tracked bytes differ from pinned Git blob: {name}")
        digest.update(entry + b"\0")
        tracked.add(name)
    if not tracked:
        raise ValueError(f"{root}: no tracked files")
    return root, digest.hexdigest(), tracked


def main():
    parser = argparse.ArgumentParser(description="Run the canonical fleet minimum checker on clean committed snapshots.")
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--checker-root", type=Path, required=True)
    parser.add_argument("--checker-commit", required=True)
    parser.add_argument("--json", type=Path, help="new JSON receipt outside both snapshots")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--report", action="store_true")
    modes.add_argument("--enforce", action="store_true")
    args = parser.parse_args(sys.argv[2:])
    if sys.version_info < (3, 11):
        raise ValueError("Python 3.11+ is required; select an existing interpreter with GIT_GUARD_VERSIONS_PYTHON")

    target = verify_tree(args.repo, args.commit)
    checker = verify_tree(args.checker_root, args.checker_commit)
    script_name = "tools/fleet_versions/check.py"
    policy_name = "policy/fleet-versions.toml"
    if not {script_name, policy_name}.issubset(checker[2]):
        raise ValueError("pinned checker tree must track tools/fleet_versions/check.py and policy/fleet-versions.toml")
    script, policy = checker[0] / script_name, checker[0] / policy_name
    mode = "--enforce" if args.enforce else "--report"
    provenance = {
        "adapter_sha256": hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest(),
        "repo_commit": args.commit, "repo_path": str(target[0]),
        "repo_inventory_sha256": target[1], "checker_commit": args.checker_commit,
        "checker_path": str(checker[0]), "checker_inventory_sha256": checker[1],
        "policy_sha256": hashlib.sha256(policy.read_bytes()).hexdigest(),
        "checker_sha256": hashlib.sha256(script.read_bytes()).hexdigest(),
        "python": sys.executable, "python_version": sys.version.split()[0], "mode": mode,
    }
    print("git-guard versions provenance: " + json.dumps(provenance, sort_keys=True), file=sys.stderr, flush=True)

    # Isolated Python omits cwd, PYTHONPATH and site packages. Add only the
    # already-verified checker module directory for its sibling imports.
    bootstrap = (
        "import runpy,sys; from pathlib import Path; "
        "script=sys.argv.pop(1); sys.path.insert(0,str(Path(script).parent)); "
        "sys.argv[0]=script; runpy.run_path(script,run_name='__main__')"
    )
    output = None
    if args.json:
        output = args.json.resolve()
        if output.exists() or any(output.is_relative_to(item[0]) for item in (target, checker)):
            raise ValueError("JSON receipt must be a new path outside both snapshots")
        if not output.parent.is_dir():
            raise ValueError("JSON receipt parent must already exist")
    with tempfile.TemporaryDirectory(prefix="git-guard-versions-") as temporary:
        report_path = Path(temporary) / "canonical.json"
        command = [sys.executable, "-I", "-S", "-B", "-c", bootstrap, str(script),
                   "--repo", str(target[0]), "--registry", str(policy), mode, "--no-network"]
        if output:
            command.extend(["--json", str(report_path)])
        result = subprocess.run(command, cwd=checker[0], env=GIT_ENV, check=False, timeout=120)
        if verify_tree(args.repo, args.commit) != target or verify_tree(args.checker_root, args.checker_commit) != checker:
            raise ValueError("source identity changed during validation; result is not qualified")
        if output:
            report = json.loads(report_path.read_text()) if report_path.exists() else None
            if result.returncode in (0, 1) and not isinstance(report, dict):
                raise ValueError("canonical checker returned success/violation without a JSON object report")
            with output.open("x", encoding="utf-8") as stream:
                json.dump({"schema_version": 1, "provenance": provenance,
                           "checker_exit_code": result.returncode, "canonical_report": report},
                          stream, indent=2, sort_keys=True)
                stream.write("\n")
    if result.returncode < 0:
        print(f"git-guard versions: checker terminated by signal {-result.returncode}", file=sys.stderr)
        return 128 - result.returncode
    return result.returncode


# Hooks/CI may export GIT_DIR, GIT_WORK_TREE or an alternate index. Those must
# not substitute another repository for either explicitly supplied root.
GIT_ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
try:
    sys.exit(main())
except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
    print(f"git-guard versions: {error}", file=sys.stderr)
    sys.exit(2)
PY
