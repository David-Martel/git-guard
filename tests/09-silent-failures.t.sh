#!/bin/sh
# Category 9 — Python silent-failure rules fire on real swallows and stay quiet
# on handlers that actually report.
#
# These rules exist because "you used a broad except" is not the interesting
# signal; the interesting signal is "this failure will be INVISIBLE at runtime".
# So each rule fires only when the handler neither logs nor re-raises. A handler
# that reports and then degrades is correct code and must not be flagged — a
# gate that cries wolf gets switched off, which is worse than not having it.
#
# Sourced by run.sh; helpers from lib.sh. Fixtures are generated at run time.
#
# Every case disables the Python tool gates in the fixture repo. These snippets
# are deliberately minimal and reference undefined names (`connect`, `logger`),
# so ruff's F821 BLOCKS for reasons that have nothing to do with the rules under
# test. The conf lines are written out per case rather than shared through a
# variable: the shared-variable version silently expanded to nothing under
# run.sh, ruff blocked instead, and the case still looked like a rule failure.
# shellcheck shell=sh

# Isolate the ast-grep layer (the Python tool gates are exercised by 02-warn).
gg_conf_py_off() {
  {
    printf 'python.ruff_check=off\n'
    printf 'python.ruff_format=off\n'
    printf 'python.mypy=off\n'
    printf 'python.basedpyright=off\n'
    for _extra in "$@"; do printf '%s\n' "$_extra"; done
  } > "$1/.qa-gate.conf"
}

# Swallows entirely: no log, no raise, no record.
gg_fixture_py_swallow() {
  mkdir -p "$1/src"
  printf 'def probe():\n    try:\n        connect()\n    except OSError:\n        pass\n' \
    > "$1/src/app.py"
}

# Reports, THEN degrades — the correct shape. Must produce no silent-failure finding.
gg_fixture_py_reports() {
  mkdir -p "$1/src"
  printf 'def probe():\n    try:\n        connect()\n    except OSError as exc:\n        logger.warning("probe failed: %%s", exc)\n        return None\n' \
    > "$1/src/app.py"
}

t_case_silent_failures() {
  t_begin "09 python silent-failure rules"

  if ! gg_has_astgrep; then
    t_skip "ast-grep absent — silent-failure rules not exercised"
    return 0
  fi

  # --- default: warns, does not block ---
  r="$(gg_mktemp_repo)"
  gg_fixture_py_swallow "$r"; gg_conf_py_off "$r"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 0 "$rc" "default: swallowed exception warns, does NOT block"
  grep -q "silent-except-pass" "$logf" 2>/dev/null \
    && t_ok "silent-except-pass names the swallow" \
    || t_fail "silent-except-pass did not fire on a bare pass handler"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- astgrep=block: the swallow blocks ---
  r="$(gg_mktemp_repo)"
  gg_fixture_py_swallow "$r"; gg_conf_py_off "$r" "astgrep=block"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "astgrep=block: swallowed exception BLOCKS"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- a handler that REPORTS then degrades is not a finding ---
  # The false-positive guard. `logger.warning(...)` before `return None` is the
  # shape the rules are written to permit.
  r="$(gg_mktemp_repo)"
  gg_fixture_py_reports "$r"; gg_conf_py_off "$r" "astgrep=block"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 0 "$rc" "log-then-return-None does NOT trip the silent-failure rules"
  grep -q "silent-except" "$logf" 2>/dev/null \
    && t_fail "false positive: reporting handler flagged as silent" \
    || t_ok "no silent-failure finding on a reporting handler"
  rm -f "$logf"; gg_rmrepo "$r"
}
