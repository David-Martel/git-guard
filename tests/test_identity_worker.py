"""Containment regressions for hooks/common/identity_worker.py (stdlib only).

Each test protects verification liveness without accepting partial attestations.
Run through tests/34-identity-worker.t.sh; needs an existing Python and Git.
"""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

WORKER = Path(__file__).resolve().parents[1] / "hooks/common/identity_worker.py"


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise RuntimeError(f"test prerequisite unavailable: {name}")
    return path


class WorkerTests(unittest.TestCase):
    @unittest.skipIf(
        os.name == "nt",
        "POSIX launch-boundary injection; Windows uses atomic Job assignment",
    )
    def test_signal_during_launch_still_reaps_child(self):
        """Protects: catchable cancellation during child ownership transfer.
        Detects: signal handler exceptions bypass launch cleanup and leak child.
        Needs: POSIX Python, supported process-group containment.
        Breadcrumb: hooks/common/identity_worker.py
        """
        with tempfile.TemporaryDirectory(prefix="gg-launch-signal-") as directory:
            root = Path(directory)
            marker = root / "alive"
            leaf = (
                "import time,pathlib; time.sleep(0.6); "
                f"pathlib.Path({str(marker)!r}).write_text('leaked')"
            )
            driver = textwrap.dedent(f"""
                import importlib.util,pathlib,signal,subprocess,sys
                spec=importlib.util.spec_from_file_location('owned_worker',{str(WORKER)!r})
                worker=importlib.util.module_from_spec(spec)
                spec.loader.exec_module(worker)
                original=subprocess.Popen
                def launched(*args,**kwargs):
                    child=original(*args,**kwargs)
                    worker.interrupted(signal.SIGTERM,None)
                    return child
                worker.subprocess.Popen=launched
                try:
                    out=pathlib.Path({str(root / "out")!r})
                    err=pathlib.Path({str(root / "err")!r})
                    worker.posix_run([sys.executable,'-c',{leaf!r}],2,out,err)
                except InterruptedError:
                    sys.exit(125)
                sys.exit(0)
                """)
            result = subprocess.run(
                [sys.executable, "-c", driver],
                capture_output=True,
                timeout=5,
                check=False,
            )
            self.assertEqual(result.returncode, 125, result.stderr)
            time.sleep(0.9)
            self.assertFalse(marker.exists(), "launch cancellation left child running")

    def test_install_runtime_failure_prevents_promotion_gate(self):
        """Protects: missing runtime cannot strand an active hook installation.
        Detects: candidate passes promotion gate despite failed offline runtime.
        Needs: Python and POSIX sh; extracted real gate avoids global config.
        Breadcrumb: install.sh
        """
        with tempfile.TemporaryDirectory(prefix="gg-install-runtime-") as directory:
            root = Path(directory)
            source = root / "source"
            common = source / "hooks/common"
            common.mkdir(parents=True)
            shutil.copyfile(WORKER.with_name("identity.sh"), common / "identity.sh")
            shutil.copyfile(WORKER, common / WORKER.name)
            for path in (source / "hooks/pre-commit", common / "qa_gate.sh"):
                path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                path.chmod(0o700)
            installer = (WORKER.parents[2] / "install.sh").read_text(encoding="utf-8")
            gate = installer.split("qa_verify_materialized_tree() {", 1)[1].split(
                "\n}\n\nmaterialize_version", 1
            )[0]
            harness = root / "gate.sh"
            harness.write_text(
                "#!/bin/sh\nqa_verify_materialized_tree() {"
                + gate
                + '\n}\nqa_verify_materialized_tree "$1"\n',
                encoding="utf-8",
            )
            tools = root / "tools"
            tools.mkdir()
            unavailable = tools / "uv"
            unavailable.write_text("#!/bin/sh\nexit 19\n", encoding="utf-8")
            unavailable.chmod(0o700)
            environment = os.environ.copy()
            environment.update(PATH=str(tools) + os.pathsep + environment["PATH"])
            result = subprocess.run(
                [require_tool("sh"), str(harness), str(source)],
                env=environment,
                capture_output=True,
                timeout=10,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"VERIFY FAILED", result.stderr)
            # Positive control: the same actual gate admits offline containment.
            uv = require_tool("uv")
            unavailable.write_text(
                "#!/bin/sh\nexec " + shlex.quote(uv.replace("\\", "/")) + ' "$@"\n',
                encoding="utf-8",
            )
            result = subprocess.run(
                [require_tool("sh"), str(harness), str(source)],
                env=environment,
                capture_output=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            (common / WORKER.name).unlink()
            result = subprocess.run(
                [require_tool("sh"), str(harness), str(source)],
                env=environment,
                capture_output=True,
                timeout=10,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0, result.stderr)

    def run_worker(self, script: str, *, timeout: int = 1, args: tuple[str, ...] = ()):
        """Use owned temporary regular output files, never pipe a verifier."""
        with tempfile.TemporaryDirectory(prefix="gg-worker-") as directory:
            root = Path(directory)
            command = [
                sys.executable,
                "-I",
                "-S",
                "-B",
                str(WORKER),
                "--timeout-seconds",
                str(timeout),
                "--output",
                str(root / "out"),
                "--error",
                str(root / "err"),
                "--",
                sys.executable,
                "-I",
                "-S",
                "-B",
                "-c",
                script,
                *args,
            ]
            started = time.monotonic()
            result = subprocess.run(
                command, capture_output=True, timeout=8, check=False
            )
            elapsed = time.monotonic() - started
            output = (root / "out").read_bytes() if (root / "out").exists() else b""
            error = (root / "err").read_bytes() if (root / "err").exists() else b""
            return result, output, error, elapsed

    def test_hang_fails_finitely(self):
        """Protects: finite signature query duration.
        Detects: a sleeping verifier exceeds its owned deadline.
        Needs: Python, supported Windows or POSIX containment.
        Breadcrumb: hooks/common/identity_worker.py
        """
        result, _, _, elapsed = self.run_worker("import time; time.sleep(60)")
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(elapsed, 5)

    def test_positive_preserves_binary_output_and_argv(self):
        """Protects: exact binary output and argument boundaries.
        Detects: shell reparsing corrupts empty, quoted or Unicode arguments.
        Needs: Python, supported Windows or POSIX containment.
        Breadcrumb: hooks/common/identity_worker.py
        """
        args = ("", "with spaces", 'a"quote', "Unicode-λ")
        result, output, error, _ = self.run_worker(
            "import json,os,sys; os.write(1,json.dumps(sys.argv[1:]).encode()); "
            "os.write(2,b'error\\x00bytes')",
            args=args,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output), list(args))
        self.assertEqual(error, b"error\x00bytes")

    def test_failure_does_not_become_success(self):
        """Protects: partial attestation remains a failure.
        Detects: a failed verifier becomes successful after output capture.
        Needs: Python, supported Windows or POSIX containment.
        Breadcrumb: hooks/common/identity_worker.py
        """
        result, output, _, _ = self.run_worker(
            "import sys; print('partial'); sys.exit(7)"
        )
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(output.strip(), b"partial")

    def test_descendant_is_retired_after_leader_exit(self):
        """Protects: successful queries release their owned process tree.
        Detects: a descendant writes after its parent and worker return.
        Needs: Python, supported Windows or POSIX containment.
        Breadcrumb: hooks/common/identity_worker.py
        """
        with tempfile.TemporaryDirectory(prefix="gg-worker-child-") as directory:
            marker = Path(directory) / "escaped.txt"
            leaf = (
                "import time,pathlib; time.sleep(2); "
                f"pathlib.Path({str(marker)!r}).write_text('alive')"
            )
            script = (
                "import subprocess,sys; "
                f"subprocess.Popen([sys.executable,'-c',{leaf!r}])"
            )
            result, _, _, _ = self.run_worker(script)
            self.assertEqual(result.returncode, 0, result.stderr)
            time.sleep(2.3)
            self.assertFalse(marker.exists(), "owned descendant survived worker return")

    def test_timeout_also_retires_descendant(self):
        """Protects: deadline terminates all ordinary owned descendants.
        Detects: a descendant survives the verifier leader timeout.
        Needs: Python, supported Windows or POSIX containment.
        Breadcrumb: hooks/common/identity_worker.py
        """
        with tempfile.TemporaryDirectory(prefix="gg-worker-timeout-") as directory:
            marker = Path(directory) / "alive.txt"
            leaf = (
                "import time,pathlib; time.sleep(2); "
                f"pathlib.Path({str(marker)!r}).write_text('alive')"
            )
            script = (
                "import subprocess,sys,time; "
                f"subprocess.Popen([sys.executable,'-c',{leaf!r}]); time.sleep(60)"
            )
            result, _, _, _ = self.run_worker(script)
            self.assertEqual(result.returncode, 124, result.stderr)
            time.sleep(1.3)
            self.assertFalse(marker.exists(), "timeout left an owned descendant alive")

    def test_output_overflow_fails_closed(self):
        """Protects: excessive output fails verification closed.
        Detects: output above the rejection threshold reports success.
        Needs: Python, supported Windows or POSIX containment.
        Breadcrumb: hooks/common/identity_worker.py
        """
        result, _, _, _ = self.run_worker("import os; os.write(1,b'x'*1048577)")
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertIn(b"exceeded", result.stderr)

    def test_invalid_budget_is_rejected(self):
        """Protects: every query has a finite permitted budget.
        Detects: zero or unlimited budgets launch a verifier.
        Needs: Python, no verifier prerequisite.
        Breadcrumb: hooks/common/identity_worker.py
        """
        result, _, _, _ = self.run_worker("raise SystemExit(0)", timeout=0)
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_identity_deadline_discards_partial_attestation(self):
        """Protects: CLI rejects partial signature-query results.
        Detects: hung fake SSH verification returns rows or exceeds budget.
        Needs: Python, uv, Git, POSIX sh, supported process containment.
        Breadcrumb: hooks/common/identity.sh
        """
        git = require_tool("git")
        shell = require_tool("sh")
        with tempfile.TemporaryDirectory(prefix="gg-identity-deadline-") as directory:
            root = Path(directory)

            def git_run(*args: str, data: bytes | None = None) -> str:
                return (
                    subprocess.run(
                        [git, *args],
                        cwd=root,
                        input=data,
                        capture_output=True,
                        check=True,
                    )
                    .stdout.decode()
                    .strip()
                )

            git_run("init", "-q")
            verifier = root / "verifier.py"
            verifier.write_text(
                "import sys,time,pathlib\n"
                f"pathlib.Path({str(root / 'called')!r}).write_text(repr(sys.argv))\n"
                "if 'find-principals' in sys.argv: print('codex')\n"
                "else: time.sleep(60)\n",
                encoding="utf-8",
            )
            git_run("config", "gpg.format", "ssh")
            launcher = root / "verifier.sh"
            launcher.write_text(
                "#!/bin/sh\nexec "
                + shlex.quote(sys.executable.replace("\\", "/"))
                + " "
                + shlex.quote(verifier.as_posix())
                + ' "$@"\n',
                encoding="utf-8",
            )
            launcher.chmod(0o700)
            git_run("config", "gpg.ssh.program", launcher.as_posix())
            git_run("config", "gitGuard.identityTimeoutSeconds", "1")
            tree = git_run("mktree", data=b"")
            commit = (
                f"tree {tree}\nauthor Fixture <fixture@example.invalid> 1 +0000\n"
                "committer Fixture <fixture@example.invalid> 1 +0000\n"
                "gpgsig -----BEGIN SSH SIGNATURE-----\n YQ==\n"
                " -----END SSH SIGNATURE-----\n\nfixture\n\nAgent: codex\n"
            )
            sha = git_run(
                "hash-object", "-t", "commit", "-w", "--stdin", data=commit.encode()
            )
            git_run("update-ref", "refs/heads/main", sha)
            signers = root / "allowed_signers"
            signers.write_text("codex ssh-ed25519 AAAA\n", encoding="utf-8")
            command = [
                sys.executable,
                "-I",
                "-S",
                "-B",
                str(WORKER),
                "--timeout-seconds",
                "5",
                "--output",
                str(root / "out"),
                "--error",
                str(root / "err"),
                "--",
                shell,
                str(WORKER.with_name("identity.sh")),
                "verify",
                "--allowed-signers",
                str(signers),
                sha,
            ]
            result = subprocess.run(
                command, cwd=root, capture_output=True, timeout=10, check=False
            )
            self.assertEqual(
                result.returncode,
                3,
                (
                    result.stderr,
                    (root / "err").read_bytes(),
                    (root / "out").read_bytes(),
                    (root / "called").read_text()
                    if (root / "called").exists()
                    else "not called",
                ),
            )
            self.assertNotIn(b"ok   ", (root / "out").read_bytes())
            self.assertIn(b"deadline", (root / "err").read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=2)
