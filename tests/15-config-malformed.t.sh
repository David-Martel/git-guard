#!/bin/sh
# Category 15 — malformed .qa-gate.conf lines are a loud, blocking error.
#
# Before this category existed, qa_load_cfg_file() silently `continue`d past
# three shapes of bad line: no `=` at all, an empty key before `=`, and a value
# containing characters outside the documented vocab. A repo's override could
# be completely inert with zero output anywhere -- exactly what happened to
# vigil-friction's `.qa-gate.conf`, which wrote all 4 overrides as
# `key   value` (space, not `=`) and got none of them applied, silently, for
# weeks. This suite pins the fix: each malformed shape now BLOCKS the commit
# and names the exact file:line, and a well-formed conf is unaffected
# (positive control alongside every negative one).
#
# Sourced by run.sh; helpers from lib.sh. Fixtures are generated at run time
# (never commit a malformed fixture into THIS repo -- git-guard's own gate
# would refuse it).
# shellcheck shell=sh

# A harmless docs-only staged change so the gate has something to evaluate
# (an empty staged set short-circuits qa_main before config even matters).
gg_fixture_docs_only() {
  printf '# docs\n' > "$1/README.md"
}

t_case_config_malformed() {
  t_begin "15 malformed .qa-gate.conf lines block loudly, naming file:line"

  # --- NEGATIVE CONTROL (the historical bug): no '=' at all ------------------
  # This is vigil-friction's exact shape: `key   value` with trailing comment.
  r="$(gg_mktemp_repo)"
  gg_fixture_docs_only "$r"
  {
    printf '# leading comments, like a real repo conf\n'
    printf '\n'
    printf 'python.ruff_check   block   # missing key-value separator\n'
  } > "$r/.qa-gate.conf"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "no '=' in a non-comment line BLOCKS the commit"
  grep -q "malformed config line" "$logf" 2>/dev/null \
    && t_ok "message says 'malformed config line'" \
    || t_fail "message does not say 'malformed config line'"
  grep -q "\.qa-gate\.conf:3" "$logf" 2>/dev/null \
    && t_ok "message names the exact file:line (:3, after 2 leading lines)" \
    || t_fail "message does not name the exact file:line"
  grep -q "do NOT 'git reset --hard'" "$logf" 2>/dev/null \
    && t_ok "the STAGED-but-UNCOMMITTED warning is still present" \
    || t_fail "missing the reset --hard warning (IRON RULE 1 feedback)"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- vigil-friction's ACTUAL file, byte for byte ----------------------------
  # Regression pin for the exact reported case: 4 space-separated override
  # lines starting at line 5. All 4 must be reported.
  r="$(gg_mktemp_repo)"
  gg_fixture_docs_only "$r"
  {
    printf '# vigil-friction QA gate config (read automatically by git-guard).\n'
    printf '# Makes the fast quality checks BLOCKING for this repo.\n'
    printf '# Values: off | warn | block.\n'
    printf '\n'
    printf 'python.ruff_check   block   # lint errors block the commit\n'
    printf 'python.ruff_format  block   # formatting must be clean\n'
    printf 'python.mypy         warn    # kept warn\n'
    printf 'python.pyright      warn    # wrong key name too (basedpyright)\n'
  } > "$r/.qa-gate.conf"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "vigil-friction's real conf (4 space-separated overrides) BLOCKS"
  grep -q "\.qa-gate\.conf:5" "$logf" 2>/dev/null \
    && t_ok "names line 5 (the first override line)" \
    || t_fail "does not name line 5"
  for ln in 6 7 8; do
    grep -q "\.qa-gate\.conf:${ln}" "$logf" 2>/dev/null \
      && t_ok "also names line $ln (every malformed line is reported, not just the first)" \
      || t_fail "does not name line $ln"
  done
  rm -f "$logf"; gg_rmrepo "$r"

  # --- empty key before '=' ---------------------------------------------------
  r="$(gg_mktemp_repo)"
  gg_fixture_docs_only "$r"
  printf '=block\n' > "$r/.qa-gate.conf"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "empty key ('=value') BLOCKS the commit"
  grep -q "empty key" "$logf" 2>/dev/null \
    && t_ok "message names the empty-key reason" \
    || t_fail "message does not name the empty-key reason"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- value with a disallowed character (space mid-value, no comment) -------
  r="$(gg_mktemp_repo)"
  gg_fixture_docs_only "$r"
  printf 'python.ruff_check=block now\n' > "$r/.qa-gate.conf"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "a value with a stray trailing token BLOCKS the commit"
  grep -q "characters outside" "$logf" 2>/dev/null \
    && t_ok "message names the bad-value-vocab reason" \
    || t_fail "message does not name the bad-value-vocab reason"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- unknown/misspelled key (syntactically VALID key=value, but the key --
  # doesn't exist) -- the OTHER half of the vigil-friction defect: even a
  # correctly-punctuated `python.pyright=warn` did nothing, because git-guard
  # has no such key (the real one is `python.basedpyright`).
  r="$(gg_mktemp_repo)"
  gg_fixture_docs_only "$r"
  printf 'python.pyright=warn\n' > "$r/.qa-gate.conf"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "a syntactically valid but UNKNOWN key BLOCKS the commit"
  grep -q "unknown config key" "$logf" 2>/dev/null \
    && t_ok "message says 'unknown config key'" \
    || t_fail "message does not say 'unknown config key'"
  grep -q "'python.pyright'" "$logf" 2>/dev/null \
    && t_ok "message names the exact unrecognized key" \
    || t_fail "message does not name the unrecognized key"
  grep -q "python.basedpyright" "$logf" 2>/dev/null \
    && t_ok "message lists the valid keys (includes the one the author probably meant)" \
    || t_fail "message does not list valid keys"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- POSITIVE CONTROL: `powershell.astgrep` is a documented EXCEPTION -- it
  # is never read via qa_cfg (ast-grep has no PowerShell grammar) but must
  # stay a RECOGNIZED key so an existing repo conf setting it does not now
  # start erroring.
  r="$(gg_mktemp_repo)"
  gg_fixture_docs_only "$r"
  printf 'powershell.astgrep=warn\n' > "$r/.qa-gate.conf"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 0 "$rc" "powershell.astgrep (deliberately inert, still recognized) does NOT block"
  grep -q "unknown config key" "$logf" 2>/dev/null \
    && t_fail "powershell.astgrep was wrongly flagged as an unknown key" \
    || t_ok "powershell.astgrep produced no unknown-key finding"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- POSITIVE CONTROL: a well-formed conf is completely unaffected ---------
  r="$(gg_mktemp_repo)"
  gg_fixture_docs_only "$r"
  {
    printf '# a normal, well-formed override file\n'
    printf 'python.ruff_check=block\n'
    printf 'python.ruff_format=warn   # inline comment is fine\n'
    printf 'astgrep=off\n'
    printf 'rules_dir=/tmp/does-not-need-to-exist-for-this-check\n'
  } > "$r/.qa-gate.conf"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 0 "$rc" "a well-formed conf still passes (no false positive from the stricter parser)"
  if grep -q "malformed config line" "$logf" 2>/dev/null
  then t_fail "well-formed conf was wrongly flagged as malformed"
  else t_ok "well-formed conf produced no malformed-config finding"
  fi
  if grep -q "unknown config key" "$logf" 2>/dev/null
  then t_fail "well-formed conf (incl. rules_dir) was wrongly flagged as an unknown key"
  else t_ok "well-formed conf produced no unknown-key finding"
  fi
  rm -f "$logf"; gg_rmrepo "$r"

  # --- the malformed-config refusal is UNCONDITIONAL, independent of --------
  # qa.enabled and of whether anything is staged that the later checks would
  # look at -- it must not be masked by qa_main's early exits, which read
  # values FROM the config that just failed to parse.
  r="$(gg_mktemp_repo)"
  gg_fixture_docs_only "$r"
  {
    printf 'qa.enabled=off\n'
    printf 'python.ruff_check   block\n'
  } > "$r/.qa-gate.conf"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "malformed line still BLOCKS even when a later valid line sets qa.enabled=off"
  rm -f "$logf"; gg_rmrepo "$r"
}
