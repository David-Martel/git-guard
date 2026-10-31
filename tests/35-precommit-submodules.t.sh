#!/bin/sh
# Category 35 — recursive submodule validation on the declared pre-commit
# pre-push route (hooks/common/precommit-provider.sh).
#
# The framework runs tools in the working checkout, so the pushed commit must be
# what is on disk. Through 0.2.18 any gitlink refused the route outright, which
# turned every push from a repository with an uninitialized or clean submodule
# into a hard stop. Validation now follows each gitlink into its checkout:
#
#   * uninitialized (no .git, empty directory): allowed with a note; QA sees only
#     the recorded commit id, never the dependency's bytes.
#   * initialized: HEAD must equal the recorded gitlink, the tracked workspace
#     must match that commit through a private index (so assume-unchanged and
#     skip-worktree cannot hide edits), no merge/rebase may be in progress, and
#     the same holds for every nested gitlink.
#   * anything else refuses before the framework runs, naming path and fix.
#
# Load-bearing assertions:
#   * POSITIVE CONTROL: every allow case asserts the framework stub actually ran
#     (marker file non-empty), and one allow case publishes through a real
#     `git push`; an allow can never pass by skipping the provider.
#   * Every refusal asserts the framework did NOT run and that the message names
#     the offending path, so a refusal from an unrelated guard cannot satisfy it.
#   * gitGuard.precommitSubmodules / GIT_GUARD_PRECOMMIT_SUBMODULES=refuse restore
#     the former blanket refusal, and an unknown value fails closed.
# shellcheck shell=sh

# Run the pre-push hook for the parent's HEAD as a new branch. The hook itself
# never transfers objects, so 'inert://no-network' keeps this offline.
sm_prepush() {  # $1 = parent repo, $2 = log, then optional NAME=value assignments
  sm_repo="$1"; sm_out="$2"; shift 2
  sm_head="$(git -C "$sm_repo" rev-parse HEAD)"
  : > "$sm_marker"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$sm_head" "$sm_zero" |
    (cd "$sm_repo" && env PATH="$sm_path" "$@" sh "$GG_ROOT/hooks/pre-push" origin 'inert://no-network') > "$sm_out" 2>&1
}

sm_expect_allow() {  # $1 = rc, $2 = label
  t_expect_rc 0 "$1" "$2 is admitted"
  if [ -s "$sm_marker" ]; then t_ok "$2 ran the framework"; else t_fail "$2 did not run the framework"; fi
}

sm_expect_refuse() {  # $1 = rc, $2 = label, $3 = fixed string the refusal must contain
  t_expect_rc 1 "$1" "$2 is refused"
  grep -qF -- "$3" "$sm_log"; t_assert $? "$2 refusal names the cause ($3)"
  if [ -s "$sm_marker" ]; then t_fail "$2 invoked the framework"; else t_ok "$2 refused before the framework"; fi
}

sm_commit() {  # $1 = repo, $2 = message
  (cd "$1" && env PATH="$sm_path" git commit -qm "$2") > "$sm_log" 2>&1 </dev/null
}

t_case_precommit_submodules() {
  t_begin '35 pre-commit pre-push validates submodules recursively'
  sm_log="$(gg_tmp_log)"
  sm_bin="$GG_T_TMPROOT/sm-framework-bin"
  sm_marker="$GG_T_TMPROOT/sm-framework-calls"
  sm_zero=0000000000000000000000000000000000000000
  mkdir -p "$sm_bin"
  # A drive-letter colon would split PATH; take the shell's own spelling.
  sm_bin="$(cd "$sm_bin" && pwd)"
  cat > "$sm_bin/pre-commit" <<EOF
#!/bin/sh
printf '%s\\n' framework >> '$sm_marker'
cat > /dev/null
exit 0
EOF
  chmod +x "$sm_bin/pre-commit"
  sm_path="$sm_bin:$PATH"

  # Why: the route must stay unchanged for ordinary repositories.
  plain="$(gg_mktemp_repo)"
  printf 'repos: []\n' > "$plain/.pre-commit-config.yaml"
  printf 'plain\n' > "$plain/a.txt"
  (cd "$plain" && git config core.hooksPath "$GG_ROOT/hooks" && git add .pre-commit-config.yaml a.txt)
  sm_commit "$plain" plain-fixture; t_expect_rc 0 "$?" 'plain parent fixture committed'
  sm_prepush "$plain" "$sm_log"; sm_expect_allow "$?" 'repository without gitlinks'
  if grep -q 'submodule' "$sm_log"; then t_fail 'gitlink-free push mentions submodules'; else t_ok 'gitlink-free push emits no submodule notes'; fi
  gg_rmrepo "$plain"

  # Fixture: parent -> dep -> nested, all local, cloned through git submodule.
  nested="$(gg_mktemp_repo)"
  printf 'nested one\n' > "$nested/n.txt"
  (cd "$nested" && git config core.hooksPath "$GG_ROOT/hooks" && git add n.txt)
  sm_commit "$nested" nested-one
  printf 'nested two\n' > "$nested/n.txt"
  (cd "$nested" && git add n.txt)
  sm_commit "$nested" nested-two
  dep="$(gg_mktemp_repo)"
  printf 'dep one\n' > "$dep/d.txt"
  (cd "$dep" && git config core.hooksPath "$GG_ROOT/hooks" && git add d.txt)
  sm_commit "$dep" dep-one
  (cd "$dep" && git -c protocol.file.allow=always submodule add -q "$nested" nested) > "$sm_log" 2>&1
  t_expect_rc 0 "$?" 'dependency records a nested submodule'
  sm_commit "$dep" dep-two; t_expect_rc 0 "$?" 'dependency commit with nested gitlink'
  dep_old="$(git -C "$dep" rev-parse HEAD~1)"
  parent="$(gg_mktemp_repo)"
  printf 'repos: []\n' > "$parent/.pre-commit-config.yaml"
  printf 'parent\n' > "$parent/a.txt"
  (cd "$parent" && git config core.hooksPath "$GG_ROOT/hooks" &&
    git -c protocol.file.allow=always submodule add -q "$dep" dep &&
    git -c protocol.file.allow=always submodule update -q --init --recursive &&
    git add .pre-commit-config.yaml a.txt) > "$sm_log" 2>&1
  t_expect_rc 0 "$?" 'parent clones the dependency recursively'
  sm_commit "$parent" parent-fixture; t_expect_rc 0 "$?" 'parent fixture committed'
  dep_sha="$(git -C "$parent" rev-parse HEAD:dep)"
  nested_sha="$(git -C "$parent/dep" rev-parse HEAD:nested)"

  # Why: the common case — dependency and its nested gitlink both checked out at
  # their recorded commits — must reach the framework and actually publish.
  sm_prepush "$parent" "$sm_log"; sm_expect_allow "$?" 'initialized clean submodules (nested clean)'
  remote="$GG_T_TMPROOT/sm-remote.git"
  git init -q --bare "$remote"
  : > "$sm_marker"
  (cd "$parent" && env PATH="$sm_path" git push "$remote" HEAD:refs/heads/main) > "$sm_log" 2>&1
  t_expect_rc 0 "$?" 'real Git push with clean nested submodules succeeds'
  if [ -s "$sm_marker" ]; then t_ok 'real Git push ran the framework'; else t_fail 'real Git push skipped the framework'; fi
  git --git-dir="$remote" rev-parse -q --verify refs/heads/main >/dev/null; t_assert $? 'real Git push published the ref'

  # Why: tracked-only, like the parent; untracked files in a submodule are not
  # the pushed source and must not block (the route never sealed them).
  printf 'scratch\n' > "$parent/dep/untracked.txt"
  sm_prepush "$parent" "$sm_log"; sm_expect_allow "$?" 'untracked file inside a submodule'
  rm -f "$parent/dep/untracked.txt"

  # Why: a checkout at another commit is not the source the gitlink publishes.
  git -C "$parent/dep" checkout -q --detach "$dep_old"
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'submodule at a different commit' "'dep' is checked out at $dep_old, but the pushed HEAD records $dep_sha"
  grep -qF 'git submodule update --init --recursive' "$sm_log"; t_assert $? 'commit mismatch names the fix'
  git -C "$parent/dep" checkout -q --detach "$dep_sha"
  (cd "$parent/dep" && git -c protocol.file.allow=always submodule update -q --init --recursive) > "$sm_log" 2>&1

  # Why: edited tracked bytes in the submodule would be what the tools read.
  printf 'edited\n' >> "$parent/dep/d.txt"
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'dirty tracked submodule file' "'dep' has staged or unstaged tracked changes against $dep_sha"
  # Why: the submodule's own live index can hide that edit (same attack the
  # parent's private index defeats); the private index must still see it.
  git -C "$parent/dep" update-index --assume-unchanged -- d.txt
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'assume-unchanged hidden submodule edit' "'dep' has staged or unstaged tracked changes"
  git -C "$parent/dep" update-index --no-assume-unchanged -- d.txt
  git -C "$parent/dep" restore -- d.txt
  # Why: a staged blob that matches nothing on disk is the next commit, not this one.
  printf 'staged\n' >> "$parent/dep/d.txt"
  git -C "$parent/dep" add d.txt
  git -C "$parent/dep" restore --worktree --source=HEAD -- d.txt
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'staged-only submodule change' "'dep' has staged or unstaged tracked changes"
  git -C "$parent/dep" restore --staged --worktree -- d.txt

  # Why: validation must recurse; a nested dependency is equally on disk.
  printf 'nested edit\n' >> "$parent/dep/nested/n.txt"
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'dirty nested submodule' "'dep/nested' has staged or unstaged tracked changes against $nested_sha"
  git -C "$parent/dep/nested" restore -- n.txt
  nested_old="$(git -C "$parent/dep/nested" rev-parse HEAD~1)"
  git -C "$parent/dep/nested" checkout -q --detach "$nested_old"
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'nested submodule at a different commit' "'dep/nested' is checked out at $nested_old, but the pushed HEAD records $nested_sha"
  git -C "$parent/dep/nested" checkout -q --detach "$nested_sha"

  # Why: a half-finished merge leaves the tree in a state no commit describes.
  merge_head="$(git -C "$parent/dep" rev-parse --git-path MERGE_HEAD)"
  case "$merge_head" in /*|?:*) : ;; *) merge_head="$parent/dep/$merge_head" ;; esac
  printf '%s\n' "$dep_sha" > "$merge_head"
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'in-progress submodule merge' "'dep' has an in-progress operation (MERGE_HEAD)"
  rm -f "$merge_head"

  # Why: an unreadable .git must not let discovery fall back to the parent.
  cp "$parent/dep/.git" "$GG_T_TMPROOT/sm-dep-gitfile"
  printf 'gitdir: ../missing-module\n' > "$parent/dep/.git"
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'broken submodule .git file' "'dep' has a .git entry that is not a readable repository"
  grep -qF "(git: " "$sm_log"; t_assert $? 'broken .git refusal carries the Git reason'
  # Why: an empty .git directory is ignored by discovery, which climbs to the
  # parent; the parent's HEAD must never stand in for the submodule's.
  rm -f "$parent/dep/.git"; mkdir "$parent/dep/.git"
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'empty .git directory in a submodule' "'dep' has a .git entry that is not a readable repository at that path; repair"
  rmdir "$parent/dep/.git"
  cp "$GG_T_TMPROOT/sm-dep-gitfile" "$parent/dep/.git"
  sm_prepush "$parent" "$sm_log"; sm_expect_allow "$?" 'restored submodule (control after refusals)'

  # Why: the knob restores the former blanket refusal, and only exact values
  # are honoured; a typo must fail closed rather than validate.
  sm_prepush "$parent" "$sm_log" GIT_GUARD_PRECOMMIT_SUBMODULES=refuse; sm_expect_refuse "$?" 'environment refuse policy' 'submodule policy is refuse'
  git -C "$parent" config gitGuard.precommitSubmodules refuse
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'config refuse policy' 'submodule policy is refuse'
  sm_prepush "$parent" "$sm_log" GIT_GUARD_PRECOMMIT_SUBMODULES=validate; sm_expect_allow "$?" 'environment validate beats config refuse'
  git -C "$parent" config gitGuard.precommitSubmodules bogus
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'unknown policy value' 'submodule policy is bogus'
  git -C "$parent" config --unset gitGuard.precommitSubmodules

  # Why: an uninitialized submodule exposes no dependency bytes to QA, so the
  # route admits it (the vigil_ai shape that 0.2.18 refused) with a note.
  (cd "$parent" && git submodule deinit -q -f dep) > "$sm_log" 2>&1
  t_expect_rc 0 "$?" 'dependency deinitialized'
  sm_prepush "$parent" "$sm_log"; sm_expect_allow "$?" 'uninitialized submodule'
  grep -qF "submodule 'dep' is not checked out" "$sm_log"; t_assert $? 'uninitialized submodule is reported'
  # Why: `git -c gitGuard.precommitSubmodules=refuse push` reaches the hook as
  # GIT_CONFIG_PARAMETERS, and `git --config-env` / GIT_CONFIG_COUNT as numbered
  # pairs. The hook clears the repository-locating Git variables before running
  # providers (#88); clearing these too would drop the caller's refusal and admit
  # this uninitialized gitlink, which only the validate policy allows.
  sm_prepush "$parent" "$sm_log" "GIT_CONFIG_PARAMETERS='gitGuard.precommitSubmodules'='refuse'"
  sm_expect_refuse "$?" 'git -c refuse policy (GIT_CONFIG_PARAMETERS)' 'submodule policy is refuse'
  sm_prepush "$parent" "$sm_log" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gitGuard.precommitSubmodules GIT_CONFIG_VALUE_0=refuse
  sm_expect_refuse "$?" 'GIT_CONFIG_COUNT refuse policy' 'submodule policy is refuse'
  # Why: files in an uninitialized directory are bytes no repository vouches for.
  printf 'stray\n' > "$parent/dep/stray.txt"
  sm_prepush "$parent" "$sm_log"; sm_expect_refuse "$?" 'stray content in an uninitialized submodule' "'dep' is not initialized but its directory has content"
  rm -f "$parent/dep/stray.txt"

  gg_rmrepo "$parent"; gg_rmrepo "$dep"; gg_rmrepo "$nested"; rm -rf "$remote"; rm -f "$sm_log"
}
