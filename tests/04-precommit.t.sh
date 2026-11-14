#!/bin/sh
# Category 4 — pre-commit blocking, end-to-end through a REAL `git commit`.
#
# Behaviour protected: with hooks/ as core.hooksPath, a BLOCK-trio violation
# leaves NO commit behind, and a clean docs change lands exactly one commit.
# Categories 1 and 28 call qa_gate.sh directly; this case proves hooks/pre-commit
# passes the gate's exit code through to git.
#
# What a failure means: the gate prints its BLOCKED message while the commit
# lands anyway. IRON RULE 1 in docs/GIT_COMMIT_SAFETY.md depends on a refused
# commit really being refused.
#
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

# Staged names with a space, a tab or a newline. qa_gate.sh passed the staged list to
# ast-grep, ruff and shellcheck with `set -- $files` under the default IFS, which splits on
# all three, so a BLOCK-trio violation in `src/my bad.rs` reached ast-grep as `src/my` and
# `bad.rs` and the commit landed (same-class sweep of the git-guard #121 review,
# 2026-11-14). A newline cannot be carried in the gate's newline-separated list at all, so
# such a name with a gated extension is refused rather than skipped.
_pc_commit() {
  # _pc_commit REPO MSG LOG: a real commit through hooks/, rules from the bundle.
  ( cd "$1" && GIT_GUARD_RULES_DIR="$GG_BUNDLED" git commit -q -m "$2" ) >/dev/null 2>"$3"
}
t_case_precommit_staged_names() {
  t_begin "04 pre-commit: staged names with spaces, tabs and newlines reach the gates whole"
  if ! gg_has_astgrep; then
    t_skip "staged names: ast-grep CLI absent (BLOCK-trio fixture cannot fire)"; return 0
  fi
  log="$GG_T_TMPROOT/pc-names.log"
  _pc_bad='static mut COUNTER: u32 = 0;\nfn main() { unsafe { COUNTER += 1; } }\n'

  r="$(gg_mktemp_repo)"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
  mkdir -p "$r/src"
  printf '%b' "$_pc_bad" > "$r/src/my bad.rs"
  ( cd "$r" && git add -A )
  _pc_commit "$r" "space" "$log"; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "a BLOCK-trio violation in a name with a space is refused (rc=$rc)"
  else t_fail "a BLOCK-trio violation in 'src/my bad.rs' was committed: the name was split"; fi
  n="$( ( cd "$r" && git rev-list --count --all 2>/dev/null ) || echo 0 )"
  t_expect_rc 0 "$n" "no commit landed for the spaced name"
  gg_rmrepo "$r"

  # Control: a clean shell script whose name has a space passes shellcheck whole. Split, it
  # was two missing files and a false block.
  if have shellcheck; then
    r="$(gg_mktemp_repo)"
    ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
    mkdir -p "$r/scripts"
    printf '#!/bin/sh\necho ok\n' > "$r/scripts/my tool.sh"
    ( cd "$r" && git add -A )
    _pc_commit "$r" "clean spaced script" "$log"
    t_expect_rc 0 "$?" "a clean script whose name has a space is checked whole and passes"
    gg_rmrepo "$r"
  else
    t_skip "staged names: shellcheck absent (spaced-script control not run)"
  fi
  # Structured-data validation looped `for f in $jf`; a spaced name split, failed its -f
  # test and was skipped, so invalid JSON (validate.json defaults to block) was committed.
  if have python3 || have python; then
    r="$(gg_mktemp_repo)"
    ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
    printf '{ "a": \n' > "$r/my config.json"
    ( cd "$r" && git add -A )
    _pc_commit "$r" "invalid spaced json" "$log"; rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'invalid JSON: my config.json' "$log"; then t_ok "invalid JSON in a name with a space is refused and named (rc=$rc)"
    else t_fail "invalid JSON in 'my config.json' was not refused (rc=$rc: $(head -c 200 "$log"))"; fi
    gg_rmrepo "$r"
  else
    t_skip "staged names: no Python for the JSON validation case"
  fi

  if gg_is_windows; then
    t_skip "staged names: tab and newline file names cannot exist in a Windows work tree"
    return 0
  fi
  _pc_tab="$(printf '\t')"
  _pc_nl='
'
  r="$(gg_mktemp_repo)"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
  mkdir -p "$r/src"
  printf '%b' "$_pc_bad" > "$r/src/a${_pc_tab}b.rs"
  ( cd "$r" && git add -A )
  _pc_commit "$r" "tab" "$log"; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "a BLOCK-trio violation in a name with a tab is refused (rc=$rc)"
  else t_fail "a BLOCK-trio violation in a tab-named file was committed: the name was split"; fi
  gg_rmrepo "$r"

  r="$(gg_mktemp_repo)"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
  mkdir -p "$r/src"
  printf 'pub fn ok() {}\n' > "$r/src/c${_pc_nl}d.rs"
  ( cd "$r" && git add -A )
  _pc_commit "$r" "newline rs" "$log"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'newline' "$log"; then t_ok "a gated file whose name has a newline is refused and the reason named (rc=$rc)"
  else t_fail "a newline-named .rs file was not refused with a reason (rc=$rc: $(head -c 300 "$log"))"; fi
  gg_rmrepo "$r"

  # Control: a newline in a name the gates never read only warns.
  r="$(gg_mktemp_repo)"
  ( cd "$r" && git config core.hooksPath "$GG_ROOT/hooks" )
  printf 'notes\n' > "$r/notes${_pc_nl}x.txt"
  ( cd "$r" && git add -A )
  _pc_commit "$r" "newline txt" "$log"
  t_expect_rc 0 "$?" "a newline in a non-gated name warns but does not block"
  gg_rmrepo "$r"
}
