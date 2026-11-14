#!/bin/sh
# Category 19 — `git-guard doctor` must FAIL LOUDLY (non-zero exit) when
# core.hooksPath was INSTALLED and is now dangling or missing an executable
# pre-commit -- but must NOT fail merely because core.hooksPath is unset
# (never installed at all), since `doctor` also runs as a CI smoke-test
# against an uninstalled checkout (.github/workflows/qa.yml).
#
# The incident this closes: on 2026-09-25 `~/.local/share/git-guard/current`
# pointed at a version directory that had been deleted, so the global
# `core.hooksPath` (`~/.git-hooks`) was DANGLING and git silently ran NO hooks
# in ANY repo on the host for about 10 minutes -- with no error, anywhere.
# `cmd_doctor` previously had no exit-code contract at all (always effectively
# 0), so even running it by hand during that window would not have surfaced
# the problem. This suite proves the new hooks-path check actually fails for
# a genuinely broken install (Case C) while staying green for the ordinary
# not-yet-installed case (Case A) -- the first version of this check
# conflated the two and broke this PR's own CI on its first run.
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

  # --- Case A: nothing installed yet -> core.hooksPath unset is NOT a
  # failure. This is the normal state for a fresh dev checkout, and it is
  # EXACTLY the state `git-guard doctor` runs in as a CI smoke-test
  # (.github/workflows/qa.yml, both jobs) -- CI never installs git-guard
  # before running this command. An earlier version of this check treated
  # unset the same as dangling and broke both CI jobs outright the first
  # time this PR's own workflow ran. Unset and dangling are different: unset
  # means "never installed" (fine); dangling means "was installed, now
  # broken" (the actual incident, Case C below).
  doctor_out="$(HOME="$fake_home" sh "$src/bin/git-guard" doctor 2>&1)"
  doctor_rc=$?
  [ "$doctor_rc" = 0 ] \
    && t_ok "doctor exits 0 when core.hooksPath is simply unset (never installed -- matches CI's own usage)" \
    || t_fail "doctor should NOT fail merely because core.hooksPath is unset, but exited $doctor_rc: $doctor_out"
  printf '%s\n' "$doctor_out" | grep -q "hooks-path" \
    && t_ok "doctor still reports the hooks-path state when unset, just not as a failure" \
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
  if gg_is_windows; then
    # NTFS does not implement chmod -x for these shell scripts. Corrupt the
    # actual required-hook membership instead; do not claim Unix mode parity.
    rm "$store/$tag_good2/hooks/pre-commit"
    defect="required pre-commit is missing"
    t_skip "doctor Unix non-executable mode NOT_TESTED on Windows"
  else
    chmod -x "$store/$tag_good2/hooks/pre-commit"
    defect="pre-commit resolves but is not executable"
  fi
  doctor_out="$(HOME="$fake_home" sh "$src/bin/git-guard" doctor 2>&1)"
  doctor_rc=$?
  [ "$doctor_rc" != 0 ] \
    && t_ok "doctor exits non-zero when $defect (rc=$doctor_rc)" \
    || t_fail "doctor should have caught $defect but exited 0"

  git -C "$GG_ROOT" worktree remove --force "$src" >/dev/null 2>&1
  # Why: a linked worktree shares refs with the real checkout, so these throwaway
  # tags would otherwise accumulate in the git-guard repo itself (found 2026-09-28:
  # ten leaked gg-verify-*/gg-doctor-* tags from earlier runs).
  for gg_leak_tag in "$tag_good" "$tag_good2"; do
    git -C "$GG_ROOT" tag -d "$gg_leak_tag" >/dev/null 2>&1 || true
  done
  git -C "$GG_ROOT" worktree prune -v >/dev/null 2>&1
}

# timeout(1) with -k bounds the pre-push mandate on every platform and, on POSIX, the
# identity query (#119). A host without a usable one refuses every push with a TOOL ERROR,
# so doctor must report it at install or update time instead of at the first push (team
# lead ruling, 2026-11-14, before the v0.2.23 rollout).
t_case_doctor_timeout_prereq() {
  t_begin "19 doctor: a missing or unusable timeout -k fails loudly"
  fake_home="$(mktemp -d "$GG_T_TMPROOT/fakehome19t.XXXXXX")"
  stub="$(mktemp -d "$GG_T_TMPROOT/stub19t.XXXXXX")"
  # Positive control: the host's own timeout passes, so the FAIL below is the stub's doing.
  doctor_out="$(HOME="$fake_home" sh "$GG_ROOT/bin/git-guard" doctor 2>&1)"
  doctor_rc=$?
  if [ "$doctor_rc" = 0 ] && printf '%s\n' "$doctor_out" | grep -q '\[ok\] *timeout'; then
    t_ok "doctor reports a working timeout -k as [ok] and exits 0"
  else
    t_fail "doctor with the host's timeout: rc=$doctor_rc, no [ok] timeout line: $doctor_out"
  fi
  # A timeout that rejects -k (BSD-like) stands in for a missing or unusable one.
  printf '#!/bin/sh\necho "timeout: illegal option -- k" >&2\nexit 125\n' > "$stub/timeout"
  chmod +x "$stub/timeout"
  for mode in "" --require-installed; do
    # shellcheck disable=SC2086  # $mode is empty or one word on purpose
    doctor_out="$(HOME="$fake_home" PATH="$stub:$PATH" sh "$GG_ROOT/bin/git-guard" doctor $mode 2>&1)"
    doctor_rc=$?
    if [ "$doctor_rc" != 0 ] \
      && printf '%s\n' "$doctor_out" | grep -q '\[FAIL\] timeout .*coreutils' \
      && printf '%s\n' "$doctor_out" | grep -q 'NOT COVERED'; then
      t_ok "doctor ${mode:-(plain)} fails with the remedy when timeout -k is unusable (rc=$doctor_rc)"
    else
      t_fail "doctor ${mode:-(plain)} with an unusable timeout: rc=$doctor_rc, output: $doctor_out"
    fi
  done
}
