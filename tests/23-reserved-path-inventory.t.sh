#!/bin/sh
# The optional native inventory must have executable filesystem qualification.
# shellcheck shell=sh

t_case_reserved_path_inventory() {
  t_begin "23 read-only Rust reserved-path inventory"
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:aarch64) : ;;
    *) t_skip "native inventory is qualified only for Linux x64/ARM64"; return ;;
  esac
  if ! command -v rustc >/dev/null 2>&1; then
    t_skip "Rust compiler absent; physical POSIX fallback remains covered"
    return
  fi
  gg_inventory_source="$GG_ROOT/hooks/common/reserved_path_inventory.rs"
  gg_inventory_tests="$GG_T_TMPROOT/reserved-inventory-tests"
  gg_inventory_log="$GG_T_TMPROOT/reserved-inventory-tests.log"
  if rustc --edition=2021 --test -D warnings "$gg_inventory_source" -o "$gg_inventory_tests" >"$gg_inventory_log" 2>&1; then
    t_ok "native filesystem fixtures compile with warnings denied"
  else
    t_fail "native filesystem fixtures failed to compile"
    cat "$gg_inventory_log" >&2
    return
  fi
  if "$gg_inventory_tests" --test-threads=1 >"$gg_inventory_log" 2>&1; then
    t_ok "all native filesystem fixtures pass"
  else
    t_fail "native filesystem fixture failed"
    cat "$gg_inventory_log" >&2
  fi
  if command -v rustfmt >/dev/null 2>&1; then
    if rustfmt --edition=2021 --check "$gg_inventory_source" >"$gg_inventory_log" 2>&1; then
      t_ok "native inventory formatting is clean"
    else
      t_fail "native inventory formatting failed"
      cat "$gg_inventory_log" >&2
    fi
  else
    t_skip "rustfmt unavailable"
  fi
}
