#!/bin/sh
# Category 17 — a single hook invocation is pinned to ONE version, start to
# finish, even if a concurrent `update --to` re-points `current` mid-run.
#
# hooks/pre-commit resolves its own directory ONCE (`pwd -P`, physically
# through the ~/.git-hooks -> current -> <tag>/hooks symlink chain) and reuses
# that resolved path for every common/*.sh it dispatches to. Without `-P`,
# a LATER file access in the SAME invocation could resolve through a DIFFERENT
# `current` target than an EARLIER one did, mixing versions within one commit.
#
# This is tested with a real race, not just a structural check: a background
# `git commit` is paused (via the test-only, default-off
# GIT_GUARD_TEST_PAUSE_AFTER_RESOLVE knob) right after hooks/pre-commit
# resolves its physical hooks dir, `current` is flipped to a SECOND
# materialized version while it sleeps, and the test asserts the invocation's
# own QA_DEBUG output still shows the FIRST version's physical path.
#
# Uses a throwaway `git worktree` (never the one tests/run.sh runs from) as
# the source for two tags materialized to the SAME content (the test tells
# the versions apart by their STORE PATH, not by any code difference between
# them -- see the header comment above for why that's sufficient).
# shellcheck shell=sh

t_case_version_pinning() {
  t_begin "17 version pinning: one hook invocation cannot mix versions"

  if ! have tar; then t_skip "tar absent"; return 0; fi

  src="$(mktemp -d "$GG_T_TMPROOT/gg-pin-src.XXXXXX")"
  rmdir "$src"
  if ! git -C "$GG_ROOT" worktree add -q --detach "$src" HEAD >/dev/null 2>&1; then
    t_fail "could not create a throwaway worktree of git-guard itself"
    return 1
  fi

  tag_a="gg-pin-a-$$"
  tag_b="gg-pin-b-$$"
  git -C "$src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag_a" HEAD
  git -C "$src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag_b" HEAD

  fake_home="$(mktemp -d "$GG_T_TMPROOT/pin-fakehome.XXXXXX")"
  store="$fake_home/.local/share/git-guard"
  hookslink="$fake_home/.git-hooks"

  ( HOME="$fake_home" sh "$src/install.sh" --to "$tag_a" --store "$store" --hooks-link "$hookslink" ) \
    >"$GG_T_TMPROOT/pin-install-a.out" 2>&1
  t_expect_rc 0 "$?" "install --to $tag_a exits 0"

  # A hermetic test repo whose commits go through the installed hookslink.
  test_repo="$(mktemp -d "$GG_T_TMPROOT/pin-repo.XXXXXX")"
  ( cd "$test_repo" && git init -q \
      && git config user.email t@t.t && git config user.name t \
      && git config commit.gpgsign false \
      && printf '# docs only\n' > README.md && git add -A )

  pin_log="$(gg_tmp_log)"
  # Background: a commit that PAUSES for 3s right after hooks/pre-commit
  # resolves its physical hooks dir (GIT_GUARD_TEST_PAUSE_AFTER_RESOLVE), with
  # QA_DEBUG on so its own "rules dir resolved to" line names which physical
  # version it actually used.
  (
    cd "$test_repo" \
      && HOME="$fake_home" GIT_CONFIG_GLOBAL="$fake_home/.gitconfig" \
         GIT_GUARD_TEST_PAUSE_AFTER_RESOLVE=3 QA_DEBUG=1 \
         GIT_GUARD_RULES_DIR='' \
         git -c core.hooksPath="$hookslink" commit -q -m "pinned commit" \
         >/dev/null 2>"$pin_log"
  ) &
  bg_pid=$!

  # Give the background commit time to start and reach its pause (it resolves
  # the physical dir and begins sleeping well under 1s in).
  sleep 1

  # Flip `current` to a SECOND version WHILE the background commit is paused.
  ( HOME="$fake_home" sh "$src/bin/git-guard" update --to "$tag_b" --store "$store" --hooks-link "$hookslink" ) \
    >"$GG_T_TMPROOT/pin-update-b.out" 2>&1
  t_expect_rc 0 "$?" "update --to $tag_b (mid-flight) exits 0"

  wait "$bg_pid"
  bg_rc=$?
  t_expect_rc 0 "$bg_rc" "the PAUSED commit still succeeds (docs-only change)"

  resolved_line="$(grep 'rules dir resolved to' "$pin_log" 2>/dev/null | head -n1)"
  case "$resolved_line" in
    *"/$tag_a/"*)
      t_ok "the paused invocation used $tag_a THROUGHOUT (resolved before the flip, unaffected by it)" ;;
    *"/$tag_b/"*)
      t_fail "VERSION MIXING: the paused invocation ended up using $tag_b, which was only installed AFTER this invocation started" ;;
    *)
      t_fail "could not find a 'rules dir resolved to' line in the captured log: $resolved_line" ;;
  esac
  rm -f "$pin_log"

  # A control: a FRESH commit started AFTER the flip completed must use the
  # NEW version -- proving the pin only holds for the invocation it was taken
  # in, not that updates get stuck.
  ( cd "$test_repo" && printf 'second\n' >> README.md && git add -A )
  pin_log2="$(gg_tmp_log)"
  ( cd "$test_repo" \
      && HOME="$fake_home" GIT_CONFIG_GLOBAL="$fake_home/.gitconfig" QA_DEBUG=1 \
         GIT_GUARD_RULES_DIR='' \
         git -c core.hooksPath="$hookslink" commit -q -m "post-flip commit" \
         >/dev/null 2>"$pin_log2" )
  t_expect_rc 0 "$?" "a fresh commit after the flip succeeds"
  resolved_line2="$(grep 'rules dir resolved to' "$pin_log2" 2>/dev/null | head -n1)"
  case "$resolved_line2" in
    *"/$tag_b/"*) t_ok "a NEW invocation after the flip correctly uses $tag_b (updates are not stuck)" ;;
    *) t_fail "a new invocation after the flip did not use $tag_b: $resolved_line2" ;;
  esac
  rm -f "$pin_log2"

  # cleanup
  git -C "$src" tag -d "$tag_a" "$tag_b" >/dev/null 2>&1
  git -C "$GG_ROOT" worktree remove --force "$src" >/dev/null 2>&1
  rm -rf "$fake_home" "$test_repo"
}
