#!/bin/sh
# Category 18 — install.sh must VERIFY a materialized tree before it is ever
# promoted to a version dir or made reachable via `current`.
#
# The incident this closes: on 2026-09-25 the currently-`current` version
# directory was deleted out from under an active `current` symlink by a manual
# (non-CLI) host operation, leaving `~/.git-hooks` (global core.hooksPath)
# DANGLING for ~10 minutes — git silently ran NO hooks anywhere on the host in
# that window. That specific mistake was a manual `rm -rf`, not a bug in
# install.sh's own materialize-then-flip logic, but the fix requested (and
# implemented) is defense in depth regardless of proximate cause:
# install.sh must never promote a broken/incomplete tree, whether "broken"
# comes from a bad tag, a damaged archive, or a corrupted on-disk copy of an
# already-materialized version.
#
# Uses a SEPARATE, throwaway `git worktree` as the "source checkout" (same
# pattern as tests/16-versioned-install.t.sh) so this never mutates the
# worktree tests/run.sh itself runs from. Fully hermetic: HOME, the store, and
# the hooks-link all live under GG_T_TMPROOT.
# shellcheck shell=sh

t_case_install_verify_before_flip() {
  t_begin "18 install verify-before-flip: a broken tag/tree is never promoted"

  if ! have tar; then t_skip "tar absent — cannot exercise git archive | tar -x"; return 0; fi

  src="$(mktemp -d "$GG_T_TMPROOT/gg-src18.XXXXXX")"
  rmdir "$src"  # git worktree add requires the target not already exist
  if ! git -C "$GG_ROOT" worktree add -q --detach "$src" HEAD >/dev/null 2>&1; then
    t_fail "could not create a throwaway worktree of git-guard itself"
    return 1
  fi

  fake_home="$(mktemp -d "$GG_T_TMPROOT/fakehome18.XXXXXX")"
  store="$fake_home/.local/share/git-guard"
  hookslink="$fake_home/.git-hooks"

  # --- Case A: a good tag installs and verifies cleanly (positive control) ---
  tag_good="gg-verify-good-$$"
  git -C "$src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag_good" HEAD

  ( HOME="$fake_home" sh "$src/install.sh" --to "$tag_good" --store "$store" --hooks-link "$hookslink" ) \
    >"$GG_T_TMPROOT/install-good.out" 2>&1
  t_expect_rc 0 "$?" "install --to $tag_good (unmodified, good) exits 0"

  [ "$(readlink "$store/current" 2>/dev/null)" = "$store/$tag_good" ] \
    && t_ok "current points at the good version after a clean install" \
    || t_fail "current does not point at $store/$tag_good"

  # --- Case B: a tag whose committed hooks/pre-commit is NOT executable ---
  # git preserves the exec bit through the tree, so `git archive` faithfully
  # reproduces a non-executable pre-commit -- this is what a corrupted/
  # mis-authored release looks like from install.sh's point of view.
  chmod -x "$src/hooks/pre-commit"
  git -C "$src" add hooks/pre-commit
  git -C "$src" -c user.email=test@example.com -c user.name=test commit -q -m "test: strip exec bit (simulated corruption)"
  tag_noexec="gg-verify-noexec-$$"
  git -C "$src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag_noexec" HEAD

  ( HOME="$fake_home" sh "$src/install.sh" --to "$tag_noexec" --store "$store" --hooks-link "$hookslink" ) \
    >"$GG_T_TMPROOT/install-noexec.out" 2>&1
  noexec_rc=$?
  [ "$noexec_rc" != 0 ] \
    && t_ok "install --to $tag_noexec (non-executable pre-commit) is REFUSED (rc=$noexec_rc)" \
    || t_fail "install --to $tag_noexec should have failed verification but exited 0"

  grep -q "VERIFY FAILED" "$GG_T_TMPROOT/install-noexec.out" \
    && t_ok "refusal names VERIFY FAILED, not a generic error" \
    || t_fail "refusal output does not mention VERIFY FAILED: $(cat "$GG_T_TMPROOT/install-noexec.out")"

  [ ! -e "$store/$tag_noexec" ] \
    && t_ok "the broken version dir was never created under the store" \
    || t_fail "$store/$tag_noexec exists despite failed verification"

  [ "$(readlink "$store/current" 2>/dev/null)" = "$store/$tag_good" ] \
    && t_ok "current is UNTOUCHED after a failed verification (still the last-good version)" \
    || t_fail "current changed after a failed verification: $(readlink "$store/current" 2>/dev/null)"

  # Restore the exec bit for the next case (working tree is reused).
  chmod +x "$src/hooks/pre-commit"

  # --- Case C: a tag whose committed hooks/common/qa_gate.sh has bad sh syntax ---
  printf 'if [ true\n' >> "$src/hooks/common/qa_gate.sh"  # unterminated [ -- guaranteed sh -n failure
  git -C "$src" add hooks/common/qa_gate.sh hooks/pre-commit
  git -C "$src" -c user.email=test@example.com -c user.name=test commit -q -m "test: inject sh syntax error (simulated corruption)"
  tag_badsyntax="gg-verify-badsyntax-$$"
  git -C "$src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag_badsyntax" HEAD

  ( HOME="$fake_home" sh "$src/install.sh" --to "$tag_badsyntax" --store "$store" --hooks-link "$hookslink" ) \
    >"$GG_T_TMPROOT/install-badsyntax.out" 2>&1
  badsyntax_rc=$?
  [ "$badsyntax_rc" != 0 ] \
    && t_ok "install --to $tag_badsyntax (qa_gate.sh sh -n failure) is REFUSED (rc=$badsyntax_rc)" \
    || t_fail "install --to $tag_badsyntax should have failed verification but exited 0"

  [ ! -e "$store/$tag_badsyntax" ] \
    && t_ok "the syntax-broken version dir was never created under the store" \
    || t_fail "$store/$tag_badsyntax exists despite failed verification"

  [ "$(readlink "$store/current" 2>/dev/null)" = "$store/$tag_good" ] \
    && t_ok "current is STILL the last-good version after the second failed verification" \
    || t_fail "current changed after the second failed verification: $(readlink "$store/current" 2>/dev/null)"

  # --- Case D: an already-materialized version dir is corrupted ON DISK
  # after materialization (disk error / manual tampering), commit marker
  # still matches -- the idempotent fast path must re-verify, not just trust
  # the marker forever.
  chmod -x "$store/$tag_good/hooks/pre-commit"
  ( HOME="$fake_home" sh "$src/install.sh" --to "$tag_good" --store "$store" --hooks-link "$hookslink" ) \
    >"$GG_T_TMPROOT/install-fastpath-corrupt.out" 2>&1
  fastpath_rc=$?
  [ "$fastpath_rc" != 0 ] \
    && t_ok "re-running install --to $tag_good after on-disk corruption is REFUSED (rc=$fastpath_rc), not silently accepted via the commit-marker fast path" \
    || t_fail "install --to $tag_good should have re-verified and failed, but exited 0"
  chmod +x "$store/$tag_good/hooks/pre-commit"  # restore for cleanup hygiene

  git -C "$GG_ROOT" worktree remove --force "$src" >/dev/null 2>&1
  git -C "$GG_ROOT" worktree prune -v >/dev/null 2>&1
}
