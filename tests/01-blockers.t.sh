#!/bin/sh
# Category 1 — blockers fire (exit non-zero). Sourced by run.sh; helpers from
# lib.sh. Each fixture is generated INSIDE a throwaway temp repo at run time so
# no planted secret / invalid file is ever committed into git-guard itself.
# shellcheck shell=sh

t_case_blockers() {
  t_begin "01 blockers fire (exit 1)"

  # --- BLOCK trio: avoid-static-mut ---
  if gg_has_astgrep; then
    r="$(gg_mktemp_repo)"
    gg_fixture_static_mut "$r"; ( cd "$r" && git add -A )
    gg_run_gate_log "$r" /tmp/gg_b_sm.$$; rc=$?
    t_expect_rc 1 "$rc" "trio avoid-static-mut blocks"
    grep -q "avoid-static-mut" /tmp/gg_b_sm.$$ 2>/dev/null \
      && t_ok "block message names avoid-static-mut" \
      || t_fail "block message missing avoid-static-mut"
    rm -f /tmp/gg_b_sm.$$; gg_rmrepo "$r"

    # --- BLOCK trio: no-glob-reexport ---
    r="$(gg_mktemp_repo)"
    gg_fixture_glob_reexport "$r"; ( cd "$r" && git add -A )
    gg_run_gate_log "$r" /tmp/gg_b_gr.$$; rc=$?
    t_expect_rc 1 "$rc" "trio no-glob-reexport blocks"
    grep -q "no-glob-reexport" /tmp/gg_b_gr.$$ 2>/dev/null \
      && t_ok "block message names no-glob-reexport" \
      || t_fail "block message missing no-glob-reexport"
    rm -f /tmp/gg_b_gr.$$; gg_rmrepo "$r"

    # --- BLOCK trio: unsafe-with-panic ---
    r="$(gg_mktemp_repo)"
    gg_fixture_unsafe_panic "$r"; ( cd "$r" && git add -A )
    gg_run_gate_log "$r" /tmp/gg_b_up.$$; rc=$?
    t_expect_rc 1 "$rc" "trio unsafe-with-panic blocks"
    grep -q "unsafe-with-panic" /tmp/gg_b_up.$$ 2>/dev/null \
      && t_ok "block message names unsafe-with-panic" \
      || t_fail "block message missing unsafe-with-panic"
    rm -f /tmp/gg_b_up.$$; gg_rmrepo "$r"
  else
    t_skip "BLOCK trio: ast-grep CLI absent (no genuine ast-grep on PATH)"
  fi

  # --- secret_scan blocks a PLANTED FAKE secret ---
  if gg_has_python; then
    r="$(gg_mktemp_repo)"
    gg_fixture_fake_secret "$r"; ( cd "$r" && git add -A )
    ( cd "$r" && sh "$GG_ROOT/hooks/common/secret_scan.sh" >/dev/null 2>/tmp/gg_sec.$$ ); rc=$?
    t_expect_rc 1 "$rc" "secret_scan blocks a planted fake AWS key"
    grep -q "possible secret" /tmp/gg_sec.$$ 2>/dev/null \
      && t_ok "secret_scan emits the un-missable BLOCKED message" \
      || t_fail "secret_scan message missing"
    rm -f /tmp/gg_sec.$$; gg_rmrepo "$r"
  else
    t_skip "secret_scan: python absent (used elsewhere in suite; scan itself needs only git+grep)"
  fi

  # --- invalid JSON blocks (validate.json=block default) ---
  if gg_has_python; then
    r="$(gg_mktemp_repo)"
    gg_fixture_bad_json "$r"; ( cd "$r" && git add -A )
    gg_run_gate_log "$r" /tmp/gg_json.$$; rc=$?
    t_expect_rc 1 "$rc" "invalid JSON blocks"
    grep -q "invalid JSON" /tmp/gg_json.$$ 2>/dev/null \
      && t_ok "block message names invalid JSON" \
      || t_fail "block message missing invalid JSON"
    rm -f /tmp/gg_json.$$; gg_rmrepo "$r"
  else
    t_skip "invalid JSON: python absent (JSON validation self-skips)"
  fi

  # --- invalid YAML blocks (needs validate.yaml=block override + pyyaml) ---
  if gg_has_python && gg_has_pyyaml; then
    r="$(gg_mktemp_repo)"
    gg_fixture_bad_yaml "$r"
    printf 'validate.yaml=block\n' > "$r/.qa-gate.conf"
    ( cd "$r" && git add -A )
    gg_run_gate_log "$r" /tmp/gg_yaml.$$; rc=$?
    t_expect_rc 1 "$rc" "invalid YAML blocks (validate.yaml=block)"
    grep -q "invalid YAML" /tmp/gg_yaml.$$ 2>/dev/null \
      && t_ok "block message names invalid YAML" \
      || t_fail "block message missing invalid YAML"
    rm -f /tmp/gg_yaml.$$; gg_rmrepo "$r"
  else
    t_skip "invalid YAML: python+pyyaml required (pyyaml absent → YAML validation self-skips)"
  fi
}
