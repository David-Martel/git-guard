#!/bin/sh
# Category 30 — the scoped mypy/basedpyright file list and .qa-gate.conf
# values survive CRLF line endings.
#
# Behaviour protected: with two or more staged Python files inside a checker's
# pyproject scope, each path reaches mypy exactly as staged, with no trailing
# carriage return, even when the interpreter's stdout writes `\r\n` (native
# Windows Python in text mode) and the repo's .qa-gate.conf has CRLF line
# endings. Both branches of the scope helper are covered: a [tool.mypy] section
# with `files`, and a pyproject without one (the pass-through branch).
#
# What a failure means: every path but the last arrives as `src/a.py\r`, mypy
# cannot open it, and a gate set to `python.mypy=block` refuses every commit
# that stages two or more Python files (issue #52). The CRLF .qa-gate.conf
# assertions are regression guards: the parser's [:space:] trims already
# removed the CR before #52, and the explicit strip keeps that from depending
# on a side effect.
#
# How the bug is simulated portably, once per defence layer:
#   * a sitecustomize.py on PYTHONPATH sets the interpreter's stdout to
#     newline="\r\n", which is what Windows text-mode stdout does natively; the
#     embedded script's own reconfigure(newline="\n") must win over it;
#   * a `python`/`python3` shim on PATH rewrites the interpreter's output to
#     CRLF after the fact, which no in-script setting can undo; the shell-side
#     `tr -d` in qa_python_scoped_files must strip it.
# The stub mypy exits 1 if any argument contains a CR, so the test reads the
# same on Linux CI, docker and Git Bash.
#
# Sourced by run.sh; helpers from lib.sh.
# shellcheck shell=sh

t_case_python_crlf() {
  t_begin "30 scoped Python file list and conf values survive CRLF"
  if ! gg_has_python; then
    t_skip "Python absent — scoped file list not produced"
    return 0
  fi

  cr="$(printf '\r')"
  r="$(gg_mktemp_repo)"
  mkdir -p "$r/src" "$r/tests" "$r/.venv/bin" "$r/crlf-fixture"
  printf 'value: int = 1\n' > "$r/src/a.py"
  printf 'other: int = 2\n' > "$r/tests/b.py"
  printf '[tool.mypy]\nfiles = ["src", "tests"]\n' > "$r/pyproject.toml"
  # CRLF on every line, including the one that sets the blocking mode.
  printf 'python.ruff_check=off\r\npython.ruff_format=off\r\nastgrep=off\r\npython.basedpyright=off\r\npython.mypy=block\r\n' \
    > "$r/.qa-gate.conf"
  ( cd "$r" && git add src/a.py tests/b.py pyproject.toml .qa-gate.conf )

  # Windows text-mode stdout, reproduced on any host.
  printf 'import sys\nsys.stdout.reconfigure(newline="\\r\\n")\n' > "$r/crlf-fixture/sitecustomize.py"

  scope_log="$(gg_tmp_log)"
  export GG_CRLF_LOG="$scope_log"
  {
    printf '#!/bin/sh\n'
    # shellcheck disable=SC2016  # literal runtime variables in the fixture script
    printf 'printf "mypy:%%s\\n" "$*" >> "$GG_CRLF_LOG"\n'
    # shellcheck disable=SC2016
    printf 'cr="$(printf "\\r")"\n'
    # shellcheck disable=SC2016
    printf 'for a in "$@"; do case "$a" in *"$cr"*) exit 1 ;; esac; done\n'
    # shellcheck disable=SC2016
    printf 'exit "${GG_CRLF_RC:-0}"\n'
  } > "$r/.venv/bin/mypy"
  chmod +x "$r/.venv/bin/mypy"

  # Positive control for the fixture: the interpreter really does emit CRLF.
  py="$(gg_python)"
  if PYTHONPATH="$r/crlf-fixture" "$py" -c 'print("x")' | od -c | grep -q '\\r'; then
    t_ok "fixture interpreter writes CRLF to stdout"
  else
    t_fail "fixture interpreter does not write CRLF; the test would prove nothing"
  fi

  expected='mypy:--ignore-missing-imports --no-error-summary src/a.py tests/b.py'
  gate_log="$(gg_tmp_log)"

  # 1. [tool.mypy] files = [...] branch.
  PYTHONPATH="$r/crlf-fixture" gg_run_gate_log "$r" "$gate_log"; rc=$?
  t_expect_rc 0 "$rc" "two staged in-scope files pass a blocking mypy under CRLF stdout and conf"
  if grep -Eq 'malformed|outside \[A-Za-z0-9' "$gate_log"; then
    t_fail "CRLF .qa-gate.conf was reported as malformed"
  else
    t_ok "CRLF .qa-gate.conf parses without a malformed-config block"
  fi
  if grep -qx -- "$expected" "$scope_log"; then
    t_ok "mypy receives both scoped paths without a carriage return"
  else
    t_fail "mypy did not receive the clean two-path list; got: $(sed "s/$cr/<CR>/g" "$scope_log" | head -3)"
  fi
  if grep -q "$cr" "$scope_log"; then
    t_fail "a carriage return reached a mypy argument"
  else
    t_ok "no mypy argument carries a carriage return"
  fi

  # The CRLF `python.mypy=block` line is in force: a real type failure blocks.
  : > "$scope_log"
  PYTHONPATH="$r/crlf-fixture" GG_CRLF_RC=1 gg_run_gate_log "$r" "$gate_log"; rc=$?
  t_expect_rc 1 "$rc" "CRLF python.mypy=block still blocks a genuine mypy failure"
  grep -q 'mypy type errors' "$gate_log"
  t_assert $? "the block names mypy, so the CRLF value was read as 'block'"

  # Shell layer on its own: an interpreter whose output is rewritten to CRLF
  # after the fact, so the embedded reconfigure cannot help. Only the
  # `tr -d` in qa_python_scoped_files stands between it and mypy.
  real_py="$(command -v "$py")"
  mkdir -p "$r/crlf-bin"
  for shim in python python3; do
    {
      printf '#!/bin/sh\n'
      # shellcheck disable=SC2016  # literal runtime variables in the fixture script
      printf 'out="$("%s" "$@")"; rc=$?\n' "$real_py"
      # shellcheck disable=SC2016
      printf '[ -n "$out" ] && printf "%%s\\n" "$out" | awk '"'"'{ sub(/\\r$/, ""); printf "%%s\\r\\n", $0 }'"'"'\n'
      # shellcheck disable=SC2016
      printf 'exit "$rc"\n'
    } > "$r/crlf-bin/$shim"
    chmod +x "$r/crlf-bin/$shim"
  done
  if "$r/crlf-bin/python" -c 'import sys; sys.stdout.reconfigure(newline="\n"); print("x")' | od -c | grep -q '\\r'; then
    t_ok "interpreter shim writes CRLF even after reconfigure(newline=LF)"
  else
    t_fail "interpreter shim does not write CRLF; the shell layer would be untested"
  fi
  : > "$scope_log"
  PATH="$r/crlf-bin:$PATH" gg_run_gate_log "$r" "$gate_log"; rc=$?
  t_expect_rc 0 "$rc" "shell-side strip passes two staged files from a CRLF-rewriting interpreter"
  grep -qx -- "$expected" "$scope_log"
  t_assert $? "shell-side strip hands mypy both paths without a carriage return"

  # 2. Pass-through branch: pyproject without a [tool.mypy] section.
  printf '[project]\nname = "crlf-fixture"\n' > "$r/pyproject.toml"
  ( cd "$r" && git add pyproject.toml )
  : > "$scope_log"
  PYTHONPATH="$r/crlf-fixture" gg_run_gate_log "$r" "$gate_log"; rc=$?
  t_expect_rc 0 "$rc" "pass-through branch passes two staged files under CRLF stdout"
  grep -qx -- "$expected" "$scope_log"
  t_assert $? "pass-through branch hands mypy both paths without a carriage return"

  unset GG_CRLF_LOG
  rm -f "$scope_log" "$gate_log"
  gg_rmrepo "$r"
}
