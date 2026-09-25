#!/bin/sh
# Category 19 — `git-guard doctor` must FAIL LOUDLY (non-zero exit) when
# core.hooksPath is unset, dangling, or missing an executable pre-commit.
#
# The incident this closes: on 2026-09-25 `~/.local/share/git-guard/current`
# pointed at a version directory that had been deleted, so the global
# `core.hooksPath` (`~/.git-hooks`) was DANGLING and git silently ran NO hooks
# in ANY repo on the host for about 10 minutes -- with no error, anywhere.
# `cmd_doctor` previously had no exit-code contract at all (always effectively
# 0), so even running it by hand during that window would not have surfaced
# the problem. This suite proves the new hooks-path check actually fails.
#
# Same throwaway-worktree + isolated-HOME pattern as tests/16 and tests/18.
# shellcheck shell=sh

t_case_doctor_hooks_resolution() {
  t_begin "19 doctor: hooks-path resolution is checked and fails loudly"

  if ! have tar; then t_skip "tar absent — cannot exercise git archive | tar -x"; return 0; fi

  src="$(mktemp -d "$GG_T_TMPROOT/gg-src19.XXXXXX")"
  rmdir "$src"
  if ! git -C "$GG_ROOT" worktree add -q --detach "$src" HEAD >/dev/null 2>&1; then
    t_fail "could not create a throwaway worktree of git-guard itself"
    return 1
  fi

  fake_home="$(mktemp -d "$GG_T_TMPROOT/fakehome19.XXXXXX")"
  store="$fake_home/.local/share/git-guard"
  hookslink="$fake_home/.git-hooks"

  # --- Case A: nothing installed yet -> core.hooksPath unset ---
  doctor_out="$(HOME="$fake_home" sh "$src/bin/git-guard" doctor 2>&1)"
  doctor_rc=$?
  [ "$doctor_rc" != 0 ] \
    && t_ok "doctor exits non-zero when core.hooksPath is unset (rc=$doctor_rc)" \
    || t_fail "doctor should have failed with core.hooksPath unset but exited 0"
  printf '%s\n' "$doctor_out" | grep -q "hooks-path" \
    && t_ok "doctor's unset-hooksPath failure names the hooks-path check" \
    || t_fail "doctor output does not mention hooks-path: $doctor_out"

  # --- Case B: a real, good install -> doctor passes ---
  tag_good="gg-doctor-good-$$"
  git -C "$src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag_good" HEAD
  ( HOME="$fake_home" sh "$src/install.sh" --to "$tag_good" --store "$store" --hooks-link "$hookslink" ) \
    >/dev/null 2>&1

  doctor_out="$(HOME="$fake_home" sh "$store/current/bin/git-guard" doctor 2>&1)"
  doctor_rc=$?
  [ "$doctor_rc" = 0 ] \
    && t_ok "doctor exits 0 against a real, resolving, executable install" \
    || t_fail "doctor should pass a good install but exited $doctor_rc: $doctor_out"
  printf '%s\n' "$doctor_out" | grep -q "\[ok\]   hooks-path" \
    && t_ok "doctor reports [ok] for hooks-path on a good install" \
    || t_fail "doctor did not report [ok] hooks-path: $doctor_out"

  # --- Case C: reproduce the actual incident -- current's TARGET is removed,
  # so core.hooksPath (still set, still a symlink chain) resolves to nothing. ---
  rm -rf "${store:?}/${tag_good:?}"
  # The installed CLI copy is itself gone now (it lived under the deleted version
  # dir), so invoke doctor via the throwaway SOURCE checkout instead -- it only
  # needs to read the fake HOME's git config, not run from the installed tree.
  doctor_out="$(HOME="$fake_home" sh "$src/bin/git-guard" doctor 2>&1)"
  doctor_rc=$?
  [ "$doctor_rc" != 0 ] \
    && t_ok "doctor exits non-zero when current's target has been deleted (dangling hooksPath), reproducing the 2026-09-25 incident (rc=$doctor_rc)" \
    || t_fail "doctor should have caught the dangling hooksPath but exited 0"
  printf '%s\n' "$doctor_out" | grep -qi "does NOT RESOLVE\|NO hooks" \
    && t_ok "doctor's failure explicitly warns that hooks are not resolving" \
    || t_fail "doctor output does not warn about non-resolving hooks: $doctor_out"

  # --- Case D: fresh good install, then pre-commit made non-executable ---
  tag_good2="gg-doctor-good2-$$"
  git -C "$src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag_good2" HEAD
  ( HOME="$fake_home" sh "$src/install.sh" --to "$tag_good2" --store "$store" --hooks-link "$hookslink" ) \
    >/dev/null 2>&1
  chmod -x "$store/$tag_good2/hooks/pre-commit"

  doctor_out="$(HOME="$fake_home" sh "$src/bin/git-guard" doctor 2>&1)"
  doctor_rc=$?
  [ "$doctor_rc" != 0 ] \
    && t_ok "doctor exits non-zero when pre-commit resolves but is not executable (rc=$doctor_rc)" \
    || t_fail "doctor should have caught the non-executable pre-commit but exited 0"

  git -C "$GG_ROOT" worktree remove --force "$src" >/dev/null 2>&1
  git -C "$GG_ROOT" worktree prune -v >/dev/null 2>&1
}
