#!/bin/sh
# Category 36 — Git Bash PATH shadowing: entry scripts must use POSIX tools.
#
# Protects: install.sh's atomic `current` swap and tests/run.sh's temp root on
#   Git Bash when native Windows coreutils sit ahead of /usr/bin on PATH.
# Detects: an entry script running a shadowing `mv` that rejects `-T`, or a
#   shadowing `mktemp` whose `C:/...` result splits every PATH built from it.
#   Observed 2026-10-28 on dtm-p1gen9 (~/bin first on PATH): `install.sh --to`
#   could not swap `current`, and most `env PATH=...` cases exited 127.
# Needs: tar, /usr/bin/mv and /usr/bin/mktemp; runs on Linux CI because a stub
#   `uname` reports MINGW64, so the Windows-only branch is exercised anywhere.
# Breadcrumb: tools/posix-tool-path.sh, sourced by install.sh and tests/run.sh.
#
# Each end-to-end check runs twice with the same fake tools first on PATH. The
# control has a non-Windows `uname` and no MSYSTEM, so the adjustment stays off
# and the fake tools must break the script; the fixed run must then succeed.
# shellcheck shell=sh

# ptp_fake_bin DIR UNAME — write fake native tools into DIR. `uname` prints
# UNAME; `mv` reports a version but rejects -T; `mktemp` returns a directory
# whose path contains a drive colon. Real tools are reached by absolute path.
ptp_fake_bin() {
  mkdir -p "$1" || return 1
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$1/uname"
  cat > "$1/mv" <<'SH'
#!/bin/sh
for a do
  case "$a" in
    --version) echo 'mv (fake native coreutils) 0.1.0'; exit 0 ;;
    -T) echo "error: unexpected argument '-T' found" >&2; exit 1 ;;
  esac
done
exec "$GG_FAKE_REAL_MV" "$@"
SH
  cat > "$1/mktemp" <<'SH'
#!/bin/sh
"$GG_FAKE_REAL_MKDIR" -p "$GG_FAKE_DRIVE/C:" || exit 1
exec "$GG_FAKE_REAL_MKTEMP" -d "$GG_FAKE_DRIVE/C:/tmp.XXXXXX"
SH
  chmod +x "$1/uname" "$1/mv" "$1/mktemp"
}

t_case_posix_tool_path() {
  t_begin "36 Git Bash PATH shadowing: entry scripts select POSIX tools"

  if ! [ -x /usr/bin/mv ] || ! [ -x /usr/bin/mktemp ]; then
    t_skip "/usr/bin/mv or /usr/bin/mktemp absent — no POSIX tool directory to prefer"
    return 0
  fi
  if ! have tar; then t_skip "tar absent — cannot exercise git archive | tar -x"; return 0; fi

  ptp_root="$(mktemp -d "$GG_T_TMPROOT/posix-path.XXXXXX")" || return 1
  GG_FAKE_REAL_MV="$(command -v mv)"
  GG_FAKE_REAL_MKTEMP="$(command -v mktemp)"
  GG_FAKE_REAL_MKDIR="$(command -v mkdir)"
  GG_FAKE_DRIVE="$ptp_root/drive"
  export GG_FAKE_REAL_MV GG_FAKE_REAL_MKTEMP GG_FAKE_REAL_MKDIR GG_FAKE_DRIVE
  ptp_win="$ptp_root/win-bin"
  ptp_lin="$ptp_root/lin-bin"
  ptp_fake_bin "$ptp_win" MINGW64_NT-10.0-26100 || { t_fail "could not write fake tools"; return 1; }
  ptp_fake_bin "$ptp_lin" Linux || { t_fail "could not write fake tools"; return 1; }
  ptp_helper="$GG_ROOT/tools/posix-tool-path.sh"

  # --- the helper itself -----------------------------------------------------
  ptp_out="$(
    PATH="$ptp_win:$PATH" MSYSTEM='' GIT_GUARD_POSIX_PATH_SET='' TMPDIR=''
    # shellcheck source=tools/posix-tool-path.sh disable=SC1091
    . "$ptp_helper" && gg_posix_tool_path
    printf '%s|%s|%s' "$(command -v mv)" "$GIT_GUARD_POSIX_PATH_SET" "$TMPDIR"
  )"
  case "$ptp_out" in
    /usr/bin/mv\|1\|/tmp|/bin/mv\|1\|/tmp) t_ok "Windows uname: shadowed mv yields to /usr/bin, TMPDIR defaults to /tmp" ;;
    *) t_fail "Windows uname: expected /usr/bin/mv|1|/tmp, got $ptp_out" ;;
  esac

  ptp_out="$(
    PATH="$ptp_win:$PATH" MSYSTEM='' GIT_GUARD_POSIX_PATH_SET='' TMPDIR=''
    PATH="$ptp_root/no-such:$PATH"
    # shellcheck source=tools/posix-tool-path.sh disable=SC1091
    . "$ptp_helper" && gg_posix_tool_path
    printf '%s' "$PATH"
  )"
  case "$ptp_out" in
    /usr/bin:*"$ptp_root/no-such:$ptp_win:"*) t_ok "the adjustment prepends and keeps the caller's PATH order behind it" ;;
    *) t_fail "unexpected adjusted PATH: $ptp_out" ;;
  esac

  ptp_out="$(
    PATH="$ptp_lin:$PATH" MSYSTEM='' GIT_GUARD_POSIX_PATH_SET=''
    # shellcheck source=tools/posix-tool-path.sh disable=SC1091
    . "$ptp_helper" && gg_posix_tool_path
    printf '%s|%s' "$(command -v mv)" "${GIT_GUARD_POSIX_PATH_SET:-unset}"
  )"
  [ "$ptp_out" = "$ptp_lin/mv|unset" ] \
    && t_ok "non-Windows host: PATH is left alone" \
    || t_fail "non-Windows host: PATH changed ($ptp_out)"

  ptp_out="$(
    PATH="$ptp_lin:$PATH" MSYSTEM=MINGW64 GIT_GUARD_POSIX_PATH_SET=''
    # shellcheck source=tools/posix-tool-path.sh disable=SC1091
    . "$ptp_helper" && gg_posix_tool_path
    command -v mv
  )"
  case "$ptp_out" in
    /usr/bin/mv|/bin/mv) t_ok "MSYSTEM alone identifies Git Bash, whatever uname prints" ;;
    *) t_fail "MSYSTEM=MINGW64 did not trigger the adjustment (mv -> $ptp_out)" ;;
  esac

  ptp_out="$(
    PATH="$ptp_win:$PATH" MSYSTEM='' GIT_GUARD_POSIX_PATH_SET=1
    # shellcheck source=tools/posix-tool-path.sh disable=SC1091
    . "$ptp_helper" && gg_posix_tool_path
    command -v mv
  )"
  [ "$ptp_out" = "$ptp_win/mv" ] \
    && t_ok "an already-adjusted parent keeps a nested caller's stub first on PATH" \
    || t_fail "GIT_GUARD_POSIX_PATH_SET=1 did not suppress the adjustment (mv -> $ptp_out)"

  # --- install.sh: atomic current swap ---------------------------------------
  ptp_src="$ptp_root/source"
  if ! git -c core.autocrlf=false clone -q --no-hardlinks "$GG_ROOT" "$ptp_src" >/dev/null 2>&1; then
    t_fail "could not create an isolated installer source clone"; return 1
  fi
  # Run the working-tree installer, as test 27 does, against a committed tag.
  cp "$GG_ROOT/install.sh" "$ptp_src/install.sh"
  mkdir -p "$ptp_src/tools"
  cp "$ptp_helper" "$ptp_src/tools/posix-tool-path.sh"
  ptp_tag="gg-test-posix-path-$$"
  git -C "$ptp_src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$ptp_tag" HEAD

  for ptp_mode in control fixed; do
    ptp_home="$ptp_root/home-$ptp_mode"
    mkdir -p "$ptp_home"
    ptp_store="$ptp_home/.local/share/git-guard"
    if [ "$ptp_mode" = control ]; then ptp_bin="$ptp_lin"; else ptp_bin="$ptp_win"; fi
    (
      export HOME="$ptp_home" GIT_CONFIG_GLOBAL="$ptp_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
      export PATH="$ptp_bin:$PATH" GIT_GUARD_POSIX_PATH_SET=''
      [ "$ptp_mode" = fixed ] || export MSYSTEM=''
      sh "$ptp_src/install.sh" --to "$ptp_tag" --store "$ptp_store" \
        --hooks-link "$ptp_home/.git-hooks" --no-git-defaults
    ) > "$ptp_root/install-$ptp_mode.log" 2>&1
    ptp_rc=$?
    ptp_stray=0
    for ptp_f in "$ptp_store"/.current.tmp.*; do
      if [ -e "$ptp_f" ] || [ -L "$ptp_f" ]; then ptp_stray=1; fi
    done
    if [ "$ptp_mode" = control ]; then
      if [ "$ptp_rc" != 0 ] && grep -q 'atomic current-swap failed' "$ptp_root/install-control.log"; then
        t_ok "control: the fake mv breaks install.sh's swap without the adjustment (rc=$ptp_rc)"
      else
        t_fail "control: fake mv did not break install.sh (rc=$ptp_rc) — this case proves nothing"
        sed 's/^/      /' "$ptp_root/install-control.log" >&2
      fi
    else
      if [ "$ptp_rc" = 0 ] && [ "$(readlink "$ptp_store/current" 2>/dev/null)" = "$ptp_store/$ptp_tag" ] \
          && [ "$ptp_stray" = 0 ]; then
        t_ok "install.sh swaps current atomically with the fake tools first on PATH"
      else
        t_fail "install.sh with shadowing tools: rc=$ptp_rc current=$(readlink "$ptp_store/current" 2>/dev/null) stray=$ptp_stray"
        sed 's/^/      /' "$ptp_root/install-fixed.log" >&2
      fi
    fi
  done

  # --- tests/run.sh: temp root feeds PATH lists ------------------------------
  # downstream_chaining builds a PATH entirely from stub directories under the
  # temp root, so a drive colon in that root makes every stub unreachable.
  for ptp_mode in control fixed; do
    if [ "$ptp_mode" = control ]; then ptp_bin="$ptp_lin"; else ptp_bin="$ptp_win"; fi
    (
      export PATH="$ptp_bin:$PATH" GIT_GUARD_POSIX_PATH_SET=''
      [ "$ptp_mode" = fixed ] || export MSYSTEM=''
      sh "$GG_ROOT/tests/run.sh" downstream_chaining
    ) > "$ptp_root/run-$ptp_mode.log" 2>&1
    ptp_rc=$?
    if [ "$ptp_mode" = control ]; then
      if [ "$ptp_rc" != 0 ] && grep -q 'temp root is not a POSIX path' "$ptp_root/run-control.log"; then
        t_ok "control: the fake mktemp breaks tests/run.sh without the adjustment (rc=$ptp_rc)"
      else
        t_fail "control: fake mktemp did not break tests/run.sh (rc=$ptp_rc) — this case proves nothing"
        sed 's/^/      /' "$ptp_root/run-control.log" >&2
      fi
    else
      if [ "$ptp_rc" = 0 ] && grep -q ', 0 failed,' "$ptp_root/run-fixed.log"; then
        t_ok "tests/run.sh keeps a POSIX temp root with the fake tools first on PATH"
      else
        t_fail "tests/run.sh with shadowing tools: rc=$ptp_rc"
        sed 's/^/      /' "$ptp_root/run-fixed.log" >&2
      fi
    fi
  done
}
