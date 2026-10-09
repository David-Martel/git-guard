#!/bin/sh
# Category 20 — git-lfs objects must reach the remote through git-guard's pre-push.
#
# git-guard is installed through core.hooksPath, which makes git ignore the
# repository's own .git/hooks — including the pre-push hook `git lfs install`
# writes there. Observed 2026-09-28 in vigil-ai-tpm: a push carrying an LFS-tracked
# xlsx was rejected by GitHub (GH008 "unknown Git LFS object") because nothing
# uploaded the object; `git lfs push` had to be run by hand. Against a local bare
# remote the push SUCCEEDS and silently leaves the remote with a dangling pointer,
# which is worse. This case asserts the object itself arrives.
# shellcheck shell=sh

t_case_lfs_prepush() {
  t_begin "20 pre-push uploads git-lfs objects under core.hooksPath"
  if ! have git-lfs; then t_skip "git-lfs not installed"; return 0; fi

  r="$(gg_mktemp_repo)"
  remote="$(mktemp -d "${GG_T_TMPROOT:-/tmp}/gg.remote.XXXXXX")"
  git init -q --bare "$remote"
  logf="$(gg_tmp_log)"
  (
    cd "$r" || exit 1
    # --skip-repo: configure the LFS filters only. Letting git-lfs write hooks here
    # would target core.hooksPath (the git-guard checkout itself).
    git lfs install --local --skip-repo >/dev/null 2>&1 || exit 1
    git config core.hooksPath "$GG_ROOT/hooks"
    git remote add origin "$remote"
    git lfs track '*.bin' >/dev/null 2>&1 || exit 1
    printf 'git-guard lfs fixture %s\n' "$$" > payload.bin
    git add .gitattributes payload.bin
    GIT_GUARD=0 git commit -q -m "lfs fixture" || exit 1
    git push -q origin HEAD:refs/heads/main
  ) >/dev/null 2>"$logf"; rc=$?
  t_expect_rc 0 "$rc" "push of an LFS-tracked file through git-guard's pre-push"

  oid="$(cd "$r" && git lfs ls-files --long 2>/dev/null | awk '{print $1; exit}')"
  if [ -z "$oid" ]; then
    t_fail "fixture did not produce an LFS pointer (git lfs ls-files empty)"
  else
    t_ok "fixture produced LFS object $oid"
    obj="$remote/lfs/objects/$(printf '%s' "$oid" | cut -c1-2)/$(printf '%s' "$oid" | cut -c3-4)/$oid"
    if [ -f "$obj" ]; then
      t_ok "LFS object reached the remote"
    else
      t_fail "LFS object did NOT reach the remote (pointer pushed, content missing): $obj"
    fi
  fi

  # The bypass skips git-guard's gates, not LFS uploads: data must still arrive.
  (
    cd "$r" || exit 1
    printf 'second %s\n' "$$" > payload2.bin
    git add payload2.bin
    GIT_GUARD=0 git commit -q -m "lfs fixture 2" || exit 1
    GIT_GUARD=0 git push -q origin HEAD:refs/heads/main
  ) >/dev/null 2>>"$logf"
  oid2="$(cd "$r" && git lfs ls-files --long 2>/dev/null | awk '$3=="payload2.bin"{print $1}')"
  if [ -n "$oid2" ] && [ -f "$remote/lfs/objects/$(printf '%s' "$oid2" | cut -c1-2)/$(printf '%s' "$oid2" | cut -c3-4)/$oid2" ]; then
    t_ok "GIT_GUARD=0 push still uploads LFS objects"
  else
    t_fail "GIT_GUARD=0 push left the LFS object behind"
  fi

  # The BLOCK branch: an LFS repo pushed from a host WITHOUT git-lfs must refuse
  # loudly instead of pushing dangling pointers. Invoke the hook directly with a
  # PATH holding only the tools it needs, none of them git-lfs.
  nolfs="$(mktemp -d "${GG_T_TMPROOT:-/tmp}/gg.nolfs.XXXXXX")"
  # Use real transport executables on MSYS, not user launchers whose own
  # lookup fails in the deliberately restricted PATH. These are the closure
  # used by pre-push and its identity/preservation/hygiene helpers.
  for tool in git sh cat mktemp rm printf dirname env awk grep sed cut tr sort wc uname date sleep find head tail; do
    tp="$(command -v "$tool" 2>/dev/null)"
    if gg_is_windows; then
      case "$tool" in
        git) tp=/mingw64/bin/git.exe ;;
        sh) tp=/usr/bin/sh.exe ;;
        *) [ ! -x "/usr/bin/$tool.exe" ] || tp="/usr/bin/$tool.exe" ;;
      esac
    fi
    if [ -x "$tp" ]; then
      if gg_is_windows; then
        # MSYS ln -s may copy the executable rather than create a native link.
        # The relocated executable cannot find its DLLs in the restricted PATH.
        # Execute the original in place, retaining its real DLL provenance.
        printf '#!/bin/sh\nexec "%s" "$@"\n' "$tp" > "$nolfs/$tool"
        chmod +x "$nolfs/$tool"
      else
        ln -s "$tp" "$nolfs/$tool"
      fi
    fi
  done
  PATH="$nolfs" sh -c 'git --version >/dev/null' || t_fail "restricted PATH transport could not execute real Git"
  if [ -x "$nolfs/git-lfs" ] || PATH="$nolfs" command -v git-lfs >/dev/null 2>&1; then
    t_fail "test PATH unexpectedly still resolves git-lfs"
  else
    blog="$(gg_tmp_log)"
    ( cd "$r" && PATH="$nolfs" sh "$GG_ROOT/hooks/pre-push" origin "$remote" \
        </dev/null >/dev/null 2>"$blog" ); rc=$?
    if [ "$rc" -ne 0 ]; then t_ok "pre-push refuses an LFS repo when git-lfs is missing (rc=$rc)"
    else t_fail "pre-push did NOT refuse an LFS repo without git-lfs"; fi
    if grep -q "git-lfs is NOT installed" "$blog" 2>/dev/null; then
      t_ok "missing git-lfs BLOCK message surfaced"
    else
      t_fail "missing git-lfs BLOCK message absent"
    fi
    # Control: the same restricted PATH on a repo with NO LFS usage must not block.
    plain="$(gg_mktemp_repo)"
    ( cd "$plain" && PATH="$nolfs" sh "$GG_ROOT/hooks/pre-push" origin "$remote" \
        </dev/null >/dev/null 2>&1 ); rc=$?
    t_expect_rc 0 "$rc" "restricted PATH without LFS usage is not blocked (control)"
    gg_rmrepo "$plain"
    rm -f "$blog"
  fi
  rm -rf "$nolfs"

  rm -f "$logf"
  gg_rmrepo "$r"
  gg_rmrepo "$remote"
}
