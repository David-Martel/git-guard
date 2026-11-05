#!/bin/sh
# Category 38: Python tools in a linked worktree use the project's environment.
#
# Behaviour protected:
# - A linked worktree with no .venv of its own runs mypy from the main checkout's
#   .venv, which is the project environment that has the repo's mypy plugins.
# - When no project environment exists and the PATH mypy cannot load the
#   project config (the "Error importing plugin" case), a blocking gate names the
#   missing environment and the fix. It does not print a bare "mypy type errors.".
# - A real type error from the project environment still blocks and shows
#   mypy's own output.
#
# What a failure means: on dtm-p1gen7 (2026-11-05, git-guard v0.2.17) a vigil-audio
# worktree without .venv fell back to ~/.local/bin/mypy. That mypy cannot import
# `pydantic.mypy`, so every Python commit was blocked with "mypy type errors." and
# no detail, for code that type-checks cleanly with the project's own mypy.
#
# Sourced by run.sh; helpers from lib.sh.
# shellcheck shell=sh

t_case_python_worktree_env() {
  t_begin "38 Python tools in a linked worktree use the main checkout's environment"

  r="$(gg_mktemp_repo)"
  mkdir -p "$r/pkg"
  {
    printf '[tool.mypy]\n'
    printf 'plugins = ["pydantic.mypy"]\n'
  } > "$r/pyproject.toml"
  # A correct pydantic model: it passes with the project's mypy, so the only
  # way the gate can block on it is a broken tool lookup.
  {
    printf 'from pydantic import BaseModel\n\n\n'
    printf 'class Reading(BaseModel):\n'
    printf '    value: int = 0\n'
  } > "$r/pkg/models.py"
  {
    printf 'python.ruff_check=off\n'
    printf 'python.ruff_format=off\n'
    printf 'python.basedpyright=off\n'
    printf 'python.mypy=block\n'
    printf 'astgrep=off\n'
  } > "$r/.qa-gate.conf"
  printf '.venv/\nworktrees/\n' > "$r/.gitignore"
  # commit-tree, not `git commit`: the fixture must not run the host's installed
  # hooks (on the affected host those hit this very bug and refuse the commit).
  ( cd "$r" && git add -A && git update-ref HEAD "$(git commit-tree -m init "$(git write-tree)")" ) \
    || { t_fail "fixture commit failed"; return 0; }
  ( cd "$r" && git worktree add -q "$r/worktrees/wt" -b wt ) || { t_fail "fixture worktree failed"; return 0; }
  wt="$r/worktrees/wt"
  printf '    unit: str = "mV"\n' >> "$wt/pkg/models.py"
  ( cd "$wt" && git add pkg/models.py )

  log="$(gg_tmp_log)"
  export GG_MYPY_LOG="$log"
  # The ambient mypy on PATH: it cannot load the project's plugin (pydantic is
  # not installed beside it). This is ~/.local/bin/mypy on the affected host.
  pathbin="$r/.pathbin"
  mkdir -p "$pathbin"
  {
    printf '#!/bin/sh\n'
    # shellcheck disable=SC2016  # literal runtime variables for the fixture script
    printf 'printf "path:%%s\\n" "$*" >> "$GG_MYPY_LOG"\n'
    printf 'echo "pyproject.toml: error: Error importing plugin '"'"'pydantic.mypy'"'"': No module named '"'"'pydantic'"'"'"\n'
    printf 'exit 2\n'
  } > "$pathbin/mypy"
  chmod +x "$pathbin/mypy"
  # The project's own mypy in the MAIN checkout's .venv (the worktree has none).
  mkdir -p "$r/.venv/bin"
  {
    printf '#!/bin/sh\n'
    # shellcheck disable=SC2016  # literal runtime variables for the fixture script
    printf 'printf "venv:%%s\\n" "$*" >> "$GG_MYPY_LOG"\n'
    # shellcheck disable=SC2016  # literal runtime variables for the fixture script
    printf 'if [ -n "${GG_MYPY_ENV_FAIL:-}" ]; then echo "pkg/models.py:6: error: Incompatible types in assignment"; exit 1; fi\n'
    printf 'exit 0\n'
  } > "$r/.venv/bin/mypy"
  chmod +x "$r/.venv/bin/mypy"

  run_gate() {
    ( cd "$wt" && env PATH="$pathbin:$PATH" GIT_GUARD_RULES_DIR="$GG_BUNDLED" \
        sh "$GG_ROOT/hooks/common/qa_gate.sh" >/dev/null 2>"$1" )
  }

  # 1. Positive control: a correct model in a venv-less worktree passes, checked
  #    by the main checkout's mypy, never the PATH one.
  gate_log="$(gg_tmp_log)"
  : > "$log"
  run_gate "$gate_log"; rc=$?
  t_expect_rc 0 "$rc" "venv-less worktree with a correct pydantic model passes"
  if grep -q '^venv:' "$log" && ! grep -q '^path:' "$log"; then
    t_ok "mypy ran from the main checkout's .venv, not from PATH"
  else
    t_fail "mypy did not resolve the main checkout's .venv (log: $(tr '\n' ' ' < "$log"))"
  fi

  # 2. A real type error from the project environment still blocks, with detail.
  : > "$log"
  GG_MYPY_ENV_FAIL=1 run_gate "$gate_log"; rc=$?
  t_expect_rc 1 "$rc" "a real type error from the project's mypy still blocks"
  grep -q 'Incompatible types in assignment' "$gate_log"
  t_assert $? "the block shows mypy's own error output"

  # 3. No project environment anywhere: block with the missing env and the fix,
  #    never a bare "mypy type errors.".
  rm -rf "$r/.venv"
  : > "$log"
  run_gate "$gate_log"; rc=$?
  t_expect_rc 1 "$rc" "PATH mypy that cannot load the project config still blocks"
  if grep -q "cannot load this project's mypy configuration" "$gate_log" \
     && grep -q 'uv sync' "$gate_log" && grep -qF "$r" "$gate_log"; then
    t_ok "the block names the missing environment, the main checkout and the fix"
  else
    t_fail "missing-env block is not actionable: $(head -5 "$gate_log" | tr '\n' ' ')"
  fi
  if grep -q 'BLOCKED: mypy type errors\.' "$gate_log"; then
    t_fail "a missing environment was reported as a generic 'mypy type errors.'"
  else
    t_ok "no generic 'mypy type errors.' for a missing environment"
  fi
  unset GG_MYPY_LOG
  ( cd "$r" && git worktree remove --force "$wt" ) >/dev/null 2>&1 || true
}
