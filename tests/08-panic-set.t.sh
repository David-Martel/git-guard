#!/bin/sh
# Category 8 — the panic set is ENFORCEABLE, not just advisory.
#
# Regression cover for a real defect: `qa_is_panic_id` forced every panic-family
# ruleId to WARN-ONLY *unconditionally*, so a repo that had done the cleanup and
# explicitly set `astgrep=block` still could not make "no unwrap() in production
# code" actually hold. The rules fired, carried `severity: error`, and blocked
# nothing. These cases pin all three tiers of the `astgrep_panics` opt-in plus
# the misclassification that rode along with the old fuzzy `*expect*` glob.
#
# Sourced by run.sh; helpers from lib.sh. Fixtures are generated inside throwaway
# temp repos at run time — never committed into git-guard itself.
# shellcheck shell=sh

# An unwrap() in library code: unconditional panic (unwrap-call/library-unwrap).
gg_fixture_unwrap() {
  mkdir -p "$1/src"
  printf 'pub fn f(o: Option<u32>) -> u32 {\n    o.unwrap()\n}\n' > "$1/src/lib.rs"
}

# A raw slice index: panics only for SOME inputs, and a caller-side length check
# can make it genuinely unreachable — the "heuristic" tier.
gg_fixture_index() {
  mkdir -p "$1/src"
  printf 'pub fn f(v: &[u32]) -> u32 {\n    v[3]\n}\n' > "$1/src/lib.rs"
}

# `#[allow(...)]` — trips prefer-expect-over-allow, which is a STYLE rule about
# attributes. Its id contains "expect", so the old glob swept it into the panic
# deny-set and made it permanently un-blockable.
gg_fixture_allow_attr() {
  mkdir -p "$1/src"
  printf '#[allow(dead_code)]\npub fn f() {}\n' > "$1/src/lib.rs"
}

# Write a per-repo .qa-gate.conf. $2.. are literal `key=value` lines.
gg_write_conf() {
  _r="$1"; shift
  : > "$_r/.qa-gate.conf"
  for _line in "$@"; do printf '%s\n' "$_line" >> "$_r/.qa-gate.conf"; done
}

t_case_panic_set() {
  t_begin "08 panic set is enforceable (astgrep_panics tiers)"

  if ! gg_has_astgrep; then
    t_skip "ast-grep absent — panic-set tiers not exercised"
    return 0
  fi

  # --- default: warns, never blocks (the account-wide anti-brick promise) ---
  r="$(gg_mktemp_repo)"
  gg_fixture_unwrap "$r"; ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 0 "$rc" "default (no conf): unwrap warns, does NOT block"
  grep -q "panic-set" "$logf" 2>/dev/null \
    && t_ok "default: warning still names the panic set" \
    || t_fail "default: no panic-set warning emitted at all"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- astgrep_panics=block: unconditional panics DO block ---
  # This is the assertion the old code could never satisfy.
  r="$(gg_mktemp_repo)"
  gg_fixture_unwrap "$r"; gg_write_conf "$r" "astgrep_panics=block"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "astgrep_panics=block: unwrap() BLOCKS"
  grep -q "unconditional panic" "$logf" 2>/dev/null \
    && t_ok "block message explains WHY (unconditional panic)" \
    || t_fail "block message missing the unconditional-panic reason"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- astgrep_panics=block: heuristic tier still only warns ---
  # An index inside a caller-validated region is a legitimate defence; blocking
  # it at the same tier as .unwrap() would punish correct code.
  r="$(gg_mktemp_repo)"
  gg_fixture_index "$r"; gg_write_conf "$r" "astgrep_panics=block"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 0 "$rc" "astgrep_panics=block: raw index warns, does NOT block"
  grep -q "input-dependent panic" "$logf" 2>/dev/null \
    && t_ok "heuristic warning points at the strict tier" \
    || t_fail "heuristic warning missing its escalation hint"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- astgrep_panics=strict: the whole set blocks ---
  r="$(gg_mktemp_repo)"
  gg_fixture_index "$r"; gg_write_conf "$r" "astgrep_panics=strict"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "astgrep_panics=strict: raw index BLOCKS"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- astgrep_panics is INDEPENDENT of astgrep ---
  # A repo holding a hard no-unwrap line should not be forced to also block on
  # every other style rule.
  r="$(gg_mktemp_repo)"
  gg_fixture_unwrap "$r"; gg_write_conf "$r" "astgrep=warn" "astgrep_panics=block"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "astgrep=warn + astgrep_panics=block: still blocks the unwrap"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- prefer-expect-over-allow is NOT a panic rule ---
  # Regression: the old `*expect*` glob swept this style rule into the deny-set,
  # so `astgrep=block` silently could not enforce it.
  r="$(gg_mktemp_repo)"
  gg_fixture_allow_attr "$r"; gg_write_conf "$r" "astgrep=block"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 1 "$rc" "astgrep=block: prefer-expect-over-allow BLOCKS (not panic-set)"
  grep -q "prefer-expect-over-allow" "$logf" 2>/dev/null \
    && t_ok "block message names prefer-expect-over-allow" \
    || t_fail "block message missing prefer-expect-over-allow"
  rm -f "$logf"; gg_rmrepo "$r"

  # --- astgrep=off still wins over every panic tier ---
  # The universal escape hatch must remain absolute, or a repo could be bricked
  # with no way out.
  r="$(gg_mktemp_repo)"
  gg_fixture_unwrap "$r"; gg_write_conf "$r" "astgrep=off" "astgrep_panics=strict"
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 0 "$rc" "astgrep=off overrides astgrep_panics=strict (escape hatch holds)"
  rm -f "$logf"; gg_rmrepo "$r"
}
