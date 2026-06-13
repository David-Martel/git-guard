#!/bin/sh
# Category 2 (flag/warn) + Category 3 (auto-fix). Sourced by run.sh.
# shellcheck shell=sh

# Category 2 — a warn-level rule warns WITHOUT blocking (exit 0 + message).
t_case_warn() {
  t_begin "02 warn-level rule warns (exit 0 + message)"
  if ! gg_has_astgrep; then
    t_skip "warn rule: ast-grep CLI absent"; return 0
  fi
  r="$(gg_mktemp_repo)"
  mkdir -p "$r/src"
  printf 'fn main() { println!("hi"); }\n' > "$r/src/m.rs"   # avoid-println = warn
  ( cd "$r" && git add -A )
  logf="$(gg_tmp_log)"
  gg_run_gate_log "$r" "$logf"; rc=$?
  t_expect_rc 0 "$rc" "warn-level avoid-println does NOT block"
  grep -qi "avoid-println" "$logf" 2>/dev/null \
    && t_ok "warn message names avoid-println (non-blocking)" \
    || t_fail "warn message for avoid-println missing"
  rm -f "$logf"; gg_rmrepo "$r"
}

# Category 3 — auto-fix path (OPT-IN via astgrep_autofix=on). avoid-println has a
# fix: that rewrites println! -> tracing::info! and re-stages the file.
t_case_autofix() {
  t_begin "03 auto-fix path (opt-in astgrep_autofix=on)"
  if ! gg_has_astgrep; then
    t_skip "auto-fix: ast-grep CLI absent (auto-fix is advisory; see QA_TOOLING §5)"; return 0
  fi
  r="$(gg_mktemp_repo)"
  mkdir -p "$r/src"
  printf 'fn main() { println!("hi"); }\n' > "$r/src/m.rs"
  printf 'astgrep_autofix=on\n' > "$r/.qa-gate.conf"
  ( cd "$r" && git add -A )
  gg_run_gate "$r"; rc=$?
  t_expect_rc 0 "$rc" "auto-fix run completes without blocking"
  if grep -q "tracing::info" "$r/src/m.rs" 2>/dev/null; then
    t_ok "auto-fix rewrote println! -> tracing::info!"
  else
    t_fail "auto-fix did not rewrite the file"
  fi
  # The rewritten file must be RE-STAGED (it was fully staged before the fix).
  if ( cd "$r" && git diff --cached -- src/m.rs | grep -q "tracing::info" ); then
    t_ok "auto-fixed file was safely re-staged"
  else
    t_fail "auto-fixed file was not re-staged"
  fi
  gg_rmrepo "$r"
}
