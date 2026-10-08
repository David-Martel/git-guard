#!/bin/sh
# Category 23 — the optional native reserved-path inventory
# (hooks/common/reserved_path_inventory.rs) is qualified before the hook uses it.
#
# Behaviour protected: the Rust source's own filesystem fixtures compile with
# warnings denied and pass; formatting is clean; a repository cannot select the
# compiler through rust-toolchain files or a repo-local PATH entry; an
# unavailable or failing toolchain falls back to the POSIX scan without
# downloading or blocking; the hook's runtime build caps lints at warn.
#
# What a failure means: the hook compiles and runs this helper inside every
# repository on commit. A repo-selected compiler is code execution chosen by the
# repository; a build that denies warnings turns a new compiler lint into a
# blocked commit everywhere.
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

  # A repository controls rust-toolchain files, not the hook's compiler. These
  # exercise the real rustup shim without installing/overriding any toolchain.
  gg_inventory_hook="$GG_ROOT/hooks/common/nul-cleanup.sh"
  if ! gg_inventory_repo="$(gg_mktemp_repo)"; then
    t_fail "cannot allocate the isolated compiler-selection fixture"
    return
  fi
  case "$gg_inventory_repo" in
    "$GG_T_TMPROOT"/*) : ;;
    *) t_fail "compiler-selection fixture escaped the suite scratch"; return ;;
  esac
  gg_inventory_rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
  gg_inventory_log="$GG_T_TMPROOT/inventory-toolchain.log"
  if command -v rustup >/dev/null 2>&1 &&
    cmp -s "$(command -v rustc)" "$(command -v rustup)"; then
    for gg_inventory_config in rust-toolchain.toml rust-toolchain; do
      if [ "$gg_inventory_config" = rust-toolchain.toml ]; then
        printf '[toolchain]\nchannel = "nightly-2099-01-01"\n' > "$gg_inventory_repo/$gg_inventory_config"
      else
        printf 'nightly-2099-01-01\n' > "$gg_inventory_repo/$gg_inventory_config"
      fi
      : > "$gg_inventory_repo/NUL.txt"
      (cd "$gg_inventory_repo" && unset RUSTUP_TOOLCHAIN &&
        RUSTUP_HOME="$gg_inventory_rustup_home" RUSTUP_AUTO_INSTALL=0 \
        sh "$gg_inventory_hook" >"$gg_inventory_log" 2>&1)
      gg_inventory_rc=$?
      if [ "$gg_inventory_rc" = 0 ] && [ ! -e "$gg_inventory_repo/NUL.txt" ] &&
        grep -q '^INVENTORY_OK:' "$gg_inventory_log"; then
        t_ok "repo $gg_inventory_config cannot select an unavailable compiler"
      else
        t_fail "repo $gg_inventory_config changed the inventory compiler"
        cat "$gg_inventory_log" >&2
      fi
      rm -f "$gg_inventory_repo/$gg_inventory_config"
    done

    gg_inventory_marker_toolchain="$gg_inventory_repo/marker-toolchain"
    gg_inventory_marker="$GG_T_TMPROOT/repo-compiler-ran"
    mkdir -p "$gg_inventory_marker_toolchain/bin" "$gg_inventory_marker_toolchain/lib"
    cat > "$gg_inventory_marker_toolchain/bin/rustc" <<'EOF'
#!/bin/sh
: > "$GG_INVENTORY_MARKER"
printf '%s\n' 'REPO_COMPILER_MARKER: repository compiler executed' >&2
exit 79
EOF
    chmod +x "$gg_inventory_marker_toolchain/bin/rustc"
    printf '[toolchain]\npath = "%s"\n' "$gg_inventory_marker_toolchain" > "$gg_inventory_repo/rust-toolchain.toml"
    for gg_inventory_temp_mode in outside nested relative; do
      if [ "$gg_inventory_temp_mode" = nested ]; then
        gg_inventory_temp="$gg_inventory_repo/private-temp"
      elif [ "$gg_inventory_temp_mode" = relative ]; then
        gg_inventory_temp=private-relative-temp
        mkdir -p "$gg_inventory_repo/$gg_inventory_temp"
      else
        gg_inventory_temp="$GG_T_TMPROOT/neutral-temp"
      fi
      if [ "$gg_inventory_temp_mode" != relative ]; then mkdir -p "$gg_inventory_temp"; fi
      rm -f "$gg_inventory_marker"
      : > "$gg_inventory_repo/NUL.txt"
      (cd "$gg_inventory_repo" && unset RUSTUP_TOOLCHAIN &&
        RUSTUP_HOME="$gg_inventory_rustup_home" RUSTUP_AUTO_INSTALL=0 \
        GG_INVENTORY_MARKER="$gg_inventory_marker" TMPDIR="$gg_inventory_temp" \
        sh "$gg_inventory_hook" >"$gg_inventory_log" 2>&1)
      gg_inventory_rc=$?
      if [ "$gg_inventory_rc" = 0 ] && [ ! -e "$gg_inventory_marker" ] &&
        [ ! -e "$gg_inventory_repo/NUL.txt" ] && grep -q '^INVENTORY_OK:' "$gg_inventory_log"; then
        t_ok "repo path compiler ignored with $gg_inventory_temp_mode TMPDIR"
      else
        t_fail "repo path compiler selected with $gg_inventory_temp_mode TMPDIR"
        cat "$gg_inventory_log" >&2
      fi
    done

    # Explicit caller selection is still authoritative and is never fetched, but
    # a missing selection is toolchain trouble: it must not block the commit.
    # The hook warns and the POSIX scan does the cleanup instead.
    : > "$gg_inventory_repo/NUL.txt"
    (cd "$gg_inventory_repo" && RUSTUP_HOME="$gg_inventory_rustup_home" \
      RUSTUP_TOOLCHAIN=nightly-2099-01-01 RUSTUP_AUTO_INSTALL=0 \
      sh "$gg_inventory_hook" >"$gg_inventory_log" 2>&1)
    gg_inventory_rc=$?
    if [ "$gg_inventory_rc" = 0 ] && [ ! -e "$gg_inventory_repo/NUL.txt" ] &&
      grep -q 'WARN_INVENTORY_BUILD' "$gg_inventory_log" &&
      grep -q 'not installed' "$gg_inventory_log" &&
      grep -q 'REMOVED_ZERO_BYTE:' "$gg_inventory_log" &&
      ! grep -Eq 'syncing channel|downloading|INVENTORY_OK:' "$gg_inventory_log"; then
      t_ok "explicit unavailable toolchain falls back to the POSIX scan without downloading"
    else
      t_fail "explicit unavailable toolchain was downloaded, blocked or skipped the fallback"
      cat "$gg_inventory_log" >&2
    fi
  else
    t_skip "rustup shim not selected; repository-local toolchain fixtures unavailable"
  fi

  # A real selected compiler failure is surfaced but does not block: the POSIX
  # scan takes over. The wrapper records the actual environment, cwd and
  # arguments rather than pretending to produce an inventory.
  gg_inventory_fail_bin="$GG_T_TMPROOT/failing-compiler"
  gg_inventory_env_log="$GG_T_TMPROOT/compiler-environment.log"
  mkdir -p "$gg_inventory_fail_bin"
  cat > "$gg_inventory_fail_bin/rustc" <<'EOF'
#!/bin/sh
printf '%s\n' "$RUSTUP_TOOLCHAIN" "$RUSTUP_HOME" "$RUSTUP_AUTO_INSTALL" "$(pwd -P)" > "$GG_INVENTORY_ENV_LOG"
printf ' %s ' "$*" > "$GG_INVENTORY_ENV_LOG.args"
printf '%s\n' 'FIXTURE_COMPILE_FAILURE: selected compiler failed' >&2
exit 47
EOF
  chmod +x "$gg_inventory_fail_bin/rustc"
  : > "$gg_inventory_repo/NUL.txt"
  (cd "$gg_inventory_repo" && PATH="$gg_inventory_fail_bin:$PATH" \
    RUSTUP_TOOLCHAIN=caller-selected RUSTUP_HOME="$gg_inventory_rustup_home" \
    RUSTUP_AUTO_INSTALL=1 GG_INVENTORY_ENV_LOG="$gg_inventory_env_log" \
    sh "$gg_inventory_hook" >"$gg_inventory_log" 2>&1)
  gg_inventory_rc=$?
  if [ "$gg_inventory_rc" = 0 ] && [ ! -e "$gg_inventory_repo/NUL.txt" ] &&
    grep -q 'FIXTURE_COMPILE_FAILURE' "$gg_inventory_log" &&
    grep -q 'WARN_INVENTORY_BUILD' "$gg_inventory_log" &&
    grep -q 'REMOVED_ZERO_BYTE:' "$gg_inventory_log" &&
    ! grep -q 'INVENTORY_OK:' "$gg_inventory_log"; then
    t_ok "selected helper compile failure is shown and the POSIX scan takes over"
  else t_fail "helper compile failure blocked or skipped the POSIX fallback"; fi
  # The hook's runtime build must not deny warnings: a lint that a newer rustc
  # makes warn-by-default would otherwise block every commit on that host.
  gg_inventory_args="$(cat "$gg_inventory_env_log.args" 2>/dev/null)"
  case "$gg_inventory_args" in
    *' --cap-lints warn '*)
      case "$gg_inventory_args" in
        *' -D '*|*' -Dwarnings '*|*' --deny '*) t_fail "hook runtime build still denies warnings" ;;
        *) t_ok "hook runtime build caps lints at warn and denies nothing" ;;
      esac ;;
    *) t_fail "hook runtime build does not cap lints at warn" ;;
  esac
  printf '%s\n' caller-selected "$gg_inventory_rustup_home" 0 / > "$GG_T_TMPROOT/compiler-environment.expected"
  if cmp -s "$gg_inventory_env_log" "$GG_T_TMPROOT/compiler-environment.expected"; then
    t_ok "neutral cwd and no auto-install preserve explicit Rustup authority"
  else t_fail "compiler cwd/environment escaped the neutral authority contract"; fi
  gg_rmrepo "$gg_inventory_repo"
}
