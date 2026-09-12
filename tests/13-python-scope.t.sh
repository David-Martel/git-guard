#!/bin/sh
# Category 13 — staged-file type checks honor pyproject project scope.
# Sourced by run.sh; helpers from lib.sh.
# shellcheck shell=sh

t_case_python_scope() {
  t_begin "13 Python type gates honor configured project scope"
  if ! gg_has_python; then
    t_skip "Python absent — TOML scope parser not exercised"
    return 0
  fi

  r="$(gg_mktemp_repo)"
  mkdir -p "$r/scripts" "$r/src" "$r/.venv/bin"
  printf 'value: int = 1\n' > "$r/scripts/typed.py"
  printf 'import missing_ros_runtime\n' > "$r/src/ros_node.py"
  {
    printf '[tool.mypy]\n'
    printf 'files = ["scripts/typed.py"]\n'
    printf '[tool.basedpyright]\n'
    printf 'include = ["scripts"]\n'
  } > "$r/pyproject.toml"
  {
    printf 'python.ruff_check=off\n'
    printf 'python.ruff_format=off\n'
    printf 'astgrep=off\n'
  } > "$r/.qa-gate.conf"
  ( cd "$r" && git add scripts/typed.py src/ros_node.py pyproject.toml .qa-gate.conf )

  scope_log="$(gg_tmp_log)"
  export GG_TYPE_SCOPE_LOG="$scope_log"
  for checker in mypy basedpyright; do
    {
      printf '#!/bin/sh\n'
      # shellcheck disable=SC2016  # write literal runtime variables into the fixture script
      printf 'printf "%%s:%%s\\n" "%s" "$*" >> "$GG_TYPE_SCOPE_LOG"\n' "$checker"
      printf 'exit "${GG_TYPE_SCOPE_RC:-0}"\n'
    } > "$r/.venv/bin/$checker"
    chmod +x "$r/.venv/bin/$checker"
  done

  gate_log="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$gate_log"; rc=$?
  t_expect_rc 0 "$rc" "configured type scopes remain non-blocking and runnable"
  if grep -qx 'mypy:--ignore-missing-imports --no-error-summary scripts/typed.py' "$scope_log"; then
    t_ok "mypy receives only its configured file"
  else
    t_fail "mypy bypassed or lost its configured file scope"
  fi
  if grep -qx 'basedpyright:scripts/typed.py' "$scope_log"; then
    t_ok "basedpyright receives only its configured include tree"
  else
    t_fail "basedpyright bypassed or lost its configured include scope"
  fi
  if grep -q 'src/ros_node.py' "$scope_log"; then
    t_fail "excluded ROS file leaked into a staged-file type invocation"
  else
    t_ok "out-of-scope ROS file is not type-checked by the account-wide gate"
  fi

  # Valid comma-separated mypy strings must still reach a blocking checker.
  printf '[tool.mypy]\nfiles = "scripts, src"\n' > "$r/pyproject.toml"
  printf 'python.mypy=block\npython.basedpyright=off\n' >> "$r/.qa-gate.conf"
  : > "$scope_log"
  GG_TYPE_SCOPE_RC=1 gg_run_gate_log "$r" "$gate_log"; rc=$?
  t_expect_rc 1 "$rc" "comma-separated mypy scope preserves blocking type failures"
  grep -q 'mypy:.*scripts/typed.py.*src/ros_node.py' "$scope_log"
  t_assert $? "comma-separated mypy scope includes both declared trees"

  # Absent include means the project root, then exclusions still apply.
  printf '[tool.basedpyright]\nexclude = ["src"]\n' > "$r/pyproject.toml"
  printf 'python.mypy=off\npython.basedpyright=block\n' >> "$r/.qa-gate.conf"
  : > "$scope_log"
  GG_TYPE_SCOPE_RC=1 gg_run_gate_log "$r" "$gate_log"; rc=$?
  t_expect_rc 1 "$rc" "exclude-only basedpyright still enforces admitted files"
  grep -qx 'basedpyright:scripts/typed.py' "$scope_log"
  t_assert $? "exclude-only basedpyright removes the excluded tree"

  # Reproduce a pre-3.11 interpreter without depending on the host version.
  # Keep a parser alias for the tomli stand-in before hiding tomllib imports.
  mkdir -p "$r/parser-fixture"
  cat > "$r/parser-fixture/sitecustomize.py" <<'PY'
import builtins
import pathlib
import sys

fixture_dir = str(pathlib.Path(__file__).parent)
original_path = sys.path[:]
sys.path = [entry for entry in sys.path if pathlib.Path(entry).resolve() != pathlib.Path(fixture_dir).resolve()]
try:
    import tomllib as parser
except ImportError:
    import tomli as parser
sys.path = original_path
sys.modules.pop("tomli", None)
sys.modules["_gg_test_parser"] = parser
original_import = builtins.__import__


def fixture_import(name, *args, **kwargs):
    if name == "tomllib" or (name == "tomli" and "GG_TEST_NO_PARSER" in __import__("os").environ):
        raise ImportError("parser hidden by compatibility fixture")
    return original_import(name, *args, **kwargs)


builtins.__import__ = fixture_import
PY
  printf 'from _gg_test_parser import load, TOMLDecodeError\n' > "$r/parser-fixture/tomli.py"
  : > "$scope_log"
  PYTHONPATH="$r/parser-fixture" GG_TYPE_SCOPE_RC=1 gg_run_gate_log "$r" "$gate_log"; rc=$?
  t_expect_rc 1 "$rc" "tomli fallback preserves blocking checker failures"
  grep -qx 'basedpyright:scripts/typed.py' "$scope_log"
  t_assert $? "tomli fallback runs the checker with filtered scope"

  # Missing parsers and invalid TOML must never turn configured block into warn.
  for checker in mypy basedpyright; do
    printf 'python.mypy=off\npython.basedpyright=off\npython.%s=block\n' "$checker" >> "$r/.qa-gate.conf"
    : > "$scope_log"
    PYTHONPATH="$r/parser-fixture" GG_TEST_NO_PARSER=1 gg_run_gate_log "$r" "$gate_log"; rc=$?
    t_expect_rc 1 "$rc" "$checker blocks if neither TOML parser is available"
    grep -q 'needs Python 3.11+ or tomli' "$gate_log"
    t_assert $? "$checker reports the missing parser remedy"
  done
  printf '[invalid TOML\n' > "$r/pyproject.toml"
  gg_run_gate_log "$r" "$gate_log"; rc=$?
  t_expect_rc 1 "$rc" "malformed TOML cannot silently disable a blocking checker"

  unset GG_TYPE_SCOPE_LOG
  rm -f "$scope_log" "$gate_log"
  gg_rmrepo "$r"
}
