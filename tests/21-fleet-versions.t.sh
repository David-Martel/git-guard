#!/bin/sh
# Exercise the public adapter, without depending on a fleet checkout or network.
t_case_fleet_versions() {
  log="$(gg_tmp_log)"
  if python3 - "$GG_ROOT" "$GG_T_TMPROOT" >"$log" 2>&1 <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT, TMP = Path(sys.argv[1]), Path(sys.argv[2])


def git(root, *args):
    return subprocess.check_output(
        ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
         "-C", str(root), *args], text=True, stderr=subprocess.PIPE
    ).strip()


def commit(root):
    git(root, "add", "-A")
    git(root, "commit", "-qm", "fixture")
    return git(root, "rev-parse", "HEAD")


def repo(path, files):
    path.mkdir()
    git(path, "init", "-q")
    git(path, "config", "user.name", "Test")
    git(path, "config", "user.email", "test@example.invalid")
    git(path, "config", "core.autocrlf", "false")
    for name, content in files.items():
        out = path / name
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(content)
    return commit(path)


CHECKER = '''import argparse, json, sys, tomllib
from pathlib import Path
import helper
p = argparse.ArgumentParser()
p.add_argument("--repo", type=Path)
p.add_argument("--registry", type=Path)
p.add_argument("--report", action="store_true")
p.add_argument("--enforce", action="store_true")
p.add_argument("--no-network", action="store_true")
p.add_argument("--json", type=Path)
a = p.parse_args()
assert a.no_network and a.report != a.enforce
try:
    policy = tomllib.loads(a.registry.read_text())
except tomllib.TOMLDecodeError:
    sys.exit(2)
print(json.dumps({"fixture_checker": True, "helper": helper.VALUE, "mode": "enforce" if a.enforce else "report"}))
if a.json:
    a.json.write_text(json.dumps({"findings": [{"status": "UNKNOWN"}, {"status": "unresolved"}],
                                  "lane_errors": ["fixture lane"], "warnings": ["missing input"]}))
value = (a.repo / "version.txt").read_text().strip()
if value == "exit7": sys.exit(7)
sys.exit(1 if a.enforce and int(value) < policy["minimum"] else 0)
'''


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="versions space ", dir=TMP)
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.target, self.checker = base / "target space", base / "checker space"
        self.target_sha = repo(self.target, {"version.txt": "10\n", ".gitignore": "ignored/\n"})
        self.checker_sha = repo(self.checker, {
            "tools/fleet_versions/check.py": CHECKER,
            "tools/fleet_versions/helper.py": "VALUE = 'pinned-module'\n",
            "policy/fleet-versions.toml": "minimum = 10\n",
            ".gitignore": "ignored/\n",
        })

    def run_adapter(self, *extra, mode="--enforce", env=None):
        return subprocess.run(
            ["sh", str(ROOT / "bin/git-guard"), "versions", "--repo", str(self.target),
             "--commit", self.target_sha, "--checker-root", str(self.checker),
             "--checker-commit", self.checker_sha, mode, *extra],
            text=True, capture_output=True, env=env, timeout=30,
        )

    def assert_result(self, expected, **kwargs):
        result = self.run_adapter(**kwargs)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_clean_spaces_and_imported_module(self):
        result = self.assert_result(0)
        self.assertIn('"fixture_checker": true', result.stdout)
        self.assertIn('"helper": "pinned-module"', result.stdout)
        self.assertIn(self.checker_sha, result.stderr)
        self.assertIn(self.target_sha, result.stderr)

    def test_enforce_fails_downgrade_report_exposes_it(self):
        (self.target / "version.txt").write_text("9\n")
        self.target_sha = commit(self.target)
        self.assert_result(1)
        self.assertIn('"mode": "report"', self.assert_result(0, mode="--report").stdout)

    def test_json_preserves_canonical_statuses_and_provenance(self):
        output = Path(self.temp.name) / "receipt space.json"
        result = self.run_adapter("--json", str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(output.read_text())
        self.assertEqual(receipt["canonical_report"], {
            "findings": [{"status": "UNKNOWN"}, {"status": "unresolved"}],
            "lane_errors": ["fixture lane"], "warnings": ["missing input"],
        })
        self.assertEqual(receipt["provenance"]["checker_commit"], self.checker_sha)
        self.assertEqual(receipt["checker_exit_code"], 0)
        self.assertEqual(len(receipt["provenance"]["adapter_sha256"]), 64)
        original = output.read_bytes()
        self.assertEqual(self.run_adapter("--json", str(output)).returncode, 2)
        self.assertEqual(output.read_bytes(), original)
        self.assertEqual(self.run_adapter("--json", str(self.target / "receipt.json")).returncode, 2)

    def test_json_zero_without_valid_object_fails_closed(self):
        script = self.checker / "tools/fleet_versions/check.py"
        for label, action in [("absent", "a.json.unlink()"),
                              ("malformed", "a.json.write_text('{broken')"),
                              ("nonobject", "a.json.write_text('[]')")]:
            with self.subTest(label=label):
                script.write_text(CHECKER.replace("value = (a.repo", action + "\nvalue = (a.repo"))
                self.checker_sha = commit(self.checker)
                output = Path(self.temp.name) / (label + ".json")
                result = self.run_adapter("--json", str(output))
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertFalse(output.exists())

    def test_nonstandard_checker_error_propagates(self):
        (self.target / "version.txt").write_text("exit7\n")
        self.target_sha = commit(self.target)
        self.assert_result(7)

    def test_malformed_registry_propagates(self):
        (self.checker / "policy/fleet-versions.toml").write_text("[bad\n")
        self.checker_sha = commit(self.checker)
        self.assert_result(2)

    def test_bad_pin_and_missing_checker_fail(self):
        for pin in ["main", "0" * 40, "333284b"]:
            with self.subTest(pin=pin):
                self.checker_sha = pin
                self.assert_result(2)
        self.checker_sha = git(self.checker, "rev-parse", "HEAD")
        git(self.checker, "rm", "tools/fleet_versions/check.py")
        self.checker_sha = commit(self.checker)
        self.assert_result(2)

    def test_target_pin_and_mode_are_required(self):
        self.target_sha = "main"
        self.assert_result(2)
        result = subprocess.run(
            ["sh", str(ROOT / "bin/git-guard"), "versions", "--enforce"],
            text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_staged_or_unstaged_target_cannot_pass(self):
        (self.target / "version.txt").write_text("9\n")
        self.assert_result(2)
        git(self.target, "add", "version.txt")
        self.assert_result(2)

    def test_untracked_and_ignored_scanner_inputs_refused(self):
        for root in [self.target, self.checker]:
            for name in ["pyproject.toml", "ignored/uv.lock"]:
                with self.subTest(root=root.name, name=name):
                    path = root / name
                    path.parent.mkdir(exist_ok=True)
                    path.write_text("extra = true\n")
                    self.assert_result(2)
                    path.unlink()
                    if name.startswith("ignored/"):
                        path.parent.rmdir()

    def test_hidden_tracked_changes_fail_byte_proof(self):
        for root, name in [(self.target, "version.txt"),
                           (self.checker, "tools/fleet_versions/helper.py")]:
            with self.subTest(name=name):
                path = root / name
                original = path.read_bytes()
                git(root, "update-index", "--assume-unchanged", name)
                path.write_text("9\n" if name == "version.txt" else "VALUE = 'changed'\n")
                self.assert_result(2)
                path.write_bytes(original)
                git(root, "update-index", "--no-assume-unchanged", name)

    def test_tracked_symlink_escape_refused(self):
        (Path(self.temp.name) / "outside.py").write_text("outside = True\n")
        for root in [self.target, self.checker]:
            with self.subTest(root=root.name):
                link = root / "escape.py"
                link.symlink_to("../outside.py")
                if root == self.target:
                    self.target_sha = commit(root)
                else:
                    self.checker_sha = commit(root)
                self.assertIn("symlink escapes", self.assert_result(2).stderr)
                git(root, "rm", "escape.py")
                if root == self.target:
                    self.target_sha = commit(root)
                else:
                    self.checker_sha = commit(root)

    def test_internal_symlink_is_allowed(self):
        (self.target / "version-alias.txt").symlink_to("version.txt")
        self.target_sha = commit(self.target)
        self.assert_result(0)

    def test_environment_cannot_replace_local_module(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (outside / "helper.py").write_text("raise RuntimeError('injected')\n")
        env = dict(os.environ, PYTHONPATH=str(outside), GIT_WORK_TREE=str(outside))
        self.assertIn('"pinned-module"', self.assert_result(0, env=env).stdout)


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
  then
    cat "$log"
    t_ok "fleet versions adapter contracts"
  else
    cat "$log" >&2
    t_fail "fleet versions adapter contracts"
  fi
}
