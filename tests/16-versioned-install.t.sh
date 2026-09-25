#!/bin/sh
# Category 16 — versioned install: materialize-from-tag, atomic `current` swap,
# and checkout-independence.
#
# The bug this closes: `~/.git-hooks` used to be a symlink straight into
# git-guard's LIVE WORKING CHECKOUT, so a `git checkout <branch>` (or even an
# uncommitted edit) there silently changed the commit hooks of every consuming
# repo. install.sh now materializes a `git archive <tag>` into an immutable
# ~/.local/share/git-guard/<tag>/ and flips a `current` symlink atomically;
# nothing about the source working tree's state should reach an installed hook
# again. This suite proves that end to end, against install.sh itself.
#
# Uses a SEPARATE, throwaway `git worktree` as the "source checkout" so this
# never touches the worktree tests/run.sh itself runs from (see the repo's own
# rule: never mutate a worktree mid-suite). Fully hermetic: HOME, the store,
# and the hooks-link all live under GG_T_TMPROOT.
# shellcheck shell=sh

gg_sha() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else printf 'no-sha-tool'
  fi
}

t_case_versioned_install() {
  t_begin "16 versioned install: materialize, atomic swap, checkout-independence"

  if ! have tar; then t_skip "tar absent — cannot exercise git archive | tar -x"; return 0; fi
  if ! have sha256sum && ! have shasum; then t_skip "neither sha256sum nor shasum present"; return 0; fi

  src="$(mktemp -d "$GG_T_TMPROOT/gg-src.XXXXXX")"
  rmdir "$src"  # git worktree add requires the target not already exist
  if ! git -C "$GG_ROOT" worktree add -q --detach "$src" HEAD >/dev/null 2>&1; then
    t_fail "could not create a throwaway worktree of git-guard itself"
    return 1
  fi

  tag_a="gg-test-a-$$"
  tag_b="gg-test-b-$$"
  git -C "$src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag_a" HEAD

  fake_home="$(mktemp -d "$GG_T_TMPROOT/fakehome.XXXXXX")"
  store="$fake_home/.local/share/git-guard"
  hookslink="$fake_home/.git-hooks"

  ( HOME="$fake_home" sh "$src/install.sh" --to "$tag_a" --store "$store" --hooks-link "$hookslink" ) \
    >"$GG_T_TMPROOT/install-a.out" 2>&1
  t_expect_rc 0 "$?" "install.sh --to $tag_a exits 0"

  [ -f "$store/$tag_a/hooks/pre-commit" ] \
    && t_ok "tag materialized under the store as an immutable version dir" \
    || t_fail "materialized version dir missing hooks/pre-commit"

  [ "$(readlink "$store/current" 2>/dev/null)" = "$store/$tag_a" ] \
    && t_ok "current symlinks to the materialized version dir" \
    || t_fail "current does not point at $store/$tag_a (got $(readlink "$store/current" 2>/dev/null))"

  ghp_installed="$(GIT_CONFIG_GLOBAL="$fake_home/.gitconfig" HOME="$fake_home" git config --global core.hooksPath 2>/dev/null)"
  [ "$ghp_installed" = "$hookslink" ] \
    && t_ok "core.hooksPath (in the isolated HOME) points at the hooks-link" \
    || t_fail "core.hooksPath was not set to $hookslink (got '$ghp_installed')"

  installed_hash_a="$(gg_sha "$hookslink/pre-commit")"
  [ -n "$installed_hash_a" ] && [ "$installed_hash_a" != "no-sha-tool" ] \
    && t_ok "installed pre-commit hash captured" \
    || t_fail "could not hash the installed pre-commit"

  # --- THE ACCEPTANCE CRITERION: a checkout in the source working tree must
  # not change what's installed. Mutate a tracked file in the SEPARATE source
  # worktree (uncommitted -- strictly stronger than a branch switch, since
  # even a committed-but-not-tagged change must not reach the install either).
  printf '\n# mutated by test 16 -- must NOT reach the install\n' >> "$src/hooks/pre-commit"
  mutated_hash="$(gg_sha "$src/hooks/pre-commit")"
  [ "$mutated_hash" != "$installed_hash_a" ] \
    && t_ok "sanity: the source worktree file was actually mutated" \
    || t_fail "sanity check failed: source mutation had no effect"

  hooks_link_target_before="$(readlink -f "$hookslink" 2>/dev/null)"
  post_mutation_hash="$(gg_sha "$hookslink/pre-commit")"
  [ "$post_mutation_hash" = "$installed_hash_a" ] \
    && t_ok "installed hook is BYTE-IDENTICAL after mutating the source working tree" \
    || t_fail "installed hook CHANGED after mutating the source working tree -- checkout-independence is broken"

  git -C "$src" checkout -q -- hooks/pre-commit  # revert the mutation, cleanly
  hooks_link_target_after="$(readlink -f "$hookslink" 2>/dev/null)"
  [ "$hooks_link_target_before" = "$hooks_link_target_after" ] \
    && t_ok "readlink -f \$hookslink is unchanged across the source-tree mutation (acceptance a)" \
    || t_fail "readlink -f \$hookslink changed across the source-tree mutation"

  # --- idempotent re-install of the same tag ---------------------------------
  ( HOME="$fake_home" sh "$src/install.sh" --to "$tag_a" --store "$store" --hooks-link "$hookslink" ) >/dev/null 2>&1
  t_expect_rc 0 "$?" "re-running install.sh --to the SAME tag is idempotent"
  [ "$(gg_sha "$hookslink/pre-commit")" = "$installed_hash_a" ] \
    && t_ok "re-install left the installed hook unchanged" \
    || t_fail "re-install of the same tag changed the installed hook"

  # --- a genuine new release: `update --to` a second tag, atomically ---------
  printf 'echo second-release-marker\n' >> "$src/hooks/post-commit"
  ( cd "$src" && git add -A \
      && git -c user.email=t@t.t -c user.name=t -c commit.gpgsign=false commit -q -m "test: second release marker" )
  git -C "$src" -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag "$tag_b" HEAD

  ( HOME="$fake_home" sh "$src/bin/git-guard" update --to "$tag_b" --store "$store" --hooks-link "$hookslink" ) \
    >"$GG_T_TMPROOT/install-b.out" 2>&1
  t_expect_rc 0 "$?" "git-guard update --to $tag_b exits 0"

  new_target="$(readlink "$store/current" 2>/dev/null)"
  [ "$new_target" = "$store/$tag_b" ] \
    && t_ok "current now resolves into the $tag_b version dir" \
    || t_fail "current does not resolve into $tag_b (got $new_target)"

  grep -q "second-release-marker" "$hookslink/post-commit" 2>/dev/null \
    && t_ok "installed post-commit reflects the NEW release after update" \
    || t_fail "installed post-commit does not reflect the new release"

  [ -f "$store/$tag_a/hooks/pre-commit" ] \
    && t_ok "the previous version ($tag_a) remains materialized after update (updates add, never mutate)" \
    || t_fail "the previous version ($tag_a) was removed by update"

  # --- update without --to is refused (never a silent no-op) -----------------
  ( HOME="$fake_home" sh "$src/bin/git-guard" update --store "$store" --hooks-link "$hookslink" ) >/dev/null 2>&1
  t_expect_rc 2 "$?" "git-guard update with no --to is refused"

  # --- git-guard status (run through the INSTALLED copy) names the ----------
  # installed version, independent of which checkout is asked.
  status_out="$(HOME="$fake_home" sh "$store/current/bin/git-guard" status 2>&1)"
  case "$status_out" in
    *"installed version:"*"$(cat "$store/$tag_b/VERSION" 2>/dev/null)"*)
      t_ok "git-guard status names the installed version" ;;
    *) t_fail "git-guard status did not name the installed version: $status_out" ;;
  esac

  # cleanup: throwaway tags + worktree only. Never touches $GG_ROOT itself.
  git -C "$src" tag -d "$tag_a" "$tag_b" >/dev/null 2>&1
  git -C "$GG_ROOT" worktree remove --force "$src" >/dev/null 2>&1
  rm -rf "$fake_home"
}
