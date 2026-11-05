#!/bin/sh
# Category 41 — install.sh replaces a real (legacy) ~/.git-hooks directory
# instead of leaving it in use, even when a backup already exists.
#
# Why: on Carbon (2026-11-05) ~/.git-hooks was a stale REAL directory holding
# an old 959-byte pre-push, and ~/.git-hooks.pre-git-guard-backup already
# existed, so the installer refused (Windows) and the stale hooks kept running.
# The versioned install never moved a real directory at all: `ln -sfn` planted
# the link inside it. Now the directory moves to .pre-git-guard-backup, or to
# .pre-git-guard-backup.<UTC timestamp> when that exists; no backup is ever
# deleted, and a failed Windows install moves the timestamped copy back.
#
# Everything runs in a clone of this repository with an isolated HOME and
# GIT_CONFIG_GLOBAL. The tag is created in that clone only.
# shellcheck shell=sh

# t_rot_install LOG [ENV...] — run the installer under test in the isolated HOME.
t_rot_install() {
  _l="$1"; shift
  ( export HOME="$rot_home" GIT_CONFIG_GLOBAL="$rot_home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
    unset MSYS
    env "$@" sh "$rot_src/install.sh" --to "$rot_tag" ) > "$_l" 2>&1
}

# t_rot_check MSG TEST... — run a test command, record ok/FAIL under MSG.
t_rot_check() {
  _msg="$1"; shift
  if "$@"; then t_ok "$_msg"; else t_fail "$_msg"; fi
}

t_case_install_rotates_legacy_hooks() {
  t_begin "41 install: a legacy real ~/.git-hooks is rotated aside, never left in use"
  if ! have tar; then t_skip "tar absent — cannot exercise git archive | tar -x"; return 0; fi
  rot_windows=0
  case "$(uname -s 2>/dev/null || echo)" in
    MINGW*|MSYS*)
      rot_windows=1
      if ! have pwsh || ! have cygpath; then
        t_skip "PowerShell7 and cygpath required for the Windows installer"; return 0
      fi ;;
  esac

  rot_root="$(mktemp -d "$GG_T_TMPROOT/rotate41.XXXXXX")" || { t_fail "mktemp"; return 1; }
  rot_src="$rot_root/source"
  if ! git -c core.autocrlf=false clone -q --no-hardlinks "$GG_ROOT" "$rot_src"; then
    t_fail "could not create an isolated installer source clone"; return 1
  fi
  # The installer under test is this checkout's; the release it installs is the clone's HEAD.
  cp "$GG_ROOT/install.sh" "$rot_src/install.sh"
  mkdir -p "$rot_src/tools/windows"
  cp "$GG_ROOT/tools/windows/set-hooks-config.ps1" "$rot_src/tools/windows/set-hooks-config.ps1"
  cp "$GG_ROOT/tools/posix-tool-path.sh" "$rot_src/tools/posix-tool-path.sh"
  rot_tag="gg-rotate41"
  git -C "$rot_src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$rot_tag" HEAD

  rot_home="$rot_root/home"
  rot_hooks="$rot_home/.git-hooks"
  rot_bk="$rot_hooks.pre-git-guard-backup"
  mkdir -p "$rot_hooks"
  printf 'first legacy pre-push\n' > "$rot_hooks/pre-push"

  # --- 1. real directory, no backup yet ---------------------------------------
  t_rot_install "$rot_root/first.log"; rc=$?
  t_expect_rc 0 "$rc" "install over a real .git-hooks directory (no backup yet) succeeds"
  t_rot_check "the .git-hooks path is now a link to the release" [ -L "$rot_hooks" ]
  t_rot_check "the linked hooks dir holds the release's pre-commit" [ -x "$rot_hooks/pre-commit" ]
  grep -qx 'first legacy pre-push' "$rot_bk/pre-push" 2>/dev/null
  t_assert $? "the legacy directory moved to .pre-git-guard-backup intact"
  rot_hp="$(GIT_CONFIG_GLOBAL="$rot_home/.gitconfig" git config --global --get core.hooksPath)"
  t_rot_check "core.hooksPath is published" [ -n "$rot_hp" ]

  # --- 2. real directory again, backup already present -------------------------
  rm -f "$rot_hooks"
  mkdir -p "$rot_hooks"
  printf 'second legacy pre-push\n' > "$rot_hooks/pre-push"
  t_rot_install "$rot_root/second.log"; rc=$?
  t_expect_rc 0 "$rc" "install succeeds when .pre-git-guard-backup already exists"
  t_rot_check "the .git-hooks path is a link again, not the stale directory" [ -L "$rot_hooks" ]
  grep -qx 'first legacy pre-push' "$rot_bk/pre-push" 2>/dev/null
  t_assert $? "the earlier backup is untouched"
  rot_stamped=""
  for rot_c in "$rot_bk".*; do
    [ -d "$rot_c" ] && grep -qx 'second legacy pre-push' "$rot_c/pre-push" 2>/dev/null && rot_stamped="$rot_c"
  done
  t_rot_check "the second legacy directory moved to a timestamped backup" [ -n "$rot_stamped" ]
  case "${rot_stamped##*.pre-git-guard-backup.}" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z*) rot_ok=0 ;;
    *) rot_ok=1 ;;
  esac
  t_assert "$rot_ok" "the timestamped backup is named .pre-git-guard-backup.<UTC YYYYmmddTHHMMSSZ>"

  # --- 3. Windows: a failed install restores the timestamped copy --------------
  if [ "$rot_windows" = 1 ]; then
    rm -f "$rot_hooks"
    mkdir -p "$rot_hooks"
    printf 'third legacy pre-push\n' > "$rot_hooks/pre-push"
    rot_bin="$rot_root/bin"; mkdir -p "$rot_bin"
    cat > "$rot_bin/ln" <<'SH'
#!/bin/sh
if [ "$3" = "$GG_ROT_FAIL_PATH" ]; then
  echo 'fixture: native symlink denied at the hooks link' >&2
  exit 77
fi
exec "$GG_ROT_REAL_LN" "$@"
SH
    chmod +x "$rot_bin/ln"
    t_rot_install "$rot_root/third.log" PATH="$rot_bin:$PATH" GG_ROT_REAL_LN="$(command -v ln)" \
      GG_ROT_FAIL_PATH="$rot_hooks"; rc=$?
    t_expect_rc 2 "$rc" "a hooks-link failure after the move is refused"
    t_rot_check "rollback left a real directory at .git-hooks, not a link" [ ! -L "$rot_hooks" ]
    grep -qx 'third legacy pre-push' "$rot_hooks/pre-push" 2>/dev/null
    t_assert $? "rollback moved the timestamped copy back to .git-hooks"
    grep -qx 'first legacy pre-push' "$rot_bk/pre-push" 2>/dev/null
    t_assert $? "rollback left the original backup in place"
    grep -qx 'second legacy pre-push' "$rot_stamped/pre-push" 2>/dev/null
    t_assert $? "rollback left the earlier timestamped backup in place"
    rot_left=0
    for rot_c in "$rot_bk".*; do
      [ -d "$rot_c" ] && grep -qx 'third legacy pre-push' "$rot_c/pre-push" 2>/dev/null && rot_left=1
    done
    t_rot_check "no orphaned copy of the restored directory is left behind" [ "$rot_left" = 0 ]
  else
    t_skip "Windows link-transaction rollback NOT_TESTED off Git Bash (POSIX installs have no transaction)"
  fi

  rm -rf "$rot_root"
}
