#!/bin/sh
# Category 13 — downstream hook chaining: CONFIGURED-BUT-UNRUNNABLE must fail loudly.
#
# The defect this pins: git-guard chained to lefthook via `command -v lefthook`,
# so a repo shipping a lefthook config on a machine without the binary had every
# one of its gates skipped in SILENCE -- a missing binary and a clean commit
# produced identical output. Measured 2026-09-11 on a fleet repo: 26 gates inert,
# 14 of them with no CI backstop.
#
# The negative control (case 1) is the load-bearing one: a repo with NO lefthook
# config must still commit normally, or this change breaks every other repo.
#
# lefthook is HIDDEN via PATH rather than assumed absent, so the case is
# deterministic on machines that do have it installed.
# shellcheck shell=sh

# PATH with no ~/.local/bin etc, so `command -v lefthook` fails deterministically.
GG_T_PATH_NO_LEFTHOOK="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

t_case_downstream_chaining() {
  t_begin "13 downstream chaining (configured-but-unrunnable fails loudly)"

  # 1. NEGATIVE CONTROL — no lefthook config: commit must still land.
  r="$(gg_mktemp_repo)"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
  printf 'hi\n' > "$r/a.txt"
  ( cd "$r" && git add a.txt )
  ( cd "$r" && env PATH="$GG_T_PATH_NO_LEFTHOOK" GIT_GUARD_RULES_DIR="$GG_BUNDLED" \
      git commit -q -m "no lefthook config" >/dev/null 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "no lefthook config + no binary: commit is UNAFFECTED"
  n="$( ( cd "$r" && git rev-list --count --all 2>/dev/null ) || echo 0 )"
  t_expect_rc 1 "$n" "the unaffected commit landed"
  gg_rmrepo "$r"

  # 2. lefthook configured but binary missing: must BLOCK and name the fix.
  r="$(gg_mktemp_repo)"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
  printf 'pre-commit:\n  commands: {}\n' > "$r/lefthook.yml"
  printf 'hi\n' > "$r/a.txt"
  ( cd "$r" && git add a.txt lefthook.yml )
  log="$(gg_tmp_log)"
  ( cd "$r" && env PATH="$GG_T_PATH_NO_LEFTHOOK" GIT_GUARD_RULES_DIR="$GG_BUNDLED" \
      git commit -m "should be blocked" >"$log" 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "configured-but-unrunnable lefthook REFUSES the commit (rc=$rc)"
  else t_fail "configured-but-unrunnable lefthook did NOT refuse (rc=0)"; fi
  n="$( ( cd "$r" && git rev-list --count --all 2>/dev/null ) || echo 0 )"
  t_expect_rc 0 "$n" "no commit landed when the gates could not run"
  grep -q 'git-guard BLOCK' "$log"; t_assert $? "the refusal is LOUD (names git-guard BLOCK)"
  grep -q 'GIT_GUARD_ALLOW_MISSING_LEFTHOOK' "$log"; t_assert $? "the message names its own escape hatch"

  # 3. Same repo + the escape hatch: must pass (deliberate opt-out is honoured).
  ( cd "$r" && env PATH="$GG_T_PATH_NO_LEFTHOOK" GIT_GUARD_RULES_DIR="$GG_BUNDLED" \
      GIT_GUARD_ALLOW_MISSING_LEFTHOOK=1 git commit -q -m "opted out" >/dev/null 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "GIT_GUARD_ALLOW_MISSING_LEFTHOOK=1 permits the commit"
  rm -f "$log"; gg_rmrepo "$r"

  # 4. Alternate config filename is detected too.
  r="$(gg_mktemp_repo)"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
  printf 'pre-commit:\n  commands: {}\n' > "$r/.lefthook.yaml"
  printf 'hi\n' > "$r/a.txt"
  ( cd "$r" && git add a.txt .lefthook.yaml )
  ( cd "$r" && env PATH="$GG_T_PATH_NO_LEFTHOOK" GIT_GUARD_RULES_DIR="$GG_BUNDLED" \
      git commit -q -m "alt name" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok ".lefthook.yaml is detected as a lefthook config (rc=$rc)"
  else t_fail ".lefthook.yaml was NOT detected (commit passed)"; fi
  gg_rmrepo "$r"

  # 5. lefthook's other config stems are detected too (.config/lefthook.yml).
  r="$(gg_mktemp_repo)"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
  mkdir -p "$r/.config"
  printf 'pre-commit:\n  commands: {}\n' > "$r/.config/lefthook.yml"
  printf 'hi\n' > "$r/a.txt"
  ( cd "$r" && git add a.txt .config/lefthook.yml )
  ( cd "$r" && env PATH="$GG_T_PATH_NO_LEFTHOOK" GIT_GUARD_RULES_DIR="$GG_BUNDLED" \
      git commit -q -m "dot-config stem" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok ".config/lefthook.yml is detected as a lefthook config (rc=$rc)"
  else t_fail ".config/lefthook.yml was NOT detected (commit passed)"; fi
  gg_rmrepo "$r"

  # 6. A config in a SUBDIRECTORY must NOT trip the gate (root-only check).
  r="$(gg_mktemp_repo)"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
  mkdir -p "$r/vendor/thing"
  printf 'pre-commit:\n  commands: {}\n' > "$r/vendor/thing/lefthook.yml"
  printf 'hi\n' > "$r/a.txt"
  ( cd "$r" && git add a.txt vendor/thing/lefthook.yml )
  ( cd "$r" && env PATH="$GG_T_PATH_NO_LEFTHOOK" GIT_GUARD_RULES_DIR="$GG_BUNDLED" \
      git commit -q -m "vendored config" >/dev/null 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "a vendored subdirectory lefthook.yml does NOT trip the gate"
  gg_rmrepo "$r"
}
