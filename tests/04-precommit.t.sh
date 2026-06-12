#!/bin/sh
# Category 4 — pre-commit blocking, end-to-end through a REAL `git commit`.
# Installs the hooks LOCALLY (per-repo core.hooksPath -> git-guard/hooks); never
# touches the global hooks config. Sourced by run.sh.
# shellcheck shell=sh

t_case_precommit() {
  t_begin "04 pre-commit blocking (real git commit)"
  if ! gg_has_astgrep; then
    t_skip "pre-commit: ast-grep CLI absent (BLOCK-trio fixture cannot fire)"; return 0
  fi
  r="$(gg_mktemp_repo)"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )

  # 1. A BLOCK-trio violation must be REFUSED (commit does not land).
  gg_fixture_static_mut "$r"
  ( cd "$r" && git add -A )
  ( cd "$r" && GIT_GUARD_RULES_DIR="$GG_BUNDLED" git commit -q -m "trio violation" >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "pre-commit refuses a BLOCK-trio violation (rc=$rc)"; else t_fail "pre-commit did NOT refuse the violation (rc=0)"; fi
  n="$( ( cd "$r" && git rev-list --count --all 2>/dev/null ) || echo 0 )"
  t_expect_rc 0 "$n" "no commit landed after the refused violation"

  # 2. A clean commit must PASS (lands one commit).
  ( cd "$r" && git rm -q --cached src/bad.rs >/dev/null 2>&1; rm -f src/bad.rs; printf '# ok\n' > README.md; git add -A )
  ( cd "$r" && GIT_GUARD_RULES_DIR="$GG_BUNDLED" git commit -q -m "clean docs" >/dev/null 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "pre-commit allows a clean docs commit"
  n="$( ( cd "$r" && git rev-list --count --all 2>/dev/null ) || echo 0 )"
  t_expect_rc 1 "$n" "exactly one commit landed (the clean one)"

  gg_rmrepo "$r"
}
