#!/bin/sh
# Category 37 — upstream vendor API policy must not suppress authored API checks.
# Review and red/green procedure: ../docs/VENDOR_GLOB_REVIEW.md.
# shellcheck shell=sh

# Protects: only exact vendor/ directory components are outside this style rule.
# Detects: accidental vendor rejection or a broad exclusion hiding authored Rust.
# Needs: genuine ast-grep; missing CLI is reported as SKIP, never a passing scan.
# Breadcrumb: rules-examples/rust/no-glob-reexport.yml (rule and path filtering).
t_case_vendor_glob_paths() {
  t_begin "37 vendor glob boundary: real per-rule path selection"
  if ! gg_has_astgrep; then t_skip "vendor path matrix: genuine ast-grep absent"; return; fi
  if have ast-grep && ast-grep --version 2>/dev/null | grep -qi ast-grep; then
    _vgb_sg=ast-grep
  else
    _vgb_sg=sg
  fi
  _vgb_dir="$(mktemp -d "$GG_T_TMPROOT/vendor-paths.XXXXXX")" || return 1
  while read -r _vgb_expected _vgb_path; do
    mkdir -p "$_vgb_dir/$(dirname "$_vgb_path")"
    printf 'pub use inner::*;\n' > "$_vgb_dir/$_vgb_path"
    ( cd "$_vgb_dir" && "$_vgb_sg" scan \
      --rule "$GG_BUNDLED/rust/no-glob-reexport.yml" --json=compact "$_vgb_path" \
      > scan.json 2> scan.err ); _vgb_rc=$?
    case "$_vgb_rc" in
      0|1) ;;
      *) t_fail "ast-grep could not scan $_vgb_path (rc=$_vgb_rc)"; continue ;;
    esac
    _vgb_hits=$(grep -o '"ruleId"' "$_vgb_dir/scan.json" | wc -l | tr -d ' ')
    t_expect_rc "$_vgb_expected" "$_vgb_hits" "no-glob-reexport matches $_vgb_path"
  done <<'PATHS'
0 vendor/candle-core/src/lib.rs
0 Native/pcai_core/vendor/candle-core/src/lib.rs
0 Native/vendor/candle-core/src/lib.rs
1 src/lib.rs
1 Native/pcai_core/pcai_core_lib/src/lib.rs
1 vendor2/src/lib.rs
1 Native/vendor-lookalike/src/lib.rs
1 Native/vendor-bridge/src/lib.rs
1 Native/sibling/src/lib.rs
PATHS
  rm -rf "$_vgb_dir"
}

# Protects: the default composed QA gate accepts upstream vendor glob APIs while
# still refusing an authored glob in the SAME staged change, then accepts repair.
# Detects: an inert rule/cache, a global vendor bypass, or a fix that rewrites the
# upstream source instead of applying a per-rule style boundary.
# Needs: genuine ast-grep and git; real gate, staged paths and isolated rule cache.
# Breadcrumb: hooks/common/qa_gate.sh qa_astgrep_run + no-glob-reexport.yml.
t_case_vendor_glob_gate() {
  t_begin "37 vendor glob boundary: composed staged QA gate"
  if ! gg_has_astgrep; then t_skip "vendor composed gate: genuine ast-grep absent"; return; fi
  _vgb_repo="$(gg_mktemp_repo)" || return 1
  _vgb_log="$(gg_tmp_log)"
  mkdir -p "$_vgb_repo/Native/pcai_core/vendor/candle-core/src" "$_vgb_repo/src"
  printf 'pub use inner::*;\n' > "$_vgb_repo/Native/pcai_core/vendor/candle-core/src/lib.rs"
  cp "$_vgb_repo/Native/pcai_core/vendor/candle-core/src/lib.rs" "$GG_T_TMPROOT/vendor-preimage.rs"
  printf 'pub use inner::a;\n' > "$_vgb_repo/src/lib.rs"
  ( cd "$_vgb_repo" && git add -A )
  gg_run_gate_log "$_vgb_repo" "$_vgb_log"; _vgb_rc=$?
  t_expect_rc 0 "$_vgb_rc" "vendor glob and named authored re-export pass default gate"
  printf 'pub use inner::*;\n' > "$_vgb_repo/src/lib.rs"
  ( cd "$_vgb_repo" && git add src/lib.rs )
  gg_run_gate_log "$_vgb_repo" "$_vgb_log"; _vgb_rc=$?
  t_expect_rc 1 "$_vgb_rc" "authored glob still blocks beside vendor glob"
  grep -q "no-glob-reexport.*BLOCK trio" "$_vgb_log"
  t_assert $? "composed refusal names the real no-glob-reexport BLOCK rule"
  printf 'pub use inner::a;\n' > "$_vgb_repo/src/lib.rs"
  ( cd "$_vgb_repo" && git add src/lib.rs )
  gg_run_gate_log "$_vgb_repo" "$_vgb_log"; _vgb_rc=$?
  t_expect_rc 0 "$_vgb_rc" "repairing only authored Rust restores acceptance"
  cmp "$GG_T_TMPROOT/vendor-preimage.rs" "$_vgb_repo/Native/pcai_core/vendor/candle-core/src/lib.rs" >/dev/null 2>&1
  t_assert $? "all three real gate executions preserve upstream vendor bytes"
  rm -f "$_vgb_log"
  gg_rmrepo "$_vgb_repo"
}
