#!/bin/sh
#
# git-guard tests -- hooks never feed repository-sized text to a loop through a
# here-document.
#
# Why this exists: on Windows, Git Bash's `sh` (GNU bash 5.3.15, x86_64-pc-cygwin)
# writes a here-document body into a pipe before anything reads it. The pipe holds
# 64 KiB, but bash only switches to a temporary file for bodies of about 65,670
# bytes and more, so a body of 65,537 to about 65,670 bytes blocks the writer
# forever at ~0 CPU. On 2026-11-27 the pre-push hook hung for 45 and then 23
# minutes on a stm32n6570 commit whose `git log -p -U0` scan text was 65,588 bytes.
# secret_scan.sh fed its whole diff to the line loop that way, in both the staged
# (pre-commit) and the `--commits` (pre-push) modes, and precommit-provider.sh fed
# its submodule loop the full `git ls-tree -r` listing the same way.
#
# Each fixture below is calibrated to about 65,600 bytes of loop input, measured
# with the hook's own git command, and the case FAILS if the calibration leaves
# the 65,537-65,670 window, so fixture drift cannot turn the check into one that
# always passes. Every hook run is bounded by timeout(1): before the fix the runs
# returned 124 on Git Bash. Other shells (dash, Linux bash) do not deadlock in
# this window, so there the case still checks findings, exit codes and cleanup.
#
# Planted secrets are ASSEMBLED FROM FRAGMENTS at run time (see 10-secret-scan.t.sh).

_hw_target=65600
_hw_lo=65537
_hw_hi=65670

# _hw_write FILE FIRST_LEN LAST_LINE -- a first line of FIRST_LEN 'a' characters,
# 1000 lines of 60, then LAST_LINE. No line holds a scanner trigger substring
# except LAST_LINE, which sits last so a truncated loop input cannot reach it.
_hw_write() {
  awk -v n="$2" -v last="$3" 'BEGIN {
    s = ""; for (i = 0; i < n; i++) s = s "a"; print s
    s = ""; for (i = 0; i < 60; i++) s = s "a"
    for (i = 0; i < 1000; i++) print s
    print last
  }' > "$1"
}

# _hw_size REPO MODE -- bytes of the text secret_scan.sh loops over: the scan of
# HEAD for MODE=commits (the exact gg_scan_commits invocation), else the staged diff.
_hw_size() {
  if [ "$2" = commits ]; then
    git -C "$1" log --no-walk=unsorted --root -m --first-parent -p -U0 --diff-filter=ACMR \
      --no-color --no-ext-diff --no-show-signature --format='git-guard-commit %H' HEAD -- | wc -c
  else
    git -C "$1" diff --cached -U0 --diff-filter=ACMR --no-color | wc -c
  fi
}

# _hw_commit REPO -- make the index the root commit at HEAD. Plumbing, like
# 10-secret-scan.t.sh, so the host's own hooks never judge a fixture.
_hw_commit() {
  _hw_tree="$(git -C "$1" write-tree)" || return 1
  _hw_c="$(printf 'fixture\n' | git -C "$1" commit-tree "$_hw_tree")" || return 1
  git -C "$1" update-ref HEAD "$_hw_c"
}

# _hw_record REPO MODE -- stage big.txt; for MODE=commits make it the root commit.
_hw_record() {
  ( cd "$1" && git add big.txt ) >/dev/null 2>&1 || return 1
  [ "$2" = commits ] || return 0
  _hw_commit "$1"
}

# _hw_fixture REPO MODE LAST_LINE -- write big.txt so the loop input is about
# _hw_target bytes; set _hw_bytes to the measured size. Fails outside the window.
_hw_fixture() {
  _hw_bytes=0
  _hw_write "$1/big.txt" 1 "$3"
  _hw_record "$1" "$2" || return 1
  _hw_bytes="$(_hw_size "$1" "$2" | tr -d ' ')"
  _hw_write "$1/big.txt" $((1 + _hw_target - _hw_bytes)) "$3"
  _hw_record "$1" "$2" || return 1
  _hw_bytes="$(_hw_size "$1" "$2" | tr -d ' ')"
  [ "$_hw_bytes" -ge "$_hw_lo" ] && [ "$_hw_bytes" -le "$_hw_hi" ]
}

# _hw_scan REPO TMPDIR [ARGS...] -- run secret_scan.sh under a timeout with a
# private TMPDIR; set _hw_rc and _hw_out.
_hw_scan() {
  _hw_repo="$1"; _hw_tmp="$2"; shift 2
  _hw_out="$(cd "$_hw_repo" && TMPDIR="$_hw_tmp" timeout -k 5 "${GG_HEREDOC_TIMEOUT:-90}" \
    sh "$GG_ROOT/hooks/common/secret_scan.sh" "$@" 2>&1)"
  _hw_rc=$?
}

# _hw_empty_dir DIR LABEL -- the scan left no temporary file behind.
_hw_empty_dir() {
  if [ -z "$(ls -A "$1" 2>/dev/null)" ]; then t_ok "$2 leaves no temporary file"
  else t_fail "$2 left files in its TMPDIR: $(ls -A "$1")"; fi
}

t_case_heredoc_pipe_window() {
  t_begin "44 hooks finish when their loop input is 65,537-65,670 bytes"

  if ! have git || ! have awk || ! have timeout; then
    t_skip "heredoc pipe window: git, awk or timeout absent"
    return 0
  fi

  _hw_aws="AKIA"; _hw_aws_b="QWERTYUIOPASDFGH"
  _hw_hit="aws_key = \"${_hw_aws}${_hw_aws_b}\""   # pragma: allowlist secret
  _hw_clean="$(printf '%s' "$_hw_hit" | tr -c 'c' 'c')"
  _hw_priv="$GG_T_TMPROOT/hw-tmp"
  mkdir -p "$_hw_priv"

  # ---- pre-push: --commits on an in-window commit that carries a token --------
  _r="$(gg_mktemp_repo)" || return 99
  if _hw_fixture "$_r" commits "$_hw_hit"; then
    t_ok "commit scan text calibrated into the window ($_hw_bytes bytes)"
  else
    t_fail "commit scan text is $_hw_bytes bytes, outside $_hw_lo-$_hw_hi; recalibrate the fixture"
  fi
  _sha="$(git -C "$_r" rev-parse HEAD)"
  _hw_scan "$_r" "$_hw_priv" --commits "$_sha"
  case "$_hw_rc:$_hw_out" in
    1:*"big.txt:1002 (AWS access key) in commit $_sha"*)
      t_ok "--commits completes and blocks the planted token (rc=1)" ;;
    124:*|137:*) t_fail "--commits hung on in-window scan text (rc=$_hw_rc)" ;;
    *) t_fail "--commits on an in-window hit: rc=$_hw_rc, output: $_hw_out" ;;
  esac
  _hw_empty_dir "$_hw_priv" "--commits hit"

  # A temporary file that cannot be created must block, never pass silently.
  _hw_scan "$_r" "$GG_T_TMPROOT/hw-no-such-dir" --commits "$_sha"
  case "$_hw_rc:$_hw_out" in
    1:*"git-guard BLOCKED: secret scan could not create a temporary file"*"Nothing was pushed."*)
      t_ok "--commits blocks when its temporary file cannot be created (rc=1)" ;;
    *) t_fail "--commits with an unusable TMPDIR: rc=$_hw_rc, output: $_hw_out" ;;
  esac
  gg_rmrepo "$_r"

  # ---- pre-push: the same size with no token passes ---------------------------
  _r="$(gg_mktemp_repo)" || return 99
  if _hw_fixture "$_r" commits "$_hw_clean"; then
    t_ok "clean commit scan text calibrated into the window ($_hw_bytes bytes)"
  else
    t_fail "clean commit scan text is $_hw_bytes bytes, outside $_hw_lo-$_hw_hi"
  fi
  _hw_scan "$_r" "$_hw_priv" --commits "$(git -C "$_r" rev-parse HEAD)"
  t_expect_rc 0 "$_hw_rc" "--commits completes and passes a clean in-window commit"
  _hw_empty_dir "$_hw_priv" "--commits clean"
  gg_rmrepo "$_r"

  # ---- pre-commit: the staged diff takes the same loop ------------------------
  _r="$(gg_mktemp_repo)" || return 99
  if _hw_fixture "$_r" staged "$_hw_hit"; then
    t_ok "staged diff calibrated into the window ($_hw_bytes bytes)"
  else
    t_fail "staged diff is $_hw_bytes bytes, outside $_hw_lo-$_hw_hi"
  fi
  _hw_scan "$_r" "$_hw_priv"
  case "$_hw_rc:$_hw_out" in
    1:*"big.txt:1002 (AWS access key). Your changes are STAGED"*)
      t_ok "staged scan completes and blocks the planted token (rc=1)" ;;
    124:*|137:*) t_fail "staged scan hung on an in-window diff (rc=$_hw_rc)" ;;
    *) t_fail "staged scan on an in-window hit: rc=$_hw_rc, output: $_hw_out" ;;
  esac
  _hw_empty_dir "$_hw_priv" "staged hit"
  _hw_scan "$_r" "$GG_T_TMPROOT/hw-no-such-dir"
  case "$_hw_rc:$_hw_out" in
    1:*"git-guard BLOCKED: secret scan could not create a temporary file"*"Staged work is preserved."*)
      t_ok "staged scan blocks when its temporary file cannot be created (rc=1)" ;;
    *) t_fail "staged scan with an unusable TMPDIR: rc=$_hw_rc, output: $_hw_out" ;;
  esac
  gg_rmrepo "$_r"

  # ---- precommit-provider: an in-window `git ls-tree -r` listing ----------------
  # Each record is "100644 blob <40 hex> TAB <path> LF", 54 bytes plus the path.
  # 1038 nine-character names and the config come to about 65,470 bytes; one
  # filler file, its name sized from the measured listing, makes up the rest.
  _r="$(gg_mktemp_repo)" || return 99
  _hw_bin="$GG_T_TMPROOT/hw-framework-bin"
  _hw_marker="$GG_T_TMPROOT/hw-framework-calls"
  mkdir -p "$_hw_bin"
  _hw_bin="$(cd "$_hw_bin" && pwd)"
  printf '#!/bin/sh\nprintf "framework\\n" >> "%s"\ncat > /dev/null\nexit 0\n' "$_hw_marker" > "$_hw_bin/pre-commit"
  chmod +x "$_hw_bin/pre-commit"
  : > "$_hw_marker"
  printf 'repos: []\n' > "$_r/.pre-commit-config.yaml"
  awk -v d="$_r" 'BEGIN { for (i = 1; i <= 1038; i++) { f = sprintf("%s/p%04d.txt", d, i); print "x" > f; close(f) } }'
  ( cd "$_r" && git add -A ) >/dev/null 2>&1
  _hw_commit "$_r"
  _hw_bytes="$(git -C "$_r" -c core.quotePath=false ls-tree -r HEAD | wc -c | tr -d ' ')"
  _hw_fill="$(awk -v n=$((_hw_target - _hw_bytes - 54 - 4)) 'BEGIN { s = ""; for (i = 0; i < n; i++) s = s "z"; print s ".txt" }')"
  printf 'x\n' > "$_r/$_hw_fill"
  ( cd "$_r" && git add -A ) >/dev/null 2>&1
  _hw_commit "$_r"
  _hw_bytes="$(git -C "$_r" -c core.quotePath=false ls-tree -r HEAD | wc -c | tr -d ' ')"
  if [ "$_hw_bytes" -ge "$_hw_lo" ] && [ "$_hw_bytes" -le "$_hw_hi" ]; then
    t_ok "tree listing calibrated into the window ($_hw_bytes bytes)"
  else
    t_fail "tree listing is $_hw_bytes bytes, outside $_hw_lo-$_hw_hi; recalibrate the fixture"
  fi
  _hw_zero=0000000000000000000000000000000000000000
  _hw_out="$(printf 'refs/heads/main %s refs/heads/main %s\n' "$(git -C "$_r" rev-parse HEAD)" "$_hw_zero" |
    (cd "$_r" && TMPDIR="$_hw_priv" PATH="$_hw_bin:$PATH" timeout -k 5 "${GG_HEREDOC_TIMEOUT:-90}" \
      sh "$GG_ROOT/hooks/common/precommit-provider.sh" pre-push origin 'inert://no-network') 2>&1)"
  _hw_rc=$?
  case "$_hw_rc" in
    0) t_ok "precommit-provider pre-push completes on an in-window tree (rc=0)" ;;
    124|137) t_fail "precommit-provider hung on an in-window tree listing (rc=$_hw_rc)" ;;
    *) t_fail "precommit-provider on an in-window tree: rc=$_hw_rc, output: $_hw_out" ;;
  esac
  if [ -s "$_hw_marker" ]; then t_ok "precommit-provider ran the framework after the gitlink walk"
  else t_fail "precommit-provider did not run the framework"; fi
  _hw_empty_dir "$_hw_priv" "precommit-provider"
  gg_rmrepo "$_r"
}
