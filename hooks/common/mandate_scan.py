"""git-guard quality mandate: changed-line enforcement and a per-file debt register.

Run through hooks/common/mandate_scan.sh (which resolves the interpreter and runs
this file with ``python3 -I``). Standard library only.

The owner's mandate (2026-10-14) is enforced at commit time: pydantic v2 only, no
strings as enumerations, no explicit ``Any``, no error path that turns a failure
into ``None``/``False``/an empty value, typed and informative errors, and no
silent failures. The canonical policy text is vigil-ai-tpm
templates/strict-python-module/RULES.md at commit ecbedf353d4a; the full rule
catalogue, with a source line per rule, is docs/QA_TOOLING.md "Quality mandate".

Modes
-----
``--staged``                 findings on lines this commit adds or modifies (the
                             staged content is exported as raw Git blobs; the
                             working tree is never read).
``--range BASE..HEAD``       the same, for a commit range (CI, pre-push).
``--all [--rev REV]``        whole-tree per-rule, per-file counts as JSON on stdout.
``--write-baseline``         write those counts for the enforced rules to
                             .git-guard/mandate-baseline.json.
``--check-baseline``         compare a whole-tree count of REV (default HEAD) to
                             the baseline recorded in that same revision.
``--pre-push``               read the pre-push ref list on stdin and run
                             --check-baseline for every pushed commit that carries
                             a baseline file.

Per-rule severity comes from ``mandate.<rule>`` keys in qa-gate.conf (read via
``qa_gate.sh --get-prefix mandate.``): ``off`` skips the rule, ``warn`` reports
changed-line findings without blocking, ``changed`` blocks changed-line findings,
``block`` blocks any finding in a scanned file.

Exit status: 0 PASSED, 1 BLOCKED (findings or a baseline violation), 2 TOOL ERROR
(a scanner exited abnormally or produced output that could not be parsed, the
config is invalid, or the rule inventory does not match). A TOOL ERROR is never
read as "no findings". A scanner that is not installed is a WARN naming every rule
it left unevaluated, matching qa_gate.sh's anti-brick policy.
"""

from __future__ import annotations

import argparse
import ast
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tokenize
from contextlib import contextmanager
from dataclasses import dataclass, field, replace
from enum import Enum, IntEnum
from pathlib import Path, PurePosixPath
from typing import (
    Dict,
    FrozenSet,
    Iterable,
    Iterator,
    List,
    Mapping,
    Optional,
    Sequence,
    Set,
    Tuple,
    Union,
)

POLICY_REVISION = "git-guard-mandate-1"
CANONICAL_POLICY = "vigil-ai-tpm templates/strict-python-module/RULES.md @ ecbedf353d4a"
BASELINE_RELPATH = ".git-guard/mandate-baseline.json"
BASELINE_VERSION = 1
ZERO_SHA = "0" * 40
# One ast-grep / ruff invocation per chunk keeps every argv far below ARG_MAX on a
# whole-tree count (vigil-spark tracks several thousand Python files).
CHUNK = 800
STDERR_TAIL_LINES = 12
COMMAND_ECHO_ARGS = 12  # argv words echoed with a TOOL ERROR
OCTAL_ESCAPE_LEN = 3  # git C-quoting writes non-ASCII bytes as \ooo
LS_META_FIELDS = 3  # "<mode> <type|sha> <sha|stage>" before the tab in ls-tree/ls-files
PRE_PUSH_FIELDS = 4  # "<local ref> <local sha> <remote ref> <remote sha>"
# Every child process is bounded. Measured 2026-10-14: the CI-pinned ast-grep
# 0.39.5 deadlocked (futex wait, no CPU) on a single-file `scan --rule` under
# load, which would hang a commit indefinitely. A timeout is a TOOL ERROR.
DEFAULT_TIMEOUT_S = 300

SCRIPT_DIR = Path(__file__).resolve().parent
QA_GATE = SCRIPT_DIR / "qa_gate.sh"
RULES_ROOT = (SCRIPT_DIR / ".." / ".." / "rules-examples" / "mandate").resolve()


class Severity(str, Enum):
    OFF = "off"
    WARN = "warn"
    CHANGED = "changed"
    BLOCK = "block"


class Language(str, Enum):
    PYTHON = "python"
    RUST = "rust"


class Outcome(IntEnum):
    PASSED = 0
    BLOCKED = 1
    TOOL_ERROR = 2


class Tool(str, Enum):
    RUFF = "ruff"
    ASTGREP = "ast-grep"
    TEXT = "text"


class MandateError(Exception):
    """The mandate could not be evaluated. Always reported as TOOL ERROR (exit 2)."""


class ToolFailure(MandateError):
    """A scanner ran but its result cannot be trusted."""

    def __init__(self, tool: str, command: Sequence[str], detail: str) -> None:
        self.tool = tool
        self.command = list(command)
        self.detail = detail
        super().__init__(f"{tool}: {detail}")


class ConfigError(MandateError):
    """The mandate.* configuration is malformed or names an unknown value."""


@dataclass(frozen=True)
class Rule:
    key: str
    policy: str
    language: Language
    default: Severity
    ruff_codes: Tuple[str, ...]
    sg_ids: Tuple[str, ...]
    text_check: bool
    exempt_tests: bool
    source: str
    why: str
    fix: str

    @property
    def tools(self) -> Tuple[Tool, ...]:
        found: List[Tool] = []
        if self.ruff_codes or self.key == "python_syntax":
            found.append(Tool.RUFF)
        if self.sg_ids:
            found.append(Tool.ASTGREP)
        if self.text_check:
            found.append(Tool.TEXT)
        return tuple(found)


def _rule(
    key: str,
    policy: str,
    default: Severity,
    *,
    ruff: Tuple[str, ...] = (),
    sg: Tuple[str, ...] = (),
    text: bool = False,
    tests_exempt: bool = False,
    language: Language = Language.PYTHON,
    source: str,
    why: str,
    fix: str,
) -> Rule:
    return Rule(
        key, policy, language, default, ruff, sg, text, tests_exempt, source, why, fix
    )


RULES: Tuple[Rule, ...] = (
    _rule(
        "pydantic_v1",
        "PY-01",
        Severity.BLOCK,
        sg=("mandate-pydantic-v1",),
        source="vigil-spark AGENTS.md:188-190; vigil-ai-tpm CLAUDE.md:76",
        why="The fleet is pydantic v2 only; v1 APIs are deprecated and validate, "
        "serialise and configure differently.",
        fix="Use the v2 spelling: field_validator / model_validator, model_config = "
        "ConfigDict(...), Model.model_validate(...); import from pydantic, not "
        "pydantic.v1.",
    ),
    _rule(
        "pydantic_v1_ambiguous",
        "PY-01",
        Severity.WARN,
        sg=("mandate-pydantic-v1-ambiguous",),
        source="vigil-spark AGENTS.md:188-190",
        why="Legacy model method names also occur on unrelated APIs. Unresolved "
        "receivers, `.dict()` and `.copy(update=...)` only warn; proven model "
        "classmethods retain the strong rule.",
        fix="On a proven model use the corresponding v2 model_validate, "
        "model_validate_json, model_dump or model_copy API. Otherwise establish "
        "the receiver's type before changing its API.",
    ),
    _rule(
        "bare_except",
        "PY-06",
        Severity.BLOCK,
        ruff=("E722",),
        tests_exempt=True,
        source="clarius AGENTS.md:653-655; vigil-ai-tpm RULES.md section 8",
        why="A bare `except:` also catches KeyboardInterrupt and SystemExit, so "
        "Ctrl-C and sys.exit() are swallowed.",
        fix="Catch the specific exception you expect, or `except Exception` and "
        "re-raise with context.",
    ),
    _rule(
        "blind_except",
        "PY-06",
        Severity.CHANGED,
        ruff=("BLE001",),
        tests_exempt=True,
        source="clarius AGENTS.md:653-655; vigil-ai-tpm pyproject.toml:80-87",
        why="Catching Exception/BaseException treats every failure alike, including "
        "programming errors that should surface.",
        fix="Catch the exceptions this code can actually recover from; let the "
        "rest propagate.",
    ),
    _rule(
        "except_pass",
        "PY-06",
        Severity.CHANGED,
        ruff=("S110",),
        sg=("mandate-except-pass",),
        tests_exempt=True,
        source="clarius AGENTS.md:653-655 (logging is not handling); "
        "vigil-ai-tpm RULES.md section 8",
        why="The handler discards the failure, so nothing downstream can tell the "
        "operation did not happen. Logging it first does not change that.",
        fix="Re-raise a typed error with context (`raise XError(...) from exc`), or "
        "use contextlib.suppress(SpecificError) for a genuinely expected case.",
    ),
    _rule(
        "except_continue",
        "PY-06",
        Severity.CHANGED,
        ruff=("S112",),
        sg=("mandate-except-continue",),
        tests_exempt=True,
        source="clarius AGENTS.md:653-655; vigil-ai-tpm RULES.md section 8",
        why="The loop skips the failed item without a record, so a partial result "
        "looks complete.",
        fix="Record the failure (`failures.append((item, exc))`) and surface it, "
        "or re-raise.",
    ),
    _rule(
        "except_sentinel",
        "PY-05",
        Severity.WARN,
        sg=("mandate-except-sentinel",),
        tests_exempt=True,
        source="clarius CLAUDE.md:422-423 (no None/bool that drops the reason)",
        why="The handler turns a failure into None/False/empty, which the caller "
        "cannot tell from a legitimate result; the cause is destroyed.",
        fix="Raise a typed error with context, or return a typed outcome (an Enum "
        "status, a Result-like object) the caller must branch on.",
    ),
    _rule(
        "broad_suppress",
        "PY-06",
        Severity.CHANGED,
        sg=("mandate-broad-suppress",),
        tests_exempt=True,
        source="clarius AGENTS.md:653-655",
        why="contextlib.suppress(Exception) silently discards every failure in the "
        "block.",
        fix="Name the exceptions you expect: "
        "contextlib.suppress(FileNotFoundError, ...).",
    ),
    _rule(
        "no_any",
        "PY-03",
        Severity.CHANGED,
        ruff=("ANN401",),
        sg=("mandate-explicit-any",),
        tests_exempt=True,
        source="clarius AGENTS.md:657-658; vigil-ai-tpm RULES.md:10-11; "
        "vigil-oto CLAUDE.md:117",
        why="`Any` switches the type checker off for every value it touches.",
        fix="Use the narrowest honest type: object, a Protocol or TypeVar, a JSON "
        "alias, a pydantic model or a TypedDict.",
    ),
    _rule(
        "raise_from",
        "PY-07",
        Severity.CHANGED,
        ruff=("B904",),
        source="vigil-ai-tpm RULES.md:48-52",
        why="Raising inside an except without `from` loses the causal link to the "
        "original error.",
        fix="Write `raise NewError(...) from exc` (or `from None` when the cause is "
        "irrelevant).",
    ),
    _rule(
        "bare_exception_raise",
        "PY-08",
        Severity.CHANGED,
        ruff=("TRY002",),
        source="clarius README.md:123-125; vigil-ai-tpm RULES.md:88-96",
        why="`raise Exception(...)` gives callers nothing typed to catch.",
        fix="Define (or reuse) a specific exception class and raise that.",
    ),
    _rule(
        "raise_without_message",
        "PY-08",
        Severity.CHANGED,
        sg=("mandate-raise-without-message",),
        source="clarius README.md:123-125; vigil-spark AGENTS.md (say how to fix)",
        why="An exception with no message tells the reader a type name and no reason.",
        fix="Say what failed, with the values that matter, and how to fix it.",
    ),
    _rule(
        "unchecked_subprocess",
        "PY-13",
        Severity.CHANGED,
        ruff=("PLW1510",),
        source="vigil-ai-tpm RULES.md:123-125",
        why="subprocess.run without `check=` ignores a failing child process.",
        fix="Pass check=True, or check=False and branch on returncode explicitly.",
    ),
    _rule(
        "suppression_code",
        "PY-09",
        Severity.CHANGED,
        ruff=("PGH003", "PGH004"),
        source="vigil-ai-tpm RULES.md:83-86; vigil-audio AGENTS.md:56-58",
        why="A blanket `# noqa` / `# type: ignore` silences every rule on the line, "
        "including ones nobody reviewed.",
        fix="Name the code: `# noqa: BLE001`, `# type: ignore[attr-defined]`.",
    ),
    _rule(
        "suppression_reason",
        "PY-09",
        Severity.CHANGED,
        text=True,
        source="vigil-ai-tpm RULES.md:83-86; vigil-ai-tpm pyproject.toml:80-87",
        why="A suppression of a mandate rule with no recorded reason is "
        "unreviewable debt.",
        fix="Add the reason on the same line: `# noqa: CODE  # SAFETY: <why this "
        "is correct>` (or `# best-effort: <why>`).",
    ),
    _rule(
        "str_enum_param",
        "PY-04",
        Severity.WARN,
        sg=("mandate-str-enum-param",),
        tests_exempt=True,
        source="clarius CLAUDE.md:420-422; vigil-spark AGENTS.md:200",
        why="A mode/state/kind parameter typed as raw str/int turns a typo into a "
        "runtime surprise and hides the closed set of values.",
        fix="Define an Enum (StrEnum/IntEnum), annotate with it, and parse raw "
        "values at the boundary.",
    ),
    _rule(
        "literal_enum",
        "PY-04",
        Severity.WARN,
        sg=("mandate-literal-enum",),
        tests_exempt=True,
        source="vigil-spark py-no-literal-enum-annotation (vigil-ai-tpm "
        "RULES.md:11 recommends Literal)",
        why="A multi-member Literal[...] is an enumeration with no runtime "
        "definition site.",
        fix="Define an Enum and annotate with it.",
    ),
    _rule(
        "magic_number",
        "PY-04",
        Severity.WARN,
        ruff=("PLR2004",),
        tests_exempt=True,
        source="clarius CLAUDE.md:420-422 (no raw numbers as enumerations)",
        why="A bare number in a comparison hides what the value means.",
        fix="Name it: a module constant or an IntEnum member.",
    ),
    _rule(
        "python_syntax",
        "PY-10",
        Severity.CHANGED,
        source="git-guard mandate (a file that cannot be parsed cannot be checked)",
        why="ruff could not parse this file, so no other mandate rule could be "
        "evaluated on it.",
        fix="Fix the syntax error (run: ruff check <file>).",
    ),
    _rule(
        "rust_panic",
        "RS-01",
        Severity.CHANGED,
        sg=("mandate-rust-panic",),
        tests_exempt=True,
        language=Language.RUST,
        source="clarius CLAUDE.md:57; vigil-audio AGENTS.md:31-38; "
        "agent-hub CLAUDE.md:253",
        why="unwrap/expect/panic!/todo!/unimplemented! abort the process instead "
        "of returning an error the caller can handle.",
        fix="Return a typed error (`ok_or(Error::...)?`, `map_err(...)?`).",
    ),
)
RULES_BY_KEY: Dict[str, Rule] = {rule.key: rule for rule in RULES}
SG_TO_KEY: Dict[str, str] = {sg: rule.key for rule in RULES for sg in rule.sg_ids}
RUFF_TO_KEY: Dict[str, str] = {
    code: rule.key for rule in RULES for code in rule.ruff_codes
}

PY_SUFFIXES = (".py",)
RS_SUFFIXES = (".rs",)
VENDORED_PARTS = frozenset(
    {"vendor", "_vendor", "third_party", "node_modules", ".venv", "site-packages"}
)
RUST_NONPROD_PARTS = frozenset({"tests", "benches", "examples"})
PY_TEST_PARTS = frozenset({"tests", "test"})

HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
NOQA_RE = re.compile(
    r"#\s*(?:(?:ruff|flake8)\s*:\s*)?noqa\s*:\s*"
    r"([A-Z]+[0-9]+(?:[\s,]+[A-Z]+[0-9]+)*)",
    re.IGNORECASE,
)
SG_IGNORE_RE = re.compile(
    r"ast-grep-ignore(?:\s*:\s*([A-Za-z0-9_\-]+(?:\s*,\s*[A-Za-z0-9_\-]+)*))?"
)
REASON_RE = re.compile(r"(#|//)\s*(SAFETY|best-effort)\s*:\s*\S")
VERSION_SYNTAX_RE = re.compile(r"\(syntax was (added|removed) in Python")
DEBUG = os.environ.get("QA_DEBUG", "") == "1"


def debug(message: str) -> None:
    if DEBUG:
        print(f"mandate[debug] {message}", file=sys.stderr)


def say(message: str = "") -> None:
    print(message, file=sys.stderr)


@dataclass(frozen=True)
class Finding:
    key: str
    path: str
    line: int
    end_line: int
    origin: str
    message: str


@dataclass
class ScanResult:
    findings: List[Finding] = field(default_factory=list)
    skipped: Dict[str, List[str]] = field(default_factory=dict)
    warnings: List[str] = field(default_factory=list)


@dataclass(frozen=True)
class Tools:
    ruff: Optional[str]
    astgrep: Optional[str]


# --------------------------------------------------------------------------- git


def run(
    command: Sequence[str],
    *,
    cwd: Path,
    tool: str,
    env: Optional[Mapping[str, str]] = None,
    stdin: Optional[bytes] = None,
) -> "subprocess.CompletedProcess[bytes]":
    """Run a command, turning "could not start" / "hung" into a named ToolFailure."""
    debug(f"$ {' '.join(command)}")
    limit = tool_timeout()
    try:
        return subprocess.run(  # noqa: S603  # SAFETY: argv list, no shell; tool paths resolved above
            list(command),
            cwd=str(cwd),
            input=stdin,
            capture_output=True,
            check=False,
            env=None if env is None else dict(env),
            timeout=limit,
        )
    except subprocess.TimeoutExpired as exc:
        raise ToolFailure(
            tool,
            command,
            f"did not finish within {limit}s (GIT_GUARD_MANDATE_TIMEOUT); it was "
            "killed. A hung scanner is not a clean scan.",
        ) from exc
    except OSError as exc:
        raise ToolFailure(tool, command, f"could not start: {exc}") from exc


def tool_timeout() -> int:
    raw = os.environ.get("GIT_GUARD_MANDATE_TIMEOUT", "")
    if not raw:
        return DEFAULT_TIMEOUT_S
    if not raw.isdigit() or int(raw) < 1:
        raise ConfigError(
            f"GIT_GUARD_MANDATE_TIMEOUT={raw!r} must be a positive number of seconds"
        )
    return int(raw)


def stderr_tail(raw: bytes) -> str:
    lines = raw.decode("utf-8", "replace").strip().splitlines()
    return "\n".join(lines[-STDERR_TAIL_LINES:]) or "<no stderr>"


def git(
    repo: Path,
    *args: str,
    stdin: Optional[bytes] = None,
    env: Optional[Mapping[str, str]] = None,
) -> bytes:
    command = ["git", *args]
    done = run(command, cwd=repo, tool="git", stdin=stdin, env=env)
    if done.returncode != 0:
        raise ToolFailure(
            "git", command, f"exit {done.returncode}: {stderr_tail(done.stderr)}"
        )
    return done.stdout


def repo_root(start: Path) -> Path:
    out = (
        git(start, "rev-parse", "--show-toplevel")
        .decode("utf-8", "surrogateescape")
        .strip()
    )
    if not out:
        raise MandateError("not inside a git work tree")
    return Path(out)


def head_sha(repo: Path) -> str:
    done = run(["git", "rev-parse", "--verify", "-q", "HEAD"], cwd=repo, tool="git")
    sha = done.stdout.decode().strip()
    return sha if done.returncode == 0 and sha else "unborn"


def verify_commit(repo: Path, rev: str) -> str:
    done = run(
        ["git", "rev-parse", "--verify", "-q", f"{rev}^{{commit}}"],
        cwd=repo,
        tool="git",
    )
    sha = done.stdout.decode().strip()
    if done.returncode != 0 or not sha:
        raise MandateError(f"'{rev}' does not name a commit in this repository")
    return sha


def unquote_git_path(raw: str) -> str:
    """Undo git's C-style quoting of a path in diff headers."""
    if not (raw.startswith('"') and raw.endswith('"')):
        return raw
    body = raw[1:-1]
    out = bytearray()
    index = 0
    simple = {
        "n": 10,
        "t": 9,
        "r": 13,
        '"': 34,
        "\\": 92,
        "a": 7,
        "b": 8,
        "f": 12,
        "v": 11,
    }
    while index < len(body):
        char = body[index]
        if char == "\\" and index + 1 < len(body):
            nxt = body[index + 1]
            if nxt in simple:
                out.append(simple[nxt])
                index += 2
                continue
            octal = body[index + 1 : index + 4]
            if len(octal) == OCTAL_ESCAPE_LEN and all(c in "01234567" for c in octal):
                out.append(int(octal, 8))
                index += 4
                continue
        out.extend(char.encode("utf-8"))
        index += 1
    return out.decode("utf-8", "surrogateescape")


def parse_changed_lines(diff: str) -> Dict[str, Set[int]]:
    """Map each post-image path in a ``-U0`` diff to the 1-based lines it adds."""
    out: Dict[str, Set[int]] = {}
    current: Optional[str] = None
    in_header = False
    # Git records use LF; Unicode separators inside source are not diff records.
    for line in diff.split("\n"):
        if line.startswith("diff --git "):
            current = None
            in_header = True
            continue
        if in_header and line.startswith("+++ "):
            target = unquote_git_path(line[4:].rstrip("\t"))
            if target == "/dev/null":
                current = None
                continue
            current = target[2:] if target.startswith("b/") else target
            out.setdefault(current, set())
            continue
        match = HUNK_RE.match(line)
        if match:
            # Hunk content can itself start "+++ "; only file headers name paths.
            in_header = False
            if current is None:
                continue
            start = int(match.group(1))
            count = int(match.group(2)) if match.group(2) is not None else 1
            out[current].update(range(start, start + count))
    return out


DIFF_FLAGS = (
    "-c",
    "core.quotePath=false",
    "-c",
    "diff.interHunkContext=0",
    "diff",
    "-U0",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--text",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    "-M",
    "--diff-filter=d",  # everything but deletions: A, M, R, C and T (type change)
)


def diff_changes(repo: Path, *args: str) -> Dict[str, Set[int]]:
    changes = parse_changed_lines(
        git(repo, *DIFF_FLAGS, *args).decode("utf-8", "surrogateescape")
    )
    # Pure renames have no +++ header. Keep their destinations for whole-file
    # BLOCK rules, with no added lines for changed-only findings or warnings.
    for path in split_nul(git(repo, *DIFF_FLAGS, "--name-only", "-z", *args)):
        changes.setdefault(path, set())
    return changes


def staged_changes(repo: Path) -> Dict[str, Set[int]]:
    """Keep merge-resolution lines new against every parent, retaining BLOCK paths."""
    merge_path = Path(
        os.fsdecode(git(repo, "rev-parse", "--git-path", "MERGE_HEAD").rstrip(b"\n"))
    )
    if not merge_path.is_absolute():
        merge_path = repo / merge_path
    try:
        merge_heads = merge_path.read_text(encoding="ascii").split()
    except FileNotFoundError:
        return diff_changes(repo, "--cached")
    except (OSError, UnicodeError) as exc:
        raise MandateError("cannot read merge parent metadata") from exc
    if not merge_heads:
        raise MandateError("merge parent metadata contains no commits")
    parents = [verify_commit(repo, "HEAD")]
    parents.extend(verify_commit(repo, parent) for parent in merge_heads)
    changes = diff_changes(repo, "--cached", parents[0])
    for parent in parents[1:]:
        other = diff_changes(repo, "--cached", parent)
        # Both diffs use exact index postimage coordinates. A line inherited
        # from any parent is old debt; keep every path for whole-file BLOCK.
        for path in changes.keys() | other.keys():
            changes.setdefault(path, set()).intersection_update(other.get(path, set()))
    return changes


def range_changes(repo: Path, spec: str) -> Tuple[str, Dict[str, Set[int]]]:
    if "..." in spec:
        left, right = spec.split("...", 1)
        head = verify_commit(repo, right or "HEAD")
        base = git(repo, "merge-base", verify_commit(repo, left), head).decode().strip()
    elif ".." in spec:
        left, right = spec.split("..", 1)
        base = verify_commit(repo, left)
        head = verify_commit(repo, right or "HEAD")
    else:
        raise MandateError(f"--range needs BASE..HEAD or BASE...HEAD, got '{spec}'")
    return head, diff_changes(repo, base, head)


def split_nul(raw: bytes) -> List[str]:
    return [
        item.decode("utf-8", "surrogateescape") for item in raw.split(b"\0") if item
    ]


def index_files(repo: Path) -> List[str]:
    files: List[str] = []
    for entry in split_nul(git(repo, "ls-files", "-s", "-z")):
        meta, _, path = entry.partition("\t")
        parts = meta.split()
        if (
            len(parts) == LS_META_FIELDS
            and parts[2] == "0"
            and parts[0] in ("100644", "100755")
        ):
            files.append(path)
    return files


def rev_files(repo: Path, rev: str) -> List[str]:
    files: List[str] = []
    for entry in split_nul(git(repo, "ls-tree", "-r", "-z", "--full-tree", rev)):
        meta, _, path = entry.partition("\t")
        parts = meta.split()
        if (
            len(parts) == LS_META_FIELDS
            and parts[1] == "blob"
            and parts[0] in ("100644", "100755")
        ):
            files.append(path)
    return files


def export_index(
    repo: Path,
    paths: Sequence[str],
    dest: Path,
    *,
    env: Optional[Mapping[str, str]] = None,
) -> None:
    """Export exact index blobs without checkout filters or attribute conversions."""
    if not paths:
        return
    objects: Dict[str, str] = {}
    for entry in split_nul(git(repo, "ls-files", "-s", "-z", env=env)):
        meta, _, path = entry.partition("\t")
        parts = meta.split()
        if (
            len(parts) == LS_META_FIELDS
            and parts[2] == "0"
            and parts[0] in ("100644", "100755")
        ):
            objects[path] = parts[1]
    # Object IDs, rather than path expressions, make the batch protocol safe for
    # filenames containing newlines. One Git process per chunk avoids one per file.
    command = ["git", "cat-file", "--batch"]
    for batch in chunks(paths):
        missing = [path for path in batch if path not in objects]
        if missing:
            raise ToolFailure("git", command, f"index file unavailable: {missing[0]!r}")
        payload = b"".join(objects[path].encode("ascii") + b"\n" for path in batch)
        blobs = io.BytesIO(git(repo, "cat-file", "--batch", stdin=payload, env=env))
        for path in batch:
            header = blobs.readline().split()
            if (
                len(header) != 3
                or header[0] != objects[path].encode("ascii")
                or header[1] != b"blob"
                or not header[2].isdigit()
            ):
                raise ToolFailure(
                    "git", command, f"invalid raw blob header for {path!r}"
                )
            size = int(header[2])
            content = blobs.read(size)
            if len(content) != size or blobs.read(1) != b"\n":
                raise ToolFailure("git", command, f"incomplete raw blob for {path!r}")
            # Both scanners can skip non-UTF-8 Python without a failing exit.
            # Validate once for changed scans and census; preserve exact bytes.
            if language_of(path) is Language.PYTHON:
                try:
                    content.decode("utf-8")
                except UnicodeDecodeError as exc:
                    raise ToolFailure(
                        "git",
                        command,
                        f"source {path!r} is not UTF-8; "
                        "convert to UTF-8 before scanning",
                    ) from exc
            exported = dest / path
            exported.parent.mkdir(parents=True, exist_ok=True)
            exported.write_bytes(content)
        if blobs.read():
            raise ToolFailure("git", command, "unexpected trailing raw blob data")


def export_rev(
    repo: Path, rev: str, paths: Sequence[str], dest: Path, scratch: Path
) -> None:
    if not paths:
        return
    env = dict(os.environ)
    env["GIT_INDEX_FILE"] = str(scratch / "mandate.index")
    git(repo, "read-tree", rev, env=env)
    export_index(repo, paths, dest, env=env)


# ------------------------------------------------------------------- path policy


def language_of(path: str) -> Optional[Language]:
    if path.endswith(PY_SUFFIXES):
        return Language.PYTHON
    if path.endswith(RS_SUFFIXES):
        return Language.RUST
    return None


def is_vendored(path: str, declared: Sequence[str]) -> bool:
    """Built-in vendored dirs, plus the snapshot's own `mandate.vendored` list."""
    parts = PurePosixPath(path).parts[:-1]
    if any(part in VENDORED_PARTS or part.startswith("external") for part in parts):
        return True
    return any(path == pre or path.startswith(pre + "/") for pre in declared)


def parse_vendored(raw: str) -> List[str]:
    prefixes: List[str] = []
    for item in raw.split(","):
        prefix = item.strip().strip("/")
        if not item.strip():
            continue
        if not prefix or item.strip().startswith("/") or ".." in prefix.split("/"):
            raise ConfigError(
                f"mandate.vendored entry {item.strip()!r} must be a repo-relative "
                "directory without '..' (comma-separated, e.g. "
                "mandate.vendored=qobi/chumpy,src/cardiac/usgr)"
            )
        prefixes.append(prefix)
    return prefixes


def is_test_path(path: str, language: Language) -> bool:
    pure = PurePosixPath(path)
    parts = set(pure.parts[:-1])
    name = pure.name
    if language is Language.PYTHON:
        return (
            bool(parts & PY_TEST_PARTS)
            or name.startswith("test_")
            or name.endswith("_test.py")
            or name == "conftest.py"
        )
    return (
        bool(parts & RUST_NONPROD_PARTS)
        or name.endswith("_test.rs")
        or name == "tests.rs"
        or name == "build.rs"
    )


def scannable(path: str, declared: Sequence[str]) -> bool:
    return language_of(path) is not None and not is_vendored(path, declared)


# ---------------------------------------------------------------------- config


CONF_CANDIDATES = (".qa-gate.conf", ".git-guard/qa-gate.conf")  # first hit wins
INDEX = ""  # load_policy snapshot: the index (staged content), not a commit


@dataclass(frozen=True)
class Policy:
    """The mandate.* configuration that governs one snapshot of the repo."""

    enabled: bool
    severities: Dict[str, Severity]
    vendored: Tuple[str, ...]
    source: str


def load_policy(repo: Path, snapshot: str) -> Policy:
    """Read the repo's mandate policy from the SAME snapshot as the code.

    ``snapshot`` is a commit SHA, or INDEX for the staged content. The repo layer
    (.qa-gate.conf, else .git-guard/qa-gate.conf) is exported from that snapshot,
    never read from the working tree: otherwise a pushed branch would be judged
    under whatever branch is checked out, and an unstaged edit would decide what a
    commit is held to (git-guard #72 review). The global defaults and the machine
    overlay (qa-gate.conf.local beside qa_gate.sh) apply on top as before, and the
    overlay is named in ``source`` so it is never an invisible input.
    """
    label = "index" if snapshot == INDEX else snapshot[:12]
    spec = ":" if snapshot == INDEX else f"{snapshot}:"
    overlay = QA_GATE.parent / "qa-gate.conf.local"
    with tempfile.TemporaryDirectory(prefix="git-guard-mandate-policy.") as tmp:
        repo_conf = ""
        source = f"{label}, no repo conf"
        for candidate in CONF_CANDIDATES:
            found = run(
                ["git", "cat-file", "blob", spec + candidate], cwd=repo, tool="git"
            )
            if found.returncode == 0:
                exported = Path(tmp) / label / candidate
                exported.parent.mkdir(parents=True, exist_ok=True)
                exported.write_bytes(found.stdout)
                repo_conf = str(exported)
                source = f"{label} {candidate}"
                break
        command = [
            "sh",
            str(QA_GATE),
            "--get-prefix",
            "mandate.",
            "--repo-conf",
            repo_conf,
        ]
        done = run(command, cwd=repo, tool="qa_gate.sh")
    if overlay.is_file():
        source += f" + machine overlay {overlay}"
    if done.returncode != 0:
        raise ConfigError(
            f"qa_gate.sh could not read the mandate.* configuration of {source} "
            f"(malformed conf; its own message is above). {stderr_tail(done.stderr)}"
        )
    values: Dict[str, str] = {}
    for line in done.stdout.decode("utf-8", "replace").splitlines():
        key, sep, value = line.partition("=")
        if sep:
            values[key.strip()] = value.strip()
    enabled_raw = values.pop("mandate.enabled", "") or "on"
    if enabled_raw not in ("on", "off"):
        raise ConfigError(
            f"mandate.enabled={enabled_raw} is not one of: on, off (policy: {source})"
        )
    vendored = tuple(parse_vendored(values.pop("mandate.vendored", "")))
    unknown = sorted(k for k in values if k[len("mandate.") :] not in RULES_BY_KEY)
    if unknown:
        raise ConfigError(
            "qa_gate.sh knows mandate keys this scanner does not: "
            + ", ".join(unknown)
            + ". QA_KNOWN_KEYS and mandate_scan.py RULES have drifted; "
            "reinstall git-guard."
        )
    severities: Dict[str, Severity] = {}
    allowed = ", ".join(s.value for s in Severity)
    for rule in RULES:
        raw = values.get(f"mandate.{rule.key}", "")
        if not raw:
            severities[rule.key] = rule.default
            continue
        try:
            severities[rule.key] = Severity(raw)
        except ValueError as exc:
            raise ConfigError(
                f"mandate.{rule.key}={raw} is not one of: {allowed} (policy: {source})"
            ) from exc
    return Policy(enabled_raw == "on", severities, vendored, source)


# ----------------------------------------------------------------------- tools


def resolve_ruff(repo: Path) -> Optional[str]:
    """Same precedence as qa_gate.sh qa_py_tool: repo venv, active venv, PATH."""
    for candidate in (
        repo / ".venv" / "bin" / "ruff",
        repo / ".venv" / "Scripts" / "ruff.exe",
    ):
        if candidate.is_file() and os.access(str(candidate), os.X_OK):
            return str(candidate)
    venv = os.environ.get("VIRTUAL_ENV", "")
    if venv:
        candidate = Path(venv) / "bin" / "ruff"
        if candidate.is_file() and os.access(str(candidate), os.X_OK):
            return str(candidate)
    return shutil.which("ruff")


def resolve_astgrep() -> Optional[str]:
    """A binary that IS ast-grep. On Linux /usr/bin/sg is util-linux set-group.

    An executable named ``ast-grep`` can only be ast-grep, so a failed version
    probe (non-zero exit, or output that does not name ast-grep) is a broken
    install and a TOOL ERROR, never "not installed" (git-guard #72 review). ``sg``
    is different: on Linux it is usually util-linux set-group, so an ``sg`` that is
    not ast-grep just means ast-grep is absent. A candidate that cannot start at
    all raises from run().
    """
    path = shutil.which("ast-grep")
    if path:
        command = [path, "--version"]
        done = run(command, cwd=Path.cwd(), tool="ast-grep")
        version = done.stdout.decode("utf-8", "replace").strip()
        if done.returncode != 0 or "ast-grep" not in version.lower():
            raise ToolFailure(
                "ast-grep",
                command,
                f"version probe failed (exit {done.returncode}, stdout "
                f"{version[:80]!r}); stderr:\n{stderr_tail(done.stderr)}. An installed "
                "ast-grep that cannot report its version cannot be trusted to scan.",
            )
        return path
    path = shutil.which("sg")
    if path:
        done = run([path, "--version"], cwd=Path.cwd(), tool="sg")
        if done.returncode == 0 and b"ast-grep" in done.stdout.lower():
            return path
        debug(f"{path} is not ast-grep (util-linux set-group?); treating as absent")
    return None


# ------------------------------------------------------------------- scanners


def chunks(items: Sequence[str]) -> Iterable[Sequence[str]]:
    for start in range(0, len(items), CHUNK):
        yield items[start : start + CHUNK]


def run_ruff(
    ruff: str, root: Path, files: Sequence[str], codes: Sequence[str]
) -> List[Finding]:
    found: List[Finding] = []
    for batch in chunks(files):
        command = [
            ruff,
            "check",
            "--isolated",
            "--no-cache",
            "--output-format",
            "json",
            "--select",
            ",".join(codes),
            "--",
            *batch,
        ]
        done = run(command, cwd=root, tool="ruff")
        if done.returncode not in (0, 1):
            raise ToolFailure(
                "ruff",
                command,
                f"exited {done.returncode}; stderr:\n{stderr_tail(done.stderr)}",
            )
        if done.stderr.strip():
            debug(f"ruff stderr: {stderr_tail(done.stderr)}")
        try:
            payload = json.loads(done.stdout.decode("utf-8", "replace") or "null")
        except json.JSONDecodeError as exc:
            raise ToolFailure(
                "ruff", command, f"unparseable JSON output: {exc}"
            ) from exc
        if not isinstance(payload, list):
            raise ToolFailure(
                "ruff", command, "JSON output is not a list of diagnostics"
            )
        if (done.returncode == 1) != bool(payload):
            raise ToolFailure(
                "ruff",
                command,
                f"exit {done.returncode} disagrees with {len(payload)} diagnostic(s); "
                f"stderr:\n{stderr_tail(done.stderr)}",
            )
        for item in payload:
            found.extend(ruff_item(item, root, command))
    return found


def ruff_item(item: object, root: Path, command: Sequence[str]) -> List[Finding]:
    if not isinstance(item, dict):
        raise ToolFailure("ruff", command, f"diagnostic is not an object: {item!r}")
    code = item.get("code")
    name = item.get("name")
    filename = item.get("filename")
    location = item.get("location")
    end = item.get("end_location")
    message = item.get("message")
    if not (
        isinstance(filename, str)
        and isinstance(location, dict)
        and isinstance(end, dict)
        and isinstance(message, str)
    ):
        raise ToolFailure(
            "ruff", command, f"diagnostic lacks filename/location: {item!r}"
        )
    row = location.get("row")
    end_row = end.get("row")
    if not isinstance(row, int) or not isinstance(end_row, int):
        raise ToolFailure("ruff", command, f"diagnostic has no integer rows: {item!r}")
    path = relative_to_root(filename, root)
    if code is None or code == "invalid-syntax" or name == "invalid-syntax":
        if VERSION_SYNTAX_RE.search(message):
            return []  # target-version advice, not a parse failure
        return [
            Finding(
                "python_syntax",
                path,
                row,
                max(row, end_row),
                "ruff:invalid-syntax",
                message,
            )
        ]
    if not isinstance(code, str) or code not in RUFF_TO_KEY:
        raise ToolFailure("ruff", command, f"unexpected rule code {code!r} in output")
    return [
        Finding(
            RUFF_TO_KEY[code], path, row, max(row, end_row), f"ruff:{code}", message
        )
    ]


def relative_to_root(filename: str, root: Path) -> str:
    candidate = Path(filename)
    if candidate.is_absolute():
        try:
            return candidate.resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            return candidate.as_posix()
    return PurePosixPath(
        filename.replace("\\", "/") if os.name == "nt" else filename
    ).as_posix()


def rule_inventory() -> Dict[str, Path]:
    ids: Dict[str, Path] = {}
    if not RULES_ROOT.is_dir():
        raise ToolFailure(
            "ast-grep", [], f"mandate rule directory missing: {RULES_ROOT}"
        )
    for path in sorted(RULES_ROOT.rglob("*.yml")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("id:"):
                ids[line[3:].strip()] = path
                break
    expected = set(SG_TO_KEY)
    missing = sorted(expected - set(ids))
    extra = sorted(set(ids) - expected)
    if missing or extra:
        raise ToolFailure(
            "ast-grep",
            [],
            f"mandate rule inventory under {RULES_ROOT} does not match the RULES table "
            f"(missing: {missing or 'none'}; unexpected: {extra or 'none'})",
        )
    return ids


@dataclass(frozen=True)
class ReceiverBinding:
    """Local static receiver evidence; unknown never means a proven model."""

    kind: str
    methods: FrozenSet[str] = frozenset()
    identity: str = ""
    dependencies: FrozenSet[str] = frozenset()
    is_instance: bool = False


UNKNOWN_RECEIVER = ReceiverBinding("unknown")
MODEL_RECEIVER = ReceiverBinding(
    "model", identity="pydantic-model", dependencies=frozenset({"pydantic-model"})
)
PYDANTIC_MODULE = ReceiverBinding("module")
PYDANTIC_SETTINGS_MODULE = ReceiverBinding("module", identity="pydantic-settings")
LEGACY_MODEL_METHODS = frozenset({"parse_obj", "parse_raw", "parse_file", "from_orm"})
MODEL_BASES = frozenset({"BaseModel", "BaseSettings", "RootModel"})
RECEIVER_TYPE_MEMBERS = frozenset(
    {
        "__class__",
        "__bases__",
        "__mro__",
        "__dict__",
        "__new__",
        "__getattr__",
        "__getattribute__",
    }
)


def receiver_bound_names(node: ast.AST) -> Set[str]:
    """Find bindings in this scope without borrowing nested function locals."""
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        return {node.name}
    names: Set[str] = set()
    if isinstance(node, ast.Lambda):
        for default in [*node.args.defaults, *node.args.kw_defaults]:
            if default is not None:
                names.update(receiver_bound_names(default))
        return names
    if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
        names.add(node.id)
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        names.update(alias.asname or alias.name.split(".")[0] for alias in node.names)
    if isinstance(node, ast.ExceptHandler) and node.name:
        names.add(node.name)
    if type(node).__name__ in {"MatchAs", "MatchStar"}:
        name = getattr(node, "name", None)
        if isinstance(name, str):
            names.add(name)
    for child in ast.iter_child_nodes(node):
        names.update(receiver_bound_names(child))
    return names


def receiver_binding_events(node: ast.AST) -> Iterable[str]:
    """Count actual scope writes, including multiple writes in one statement."""
    children: List[ast.AST]
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        yield node.name
        if isinstance(node, ast.ClassDef):
            children = [*node.decorator_list, *node.bases]
            children.extend(keyword.value for keyword in node.keywords)
        else:
            children = [*node.decorator_list, *node.args.defaults]
            children.extend(d for d in node.args.kw_defaults if d is not None)
    elif isinstance(node, ast.Lambda):
        children = [*node.args.defaults]
        children.extend(d for d in node.args.kw_defaults if d is not None)
    elif isinstance(node, (ast.Import, ast.ImportFrom)):
        yield from (alias.asname or alias.name.split(".")[0] for alias in node.names)
        return
    elif isinstance(node, ast.AnnAssign) and node.value is None:
        children = [node.annotation]
        if not isinstance(node.target, ast.Name):
            children.append(node.target)
    elif isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
        yield node.id
        return
    else:
        if isinstance(node, ast.ExceptHandler) and node.name:
            yield node.name
        if type(node).__name__ in {"MatchAs", "MatchStar", "MatchMapping"}:
            name = getattr(node, "name", None) or getattr(node, "rest", None)
            if isinstance(name, str):
                yield name
        if isinstance(
            node, (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
        ):
            children = [g.iter for g in node.generators]
            children.extend(c for g in node.generators for c in g.ifs)
            values = (
                [node.key, node.value] if isinstance(node, ast.DictComp) else [node.elt]
            )
            children.extend(value for value in values if value is not None)
        else:
            children = list(ast.iter_child_nodes(node))
    for child in children:
        if child is not None:
            yield from receiver_binding_events(child)


def receiver_rebound_names(nodes: Iterable[ast.AST]) -> Set[str]:
    """Rebound captures cannot retain their earlier plain receiver proof."""
    counts: Dict[str, int] = {}
    for node in nodes:
        for name in receiver_binding_events(node):
            counts[name] = counts.get(name, 0) + 1
    return {name for name, count in counts.items() if count > 1}


def receiver_declared_writes(nodes: Sequence[ast.AST]) -> Set[str]:
    """Summarize declared global/nonlocal writes without executing callees."""
    written = {name for node in nodes for name in receiver_binding_events(node)}
    declared: Set[str] = set()
    nested: Set[str] = set()
    pending: List[ast.AST] = list(nodes)
    while pending:
        node = pending.pop()
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            continue
        if isinstance(node, ast.ClassDef):
            nested.update(receiver_declared_writes(node.body))
            continue
        if isinstance(node, (ast.Global, ast.Nonlocal)):
            declared.update(node.names)
        pending.extend(ast.iter_child_nodes(node))
    return (declared & written) | nested


def receiver_immediate_call_names(nodes: Iterable[ast.AST]) -> Set[str]:
    """Find syntactic local calls across eager, not deferred, evaluation."""
    names: Set[str] = set()
    pending = list(nodes)
    while pending:
        node = pending.pop()
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name):
                names.add(node.func.id)
            elif isinstance(node.func, ast.Attribute):
                names.add(node.func.attr)
        children: List[Optional[ast.AST]]
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            args = [*node.args.posonlyargs, *node.args.args, *node.args.kwonlyargs]
            if node.args.vararg:
                args.append(node.args.vararg)
            if node.args.kwarg:
                args.append(node.args.kwarg)
            children = [
                *node.decorator_list,
                *node.args.defaults,
                *node.args.kw_defaults,
            ]
            children.extend([node.returns, *(arg.annotation for arg in args)])
        elif isinstance(node, ast.Lambda):
            children = [*node.args.defaults, *node.args.kw_defaults]
        elif isinstance(node, ast.GeneratorExp):
            children = [node.generators[0].iter] if node.generators else []
        else:
            children = list(ast.iter_child_nodes(node))
        pending.extend(child for child in children if child is not None)
    return names


def receiver_comprehension_body(node: ast.AST) -> List[ast.AST]:
    """Separate per-iteration expressions from the eager first iterator."""
    generators = getattr(node, "generators", ())
    body: List[ast.AST] = [item.iter for item in generators[1:]]
    body.extend(condition for item in generators for condition in item.ifs)
    values = (
        [node.key, node.value]
        if isinstance(node, ast.DictComp)
        else [getattr(node, "elt")]
    )
    body.extend(value for value in values if value is not None)
    return body


def receiver_walrus_names(node: ast.AST) -> Set[str]:
    """Comprehension walrus targets bind outside it, unlike lambda locals."""
    pending = [node]
    names: Set[str] = set()
    while pending:
        child = pending.pop()
        if isinstance(child, ast.NamedExpr):
            names.update(receiver_bound_names(child.target))
        if isinstance(child, ast.Lambda):
            pending.extend(
                d for d in [*child.args.defaults, *child.args.kw_defaults] if d
            )
        else:
            pending.extend(ast.iter_child_nodes(child))
    return names


def receiver_target_name(node: ast.AST) -> Optional[str]:
    """Find a syntactic target root without evaluating an expression."""
    while isinstance(node, (ast.Attribute, ast.Subscript)):
        node = node.value
    return node.id if isinstance(node, ast.Name) else None


def receiver_target_mutation(node: ast.AST) -> Optional[Tuple[str, bool]]:
    """Separate method-namespace/type changes from ordinary field writes."""
    if isinstance(node, ast.Attribute):
        member = node.attr
    elif (
        isinstance(node, ast.Subscript)
        and isinstance(node.value, ast.Attribute)
        and node.value.attr == "__dict__"
    ):
        key = node.slice
        # Python 3.8 wraps subscript expressions in Index; newer ASTs do not.
        if type(key).__name__ == "Index":
            key = getattr(key, "value", key)
        member = (
            key.value
            if isinstance(key, ast.Constant) and isinstance(key.value, str)
            else "__dict__"
        )
    else:
        return None
    if member not in LEGACY_MODEL_METHODS | RECEIVER_TYPE_MEMBERS:
        return None
    name = receiver_target_name(node)
    return (name, member in RECEIVER_TYPE_MEMBERS) if name else None


def receiver_target_leaves(target: ast.AST) -> Iterable[ast.AST]:
    """Expand assignment containers without treating loaded expressions as writes."""
    pending = [target]
    while pending:
        node = pending.pop()
        if isinstance(node, (ast.Tuple, ast.List)):
            pending.extend(node.elts)
        elif isinstance(node, ast.Starred):
            pending.append(node.value)
        else:
            yield node


def receiver_mutated_names(
    nodes: Iterable[ast.AST], include_class_bodies: bool = True
) -> Dict[str, bool]:
    """Find relevant mutations/aliases; the value marks type-proof invalidation."""
    pending = list(nodes)
    aliases: Dict[str, Set[str]] = {}
    mutated: Dict[str, bool] = {}
    while pending:
        node = pending.pop()
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) or (
            isinstance(node, ast.ClassDef) and not include_class_bodies
        ):
            continue
        targets: Sequence[ast.AST] = ()
        if isinstance(node, (ast.Assign, ast.Delete)):
            targets = node.targets
        elif isinstance(
            node, (ast.AugAssign, ast.For, ast.AsyncFor, ast.comprehension)
        ) or (isinstance(node, ast.AnnAssign) and node.value is not None):
            targets = (node.target,)
        elif isinstance(node, ast.withitem) and node.optional_vars is not None:
            targets = (node.optional_vars,)
        for target in targets:
            for leaf in receiver_target_leaves(target):
                mutation = receiver_target_mutation(leaf)
                if mutation:
                    name, changes_type = mutation
                    mutated[name] = mutated.get(name, False) or changes_type
            value = getattr(node, "value", None)
            if isinstance(target, ast.Name) and isinstance(value, ast.Name):
                aliases.setdefault(target.id, set()).add(value.id)
                aliases.setdefault(value.id, set()).add(target.id)
        pending.extend(ast.iter_child_nodes(node))
    while True:
        expanded = dict(mutated)
        for name, changes_type in mutated.items():
            for alias in aliases.get(name, set()):
                expanded[alias] = expanded.get(alias, False) or changes_type
        if expanded == mutated:
            return mutated
        mutated = expanded


class PydanticReceivers(ast.NodeVisitor):
    """Track local class/constructor/annotation evidence without executing imports."""

    def __init__(self, source: str) -> None:
        self.source = source
        self.env: Dict[str, ReceiverBinding] = {}
        self.class_binding: Optional[ReceiverBinding] = None
        self.class_outer: Optional[Dict[str, ReceiverBinding]] = None
        self.class_comprehension_outer: Optional[Dict[str, ReceiverBinding]] = None
        self.has_star_import = False
        self.sensitive_call_names: Dict[str, bool] = {}
        self.binding_call_names: Dict[str, Set[str]] = {}
        self.capture_call_changes_type: Optional[bool] = None
        self.rebound: Set[str] = set()
        self.mutated: Dict[str, bool] = {}
        self.calls: Dict[Tuple[int, int, str], Set[str]] = {}

    def visit_Module(self, node: ast.Module) -> None:
        for child in ast.walk(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                written = receiver_declared_writes(child.body)
                if written:
                    self.binding_call_names.setdefault(child.name, set()).update(
                        written
                    )
                effects = receiver_mutated_names(child.body, include_class_bodies=True)
                if effects:
                    self.sensitive_call_names[child.name] = (
                        self.sensitive_call_names.get(child.name, False)
                        or any(effects.values())
                    )
        self.has_star_import = any(
            isinstance(child, ast.ImportFrom)
            and any(alias.name == "*" for alias in child.names)
            for child in ast.walk(node)
        )
        self.rebound = receiver_rebound_names(node.body)
        self.mutated = receiver_mutated_names(node.body)
        with self.call_effect_scope(node.body):
            self.generic_visit(node)

    def value(self, node: Optional[ast.AST]) -> ReceiverBinding:
        if isinstance(node, ast.Name):
            if node.id == "object" and node.id not in self.env:
                return ReceiverBinding("plain")
            return self.env.get(node.id, UNKNOWN_RECEIVER)
        if isinstance(node, ast.Attribute):
            namespace = self.value(node.value)
            if namespace == PYDANTIC_MODULE:
                if node.attr in MODEL_BASES:
                    return MODEL_RECEIVER
                if node.attr in {"v1", "main"}:
                    return PYDANTIC_MODULE
            elif namespace == PYDANTIC_SETTINGS_MODULE and node.attr == "BaseSettings":
                return MODEL_RECEIVER
        if isinstance(node, ast.Call):
            binding = self.value(node.func)
            if binding.kind in {"model", "plain"} and not binding.is_instance:
                return replace(binding, is_instance=True)
            return UNKNOWN_RECEIVER
        if isinstance(node, ast.Subscript):
            binding = self.value(node.value)
            return binding if binding.kind == "model" else UNKNOWN_RECEIVER
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            try:
                return self.value(ast.parse(node.value, mode="eval").body)
            except SyntaxError:
                return UNKNOWN_RECEIVER
        return UNKNOWN_RECEIVER

    def scoped(
        self, nodes: Iterable[ast.AST], env: Dict[str, ReceiverBinding]
    ) -> Dict[str, ReceiverBinding]:
        nodes = list(nodes)
        previous = self.env
        self.env = env
        with self.call_effect_scope(nodes):
            for node in nodes:
                self.visit(node)
        result = self.env
        self.env = previous
        return result

    def call_effects(self, nodes: Iterable[ast.AST]) -> Tuple[Set[str], Optional[bool]]:
        """Summarize one level of already known local callable effects."""
        nodes = list(nodes)
        written = receiver_declared_writes(nodes)
        changes_type: Optional[bool] = None
        for name in receiver_immediate_call_names(nodes):
            written.update(self.binding_call_names.get(name, set()))
            if name in self.sensitive_call_names:
                changes_type = bool(changes_type) or self.sensitive_call_names[name]
        return written, changes_type

    @contextmanager
    def call_effect_scope(self, nodes: Iterable[ast.AST]) -> Iterator[None]:
        """Keep eager may-effects visible to captures made in this scope."""
        previous_rebound = self.rebound
        previous_changes = self.capture_call_changes_type
        written, changes_type = self.call_effects(nodes)
        self.rebound = self.rebound | written
        if changes_type is not None:
            self.capture_call_changes_type = bool(previous_changes) or changes_type
        try:
            yield
        finally:
            self.rebound = previous_rebound
            self.capture_call_changes_type = previous_changes

    @staticmethod
    def apply_call_effects(
        env: Dict[str, ReceiverBinding], written: Set[str], changes_type: Optional[bool]
    ) -> None:
        """Forfeit affected proofs without confusing rebinding with mutation."""
        for name in written:
            env[name] = UNKNOWN_RECEIVER
        if changes_type is not None:
            for name, value in list(env.items()):
                if value.kind == "plain" or (changes_type and value.kind == "model"):
                    env[name] = UNKNOWN_RECEIVER

    def visit_Import(self, node: ast.Import) -> None:
        for alias in node.names:
            name = alias.asname or alias.name.split(".")[0]
            if alias.name.split(".")[0] == "pydantic":
                self.env[name] = PYDANTIC_MODULE
            elif alias.name == "pydantic_settings":
                self.env[name] = PYDANTIC_SETTINGS_MODULE
            else:
                self.env[name] = UNKNOWN_RECEIVER

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        if any(alias.name == "*" for alias in node.names):
            self.env = {name: UNKNOWN_RECEIVER for name in self.env}
            return
        module = node.module or ""
        pydantic = node.level == 0 and (
            module == "pydantic_settings" or module.split(".")[0] == "pydantic"
        )
        for alias in node.names:
            self.env[alias.asname or alias.name] = (
                MODEL_RECEIVER
                if pydantic and alias.name in MODEL_BASES
                else UNKNOWN_RECEIVER
            )

    def visit_Assign(self, node: ast.Assign) -> None:
        self.visit(node.value)
        binding = self.value(node.value)
        for target in node.targets:
            self.visit(target)
            self.invalidate_target(target)
            for name in receiver_bound_names(target):
                self.env[name] = (
                    binding if isinstance(target, ast.Name) else UNKNOWN_RECEIVER
                )

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if node.value is not None:
            self.visit(node.value)
        binding = self.value(node.value)
        self.visit(node.target)
        self.visit(node.annotation)
        if node.value is None:
            return
        if binding == UNKNOWN_RECEIVER:
            binding = self.value(node.annotation)
        self.invalidate_target(node.target)
        for name in receiver_bound_names(node.target):
            self.env[name] = binding

    def visit_NamedExpr(self, node: ast.NamedExpr) -> None:
        self.visit(node.value)
        for name in receiver_bound_names(node.target):
            self.env[name] = self.value(node.value)

    @staticmethod
    def invalidate_binding(
        env: Dict[str, ReceiverBinding], name: str, changes_type: bool
    ) -> None:
        binding = env.get(name, UNKNOWN_RECEIVER)
        for candidate, value in list(env.items()):
            if value.kind == "model" and not changes_type:
                continue
            if (
                candidate == name
                or (binding.identity and binding.identity in value.dependencies)
                or (
                    binding.kind == "unknown"
                    and (
                        value.kind == "plain"
                        or (changes_type and value.kind == "model")
                    )
                )
            ):
                env[candidate] = UNKNOWN_RECEIVER

    def invalidate_target(self, target: ast.AST) -> None:
        for leaf in receiver_target_leaves(target):
            mutation = receiver_target_mutation(leaf)
            if mutation:
                self.invalidate_binding(self.env, *mutation)

    def stable_binding(
        self, binding: ReceiverBinding, outer: Mapping[str, ReceiverBinding]
    ) -> ReceiverBinding:
        if self.capture_call_changes_type is not None and (
            binding.kind == "plain"
            or (self.capture_call_changes_type and binding.kind == "model")
        ):
            return UNKNOWN_RECEIVER
        for name, changes_type in self.mutated.items():
            if binding.kind == "model" and not changes_type:
                continue
            changed = outer.get(name, UNKNOWN_RECEIVER)
            if changed.kind == "unknown" and (
                binding.kind == "plain" or (changes_type and binding.kind == "model")
            ):
                return UNKNOWN_RECEIVER
            if changed.identity and changed.identity in binding.dependencies:
                return UNKNOWN_RECEIVER
        return binding

    def plain_class_methods(
        self,
        node: ast.ClassDef,
        bases: Sequence[ReceiverBinding],
        outer: Mapping[str, ReceiverBinding],
    ) -> FrozenSet[str]:
        methods = set().union(*(base.methods for base in bases))
        shadowed = set(outer)
        for child in node.body:
            names = receiver_bound_names(child)
            if isinstance(child, ast.AnnAssign) and child.value is None:
                continue
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                plain = all(
                    isinstance(decorator, ast.Name)
                    and decorator.id in {"classmethod", "staticmethod"}
                    and decorator.id not in shadowed
                    for decorator in child.decorator_list
                )
                if plain:
                    methods.add(child.name)
                else:
                    methods.discard(child.name)
            else:
                methods.difference_update(names)
            shadowed.update(names)
        return frozenset(methods)

    @staticmethod
    def plain_initializer_supported(node: ast.ClassDef) -> bool:
        for child in node.body:
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) and (
                child.name == "__init__"
            ):
                if receiver_mutated_names(child.body) or any(
                    isinstance(part, ast.Call) for part in ast.walk(child)
                ):
                    return False
        return True

    @staticmethod
    def class_mutation_barrier(
        env: Dict[str, ReceiverBinding], mutations: Mapping[str, bool]
    ) -> None:
        """Share immediate class effects with enclosing and comprehension views."""
        if mutations:
            for name, value in list(env.items()):
                if value.kind == "plain":
                    env[name] = UNKNOWN_RECEIVER
            for name, changes_type in mutations.items():
                if changes_type:
                    PydanticReceivers.invalidate_binding(env, name, True)

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        for expression in [
            *node.decorator_list,
            *node.bases,
            *(keyword.value for keyword in node.keywords),
        ]:
            self.visit(expression)
        nested = self.class_binding is not None
        body_outer = (
            self.class_comprehension_outer
            if nested and self.class_comprehension_outer is not None
            else self.env
        )
        method_outer = (
            self.class_outer if nested and self.class_outer is not None else self.env
        )
        bases = [self.value(base) for base in node.bases]
        dynamic = any(
            receiver_bound_names(child) & {"__new__", "__getattr__", "__getattribute__"}
            for child in node.body
        )
        methods = self.plain_class_methods(node, bases, body_outer)
        model_base = any(
            base.kind == "model" and not base.is_instance for base in bases
        )
        uncertain_keywords = bool(node.keywords) and (
            not model_base
            or any(keyword.arg in {None, "metaclass"} for keyword in node.keywords)
        )
        if (
            node.decorator_list
            or uncertain_keywords
            or dynamic
            or (not model_base and len(bases) > 1)
            or (not model_base and not self.plain_initializer_supported(node))
        ):
            binding = UNKNOWN_RECEIVER
        elif model_base or all(
            base.kind == "plain" and not base.is_instance for base in bases
        ):
            identity = f"class:{node.lineno}:{node.name}"
            dependencies = frozenset({identity}).union(
                *(base.dependencies for base in bases)
            )
            binding = ReceiverBinding(
                "model" if model_base else "plain",
                methods,
                identity,
                dependencies,
            )
        else:
            binding = UNKNOWN_RECEIVER
        previous = self.class_binding
        previous_outer = self.class_outer
        previous_comprehension_outer = self.class_comprehension_outer
        mutations = receiver_mutated_names(node.body, include_class_bodies=True)
        written, changes_type = self.call_effects(node.body)
        self.class_binding = binding
        self.class_outer = dict(method_outer)
        self.class_comprehension_outer = dict(body_outer)
        self.class_mutation_barrier(self.class_comprehension_outer, mutations)
        self.apply_call_effects(self.class_comprehension_outer, written, changes_type)
        if not nested:
            self.class_outer[node.name] = binding
        self.scoped(node.body, dict(body_outer))
        self.class_binding = previous
        self.class_outer = previous_outer
        self.class_comprehension_outer = previous_comprehension_outer
        self.class_mutation_barrier(self.env, mutations)
        self.apply_call_effects(self.env, written, changes_type)
        if (mutations or changes_type is not None) and binding.kind == "plain":
            binding = UNKNOWN_RECEIVER
        self.env[node.name] = binding

    def deferred_bindings(
        self,
        outer: Optional[Mapping[str, ReceiverBinding]] = None,
    ) -> Tuple[Mapping[str, ReceiverBinding], Dict[str, ReceiverBinding]]:
        if outer is None:
            outer = (
                self.class_outer
                if self.class_binding and self.class_outer is not None
                else self.env
            )
        local = dict(outer)
        if self.has_star_import:
            local = {name: UNKNOWN_RECEIVER for name in local}
        self.apply_call_effects(local, set(), self.capture_call_changes_type)
        for name, changes_type in self.mutated.items():
            self.invalidate_binding(local, name, changes_type)
        for name in self.rebound:
            local[name] = UNKNOWN_RECEIVER
        return outer, local

    def visit_FunctionDef(
        self, node: Union[ast.FunctionDef, ast.AsyncFunctionDef]
    ) -> None:
        args = [*node.args.posonlyargs, *node.args.args, *node.args.kwonlyargs]
        if node.args.vararg:
            args.append(node.args.vararg)
        if node.args.kwarg:
            args.append(node.args.kwarg)
        for expression in [
            *node.decorator_list,
            *node.args.defaults,
            *node.args.kw_defaults,
            node.returns,
            *(argument.annotation for argument in args),
        ]:
            if expression is not None:
                self.visit(expression)
        outer, local = self.deferred_bindings()
        for statement in node.body:
            for name in receiver_bound_names(statement):
                local[name] = UNKNOWN_RECEIVER
        for argument in args:
            annotation = self.stable_binding(self.value(argument.annotation), outer)
            local[argument.arg] = (
                replace(annotation, is_instance=True)
                if annotation.kind in {"model", "plain"}
                else annotation
            )
            if (
                isinstance(argument.annotation, ast.Name)
                and argument.annotation.id in self.rebound
            ):
                local[argument.arg] = UNKNOWN_RECEIVER
        static = any(
            isinstance(d, ast.Name) and d.id == "staticmethod"
            for d in node.decorator_list
        )
        if self.class_binding and args and not static and args[0].annotation is None:
            binding = self.stable_binding(self.class_binding, outer)
            class_method = any(
                isinstance(d, ast.Name)
                and d.id == "classmethod"
                and d.id not in self.env
                for d in node.decorator_list
            )
            local[args[0].arg] = (
                replace(binding, is_instance=not class_method)
                if binding.kind in {"model", "plain"}
                else binding
            )
        previous = self.class_binding
        previous_rebound = self.rebound
        previous_mutated = self.mutated
        self.class_binding = None
        self.rebound = self.rebound | receiver_rebound_names(node.body)
        self.mutated = dict(self.mutated)
        for name, changes_type in receiver_mutated_names(node.body).items():
            self.mutated[name] = self.mutated.get(name, False) or changes_type
        self.scoped(node.body, local)
        self.class_binding = previous
        self.rebound = previous_rebound
        self.mutated = previous_mutated
        self.env[node.name] = UNKNOWN_RECEIVER

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_Lambda(self, node: ast.Lambda) -> None:
        for default in [*node.args.defaults, *node.args.kw_defaults]:
            if default is not None:
                self.visit(default)
        _, local = self.deferred_bindings()
        args = [*node.args.posonlyargs, *node.args.args, *node.args.kwonlyargs]
        if node.args.vararg:
            args.append(node.args.vararg)
        if node.args.kwarg:
            args.append(node.args.kwarg)
        for argument in args:
            local[argument.arg] = UNKNOWN_RECEIVER
        previous_class = self.class_binding
        self.class_binding = None
        self.scoped([node.body], local)
        self.class_binding = previous_class

    def comprehension(self, node: ast.AST, deferred: bool = False) -> None:
        previous = self.env
        previous_class = self.class_binding
        generators = list(getattr(node, "generators", ()))
        if generators:
            self.visit(generators[0].iter)
        body = receiver_comprehension_body(node)
        written, changes_type = self.call_effects(body)
        mutations = receiver_mutated_names([node])
        local = dict(previous)
        with self.call_effect_scope(body):
            local = self.deferred_bindings()[1] if deferred else dict(previous)
            if (
                self.class_binding is not None
                and self.class_comprehension_outer is not None
            ):
                local = dict(self.class_comprehension_outer)
                if deferred:
                    local = self.deferred_bindings(self.class_comprehension_outer)[1]
            self.class_binding = None
            self.apply_call_effects(local, written, changes_type)
            for name, mutates_type in mutations.items():
                self.invalidate_binding(local, name, mutates_type)
            self.env = local
            for index, generator in enumerate(generators):
                if index:
                    self.visit(generator.iter)
                for name in receiver_bound_names(generator.target):
                    local[name] = UNKNOWN_RECEIVER
                for condition in generator.ifs:
                    self.visit(condition)
            if isinstance(node, ast.DictComp):
                for value in (node.key, node.value):
                    if value is not None:
                        self.visit(value)
            else:
                self.visit(getattr(node, "elt"))
        self.env = previous
        self.class_binding = previous_class
        for name in receiver_walrus_names(node):
            before = previous.get(name, UNKNOWN_RECEIVER)
            after = local.get(name, UNKNOWN_RECEIVER)
            self.env[name] = before if before == after else UNKNOWN_RECEIVER
        self.apply_call_effects(self.env, written, changes_type)
        for name, mutates_type in mutations.items():
            self.invalidate_binding(self.env, name, mutates_type)

    visit_ListComp = comprehension
    visit_SetComp = comprehension
    visit_DictComp = comprehension

    def visit_GeneratorExp(self, node: ast.GeneratorExp) -> None:
        self.comprehension(node, deferred=True)

    def visit_Delete(self, node: ast.Delete) -> None:
        for target in node.targets:
            self.visit(target)
            self.invalidate_target(target)
        for name in receiver_bound_names(node):
            self.env[name] = UNKNOWN_RECEIVER

    def visit_AugAssign(self, node: ast.AugAssign) -> None:
        self.visit(node.target)
        self.visit(node.value)
        self.invalidate_target(node.target)
        for name in receiver_bound_names(node.target):
            self.env[name] = UNKNOWN_RECEIVER

    def merge_bindings(
        self, left: Mapping[str, ReceiverBinding], right: Mapping[str, ReceiverBinding]
    ) -> None:
        for name in set(left) | set(right):
            one = left.get(name, UNKNOWN_RECEIVER)
            two = right.get(name, UNKNOWN_RECEIVER)
            if one == two:
                self.env[name] = one
            elif one.kind in {"model", "plain"} and replace(
                one, is_instance=False
            ) == replace(two, is_instance=False):
                self.env[name] = replace(
                    one, is_instance=one.is_instance or two.is_instance
                )
            else:
                self.env[name] = UNKNOWN_RECEIVER

    def visit_If(self, node: ast.If) -> None:
        self.visit(node.test)
        left = self.scoped(node.body, dict(self.env))
        right = self.scoped(node.orelse, dict(self.env))
        self.merge_bindings(left, right)

    def visit_IfExp(self, node: ast.IfExp) -> None:
        self.visit(node.test)
        left = self.scoped([node.body], dict(self.env))
        right = self.scoped([node.orelse], dict(self.env))
        self.merge_bindings(left, right)

    def visit_BoolOp(self, node: ast.BoolOp) -> None:
        self.visit(node.values[0])
        for value in node.values[1:]:
            before = dict(self.env)
            branch = self.scoped([value], dict(before))
            self.merge_bindings(before, branch)

    def visit_Compare(self, node: ast.Compare) -> None:
        self.visit(node.left)
        self.visit(node.comparators[0])
        for value in node.comparators[1:]:
            before = dict(self.env)
            branch = self.scoped([value], dict(before))
            self.merge_bindings(before, branch)

    def conservative_control(self, node: ast.AST) -> None:
        headers = {"iter", "test", "items"}
        for field_name, item in ast.iter_fields(node):
            if field_name in headers:
                nodes = item if isinstance(item, list) else [item]
                for child in nodes:
                    if isinstance(child, ast.AST):
                        self.visit(child)
        base = dict(self.env)
        assigned = receiver_bound_names(node)
        mutations = receiver_mutated_names([node])
        written, call_changes_type = self.call_effects([node])
        self.apply_call_effects(base, written, call_changes_type)
        for name in assigned:
            base[name] = UNKNOWN_RECEIVER
        for name, mutates_type in mutations.items():
            self.invalidate_binding(base, name, mutates_type)
        for field_name, item in ast.iter_fields(node):
            if field_name in headers:
                continue
            if isinstance(item, list):
                nodes = [child for child in item if isinstance(child, ast.AST)]
                self.scoped(nodes, dict(base))
            elif isinstance(item, ast.AST):
                self.scoped([item], dict(base))
        for name in assigned:
            self.env[name] = UNKNOWN_RECEIVER
        for name, changes_type in mutations.items():
            self.invalidate_binding(self.env, name, changes_type)
        self.apply_call_effects(self.env, written, call_changes_type)

    visit_For = conservative_control
    visit_AsyncFor = conservative_control
    visit_While = conservative_control
    visit_With = conservative_control
    visit_AsyncWith = conservative_control
    visit_Try = conservative_control
    visit_TryStar = conservative_control
    visit_Match = conservative_control

    def visit_Call(self, node: ast.Call) -> None:
        function = node.func
        if (
            isinstance(function, ast.Attribute)
            and function.attr in LEGACY_MODEL_METHODS
        ):
            binding = self.value(function.value)
            kind = binding.kind
            if kind == "plain" and function.attr not in binding.methods:
                kind = "unknown"
            segment = ast.get_source_segment(self.source, node)
            if segment is not None:
                key = (node.lineno, getattr(node, "end_lineno", node.lineno), segment)
                self.calls.setdefault(key, set()).add(kind)
        self.generic_visit(node)
        written, changes_type = self.call_effects([node])
        self.apply_call_effects(self.env, written, changes_type)


class PydanticReceiverCache:
    """Bind method candidates to the exact exported source being scanned."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.files: Dict[str, Dict[Tuple[int, int, str], Set[str]]] = {}
        self.issues: Dict[str, str] = {}

    def classify(self, finding: Finding, text: object) -> List[Finding]:
        if isinstance(text, str) and text.lstrip().startswith(
            ("class ", "from ", "import ", "@")
        ):
            return [finding]
        if finding.path not in self.files:
            source = (self.root / finding.path).read_text(encoding="utf-8-sig")
            resolver = PydanticReceivers(source)
            try:
                resolver.visit(ast.parse(source))
            except SyntaxError as error:
                # Ruff owns syntax validity; this records missing type evidence.
                self.issues[finding.path] = (
                    f"receiver analysis unavailable at line {error.lineno}"
                )
            self.files[finding.path] = resolver.calls
        if not isinstance(text, str):
            return [finding]
        normalized = text.replace("\r\n", "\n").replace("\r", "\n")
        key = (finding.line, finding.end_line, normalized)
        kinds = self.files[finding.path].get(key)
        # Non-method namespace/decorator/Config findings retain their strong rule.
        if kinds is None and not re.search(
            r"\.(parse_obj|parse_raw|parse_file|from_orm)\s*\(", normalized
        ):
            return [finding]
        result = [finding] if kinds and "model" in kinds else []
        if not kinds or "unknown" in kinds or "module" in kinds:
            result.append(
                Finding(
                    "pydantic_v1_ambiguous",
                    finding.path,
                    finding.line,
                    finding.end_line,
                    finding.origin,
                    "Possible legacy model method: receiver is unresolved, "
                    "not proven Pydantic"
                    + (
                        "; " + self.issues[finding.path]
                        if finding.path in self.issues
                        else ""
                    ),
                )
            )
        return result


def run_astgrep(
    sg: str, root: Path, scratch: Path, files: Sequence[str], sg_ids: Sequence[str]
) -> List[Finding]:
    inventory = rule_inventory()
    dirs = sorted({inventory[i].parent.as_posix() for i in sg_ids})
    config = scratch / "mandate-sgconfig.yml"
    config.write_text(
        "# generated by mandate_scan.py\nruleDirs:\n"
        + "".join(f"  - {d}\n" for d in dirs),
        encoding="utf-8",
    )
    pattern = "^(" + "|".join(re.escape(i) for i in sorted(sg_ids)) + ")$"
    found: List[Finding] = []
    receivers = PydanticReceiverCache(root)
    for batch in chunks(files):
        command = [
            sg,
            "scan",
            "-c",
            str(config),
            "--filter",
            pattern,
            "--json=stream",
            "--",
            *batch,
        ]
        done = run(command, cwd=root, tool="ast-grep")
        if done.returncode != 0:
            raise ToolFailure(
                "ast-grep",
                command,
                f"exited {done.returncode}; stderr:\n{stderr_tail(done.stderr)}",
            )
        for number, raw in enumerate(
            done.stdout.decode("utf-8", "replace").splitlines(), 1
        ):
            if raw.strip():
                found.extend(astgrep_item(raw, number, command, receivers))
    return found


def astgrep_item(
    raw: str,
    number: int,
    command: Sequence[str],
    receivers: Optional[PydanticReceiverCache] = None,
) -> List[Finding]:
    try:
        item = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ToolFailure(
            "ast-grep", command, f"unparseable JSON at line {number}: {exc}"
        ) from exc
    if not isinstance(item, dict):
        raise ToolFailure("ast-grep", command, f"line {number} is not a JSON object")
    rule_id = item.get("ruleId")
    path = item.get("file")
    span = item.get("range")
    message = item.get("message")
    start = span.get("start") if isinstance(span, dict) else None
    end = span.get("end") if isinstance(span, dict) else None
    line = start.get("line") if isinstance(start, dict) else None
    end_line = end.get("line") if isinstance(end, dict) else None
    if not (
        isinstance(rule_id, str)
        and isinstance(path, str)
        and isinstance(line, int)
        and isinstance(end_line, int)
    ):
        raise ToolFailure(
            "ast-grep", command, f"finding {number} lacks ruleId/file/range"
        )
    if rule_id not in SG_TO_KEY:
        if not rule_id.startswith("mandate-"):
            debug(f"ignoring ast-grep meta finding {rule_id}")
            return []
        raise ToolFailure("ast-grep", command, f"unknown mandate rule id {rule_id!r}")
    # ast-grep ranges are 0-based; everything else here is 1-based.
    finding = Finding(
        SG_TO_KEY[rule_id],
        PurePosixPath(path.replace("\\", "/") if os.name == "nt" else path).as_posix(),
        line + 1,
        end_line + 1,
        f"ast-grep:{rule_id}",
        message if isinstance(message, str) else rule_id,
    )
    if rule_id == "mandate-pydantic-v1" and receivers is not None:
        return receivers.classify(finding, item.get("text"))
    return [finding]


def suppression_codes(enabled: Mapping[str, Severity]) -> Set[str]:
    return {
        code
        for rule in RULES
        if enabled[rule.key] is not Severity.OFF
        for code in rule.ruff_codes
    }


def text_findings(
    root: Path, files: Sequence[str], enabled: Mapping[str, Severity]
) -> List[Finding]:
    """suppression_reason: a mandate suppression on a line with no recorded reason."""
    codes = suppression_codes(enabled)
    found: List[Finding] = []
    for rel in files:
        for number, comment in sorted(comments_by_line(root, rel).items()):
            problem = unjustified_suppression(comment, codes)
            if problem:
                found.append(
                    Finding("suppression_reason", rel, number, number, "text", problem)
                )
    return found


def unjustified_suppression(comment: str, codes: Set[str]) -> str:
    """Why ``comment`` (comment text only, never code or strings) is unjustified."""
    noqa = NOQA_RE.search(comment)
    named = (
        {c.upper() for c in re.split(r"[\s,]+", noqa.group(1)) if c} if noqa else set()
    )
    guards = sorted(named & codes & set(RULES_BY_KEY["suppression_code"].ruff_codes))
    if guards:
        return f"suppression checks cannot suppress themselves: {', '.join(guards)}"
    if REASON_RE.search(comment):
        return ""
    if noqa:
        hit = sorted(named & codes)
        if hit:
            return (
                f"`# noqa: {', '.join(hit)}` suppresses a mandate rule with no reason"
            )
    ignore = SG_IGNORE_RE.search(comment)
    if ignore:
        ids = ignore.group(1)
        if ids is None:
            return (
                "blanket `ast-grep-ignore` suppresses every mandate rule with no reason"
            )
        named = {i.strip() for i in ids.split(",")}
        hit = sorted(named & set(SG_TO_KEY))
        if hit:
            return (
                f"`ast-grep-ignore: {', '.join(hit)}` suppresses a mandate rule "
                "with no reason"
            )
    return ""


# A string literal on one line: "...", '...' (Python) or "..." (Rust).
PY_STRING_RE = re.compile(r"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'")
RUST_STRING_RE = re.compile(r"\"(?:\\.|[^\"\\])*\"")


def comments_by_line(root: Path, rel: str) -> Dict[int, str]:
    """1-based line -> the comment text on that line, and nothing else.

    Suppressions and their reasons are read from comments only: a docstring or a
    message string that merely mentions ``# noqa: BLE001`` must neither suppress a
    finding nor be reported as an unjustified suppression. Python comments come from
    the tokenizer; Rust (and Python that does not tokenize) strip one-line string
    literals and take the text from the comment marker on.
    """
    lines = read_lines(root / rel)
    if language_of(rel) is Language.RUST:
        return marker_comments(lines, "//", RUST_STRING_RE)
    text = "\n".join(lines) + "\n"
    try:
        tokens = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, SyntaxError) as exc:
        debug(f"{rel}: tokenizer failed ({exc}); using the line heuristic")
        return marker_comments(lines, "#", PY_STRING_RE)
    return {t.start[0]: t.string for t in tokens if t.type == tokenize.COMMENT}


def marker_comments(
    lines: Sequence[str], marker: str, strings: "re.Pattern[str]"
) -> Dict[int, str]:
    found: Dict[int, str] = {}
    for number, line in enumerate(lines, 1):
        bare = strings.sub(lambda m: " " * len(m.group(0)), line)
        at = bare.find(marker)
        if at >= 0:
            found[number] = line[at:]
    return found


def read_lines(path: Path) -> List[str]:
    try:
        # Match physical source lines after read_text normalizes CRLF and CR.
        lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
        if lines[-1] == "":
            lines.pop()
        return lines
    except OSError as exc:
        raise ToolFailure(
            "read", [str(path)], f"cannot read exported file: {exc}"
        ) from exc


# ------------------------------------------------------------ suppression filter


def suppressed(
    finding: Finding, lines: Sequence[str], comments: Mapping[int, str]
) -> bool:
    """Our own suppression model, a superset of ast-grep's native one.

    ast-grep 0.39.5 ignores a same-line ``ast-grep-ignore: id  # SAFETY: ...`` that
    0.45.3 honours, so relying on ast-grep alone would make the outcome depend on the
    installed version. A finding is suppressed when the comment on its first line
    names the rule's ruff code in ``# noqa:``, or when ``ast-grep-ignore`` (bare or
    naming one of the rule's ids) is in that comment or on a comment-only line
    directly above it. Only comment text counts, never code or string literals.
    """
    rule = RULES_BY_KEY[finding.key]
    if rule.text_check or finding.key in ("python_syntax", "suppression_code"):
        return False
    current = comments.get(finding.line, "")
    noqa = NOQA_RE.search(current)
    if noqa and rule.ruff_codes:
        named = {c.upper() for c in re.split(r"[\s,]+", noqa.group(1)) if c}
        if named & set(rule.ruff_codes):
            return True
    candidates = [current]
    above = finding.line - 1
    if 1 <= above <= len(lines) and above in comments:
        if lines[above - 1].strip().startswith(("#", "//")):
            candidates.append(comments[above])
    for text in candidates:
        for match in SG_IGNORE_RE.finditer(text):
            ids = match.group(1)
            if ids is None:
                return True
            if {i.strip() for i in ids.split(",")} & set(rule.sg_ids):
                return True
    return False


# --------------------------------------------------------------------- scanning


def scan_tree(
    root: Path,
    scratch: Path,
    files: Sequence[str],
    policy: Policy,
    tools: Tools,
) -> ScanResult:
    """Run every enabled rule over ``files`` (paths relative to ``root``)."""
    enabled = policy.severities
    result = ScanResult()
    active = [r for r in RULES if enabled[r.key] is not Severity.OFF]
    py_files = [f for f in files if language_of(f) is Language.PYTHON]
    rs_files = [f for f in files if language_of(f) is Language.RUST]
    by_lang = {Language.PYTHON: py_files, Language.RUST: rs_files}
    live = [r for r in active if by_lang[r.language]]

    ruff_rules = [r for r in live if Tool.RUFF in r.tools]
    if ruff_rules and tools.ruff is None:
        result.skipped["ruff"] = [r.key for r in ruff_rules]
    elif ruff_rules and tools.ruff is not None:
        # python_syntax has no code of its own: ruff reports a parse failure under
        # any selection, so when it is the only ruff rule left a cheap code is
        # selected and its findings are filtered out below.
        codes = sorted({c for r in ruff_rules for c in r.ruff_codes}) or ["E722"]
        raw = run_ruff(tools.ruff, root, py_files, codes)
        wanted = {r.key for r in ruff_rules}
        result.findings.extend(f for f in raw if f.key in wanted)

    sg_rules = [r for r in live if r.sg_ids]
    if sg_rules and tools.astgrep is None:
        result.skipped["ast-grep"] = [r.key for r in sg_rules]
    elif sg_rules and tools.astgrep is not None:
        sg_ids = [i for r in sg_rules for i in r.sg_ids]
        if py_files and enabled["pydantic_v1_ambiguous"] is not Severity.OFF:
            # Strong rule supplies method-name candidates even when its own
            # policy is off; receiver classification selects the actual rule.
            sg_ids = sorted(set(sg_ids) | {"mandate-pydantic-v1"})
        targets = sorted({f for r in sg_rules for f in by_lang[r.language]})
        result.findings.extend(
            run_astgrep(tools.astgrep, root, scratch, targets, sg_ids)
        )

    if files and any(r.text_check for r in active):
        result.findings.extend(text_findings(root, py_files + rs_files, enabled))

    result.findings = postprocess(
        root,
        [f for f in result.findings if enabled[f.key] is not Severity.OFF],
        policy.vendored,
    )
    return result


def postprocess(
    root: Path, findings: Iterable[Finding], declared: Sequence[str]
) -> List[Finding]:
    """Drop test-exempt and suppressed findings; de-duplicate per rule/file/line."""
    cache: Dict[str, Tuple[List[str], Dict[int, str]]] = {}
    seen: Set[Tuple[str, str, int]] = set()
    kept: List[Finding] = []
    for finding in sorted(findings, key=lambda f: (f.path, f.line, f.key, f.origin)):
        rule = RULES_BY_KEY[finding.key]
        language = language_of(finding.path)
        if language is None or is_vendored(finding.path, declared):
            continue
        if rule.exempt_tests and is_test_path(finding.path, language):
            continue
        if finding.path not in cache:
            cache[finding.path] = (
                read_lines(root / finding.path),
                comments_by_line(root, finding.path),
            )
        if suppressed(finding, *cache[finding.path]):
            continue
        ident = (finding.key, finding.path, finding.line)
        if ident in seen:
            continue
        seen.add(ident)
        kept.append(finding)
    return kept


# ------------------------------------------------------------------- reporting


def debt_hint(finding: Finding) -> str:
    rule = RULES_BY_KEY[finding.key]
    marker = "//" if language_of(finding.path) is Language.RUST else "#"
    if rule.text_check or finding.key == "suppression_code":
        return (
            "a suppression cannot itself be suppressed; add the code / reason as shown."
        )
    if finding.key == "python_syntax":
        return "none: fix the file so the other rules can be evaluated."
    if finding.origin.startswith("ruff:"):
        code = finding.origin.split(":", 1)[1]
        return (
            f"append `  {marker} noqa: {code}  {marker} SAFETY: <why this is correct>` "
            f"to line {finding.line}."
        )
    sg_id = rule.sg_ids[0] if rule.sg_ids else finding.key
    if finding.origin.startswith("ast-grep:"):
        sg_id = finding.origin.split(":", 1)[1]
    return (
        f"append `  {marker} ast-grep-ignore: {sg_id}  {marker} SAFETY: <why this is "
        f"correct>` to line {finding.line}."
    )


def print_finding(finding: Finding, verdict: str, root: Path) -> None:
    rule = RULES_BY_KEY[finding.key]
    lines = read_lines(root / finding.path)
    text = lines[finding.line - 1].strip() if 0 < finding.line <= len(lines) else ""
    say(
        f"git-guard mandate {verdict} [{finding.key}] {rule.policy} "
        f"{finding.path}:{finding.line} ({finding.origin})"
    )
    say(f"    >> {text}")
    say(f"    what: {finding.message}")
    say(f"    why:  {rule.why} [{rule.source}]")
    say(f"    fix:  {rule.fix}")
    say(f"    debt: {debt_hint(finding)}")


def print_skips(skipped: Mapping[str, Sequence[str]]) -> None:
    hints = {"ruff": "uv tool install ruff", "ast-grep": "npm install -g @ast-grep/cli"}
    for tool, keys in skipped.items():
        if keys:
            say(
                f"git-guard mandate WARN: {tool} is not installed, so these rules "
                f"were NOT evaluated: {', '.join(sorted(set(keys)))}. "
                f"Install: {hints.get(tool, tool)}"
            )


def summarize_keys(findings: Sequence[Finding]) -> str:
    counts: Dict[str, int] = {}
    for finding in findings:
        counts[finding.key] = counts.get(finding.key, 0) + 1
    return ", ".join(f"{k} ({n})" for k, n in sorted(counts.items()))


# ------------------------------------------------------------------ changed mode


def changed_mode(
    repo: Path,
    changes: Mapping[str, Set[int]],
    export: str,
    policy: Policy,
    tools: Tools,
) -> Outcome:
    enabled = policy.severities
    # Match census destination modes before exporting: a symlink is a Git blob,
    # but its target text is not Python/Rust source. Type changes into regular
    # files still enter the same scan as added/modified files.
    regular = set(index_files(repo) if export == "index" else rev_files(repo, export))
    files = sorted(p for p in changes if p in regular and scannable(p, policy.vendored))
    if not files:
        debug("no Python/Rust files changed")
        return Outcome.PASSED
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="git-guard-mandate.") as tmp:
        scratch = Path(tmp)
        root = scratch / "tree"
        root.mkdir()
        if export == "index":
            export_index(repo, files, root)
        else:
            export_rev(repo, export, files, root, scratch)
        present = [
            f for f in files if (root / f).is_file() and not (root / f).is_symlink()
        ]
        for f in present:
            try:
                raw = (root / f).read_bytes()
            except OSError as exc:
                raise ToolFailure(
                    "read", [f], f"cannot read exported file: {exc}"
                ) from exc
            if b"\r" in raw.replace(b"\r\n", b""):
                raise ToolFailure(
                    "git",
                    [f],
                    "lone CR line endings make changed-line coordinates ambiguous; "
                    "convert to LF or CRLF before scanning",
                )
        result = scan_tree(root, scratch, present, policy, tools)
        blocking: List[Finding] = []
        warnings: List[Finding] = []
        for finding in result.findings:
            severity = enabled[finding.key]
            on_changed = bool(
                set(range(finding.line, finding.end_line + 1))
                & changes.get(finding.path, set())
            )
            if severity is Severity.BLOCK or (
                severity is Severity.CHANGED and on_changed
            ):
                blocking.append(finding)
            elif severity is Severity.WARN and on_changed:
                warnings.append(finding)
        for finding in warnings:
            print_finding(finding, "WARN", root)
        for finding in blocking:
            print_finding(finding, "BLOCK", root)
    print_skips(result.skipped)
    elapsed = time.monotonic() - started
    scope = f"{len(present)} file(s), {elapsed:.1f}s, policy: {policy.source}"
    if blocking:
        say(
            f"git-guard mandate: BLOCKED — {len(blocking)} finding(s) on {scope}: "
            f"{summarize_keys(blocking)}. Fix each as shown, or record justified "
            "debt on the "
            "line with the noqa / ast-grep-ignore form plus `SAFETY: <reason>`."
        )
        return Outcome.BLOCKED
    note = f", {len(warnings)} warning(s)" if warnings else ""
    skipped = sum(len(v) for v in result.skipped.values())
    tail = f"; {skipped} rule(s) NOT evaluated (see WARN above)" if skipped else ""
    say(f"git-guard mandate: PASSED — 0 blocking findings on {scope}{note}{tail}.")
    return Outcome.PASSED


# --------------------------------------------------------------- whole-tree mode


@dataclass
class Census:
    measured_at: str
    files: int
    counts: Dict[str, Dict[str, int]]
    skipped: Dict[str, List[str]]


def census(repo: Path, rev: Optional[str], policy: Policy, tools: Tools) -> Census:
    enabled = policy.severities
    if rev is None:
        files = [f for f in index_files(repo) if scannable(f, policy.vendored)]
        measured = f"index@{head_sha(repo)}"
    else:
        sha = verify_commit(repo, rev)
        files = [f for f in rev_files(repo, sha) if scannable(f, policy.vendored)]
        measured = sha
    with tempfile.TemporaryDirectory(prefix="git-guard-mandate.") as tmp:
        scratch = Path(tmp)
        root = scratch / "tree"
        root.mkdir()
        if rev is None:
            export_index(repo, files, root)
        else:
            export_rev(repo, measured, files, root, scratch)
        present = [
            f for f in files if (root / f).is_file() and not (root / f).is_symlink()
        ]
        result = scan_tree(root, scratch, present, policy, tools)
    counts: Dict[str, Dict[str, int]] = {
        r.key: {} for r in RULES if enabled[r.key] is not Severity.OFF
    }
    for finding in result.findings:
        per_file = counts.setdefault(finding.key, {})
        per_file[finding.path] = per_file.get(finding.path, 0) + 1
    return Census(measured, len(present), counts, result.skipped)


def enforced_keys(enabled: Mapping[str, Severity]) -> List[str]:
    return [
        r.key for r in RULES if enabled[r.key] in (Severity.CHANGED, Severity.BLOCK)
    ]


def all_mode(repo: Path, rev: Optional[str], policy: Policy, tools: Tools) -> Outcome:
    enabled = policy.severities
    result = census(repo, rev, policy, tools)
    payload = {
        "version": BASELINE_VERSION,
        "policy_revision": POLICY_REVISION,
        "canonical_policy": CANONICAL_POLICY,
        "measured_at_commit": result.measured_at,
        "policy": policy.source,
        "scanned_files": result.files,
        "severity": {r.key: enabled[r.key].value for r in RULES},
        "totals": {k: sum(v.values()) for k, v in sorted(result.counts.items())},
        "skipped": result.skipped,
        "rules": {
            k: dict(sorted(v.items())) for k, v in sorted(result.counts.items()) if v
        },
    }
    print(json.dumps(payload, indent=2, sort_keys=False))
    print_skips(result.skipped)
    return Outcome.PASSED


def write_baseline(
    repo: Path,
    target: Path,
    rev: Optional[str],
    policy: Policy,
    tools: Tools,
) -> Outcome:
    enabled = policy.severities
    result = census(repo, rev, policy, tools)
    unevaluated = sorted(
        {k for keys in result.skipped.values() for k in keys}
        & set(enforced_keys(enabled))
    )
    if unevaluated:
        print_skips(result.skipped)
        raise MandateError(
            "refusing to write a baseline with unevaluated rules "
            f"({', '.join(unevaluated)}): their ceilings would be recorded as zero. "
            "Install the missing scanner and re-run --write-baseline."
        )
    rules: Dict[str, Dict[str, int]] = {
        k: dict(sorted(result.counts.get(k, {}).items()))
        for k in sorted(enforced_keys(enabled))
    }
    payload: Dict[str, object] = {
        "version": BASELINE_VERSION,
        "policy_revision": POLICY_REVISION,
        "measured_at_commit": result.measured_at,
        "rules": rules,
    }
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    total = sum(sum(v.values()) for v in rules.values())
    say(
        f"git-guard mandate: wrote {target} — {total} recorded finding(s) across "
        f"{len(rules)} enforced rule(s), measured at {result.measured_at}. "
        "Review the diff and commit it with the change it accounts for."
    )
    return Outcome.PASSED


class BaselineProblem(Enum):
    MALFORMED = "MALFORMED"
    REGRESSION = "REGRESSION"
    UNRATCHETED = "UNRATCHETED"
    UNDECLARED = "UNDECLARED"
    STALE = "STALE"


def parse_baseline(
    text: str, origin: str
) -> Tuple[Dict[str, Dict[str, int]], List[str]]:
    """Validate the baseline document. Returns (rules, problems)."""
    problems: List[str] = []
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as exc:
        return {}, [f"{origin} is not valid JSON: {exc}"]
    if not isinstance(doc, dict):
        return {}, [f"{origin}: top level must be a JSON object"]
    allowed = {"version", "policy_revision", "measured_at_commit", "rules", "_comment"}
    extra = sorted(set(doc) - allowed)
    if extra:
        problems.append(
            f"{origin}: unknown top-level key(s) {extra}; allowed: {sorted(allowed)}"
        )
    if doc.get("version") != BASELINE_VERSION or isinstance(doc.get("version"), bool):
        problems.append(
            f'{origin}: "version" must be {BASELINE_VERSION}, '
            f"got {doc.get('version')!r}"
        )
    for key in ("policy_revision", "measured_at_commit"):
        if not isinstance(doc.get(key), str) or not doc.get(key):
            problems.append(f'{origin}: "{key}" must be a non-empty string')
    rules = doc.get("rules")
    if not isinstance(rules, dict):
        problems.append(
            f'{origin}: "rules" must be an object of {{rule: {{path: count}}}}'
        )
        return {}, problems
    parsed: Dict[str, Dict[str, int]] = {}
    for rule_key, per_file in rules.items():
        if not isinstance(per_file, dict):
            problems.append(
                f"{origin}: rules.{rule_key} must be an object of {{path: count}}"
            )
            continue
        parsed[rule_key] = {}
        for path, count in per_file.items():
            if isinstance(count, bool) or not isinstance(count, int) or count < 1:
                problems.append(
                    f'{origin}: rules.{rule_key}["{path}"] = {count!r}; counts are '
                    "positive integers (delete the entry instead of writing 0)"
                )
                continue
            parsed[rule_key][path] = count
    if problems:
        return {}, problems
    if doc.get("policy_revision") != POLICY_REVISION:
        say(
            f"git-guard mandate NOTE: {origin} was written under policy "
            f"{doc.get('policy_revision')!r}; this git-guard enforces "
            f"{POLICY_REVISION!r}. Counts are compared as-is."
        )
    return parsed, []


def evaluate_baseline(
    counts: Mapping[str, Mapping[str, int]],
    ceilings: Mapping[str, Mapping[str, int]],
    enforced: Sequence[str],
    origin: str,
) -> List[Tuple[BaselineProblem, str]]:
    problems: List[Tuple[BaselineProblem, str]] = []
    enforced_set = set(enforced)
    for key in sorted(set(ceilings) - enforced_set):
        state = (
            "unknown to this git-guard"
            if key not in RULES_BY_KEY
            else "not enforced (its severity is off or warn)"
        )
        problems.append(
            (
                BaselineProblem.STALE,
                f'rules.{key} is {state}. Delete "{key}" from {origin}.',
            )
        )
    for key in enforced:
        actual = counts.get(key, {})
        ceiling = ceilings.get(key)
        if ceiling is None:
            if actual:
                total = sum(actual.values())
                problems.append(
                    (
                        BaselineProblem.UNDECLARED,
                        f"{key}: {total} finding(s) but no rules.{key} entry in "
                        f"{origin}. Fix them, or declare the backlog deliberately "
                        "(--write-baseline) so a reviewer sees it.",
                    )
                )
            continue
        for path in sorted(set(actual) | set(ceiling)):
            have = actual.get(path, 0)
            limit = ceiling.get(path, 0)
            if have > limit:
                problems.append(
                    (
                        BaselineProblem.REGRESSION,
                        f"{key} {path}: {have} finding(s), ceiling {limit} "
                        f"(+{have - limit}). Fix the new finding (list it: "
                        "mandate_scan.sh --range <upstream>..HEAD) or raise "
                        f'rules.{key}["{path}"] to {have} in the same diff, with '
                        "the reason in the commit message.",
                    )
                )
            elif have < limit:
                edit = (
                    f'set rules.{key}["{path}"] to {have}'
                    if have
                    else f'delete rules.{key}["{path}"]'
                )
                problems.append(
                    (
                        BaselineProblem.UNRATCHETED,
                        f"{key} {path}: {have} finding(s), ceiling {limit}. "
                        f"Ratchet it: in {origin}, {edit} (or re-run "
                        "--write-baseline). If many entries report this at once, "
                        "suspect the scan, not the tree.",
                    )
                )
    return problems


def check_baseline(
    repo: Path,
    rev: str,
    baseline_file: Optional[Path],
    policy: Policy,
    tools: Tools,
) -> Outcome:
    enabled = policy.severities
    sha = verify_commit(repo, rev)
    if baseline_file is not None:
        origin = str(baseline_file)
        try:
            text = baseline_file.read_text(encoding="utf-8")
        except OSError as exc:
            raise MandateError(f"cannot read baseline {baseline_file}: {exc}") from exc
    else:
        origin = f"{BASELINE_RELPATH} at {sha[:12]}"
        done = run(["git", "show", f"{sha}:{BASELINE_RELPATH}"], cwd=repo, tool="git")
        if done.returncode != 0:
            say(
                f"git-guard mandate: no {BASELINE_RELPATH} in {sha[:12]}; no debt "
                "register to check (changed-line enforcement still applies at commit "
                "time)."
            )
            return Outcome.PASSED
        text = done.stdout.decode("utf-8", "replace")
    ceilings, malformed = parse_baseline(text, origin)
    if malformed:
        for problem in malformed:
            say(f"git-guard mandate BLOCK MALFORMED {problem}")
        say(
            f"git-guard mandate: BLOCKED — the debt register {origin} is malformed, "
            "so the ratchet cannot be evaluated. Fix the file (schema: "
            'docs/QA_TOOLING.md "Quality mandate") or regenerate it with '
            "--write-baseline."
        )
        return Outcome.BLOCKED
    result = census(repo, sha, policy, tools)
    unevaluated = {k for keys in result.skipped.values() for k in keys}
    enforced = [k for k in enforced_keys(enabled) if k not in unevaluated]
    print_skips(result.skipped)
    # These two syntax heuristics used to block account-wide. Their historical
    # ceilings must not re-create that veto after the effective policy is WARN.
    # Schema validation above and every explicitly enforced ratchet stay intact.
    legacy_advisories = {
        key
        for key in ("except_sentinel", "str_enum_param")
        if key in ceilings and enabled[key] is Severity.WARN
    }
    for key in sorted(legacy_advisories):
        say(
            f"git-guard mandate WARN legacy baseline [{key}]: its historical "
            "ceilings are advisory under the effective warn policy."
        )
    problems = evaluate_baseline(
        result.counts,
        {
            k: v
            for k, v in ceilings.items()
            if k not in unevaluated and k not in legacy_advisories
        },
        enforced,
        origin,
    )
    for kind, text_line in problems:
        say(f"git-guard mandate BLOCK {kind.value} {text_line}")
    total = sum(sum(v.values()) for k, v in result.counts.items() if k in enforced)
    if problems:
        kinds = sorted({k.value for k, _ in problems})
        say(
            f"git-guard mandate: BLOCKED — debt register check failed at {sha[:12]} "
            f"({len(problems)} problem(s): {', '.join(kinds)}; {total} finding(s) "
            f"counted over {result.files} file(s); policy: {policy.source})."
        )
        return Outcome.BLOCKED
    say(
        f"git-guard mandate: PASSED — debt register holds at {sha[:12]} ({total} "
        f"recorded finding(s) over {result.files} file(s); policy: "
        f"{policy.source})."
    )
    return Outcome.PASSED


def new_register_commits(repo: Path, local_sha: str, remote_sha: str) -> List[str]:
    """Every commit a ref update introduces, including source-only changes.

    An intermediate commit with a regressed or malformed register must not slip
    through because the tip's register is fine (git-guard #72 review, P1).
    """
    if remote_sha == ZERO_SHA:
        scope = ["--not", "--remotes"]  # a new ref: everything no remote has
    else:
        remote = run(
            ["git", "cat-file", "-e", f"{remote_sha}^{{commit}}"],
            cwd=repo,
            tool="git",
        )
        # A force push can replace a remote commit never fetched locally.
        # Use the new-ref boundary when that commit is unavailable: keep local
        # intermediate registers, without rechecking known published history.
        scope = (
            ["--not", remote_sha] if remote.returncode == 0 else ["--not", "--remotes"]
        )
    command = ["git", "rev-list", "--full-history", local_sha, *scope]
    listed = run(
        command,
        cwd=repo,
        tool="git",
    )
    if listed.returncode != 0:
        raise ToolFailure("git", command, "cannot enumerate introduced commits")
    return [local_sha] + [c for c in listed.stdout.decode().split() if c != local_sha]


def pushed_baseline_shas(repo: Path, ref_lines: str) -> List[str]:
    """Pushed commits (from a pre-push ref list) that carry a debt register."""
    shas: List[str] = []
    for line in ref_lines.splitlines():
        parts = line.split()
        if len(parts) != PRE_PUSH_FIELDS:
            continue
        local_ref, local_sha, remote_sha = parts[0], parts[1], parts[3]
        if local_sha == ZERO_SHA or local_ref.startswith("refs/tags/"):
            continue
        for sha in new_register_commits(repo, local_sha, remote_sha):
            if sha in shas:
                continue
            has = run(
                ["git", "cat-file", "-e", f"{sha}:{BASELINE_RELPATH}"],
                cwd=repo,
                tool="git",
            )
            if has.returncode == 0:
                shas.append(sha)
            else:
                debug(f"{sha[:12]} carries no {BASELINE_RELPATH}")
    return shas


def pre_push(repo: Path, shas: Sequence[str]) -> Outcome:
    """Check each pushed commit's register under that commit's own policy."""
    worst = Outcome.PASSED
    tools: Optional[Tools] = None
    for sha in shas:
        policy = load_policy(repo, sha)
        if not policy.enabled:
            say(
                f"git-guard mandate: mandate.enabled=off in {policy.source}; the "
                f"debt register of {sha[:12]} is not checked."
            )
            continue
        tools = tools or resolve_tools(repo)
        worst = max(worst, check_baseline(repo, sha, None, policy, tools))
    return worst


def resolve_tools(repo: Path) -> Tools:
    tools = Tools(ruff=resolve_ruff(repo), astgrep=resolve_astgrep())
    debug(f"ruff={tools.ruff} ast-grep={tools.astgrep} rules={RULES_ROOT}")
    return tools


# ------------------------------------------------------------------------- main


def list_rules() -> None:
    for rule in RULES:
        backends = [f"ruff:{c}" for c in rule.ruff_codes] + [
            f"ast-grep:{i}" for i in rule.sg_ids
        ]
        if rule.text_check:
            backends.append("text")
        if rule.key == "python_syntax":
            backends.append("ruff:invalid-syntax")
        print(
            f"{rule.key}\t{rule.default.value}\t{rule.policy}\t{rule.language.value}\t"
            f"{'tests-exempt' if rule.exempt_tests else 'tests-included'}\t"
            f"{','.join(backends)}"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mandate_scan.sh",
        description='git-guard quality mandate (docs/QA_TOOLING.md "Quality mandate").',
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--staged", action="store_true", help="changed lines of the index"
    )
    mode.add_argument(
        "--range", metavar="BASE..HEAD", help="changed lines of a commit range"
    )
    mode.add_argument("--all", action="store_true", help="whole-tree counts as JSON")
    mode.add_argument(
        "--write-baseline", action="store_true", help="write the debt register"
    )
    mode.add_argument(
        "--check-baseline", action="store_true", help="enforce the debt register"
    )
    mode.add_argument(
        "--pre-push", action="store_true", help="pre-push ref list on stdin"
    )
    mode.add_argument("--list-rules", action="store_true", help="print the rule table")
    parser.add_argument(
        "--rev",
        help="commit to count (--all/--write-baseline: default the "
        "index; --check-baseline: default HEAD)",
    )
    parser.add_argument(
        "--baseline", type=Path, help=f"baseline file (default {BASELINE_RELPATH})"
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.list_rules:
        list_rules()
        return Outcome.PASSED
    try:
        repo = repo_root(Path.cwd())
        pushed: List[str] = []
        if args.pre_push:
            # Nothing to check -> touch nothing (no config read, no tool probe):
            # a repo without a debt register must push exactly as before.
            pushed = pushed_baseline_shas(repo, sys.stdin.read())
            if not pushed:
                return Outcome.PASSED
        if args.pre_push:
            return pre_push(repo, pushed)
        # Policy comes from the snapshot being scanned: the index for staged
        # content and index-based counts, otherwise the named commit.
        if args.staged:
            snapshot, changes, export = INDEX, staged_changes(repo), "index"
        elif args.range:
            head, changes = range_changes(repo, args.range)
            snapshot, export = head, head
        elif args.check_baseline:
            snapshot = verify_commit(repo, args.rev or "HEAD")
        else:
            snapshot = INDEX if args.rev is None else verify_commit(repo, args.rev)
        policy = load_policy(repo, snapshot)
        debug(f"policy: {policy.source}")
        if not policy.enabled:
            debug("mandate.enabled=off")
            return Outcome.PASSED
        tools = resolve_tools(repo)
        if args.staged or args.range:
            return changed_mode(repo, changes, export, policy, tools)
        if args.all:
            return all_mode(repo, args.rev, policy, tools)
        if args.write_baseline:
            target = args.baseline or repo / BASELINE_RELPATH
            return write_baseline(repo, target, args.rev, policy, tools)
        return check_baseline(repo, snapshot, args.baseline, policy, tools)
    except ToolFailure as exc:
        say(f"git-guard mandate TOOL ERROR [{exc.tool}]: {exc.detail}")
        if exc.command:
            shown = exc.command[:COMMAND_ECHO_ARGS]
            more = " ..." if len(exc.command) > COMMAND_ECHO_ARGS else ""
            say(f"    command: {' '.join(shown)}{more}")
        say(
            "git-guard mandate: TOOL ERROR — the quality mandate could not be "
            "evaluated, so the result is refused (fail closed); this is NOT a clean "
            "scan. Fix the tool or its configuration and retry."
        )
        return Outcome.TOOL_ERROR
    except MandateError as exc:
        say(f"git-guard mandate TOOL ERROR [config]: {exc}")
        say(
            "git-guard mandate: TOOL ERROR — the quality mandate could not be "
            "evaluated, so the result is refused (fail closed)."
        )
        return Outcome.TOOL_ERROR


if __name__ == "__main__":
    sys.exit(int(main()))
