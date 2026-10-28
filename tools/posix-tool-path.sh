# shellcheck shell=sh
#
# gg_posix_tool_path — on Git Bash / MSYS2 / Cygwin, put the shell's own POSIX
# tool directory ahead of PATH for THIS process and its children.
#
# Sourced by install.sh and tests/run.sh before they run any external tool.
#
# Why: a Windows PATH may deliberately list native Windows builds of coreutils
# (uutils-style env, cp, mv, rm, ln, readlink, mktemp, ls, uname) ahead of Git
# Bash's /usr/bin. Inside Git Bash those shadow the POSIX tools this code was
# written against. Observed 2026-10-28 on dtm-p1gen9 with ~/bin first on PATH:
#   * install.sh: the shadowing `mv` reports a --version but rejects `-T`, so
#     the atomic `current` swap fails and leaves a stray `.current.tmp.*` link;
#     its `cp` cannot overwrite an existing file (os error 80).
#   * tests/run.sh: the shadowing `mktemp` returns a `C:/...` path, and its
#     drive colon splits every PATH built from the temp root, so stub tools
#     vanish and nearly every `env PATH=...` case exits 127.
#   * the shadowing `uname -s` prints `Windows_NT`, so a MINGW*/MSYS* match
#     (install.sh's native-symlink mode) misses the host altogether.
#
# Detection accepts MSYSTEM (set by every Git Bash / MSYS2 login shell) or a
# Windows-like `uname -s`, including the shadowing build's `Windows_NT`. PATH is
# only rewritten when one of the tools above resolves outside /usr/bin and /bin,
# so an ordinary Git Bash keeps its PATH order. Linux, WSL and macOS are never
# touched. Only shell builtins run before the rewrite (besides the probed
# `uname`), because any external tool may be the shadowing one.
#
# GIT_GUARD_POSIX_PATH_SET=1 is exported once the check has run. A nested entry
# point (a test case running install.sh with a stub tool deliberately first on
# PATH) then keeps its caller's PATH instead of burying the stub behind /usr/bin.
# Exporting it yourself turns this adjustment off.

gg_posix_tool_path() {
  [ -z "${GIT_GUARD_POSIX_PATH_SET:-}" ] || return 0
  if [ -z "${MSYSTEM:-}" ]; then
    case "$(uname -s 2>/dev/null)" in
      MINGW*|MSYS*|CYGWIN*|Windows_NT) : ;;
      *) return 0 ;;
    esac
  fi
  # no-op if: the shell has no POSIX tool directory to prefer.
  [ -x /usr/bin/mv ] && [ -x /usr/bin/mktemp ] || return 0

  gg_ptp_shadowed=0
  for gg_ptp_tool in env cp mv rm ln readlink mktemp ls uname; do
    gg_ptp_found="$(command -v "$gg_ptp_tool" 2>/dev/null)" || continue
    case "$gg_ptp_found" in
      /usr/bin/*|/bin/*) : ;;
      *) gg_ptp_shadowed=1 ;;
    esac
  done
  if [ "$gg_ptp_shadowed" = 1 ]; then
    # /bin is normally the same mount as /usr/bin on MSYS2; add it only when it
    # is a distinct directory.
    gg_ptp_usr="$(cd /usr/bin 2>/dev/null && pwd -P)"
    gg_ptp_bin="$(cd /bin 2>/dev/null && pwd -P)"
    if [ -n "$gg_ptp_bin" ] && [ "$gg_ptp_bin" != "$gg_ptp_usr" ]; then
      PATH="/usr/bin:/bin:$PATH"
    else
      PATH="/usr/bin:$PATH"
    fi
    export PATH
  fi

  # A temp root must be a POSIX path: a drive colon in it breaks PATH lists.
  case "${TMPDIR:-}" in
    '') TMPDIR=/tmp ;;
    [A-Za-z]:*)
      if gg_ptp_tmp="$(cygpath -u "$TMPDIR" 2>/dev/null)" && [ -n "$gg_ptp_tmp" ]; then
        TMPDIR="$gg_ptp_tmp"
      else
        TMPDIR=/tmp
      fi
      ;;
  esac
  export TMPDIR

  GIT_GUARD_POSIX_PATH_SET=1
  export GIT_GUARD_POSIX_PATH_SET
  unset gg_ptp_shadowed gg_ptp_tool gg_ptp_found gg_ptp_usr gg_ptp_bin gg_ptp_tmp
}
