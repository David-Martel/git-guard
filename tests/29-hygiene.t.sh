#!/bin/sh
# Category 29 — backlog hygiene limits (hooks/common/hygiene.sh).
#
# The owner's rule (2026-10-09): worktree, branch and PR backlog clearance comes
# before new work, with enforced limits. git-guard enforces it at the one point
# where it cannot strand work: pushing a NEW branch. Commits, pushes of existing
# branches, deletes and tags are never blocked.
#
# Load-bearing assertions:
#   * POSITIVE CONTROL: over hygiene.maxWorktrees, a real `git push` of a new
#     branch is refused, the branch does not reach the remote, and the message
#     names the config key and the drain command.
#   * A commit and a push of an EXISTING branch in the same over-limit repo
#     succeed (a hook that blocked them would strand WIP).
#   * Delete pushes pass (draining IS deleting).
#   * Escape hatches: GIT_GUARD_HYGIENE=off|warn, GIT_GUARD=0.
#   * Infrastructure worktrees locked with an exempt reason prefix do not count.
#   * Stale-branch and open-PR dimensions block the same way; an unreachable or
#     failing `gh` skips the PR dimension quietly.
#   * post-checkout warns after `git worktree add` and never fails.
#   * drain: --dry-run changes nothing; --apply removes only clean, merged,
#     unlocked worktrees/branches, refuses dirty or locked ones, and bundles a
#     branch with unique commits instead of deleting it.
#   * drain never deletes a branch git itself treats as in use: checked out
#     in any worktree, or under an in-progress rebase, bisect or
#     rebase --update-refs (worktree list shows those as "detached"), also
#     when that starts between inspection and the delete at the same tip.
#   * `hygiene.sh defaults` sets global defaults only when unset.
# shellcheck shell=sh

# t_hyg_repo — a repo with one commit on main pushed to a bare origin, and
# hooks disabled for fixture setup (assertions run git-guard's hooks explicitly
# through core.hooksPath on the command line). Echoes the repo path.
t_hyg_repo() {
  _r="$(gg_mktemp_repo)" || return 1
  _o="$(mktemp -d "$GG_T_TMPROOT/origin.XXXXXX")" || return 1
  mkdir -p "$GG_T_TMPROOT/no-hooks"
  (
    git init -q --bare "$_o" || exit 1
    cd "$_r" || exit 1
    git config core.hooksPath "$GG_T_TMPROOT/no-hooks"
    git checkout -q -b main
    printf '# fixture\n' > README.md
    git add README.md
    git commit -q -m "initial" || exit 1
    git remote add origin "$_o"
    git push -q origin main 2>/dev/null || exit 1
    git remote set-head origin main >/dev/null 2>&1 || exit 1
    git config hygiene.drainMinAgeMinutes 0
  ) || return 1
  printf '%s' "$_r"
}

# t_hyg_gg REPO LOG CMD... — run a git command in REPO with git-guard's hooks
# from this checkout. Returns the command's exit code.
t_hyg_gg() {
  _r="$1"; _l="$2"; shift 2
  ( cd "$_r" && GIT_GUARD_RULES_DIR="$GG_BUNDLED" git -c core.hooksPath="$GG_ROOT/hooks" "$@" >"$_l" 2>&1 )
}

# t_hyg_branch REPO NAME — create branch NAME with one unique commit (stays on
# the current branch).
t_hyg_branch() {
  (
    cd "$1" || exit 1
    git checkout -q -b "$2" || exit 1
    printf '%s\n' "$2" > "$2.txt"
    git add "$2.txt" && git commit -q -m "add $2" || exit 1
    git checkout -q -
  )
}

# t_hyg_remote_has REPO BRANCH — true when origin has refs/heads/BRANCH.
t_hyg_remote_has() {
  [ -n "$(git -C "$1" ls-remote origin "refs/heads/$2" 2>/dev/null)" ]
}

# The machine's GLOBAL git config must not decide the outcome: once install.sh
# rolls hygiene.* keys out globally they would leak into every fixture. Pin an
# empty global config for the case and restore the caller's afterwards.
# t_hyg_sha256 FILE — portable sha256 (stock macOS has shasum, not sha256sum).
t_hyg_sha256() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  fi
}

t_case_hygiene() {
  t_begin "29 backlog hygiene limits (new-branch push gate, warn, drain)"
  hyg_had_gcg="${GIT_CONFIG_GLOBAL+x}"
  hyg_old_gcg="${GIT_CONFIG_GLOBAL-}"
  GIT_CONFIG_GLOBAL="$GG_T_TMPROOT/hyg-empty-global"
  : > "$GIT_CONFIG_GLOBAL"
  export GIT_CONFIG_GLOBAL
  t_hyg_body
  if [ -n "$hyg_had_gcg" ]; then GIT_CONFIG_GLOBAL="$hyg_old_gcg"; export GIT_CONFIG_GLOBAL
  else unset GIT_CONFIG_GLOBAL; fi
}

t_hyg_body() {
  hyg="$GG_ROOT/hooks/common/hygiene.sh"
  [ -f "$hyg" ] || { t_fail "hooks/common/hygiene.sh missing"; return 0; }
  [ -x "$GG_ROOT/hooks/post-checkout" ] || t_fail "hooks/post-checkout missing or not executable"

  r="$(t_hyg_repo)" || { t_fail "could not build the hygiene fixture repo"; return 0; }
  log="$(gg_tmp_log)"
  wtp="$GG_T_TMPROOT/hyg-wt"
  mkdir -p "$wtp"

  # --- over the worktree limit -------------------------------------------
  git -C "$r" config hygiene.maxWorktrees 2
  git -C "$r" config hygiene.maxStaleBranches 0
  for n in 1 2 3; do
    git -C "$r" worktree add -q -b "w$n" "$wtp/w$n" >/dev/null 2>&1 || t_fail "worktree add w$n"
  done

  t_hyg_branch "$r" feat-new
  t_hyg_gg "$r" "$log" push origin feat-new; rc=$?
  ( cd "$r" && printf 'refs/heads/x %s refs/heads/x 0000000000000000000000000000000000000000\n' \
      "$(git rev-parse HEAD)" | sh "$hyg" pre-push origin "$(git remote get-url origin)" >/dev/null 2>&1 ); hrc=$?
  t_expect_rc 77 "$hrc" "hygiene.sh pre-push refuses with the distinct code 77"
  if [ "$rc" -ne 0 ]; then t_ok "new-branch push refused over hygiene.maxWorktrees (rc=$rc)"
  else t_fail "new-branch push was NOT refused over the worktree limit"; fi
  t_hyg_remote_has "$r" feat-new \
    && t_fail "refused branch reached the remote anyway" \
    || t_ok "refused branch did not reach the remote"
  grep -q "hygiene.maxWorktrees" "$log" && t_ok "refusal names hygiene.maxWorktrees" \
    || t_fail "refusal does not name hygiene.maxWorktrees"
  grep -q "git-guard hygiene drain --dry-run" "$log" && t_ok "refusal names the drain command" \
    || t_fail "refusal does not name the drain command"
  grep -q "w3" "$log" && t_ok "refusal lists the worktrees to drain" \
    || t_fail "refusal does not list the worktrees"

  # Commits and existing-branch pushes are never blocked.
  printf 'more\n' >> "$r/README.md"
  git -C "$r" add README.md
  t_hyg_gg "$r" "$log" commit -q -m "existing-branch commit"; rc=$?
  t_expect_rc 0 "$rc" "commit on an existing branch is never blocked over the limit"
  grep -q "git-guard hygiene" "$log" && t_fail "commit printed a hygiene message" \
    || t_ok "commit is silent about hygiene"
  t_hyg_gg "$r" "$log" push origin main; rc=$?
  t_expect_rc 0 "$rc" "push of an existing branch is never blocked over the limit"
  grep -q "git-guard hygiene" "$log" && t_fail "existing-branch push printed a hygiene message" \
    || t_ok "existing-branch push is silent about hygiene"

  # The ref list still reaches the downstream pre-push gate after hygiene
  # buffered it.
  ds="$GG_T_TMPROOT/hyg-downstream"
  printf '#!/bin/sh\ncat > "%s.refs"\n' "$ds" > "$ds"; chmod +x "$ds"
  printf 'again\n' >> "$r/README.md"; git -C "$r" add README.md
  git -C "$r" commit -q -m "second existing-branch commit"
  ( cd "$r" && GIT_GUARD_DOWNSTREAM_PRE_PUSH="$ds" git -c core.hooksPath="$GG_ROOT/hooks" push origin main >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "push with a downstream pre-push gate succeeds"
  grep -q "refs/heads/main" "$ds.refs" 2>/dev/null && t_ok "downstream gate received the replayed ref list" \
    || t_fail "downstream gate did not receive the ref list"

  # First publish of the default branch to a new remote is not new work.
  o2="$(mktemp -d "$GG_T_TMPROOT/origin2.XXXXXX")"; git init -q --bare "$o2"
  git -C "$r" remote add second "$o2"
  t_hyg_gg "$r" "$log" push second main; rc=$?
  t_expect_rc 0 "$rc" "first publish of main to a new remote is never blocked"

  # Tags are not branches.
  git -C "$r" tag -a -m t v-hyg-1 >/dev/null 2>&1 || git -C "$r" tag v-hyg-1
  t_hyg_gg "$r" "$log" push origin v-hyg-1; rc=$?
  t_expect_rc 0 "$rc" "tag push is never blocked"

  # Escape hatches.
  ( cd "$r" && GIT_GUARD_HYGIENE=warn GIT_GUARD_RULES_DIR="$GG_BUNDLED" \
      git -c core.hooksPath="$GG_ROOT/hooks" push origin feat-new >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "GIT_GUARD_HYGIENE=warn lets the new branch through"
  grep -q "git-guard hygiene WARN" "$log" && t_ok "warn mode still prints the warning" \
    || t_fail "warn mode printed no warning"
  t_hyg_branch "$r" feat-off
  ( cd "$r" && GIT_GUARD_HYGIENE=off git -c core.hooksPath="$GG_ROOT/hooks" push origin feat-off >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "GIT_GUARD_HYGIENE=off lets the new branch through"
  t_hyg_branch "$r" feat-bypass
  ( cd "$r" && GIT_GUARD=0 git -c core.hooksPath="$GG_ROOT/hooks" push origin feat-bypass >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "GIT_GUARD=0 bypasses the hygiene gate"
  t_hyg_branch "$r" feat-cfg
  git -C "$r" config hygiene.mode off
  t_hyg_gg "$r" "$log" push origin feat-cfg; rc=$?
  t_expect_rc 0 "$rc" "hygiene.mode=off (git config) lets the new branch through"
  git -C "$r" config --unset hygiene.mode

  # Delete pushes pass even over the limit.
  t_hyg_gg "$r" "$log" push origin --delete feat-off; rc=$?
  t_expect_rc 0 "$rc" "delete push is never blocked"

  # Exempt infrastructure locks are not counted (3 -> 2 counted == limit).
  git -C "$r" config hygiene.exemptLockPrefix "vigil.fleet-build/"
  git -C "$r" worktree lock --reason "vigil.fleet-build/pin" "$wtp/w3"
  t_hyg_branch "$r" feat-exempt
  t_hyg_gg "$r" "$log" push origin feat-exempt; rc=$?
  t_expect_rc 0 "$rc" "worktree locked with an exempt reason prefix is not counted"
  git -C "$r" worktree unlock "$wtp/w3"
  git -C "$r" config --unset hygiene.exemptLockPrefix

  # --- post-checkout warns after `git worktree add` ------------------------
  t_hyg_gg "$r" "$log" worktree add -q -b w4 "$wtp/w4"; rc=$?
  t_expect_rc 0 "$rc" "post-checkout never fails a worktree add"
  grep -q "git-guard hygiene WARN" "$log" && t_ok "post-checkout warns when worktrees exceed the limit" \
    || t_fail "post-checkout printed no warning over the limit"
  t_hyg_gg "$r" "$log" checkout -q main; rc=$?
  grep -q "git-guard hygiene" "$log" \
    && t_fail "post-checkout warned on an ordinary branch checkout (should be quiet)" \
    || t_ok "post-checkout is quiet on an ordinary checkout"

  # --- drain --------------------------------------------------------------
  # w1: clean + merged (tip == main's ancestor) -> removable.
  # w2: dirty -> refused.   w3: locked -> refused.   w4: clean + merged.
  # Age guard: with the default (1440 min) a worktree whose HEAD just moved is
  # kept, because it may be another agent's live checkout.
  git -C "$r" config --unset hygiene.drainMinAgeMinutes
  ( cd "$r" && sh "$hyg" drain --apply >"$log" 2>&1 )
  [ -d "$wtp/w1" ] && [ -d "$wtp/w4" ] && t_ok "drain keeps worktrees whose HEAD moved recently (default age guard)" \
    || t_fail "drain removed a freshly created worktree despite the age guard"
  grep -q "drainMinAgeMinutes" "$log" && t_ok "age-guard keep is explained" || t_fail "age-guard keep not explained"
  git -C "$r" config hygiene.drainMinAgeMinutes 0
  printf 'wip\n' > "$wtp/w2/wip.txt"
  git -C "$r" worktree lock --reason "agent busy" "$wtp/w3"
  ( cd "$r" && sh "$hyg" drain --dry-run >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "drain --dry-run exits 0"
  git -C "$r" rev-parse -q --verify refs/heads/w1 >/dev/null || t_fail "drain --dry-run deleted branch w1"
  [ -d "$wtp/w1" ] && [ -d "$wtp/w4" ] && t_ok "drain --dry-run removed nothing" \
    || t_fail "drain --dry-run removed a worktree"
  grep -q "w1" "$log" && t_ok "dry run lists the drainable worktree" || t_fail "dry run did not list w1"

  ( cd "$r" && sh "$hyg" drain --apply >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "drain --apply exits 0"
  [ ! -d "$wtp/w1" ] && t_ok "drain --apply removed the clean merged worktree" \
    || t_fail "drain --apply kept the clean merged worktree w1"
  git -C "$r" rev-parse -q --verify refs/heads/w1 >/dev/null \
    && t_fail "drain --apply kept the merged branch w1" \
    || t_ok "drain --apply deleted the merged branch w1"
  [ -f "$wtp/w2/wip.txt" ] && t_ok "drain --apply refused the dirty worktree" \
    || t_fail "drain --apply removed a DIRTY worktree"
  [ ! -d "$wtp/w4" ] && t_ok "drain --apply removed the second clean merged worktree (w4)" \
    || t_fail "drain --apply kept the clean merged worktree w4"
  [ -d "$wtp/w3" ] && t_ok "drain --apply refused the locked worktree" \
    || t_fail "drain --apply removed a LOCKED worktree"
  git -C "$r" worktree unlock "$wtp/w3"

  # Unique work: a stale branch whose upstream is gone and whose commit is not
  # on main is bundled, never deleted.
  t_hyg_branch "$r" gone-unique
  git -C "$r" push -q origin gone-unique 2>/dev/null
  git -C "$r" branch -q --set-upstream-to=origin/gone-unique gone-unique
  git -C "$r" push -q origin --delete gone-unique 2>/dev/null
  git -C "$r" fetch -q --prune origin
  pres="$GG_T_TMPROOT/hyg-preserve"
  git -C "$r" config hygiene.preserveDir "$pres"
  ( cd "$r" && sh "$hyg" drain --apply >"$log" 2>&1 ); rc=$?
  git -C "$r" rev-parse -q --verify refs/heads/gone-unique >/dev/null \
    && t_ok "branch with unique commits is kept" || t_fail "branch with UNIQUE commits was deleted"
  ls "$pres"/*/gone-unique*.bundle >/dev/null 2>&1 \
    && t_ok "unique branch preserved as a bundle" || t_fail "no bundle written for the unique branch"
  bfile="$(ls "$pres"/*/gone-unique*.bundle 2>/dev/null | head -n1)"
  if [ -n "$bfile" ] && [ -f "$bfile.sha256" ] &&
     [ "$(awk '{print $1}' "$bfile.sha256")" = "$(t_hyg_sha256 "$bfile")" ]; then
    t_ok "bundle has a matching .sha256 sidecar"
  else t_fail "bundle .sha256 sidecar missing or wrong"; fi
  [ -z "$(git -C "$r" for-each-ref refs/git-guard-preserve)" ] \
    && t_ok "temporary preservation ref removed after bundling" \
    || t_fail "temporary preservation ref left behind"

  # --- preservation is fail-closed (squash/patch-equivalent work) ----------
  # pe-wt (in a worktree) and pe-br (upstream deleted on merge) are
  # cherry-picked onto main, so they are integrated by patch but NOT
  # ancestors: removal needs a verified bundle first.
  r3="$(t_hyg_repo)" || { t_fail "fixture r3"; return 0; }
  t_hyg_branch "$r3" pe-wt
  t_hyg_branch "$r3" pe-br
  (
    cd "$r3" || exit 1
    # Advance main first: replaying onto the SAME parent within one second
    # reproduces the identical commit (same tree, author, dates), which would
    # make the branch a plain ancestor and the test vacuous on a fast host.
    printf 'advance
' > advance.txt
    git add advance.txt && git commit -q -m "advance main" || exit 1
    git cherry-pick pe-wt pe-br >/dev/null 2>&1 || exit 1
    git push -q origin main pe-br 2>/dev/null || exit 1
    # Merged-and-deleted on GitHub: the upstream is gone after a prune.
    git branch -q --set-upstream-to=origin/pe-br pe-br || exit 1
    git push -q origin --delete pe-br 2>/dev/null || exit 1
    git fetch -q --prune origin || exit 1
    git worktree add -q "$wtp/pe-wt" pe-wt >/dev/null 2>&1 || exit 1
  ) || t_fail "could not build the patch-equivalent fixture"
  printf 'not a dir\n' > "$GG_T_TMPROOT/hyg-blocker"
  git -C "$r3" config hygiene.preserveDir "$GG_T_TMPROOT/hyg-blocker/sub"
  if git -C "$r3" merge-base --is-ancestor pe-wt main; then
    t_fail "fixture: pe-wt is an ancestor of main, so the bundle path is not exercised"
  else t_ok "fixture: pe-wt is patch-equivalent, not an ancestor"; fi
  ( cd "$r3" && sh "$hyg" drain --apply >"$log" 2>&1 )
  [ -d "$wtp/pe-wt" ] && t_ok "failed bundle: patch-equivalent worktree NOT removed" \
    || t_fail "worktree removed although its bundle could not be written"
  git -C "$r3" rev-parse -q --verify refs/heads/pe-wt >/dev/null \
    && t_ok "failed bundle: worktree branch NOT deleted" || t_fail "branch pe-wt deleted after a failed bundle"
  git -C "$r3" rev-parse -q --verify refs/heads/pe-br >/dev/null \
    && t_ok "failed bundle: stale branch NOT deleted" || t_fail "branch pe-br deleted after a failed bundle"
  grep -q "PRESERVE FAILED" "$log" && t_ok "failed bundle is reported" || t_fail "failed bundle not reported"
  pres3="$GG_T_TMPROOT/hyg-preserve3"
  git -C "$r3" config hygiene.preserveDir "$pres3"
  ( cd "$r3" && sh "$hyg" drain --apply >"$log" 2>&1 )
  [ ! -d "$wtp/pe-wt" ] && ! git -C "$r3" rev-parse -q --verify refs/heads/pe-br >/dev/null \
    && t_ok "with a writable preserve dir the patch-equivalent work is drained" \
    || t_fail "patch-equivalent work not drained once preservation can succeed"
  [ "$(ls "$pres3"/*/pe-*.bundle 2>/dev/null | wc -l | tr -d ' ')" = "2" ] \
    && t_ok "both patch-equivalent tips were bundled before deletion" \
    || t_fail "expected 2 bundles for pe-wt and pe-br"
  gg_rmrepo "$r3"

  # --- review findings: detached worktrees, quoted names, ancestor -d ------
  r4="$(t_hyg_repo)" || { t_fail "fixture r4"; return 0; }
  git -C "$r4" config hygiene.preserveDir "$GG_T_TMPROOT/hyg-preserve4"
  # A clean detached worktree at an ancestor of the base drains (an empty
  # branch field used to shift the record and keep it forever).
  git -C "$r4" worktree add -q --detach "$wtp/det" main >/dev/null 2>&1
  # A branch whose only change is a non-ASCII, glob-like file name is NOT on
  # main: it must never be judged content-equivalent (quoted pathspec).
  (
    cd "$r4" || exit 1
    git checkout -q -b sq || exit 1
    printf 'cv\n' > "$(printf 'r\303\251sum\303\251[1].md')"
    git add -A && git commit -q -m "non-ascii file" || exit 1
    git checkout -q main
    git push -q origin sq 2>/dev/null || exit 1
    git branch -q --set-upstream-to=origin/sq sq || exit 1
    git push -q origin --delete sq 2>/dev/null || exit 1
    git fetch -q --prune origin || exit 1
  ) || t_fail "could not build the r4 fixture"
  # An ancestor of origin/main that is NOT merged into the (behind) local HEAD:
  # `branch -d` refuses, and the exact-tip delete must succeed with no bundle.
  (
    cd "$r4" || exit 1
    git checkout -q -b anc || exit 1
    printf 'a\n' > anc.txt && git add anc.txt && git commit -q -m "anc" || exit 1
    git checkout -q main
    git push -q origin anc:main 2>/dev/null || exit 1
    git fetch -q origin || exit 1
  ) || t_fail "could not build the ancestor fixture"
  ( cd "$r4" && sh "$hyg" drain --apply >"$log" 2>&1 )
  [ ! -d "$wtp/det" ] && t_ok "clean detached worktree at an ancestor is drained" \
    || t_fail "detached worktree was not drained"
  git -C "$r4" rev-parse -q --verify refs/heads/sq >/dev/null \
    && t_ok "unmerged non-ASCII/glob-named change is kept" || t_fail "unmerged non-ASCII branch was DELETED"
  if grep "content-equivalent" "$log" | grep -q "branch sq "; then
    t_fail "non-ASCII change judged content-equivalent"
  else t_ok "non-ASCII change not judged content-equivalent"; fi
  git -C "$r4" rev-parse -q --verify refs/heads/anc >/dev/null \
    && t_fail "ancestor branch kept although merged into origin/main" || t_ok "ancestor branch deleted although -d refused"
  ls "$GG_T_TMPROOT/hyg-preserve4"/*/anc-*.bundle >/dev/null 2>&1 \
    && t_fail "ancestor branch got a (full-history) bundle" || t_ok "ancestor branch needed no bundle"
  gg_rmrepo "$r4"

  # --- a signal ends drain: no removals after TERM, temp dir cleaned -------
  # (TERM, not INT: a background job in a non-interactive shell ignores INT.)
  r5="$(t_hyg_repo)" || { t_fail "fixture r5"; return 0; }
  git -C "$r5" worktree add -q --detach "$wtp/sig" main >/dev/null 2>&1
  tdir="$GG_T_TMPROOT/hyg-tmp5"; mkdir -p "$tdir"
  ( cd "$r5" && TMPDIR="$tdir" GIT_GUARD_HYGIENE_TEST_PAUSE=3 exec sh "$hyg" drain --apply >"$log" 2>&1 ) &
  dpid=$!
  sleep 1
  kill -TERM "$dpid" 2>/dev/null
  wait "$dpid"; rc=$?
  [ "$rc" -ne 0 ] && t_ok "TERM during drain exits non-zero (rc=$rc)" || t_fail "TERM during drain exited 0"
  [ -d "$wtp/sig" ] && t_ok "nothing removed after TERM" || t_fail "drain kept removing after TERM"
  [ -z "$(ls -A "$tdir" 2>/dev/null)" ] && t_ok "temp dir removed on TERM" || t_fail "temp dir left behind after TERM"
  gg_rmrepo "$r5"

  # --- exact-tip guards: a ref that moves after inspection is kept ---------
  r6="$(t_hyg_repo)" || { t_fail "fixture r6"; return 0; }
  (
    cd "$r6" || exit 1
    git branch mv                      # at C0, merged
    printf 'c1\n' > c1.txt && git add c1.txt && git commit -q -m c1 || exit 1
    git push -q origin main 2>/dev/null || exit 1
    git worktree add -q --detach "$wtp/mvwt" HEAD~1 >/dev/null 2>&1 || exit 1
  ) || t_fail "could not build the r6 fixture"
  c1="$(git -C "$r6" rev-parse main)"
  # Branch moves to another MERGED commit (C1) between inspection and delete:
  # `branch -d` would still delete it; the compare-and-delete must not.
  git -C "$r6" worktree lock --reason "hold" "$wtp/mvwt"
  ( cd "$r6" && GIT_GUARD_HYGIENE_TEST_PAUSE_AT=delete \
      GIT_GUARD_HYGIENE_TEST_HOOK="git branch -f mv $c1" \
      sh "$hyg" drain --apply >"$log" 2>&1 )
  [ "$(git -C "$r6" rev-parse -q --verify refs/heads/mv)" = "$c1" ] \
    && t_ok "branch moved after inspection is kept (exact-tip delete)" \
    || t_fail "branch that MOVED after inspection was deleted"
  git -C "$r6" worktree unlock "$wtp/mvwt"
  # Worktree HEAD moves between inspection and removal: keep it.
  ( cd "$r6" && GIT_GUARD_HYGIENE_TEST_PAUSE_AT=remove \
      GIT_GUARD_HYGIENE_TEST_HOOK="git -C '$wtp/mvwt' checkout -q --detach $c1" \
      sh "$hyg" drain --apply >"$log" 2>&1 )
  [ -d "$wtp/mvwt" ] && t_ok "worktree whose HEAD changed after inspection is kept" \
    || t_fail "worktree removed although its HEAD changed after inspection"
  grep -q "changed since inspection" "$log" && t_ok "changed worktree keep is explained" \
    || t_fail "changed worktree keep not explained"
  gg_rmrepo "$r6"

  # --- custody can change without a tip movement --------------------------
  r7="$(t_hyg_repo)" || { t_fail "fixture r7"; return 0; }
  git -C "$r7" branch late-checkout
  reviewed="$(git -C "$r7" rev-parse HEAD)"
  ( cd "$r7" && GIT_GUARD_HYGIENE_TEST_PAUSE_AT=delete \
      GIT_GUARD_HYGIENE_TEST_HOOK='git checkout -q late-checkout' \
      sh "$hyg" drain --apply >"$log" 2>&1 )
  [ "$(git -C "$r7" rev-parse -q --verify refs/heads/late-checkout)" = "$reviewed" ] \
    && t_ok "same-tip branch checked out after inspection is retained" \
    || t_fail "drain deleted the newly checked-out same-tip branch"
  git -C "$r7" checkout -q main
  git -C "$r7" branch late-linked
  ( cd "$r7" && GIT_GUARD_HYGIENE_TEST_PAUSE_AT=delete \
      GIT_GUARD_HYGIENE_TEST_HOOK="git worktree add -q '$wtp/late-linked' late-linked" \
      sh "$hyg" drain --apply >"$log" 2>&1 )
  [ "$(git -C "$r7" rev-parse -q --verify refs/heads/late-linked)" = "$reviewed" ] \
    && t_ok "same-tip branch newly registered in another worktree is retained" \
    || t_fail "drain deleted a branch newly registered in another worktree"
  git -C "$r7" worktree lock --reason 'active custody' "$wtp/late-linked"
  git -C "$r7" branch ignored-payload
  git -C "$r7" worktree add -q "$wtp/late-ignored" ignored-payload
  printf '*.cache\n' >> "$(git -C "$r7" rev-parse --absolute-git-dir)/info/exclude"
  ( cd "$r7" && GIT_GUARD_HYGIENE_TEST_PAUSE_AT=remove \
      GIT_GUARD_HYGIENE_TEST_HOOK="printf 'owned ignored bytes\\n' > '$wtp/late-ignored/new.cache'" \
      sh "$hyg" drain --apply >"$log" 2>&1 )
  [ -f "$wtp/late-ignored/new.cache" ] && \
      [ "$(cat "$wtp/late-ignored/new.cache")" = 'owned ignored bytes' ] \
    && t_ok "ignored work appearing after inspection retains the worktree and bytes" \
    || t_fail "drain removed ignored work that appeared after inspection"
  git -C "$r7" worktree unlock "$wtp/late-linked"
  gg_rmrepo "$r7"

  # An unavailable/erroring final registration scan must never permit deletion.
  r8="$(t_hyg_repo)" || { t_fail "fixture r8"; return 0; }
  git -C "$r8" branch scan-failure
  reviewed="$(git -C "$r8" rev-parse HEAD)"
  scanbin="$GG_T_TMPROOT/scan-error-bin"; mkdir -p "$scanbin"
  realgrep="$(command -v grep)"
  printf '#!/bin/sh\ncase "$1" in -Fqx) exit 2 ;; esac\nexec "%s" "$@"\n' "$realgrep" > "$scanbin/grep"
  chmod +x "$scanbin/grep"
  ( cd "$r8" && PATH="$scanbin:$PATH" sh "$hyg" drain --apply >"$log" 2>&1 )
  [ "$(git -C "$r8" rev-parse -q --verify refs/heads/scan-failure)" = "$reviewed" ] \
    && t_ok "failed final checkout scan retains the reviewed branch" \
    || t_fail "final checkout scan failure allowed branch deletion"
  gg_rmrepo "$r8"

  # --- a branch under rebase or bisect is in use --------------------------
  # `git worktree list` prints such a worktree as "detached", so a scan of its
  # `branch` lines misses it. git's own `branch -d` (branch_checked_out) reads
  # rebase-merge/head-name, rebase-apply/head-name, rebase-merge/update-refs
  # and BISECT_START and refuses; drain must also keep these branches, both in
  # the inventory and at the delete, including when the rebase starts after
  # inspection at the same tip.
  r9="$(t_hyg_repo)" || { t_fail "fixture r9"; return 0; }
  (
    cd "$r9" || exit 1
    for c in c1 c2 c3; do
      printf '%s\n' "$c" > "$c.txt" && git add "$c.txt" && git commit -q -m "$c" || exit 1
    done
    git push -q origin main 2>/dev/null || exit 1
    git branch rebasing && git branch bisecting && git branch upd-top && git branch upd-mid HEAD~1 || exit 1
    git worktree add -q "$wtp/rebasing" rebasing || exit 1
    git worktree add -q "$wtp/bisecting" bisecting || exit 1
    git worktree add -q "$wtp/upd-top" upd-top || exit 1
    # `--exec false` stops the rebase after its first pick: no editor needed.
    git -C "$wtp/rebasing" rebase -q --exec false HEAD~1 >/dev/null 2>&1
    git -C "$wtp/bisecting" bisect start >/dev/null 2>&1 &&
      git -C "$wtp/bisecting" bisect bad >/dev/null 2>&1 &&
      git -C "$wtp/bisecting" bisect good HEAD~3 >/dev/null 2>&1 || exit 1
    exit 0
  ) || t_fail "could not build the r9 fixture"
  r9_tip="$(git -C "$r9" rev-parse main)"
  r9_mid="$(git -C "$r9" rev-parse main~1)"
  # rebase --update-refs (git 2.38+) is optional: older git has no such state.
  r9_upd=0
  if git -C "$wtp/upd-top" rebase -q --update-refs --exec false HEAD~2 >/dev/null 2>&1 ||
     [ -f "$(git -C "$wtp/upd-top" rev-parse --absolute-git-dir)/rebase-merge/update-refs" ]; then
    r9_upd=1
  fi
  # Oracle: git itself treats each as in use. If `branch -d` deleted one, the
  # fixture is not testing what it claims.
  for b in rebasing bisecting; do
    git -C "$r9" branch -d "$b" >/dev/null 2>&1 && t_fail "fixture: git branch -d deleted $b (not in use)"
  done
  if [ "$r9_upd" = "1" ]; then
    git -C "$r9" branch -d upd-mid >/dev/null 2>&1 && t_fail "fixture: git branch -d deleted upd-mid (not in use)"
  fi
  ( cd "$r9" && sh "$hyg" report >"$log" 2>&1 )
  if grep -Eq '^    (rebasing|bisecting)  \(' "$log"; then
    t_fail "branch under rebase/bisect counted as a stale branch"
  else t_ok "branch under rebase/bisect is not counted as stale"; fi
  ( cd "$r9" && sh "$hyg" drain --apply >"$log" 2>&1 )
  [ "$(git -C "$r9" rev-parse -q --verify refs/heads/rebasing)" = "$r9_tip" ] \
    && t_ok "branch under an in-progress rebase in a worktree is retained" \
    || t_fail "drain deleted a branch that a worktree is rebasing"
  [ "$(git -C "$r9" rev-parse -q --verify refs/heads/bisecting)" = "$r9_tip" ] \
    && t_ok "branch under an in-progress bisect in a worktree is retained" \
    || t_fail "drain deleted a branch that a worktree is bisecting"
  if [ "$r9_upd" = "1" ]; then
    [ "$(git -C "$r9" rev-parse -q --verify refs/heads/upd-mid)" = "$r9_mid" ] \
      && t_ok "branch listed in a rebase --update-refs is retained" \
      || t_fail "drain deleted a branch that rebase --update-refs will rewrite"
  else
    t_skip "git $(git --version | awk '{print $3}') has no rebase --update-refs"
  fi
  # Same tip, rebase started between inspection and delete (the delete hook).
  git -C "$r9" branch late-rebase
  ( cd "$r9" && GIT_GUARD_HYGIENE_TEST_PAUSE_AT=delete \
      GIT_GUARD_HYGIENE_TEST_HOOK="git worktree add -q '$wtp/late-rebase' late-rebase && git -C '$wtp/late-rebase' rebase -q --exec false HEAD~1" \
      sh "$hyg" drain --apply >"$log" 2>&1 )
  r9_lgd="$(git -C "$wtp/late-rebase" rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -n "$r9_lgd" ] && [ -d "$r9_lgd/rebase-merge" ]; then
    [ "$(git -C "$r9" rev-parse -q --verify refs/heads/late-rebase)" = "$r9_tip" ] \
      && t_ok "same-tip branch whose rebase started after inspection is retained" \
      || t_fail "drain deleted a same-tip branch whose rebase started after inspection"
  else
    t_fail "fixture: the delete hook did not leave late-rebase mid-rebase"
  fi
  for w in rebasing late-rebase upd-top; do git -C "$wtp/$w" rebase --abort >/dev/null 2>&1; done
  git -C "$wtp/bisecting" bisect reset >/dev/null 2>&1
  gg_rmrepo "$r9"

  # --- stale-branch dimension --------------------------------------------
  r2="$(t_hyg_repo)" || { t_fail "fixture r2"; return 0; }
  git -C "$r2" config hygiene.maxWorktrees 0
  git -C "$r2" config hygiene.maxStaleBranches 1
  git -C "$r2" branch merged-a
  git -C "$r2" branch merged-b
  t_hyg_branch "$r2" feat-two
  t_hyg_gg "$r2" "$log" push origin feat-two; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "new-branch push refused over hygiene.maxStaleBranches (rc=$rc)"
  else t_fail "new-branch push NOT refused over the stale-branch limit"; fi
  grep -q "hygiene.maxStaleBranches" "$log" && t_ok "refusal names hygiene.maxStaleBranches" \
    || t_fail "refusal does not name hygiene.maxStaleBranches"
  ( cd "$r2" && sh "$hyg" drain --apply >/dev/null 2>&1 )
  t_hyg_gg "$r2" "$log" push origin feat-two; rc=$?
  t_expect_rc 0 "$rc" "after drain the same new-branch push succeeds (negative control)"

  # --- open-PR dimension (stubbed gh) --------------------------------------
  stub="$GG_T_TMPROOT/fake-gh"
  printf '#!/bin/sh\necho 9\n' > "$stub"; chmod +x "$stub"
  git -C "$r2" config hygiene.maxOpenPRs 5
  zero=0000000000000000000000000000000000000000
  tip="$(git -C "$r2" rev-parse HEAD)"
  printf 'refs/heads/pr-x %s refs/heads/pr-x %s\n' "$tip" "$zero" > "$GG_T_TMPROOT/refs-new"
  ( cd "$r2" && GIT_GUARD_HYGIENE_GH="$stub" sh "$GG_ROOT/hooks/pre-push" origin git@github.com:o/r.git \
      <"$GG_T_TMPROOT/refs-new" >"$log" 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "new-branch push refused over hygiene.maxOpenPRs (rc=$rc)"
  else t_fail "new-branch push NOT refused over the open-PR limit"; fi
  grep -q "hygiene.maxOpenPRs" "$log" && t_ok "refusal names hygiene.maxOpenPRs" \
    || t_fail "refusal does not name hygiene.maxOpenPRs"
  printf '#!/bin/sh\nexit 1\n' > "$stub"
  ( cd "$r2" && GIT_GUARD_HYGIENE_GH="$stub" sh "$GG_ROOT/hooks/pre-push" origin git@github.com:o/r.git \
      <"$GG_T_TMPROOT/refs-new" >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "a failing/offline gh skips the PR dimension quietly"

  # --- global defaults: only when unset ------------------------------------
  fh="$(mktemp -d "$GG_T_TMPROOT/hyg-home.XXXXXX")"
  printf '[hygiene]\n\tmaxWorktrees = 7\n' > "$fh/.gitconfig"
  ( HOME="$fh" GIT_CONFIG_GLOBAL="$fh/.gitconfig" sh "$hyg" defaults >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "hygiene.sh defaults exits 0"
  gget() { HOME="$fh" GIT_CONFIG_GLOBAL="$fh/.gitconfig" git config --global --get "$1"; }
  [ "$(gget hygiene.maxWorktrees)" = "7" ] && t_ok "defaults keeps an existing hygiene.maxWorktrees" \
    || t_fail "defaults overwrote hygiene.maxWorktrees (got $(gget hygiene.maxWorktrees))"
  [ "$(gget hygiene.maxStaleBranches)" = "5" ] && t_ok "defaults sets hygiene.maxStaleBranches=5" \
    || t_fail "hygiene.maxStaleBranches not defaulted (got $(gget hygiene.maxStaleBranches))"
  [ "$(gget fetch.prune)" = "true" ] && t_ok "defaults sets fetch.prune=true" || t_fail "fetch.prune not set"
  [ -z "$(gget fetch.pruneTags)" ] && t_ok "defaults leaves fetch.pruneTags alone (local-only tags survive)" \
    || t_fail "defaults set fetch.pruneTags"
  HOME="$fh" GIT_CONFIG_GLOBAL="$fh/.gitconfig" git config --global --get-all hygiene.exemptLockPrefix \
    | grep -qx "vigil.fleet-build/" && t_ok "defaults seeds the infrastructure lock prefixes" \
    || t_fail "defaults did not seed hygiene.exemptLockPrefix"
  [ -z "$(gget gc.worktreePruneExpire)" ] && t_ok "defaults leaves gc.worktreePruneExpire alone" \
    || t_fail "defaults changed gc.worktreePruneExpire"

  rm -f "$log"
  gg_rmrepo "$r"; gg_rmrepo "$r2"
}
