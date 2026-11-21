#!/bin/sh
# Category 37 — hygiene sync auto-remove: hygiene.syncRemove + drain
# --unattended (hooks/common/hygiene.sh hyg_custody, hyg_drain, hyg_sync_repo).
#
# Owner direction (2026-10-31, via team-lead): sync may remove what drain
# already proves integrated (clean, unlocked, no ignored data, HEAD unchanged
# for a day, exact-tip delete, bundle first), but only when switched on, and it
# must never touch another lane's work unless a custody check passes. Bundles
# and manifests only: ignored data is never archived, so a tree holding any is
# kept.
#
# Load-bearing assertions:
#   * POSITIVE CONTROL: with hygiene.syncRemove=true, a custody.grants line for
#     the repo and an agent-bus stub listing no claim on the item, sync removes
#     an integrated worktree (ancestor), a squash-merged worktree (with a
#     verified bundle) and a merged stale branch; the report and the
#     append-only sync-removals.jsonl manifest record each one with its Agent
#     trailer, custody reason and bundle. Each refusal below starts from this
#     same fixture, so a refusal that never fires cannot pass by accident.
#   * Default off: without hygiene.syncRemove, nothing is removed.
#   * sync --dry-run with removal on removes nothing.
#   * A failed fetch of any remote in the repo keeps everything: drain runs
#     as a dry run and the report says removal was withheld. So does an
#     upstream remote with no URL, and a hygiene.baseRef that is no remote's
#     (a local branch); a local upstream (remote ".") does not.
#   * The integration ref's own remote is fetched (codex review of #107 at
#     9ce7fe3, P1): with hygiene.baseRef on a second remote (lab/integ, a
#     slash in its name) that rolled main back after integrating sq, sq is
#     judged against the refreshed ref and kept. The positive control, the
#     same fixture left fresh, removes both worktrees and names main as the
#     default branch (hyg_base_name strips the whole remote name).
#   * A successful fetch is not proof of freshness (codex review of #107 at
#     0dca80a4, P1): with a narrow refspec that never refreshes the rolled-back
#     integration ref, and with a negative refspec that hides an upstream which
#     resumed, removal is withheld ("... is stale"). Their controls, the same
#     refspecs with nothing moved, are proven fresh by ls-remote and remove the
#     merged stale branch.
#   * index.lock (claude review of #107 at 9ce7fe3): a worktree whose index
#     is locked is kept by drain's own inspection, and one locked after
#     inspection is kept by the recheck right before removal; the unlocked
#     worktree in the same run is removed.
#   * Refusals, each keeping every item: no custody.grants file; a grants file
#     that names another repo; a claim naming the branch; a claims read that
#     fails; no agent-bus CLI; ignored data in the worktree; a repo-local
#     hygiene.drainMinAgeMinutes=0 on a fresh worktree (the one-day floor
#     holds); a branch whose reflog moved within the day, and one with no
#     reflog; a repo-local hygiene.syncRemove=false; a worktree whose HEAD
#     moves between inspection and removal; drain --unattended with
#     --allow-ignored (refused outright).
#   * In use (codex review of #107 at 2252511, P1): a process with its cwd in
#     a worktree keeps it, whether it was there at inspection or entered right
#     before removal, while the same run removes the unused items. Off Linux
#     there is no /proc to prove a tree unused, so unattended drain keeps
#     every worktree (cwd-check-unavailable), as sync keeps every checkout.
#   * hygiene.custodyBus=false grants without the claims check (the control
#     for the missing-CLI refusal).
# shellcheck shell=sh

# t_rm_fixture NAME — t_sync_fixture plus, in SY_REPO: worktree "done" at main
# (an ancestor), worktree "sq" whose commit main took as a squash, and branch
# "old" at an older main. Both worktrees' HEAD logs and the branch reflogs are
# dated 2020, so the age guard passes. Sets RM_DONE RM_SQ RM_REAL.
t_rm_fixture() {
  t_sync_fixture "$1" || return 1
  RM_DONE="$SY_ROOT/repo-done"; RM_SQ="$SY_ROOT/repo-sq"
  (
    cd "$SY_SEED" || exit 1
    git checkout -q -b sq || exit 1
    printf 'sq\n' > sq.txt; git add sq.txt; git commit -q -m "sq work" -m "Agent: claude" || exit 1
    git push -q origin sq 2>/dev/null || exit 1
    git checkout -q main
  ) || return 1
  git -C "$SY_REPO" fetch -q origin || return 1
  git -C "$SY_REPO" branch -q old HEAD || return 1
  git -C "$SY_REPO" worktree add -q -b "done" "$RM_DONE" HEAD >/dev/null 2>&1 || return 1
  git -C "$SY_REPO" worktree add -q --track -b sq "$RM_SQ" origin/sq >/dev/null 2>&1 || return 1
  (
    cd "$SY_SEED" || exit 1
    printf 'sq\n' > sq.txt; git add sq.txt; git commit -q -m "squash of sq" || exit 1
    git push -q origin main 2>/dev/null || exit 1
    git push -q origin --delete sq 2>/dev/null || exit 1
  ) || return 1
  _gd="$SY_REPO/.git"
  touch -t 202001010000 "$_gd/worktrees/repo-done/logs/HEAD" "$_gd/worktrees/repo-sq/logs/HEAD" \
    "$_gd/logs/refs/heads/old" "$_gd/logs/refs/heads/done" "$_gd/logs/refs/heads/sq" || return 1
  RM_REAL="$(cd "$SY_REPO" && pwd -P)"
  mkdir -p "$XDG_CONFIG_HOME/git-guard"
  printf '# test grant\n%s\t*\n' "$RM_REAL" > "$XDG_CONFIG_HOME/git-guard/custody.grants"
  : > "$RM_CLAIMS"
  git config --file "$GIT_CONFIG_GLOBAL" hygiene.syncRemove true
  return 0
}

# t_rm_expect_kept NAME REASON — sync, then every item survives and the drain
# lines in the report name REASON.
t_rm_expect_kept() {
  # shellcheck disable=SC2086  # RM_ARGS is empty or one flag
  t_sync_run "$sylog" $RM_ARGS
  if [ -d "$RM_DONE" ] && [ -d "$RM_SQ" ] && git -C "$SY_REPO" rev-parse -q --verify refs/heads/old >/dev/null &&
     git -C "$SY_REPO" rev-parse -q --verify refs/heads/done >/dev/null; then
    t_ok "$1: nothing removed"
  else
    t_fail "$1: an item was removed"; grep -F '"lines"' "$report" | head -c 2000 >&2
  fi
  if grep -Fq -- "$2" "$report"; then t_ok "$1: report names '$2'"
  else t_fail "$1: report lacks '$2'"; head -c 3000 "$report" | sed 's/^/      /' >&2; fi
}

t_case_sync_remove() {
  t_begin "37 hygiene sync auto-remove (syncRemove, custody grants, agent-bus claims, unattended drain)"
  rm_had_gcg="${GIT_CONFIG_GLOBAL+x}"; rm_old_gcg="${GIT_CONFIG_GLOBAL-}"
  rm_had_xdg="${XDG_STATE_HOME+x}"; rm_old_xdg="${XDG_STATE_HOME-}"
  rm_had_xcfg="${XDG_CONFIG_HOME+x}"; rm_old_xcfg="${XDG_CONFIG_HOME-}"
  rm_had_bus="${GIT_GUARD_AGENT_BUS+x}"; rm_old_bus="${GIT_GUARD_AGENT_BUS-}"
  rm_had_cb="${GIT_GUARD_CUSTODY_BUS+x}"; rm_old_cb="${GIT_GUARD_CUSTODY_BUS-}"
  GIT_CONFIG_GLOBAL="$GG_T_TMPROOT/rm-global"; : > "$GIT_CONFIG_GLOBAL"
  XDG_STATE_HOME="$GG_T_TMPROOT/rm-state"; XDG_CONFIG_HOME="$GG_T_TMPROOT/rm-config"
  rm -rf "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"
  RM_CLAIMS="$GG_T_TMPROOT/rm-claims.json"
  GIT_GUARD_AGENT_BUS="$GG_T_TMPROOT/rm-agent-bus"
  # The stub prints a claims listing whose entries are the lines of RM_CLAIMS;
  # with RM_CLAIMS_FAIL present it fails, as an unreachable hub does.
  printf '#!/bin/sh\n[ -e "%s.fail" ] && exit 3\nprintf "{\\"claims\\":["; cat "%s"; printf "],\\"count\\":0}\\n"\n' \
    "$RM_CLAIMS" "$RM_CLAIMS" > "$GIT_GUARD_AGENT_BUS"
  chmod +x "$GIT_GUARD_AGENT_BUS"
  unset GIT_GUARD_CUSTODY_BUS
  export GIT_CONFIG_GLOBAL XDG_STATE_HOME XDG_CONFIG_HOME GIT_GUARD_AGENT_BUS
  t_sync_remove_body
  if [ -n "$rm_had_gcg" ]; then GIT_CONFIG_GLOBAL="$rm_old_gcg"; export GIT_CONFIG_GLOBAL; else unset GIT_CONFIG_GLOBAL; fi
  if [ -n "$rm_had_xdg" ]; then XDG_STATE_HOME="$rm_old_xdg"; export XDG_STATE_HOME; else unset XDG_STATE_HOME; fi
  if [ -n "$rm_had_xcfg" ]; then XDG_CONFIG_HOME="$rm_old_xcfg"; export XDG_CONFIG_HOME; else unset XDG_CONFIG_HOME; fi
  if [ -n "$rm_had_bus" ]; then GIT_GUARD_AGENT_BUS="$rm_old_bus"; export GIT_GUARD_AGENT_BUS; else unset GIT_GUARD_AGENT_BUS; fi
  if [ -n "$rm_had_cb" ]; then GIT_GUARD_CUSTODY_BUS="$rm_old_cb"; export GIT_GUARD_CUSTODY_BUS; else unset GIT_GUARD_CUSTODY_BUS; fi
}

t_sync_remove_body() {
  sylog="$(gg_tmp_log)"
  report="$XDG_STATE_HOME/git-guard/sync-report.json"
  manifest="$XDG_STATE_HOME/git-guard/sync-removals.jsonl"
  RM_ARGS=""

  # --- off Linux: no /proc to prove a tree unused, so no worktree is removed --
  # (the removal controls below need /proc; CI runs them on Linux)
  if ! t_sync_can_ff; then
    t_rm_fixture nocwd || { t_fail "could not build the remove fixture"; return 0; }
    t_sync_run "$sylog"
    [ -d "$RM_DONE" ] && [ -d "$RM_SQ" ] && t_ok "off Linux: unattended drain keeps every worktree (cwd check unavailable)" \
      || t_fail "off Linux: a worktree was removed without a cwd check"
    grep -Fq "cwd-check-unavailable" "$report" && t_ok "off Linux: the report names cwd-check-unavailable" \
      || { t_fail "off Linux: report lacks cwd-check-unavailable"; head -c 3000 "$report" >&2; }
    t_skip "off Linux: removal positive control and in-use controls need /proc"
  else
    t_rm_positive_and_in_use
  fi
  t_rm_refusals
}

t_rm_positive_and_in_use() {
  # --- positive control ----------------------------------------------------
  t_rm_fixture ctl || { t_fail "could not build the remove fixture"; return 0; }
  t_sync_run "$sylog"; rc=$?
  t_expect_rc 0 "$rc" "sync with removal on exits 0"
  [ ! -e "$RM_DONE" ] && t_ok "integrated (ancestor) worktree removed" \
    || { t_fail "ancestor worktree was not removed"; head -c 3000 "$report" >&2; }
  [ ! -e "$RM_SQ" ] && t_ok "squash-merged worktree removed" || t_fail "squash-merged worktree was not removed"
  git -C "$SY_REPO" rev-parse -q --verify refs/heads/old >/dev/null \
    && t_fail "merged stale branch was not removed" || t_ok "merged stale branch removed"
  git -C "$SY_REPO" rev-parse -q --verify refs/heads/done >/dev/null \
    && t_fail "worktree branch done kept" || t_ok "the removed worktree's branch is deleted too"
  sqb="$(ls "$XDG_STATE_HOME"/git-guard/preserve/repo/sq-*.bundle 2>/dev/null | head -1)"
  if [ -n "$sqb" ] && [ -f "$sqb.sha256" ] && git -C "$SY_REPO" bundle verify -q "$sqb" >/dev/null 2>&1; then
    t_ok "squash-merged tip preserved as a verified bundle with its sha256"
  else t_fail "no verified bundle for the squash-merged tip"; fi
  if gg_has_python; then
    "$(gg_python)" -c '
import json, sys
d = json.load(open(sys.argv[1]))
r = {(x["kind"], x["branch"]): x for x in d["removals"]}
ok = (("worktree", "sq") in r and r[("worktree", "sq")]["bundle"] and r[("worktree", "sq")]["agent"] == "claude"
      and r[("worktree", "sq")]["custody"].startswith("granted") and ("branch", "old") in r and ("worktree", "done") in r)
m = [json.loads(l) for l in open(sys.argv[2])]
ok = ok and any(x["kind"] == "worktree" and x["branch"] == "sq" and x["bundle"] for x in m)
sys.exit(0 if ok else 1)' "$report" "$manifest" \
      && t_ok "report removals and the manifest record each removal with agent, custody and bundle" \
      || { t_fail "removal records incomplete"; cat "$manifest" >&2; }
  else t_skip "python absent: removal records not parsed"; fi

  # --- in use: a process working in the tree keeps it (codex review of #107 at
  # 2252511, P1: sync logged `skip: in-use` and drain then removed the tree).
  # The same run removes the other items, so the veto is per item and the
  # removal path is live.
  t_rm_fixture inuse || t_fail "fixture inuse"
  ( cd "$RM_DONE" && exec sleep 60 ) &
  rm_pid=$!
  t_sync_run "$sylog"
  if [ -d "$RM_DONE" ] && kill -0 "$rm_pid" 2>/dev/null; then
    t_ok "worktree with a live process in it kept"
  else t_fail "worktree with a live process in it was removed"; head -c 3000 "$report" >&2; fi
  grep -Fq "in-use (pid $rm_pid has its cwd in the tree)" "$report" && t_ok "report names the in-use pid" \
    || t_fail "report lacks the in-use pid"
  [ ! -e "$RM_SQ" ] && t_ok "in-use run still removes the unused squash-merged worktree" \
    || t_fail "in-use run kept the unused worktree too"
  kill "$rm_pid" 2>/dev/null; wait "$rm_pid" 2>/dev/null
  # A process that enters the tree after inspection, right before removal.
  t_rm_fixture inuse-late || t_fail "fixture inuse-late"
  rm_pidf="$GG_T_TMPROOT/rm-late.pid"; rm -f "$rm_pidf"
  ( GIT_GUARD_HYGIENE_TEST_PAUSE_AT=remove \
      GIT_GUARD_HYGIENE_TEST_HOOK="[ -e '$rm_pidf' ] || { cd '$RM_DONE' && { sleep 60 </dev/null >/dev/null 2>&1 & echo \$! > '$rm_pidf'; }; }" \
      t_sync_run "$sylog" )
  rm_pid="$(cat "$rm_pidf" 2>/dev/null)"
  [ -n "$rm_pid" ] && t_ok "late-entry fixture started its process" || t_fail "late-entry fixture started no process"
  [ -d "$RM_DONE" ] && t_ok "worktree a process entered after inspection kept" \
    || t_fail "worktree a process entered after inspection was removed"
  grep -Fq "has its cwd in the tree) at removal" "$report" && t_ok "report names the in-use veto at removal" \
    || { t_fail "report lacks the at-removal veto"; grep -F '"lines"' "$report" | head -c 2000 >&2; }
  [ -z "$rm_pid" ] || { kill "$rm_pid" 2>/dev/null; :; }

  # --- index.lock taken after inspection (claude review of #107 at 9ce7fe3):
  # a `git -C` process can hold a worktree's index.lock with its cwd
  # elsewhere, so the cwd veto does not see it. The hook locks both
  # worktrees' indexes at the first removal pause (worktree order is the
  # filesystem's), so one is caught by the recheck right before removal.
  t_rm_fixture idxlock-late || t_fail "fixture idxlock-late"
  rm_gdd="$SY_REPO/.git/worktrees/repo-done"; rm_gds="$SY_REPO/.git/worktrees/repo-sq"
  ( GIT_GUARD_HYGIENE_TEST_PAUSE_AT=remove \
      GIT_GUARD_HYGIENE_TEST_HOOK="touch '$rm_gdd/index.lock' '$rm_gds/index.lock'" \
      t_sync_run "$sylog" )
  [ -d "$RM_DONE" ] && [ -d "$RM_SQ" ] && t_ok "worktrees whose index.lock appeared after inspection kept" \
    || { t_fail "a worktree whose index.lock appeared after inspection was removed"; grep -F '"lines"' "$report" | head -c 2000 >&2; }
  grep -Fq "(locked: index.lock at removal" "$report" && t_ok "report names the index.lock veto at removal" \
    || { t_fail "report lacks the index.lock veto at removal"; grep -F '"lines"' "$report" | head -c 2000 >&2; }
  rm -f "$rm_gdd/index.lock" "$rm_gds/index.lock"

  # --- integration ref on a second remote (codex review of #107 at 9ce7fe3,
  # P1): the positive control. hygiene.baseRef names a ref of remote
  # lab/integ (a slash in the name, matched against `git remote`), written
  # short; origin/HEAD is gone and stays gone, so baseRef is the base. Sync
  # fetches lab/integ and removes the integrated items.
  t_rm_baseref_fixture baseref-ok || t_fail "fixture baseref-ok"
  git -C "$SY_REPO" config hygiene.baseRef lab/integ/main
  t_sync_run "$sylog"
  [ ! -e "$RM_DONE" ] && [ ! -e "$RM_SQ" ] && t_ok "baseRef on a fresh second remote: integrated worktrees removed" \
    || { t_fail "baseRef on a fresh second remote: integrated worktrees kept"; grep -F '"lines"' "$report" | head -c 2000 >&2; }
  grep -Fq '"remote":"lab/integ","result":"ok"' "$report" && t_ok "baseRef on a fresh second remote: that remote was fetched" \
    || t_fail "baseRef on a fresh second remote: that remote was not fetched"
  # hyg_base_name strips the whole remote name: the primary on main is the
  # default branch, not "integ/main".
  grep -Fq "not-default-branch" "$report" && t_fail "baseRef on a slashed remote misnames the default branch" \
    || t_ok "baseRef on a slashed remote: the primary on main is the default branch"

  # --- index.lock at inspection, with the control in the same run: the
  # locked worktree is kept, the unlocked one is removed.
  t_rm_fixture idxlock-ctl || t_fail "fixture idxlock-ctl"
  : > "$SY_REPO/.git/worktrees/repo-done/index.lock"
  t_sync_run "$sylog"
  [ ! -e "$RM_SQ" ] && t_ok "index.lock run still removes the unlocked worktree" \
    || t_fail "index.lock run kept the unlocked worktree too"
  rm -f "$SY_REPO/.git/worktrees/repo-done/index.lock"
}

# t_rm_resume_old REMOTE_REPO — add a commit to branch old in the bare
# REMOTE_REPO through a throwaway clone (an upstream that resumed after its
# merge).
t_rm_resume_old() {
  rm -rf "$1.work"
  (
    git clone -q -b old "$1" "$1.work" 2>/dev/null && cd "$1.work" || exit 1
    git config user.email tester@git-guard.local; git config user.name git-guard-tester
    git config commit.gpgsign false; git config core.hooksPath "$GG_T_TMPROOT/no-hooks"
    printf 'resumed\n' > resumed.txt; git add resumed.txt; git commit -q -m "resumed after merge" || exit 1
    git push -q origin old 2>/dev/null
  )
}

# t_rm_baseref_fixture NAME — t_rm_fixture plus a second remote, lab/integ,
# cloned from origin after the squash (so its main integrates sq), with
# origin/HEAD removed and kept removed (remote.origin.followRemoteHEAD=never:
# Git 2.48+ fetch otherwise recreates it, and origin/HEAD outranks
# hygiene.baseRef). The caller sets hygiene.baseRef. Sets RM_INTEG.
t_rm_baseref_fixture() {
  t_rm_fixture "$1" || return 1
  RM_INTEG="$SY_ROOT/../integ.git"; rm -rf "$RM_INTEG"
  git clone -q --bare "$SY_ORIGIN" "$RM_INTEG" 2>/dev/null || return 1
  git -C "$SY_REPO" remote add lab/integ "$RM_INTEG" || return 1
  git -C "$SY_REPO" fetch -q lab/integ || return 1
  git -C "$SY_REPO" config remote.origin.followRemoteHEAD never
  git -C "$SY_REPO" remote set-head origin -d >/dev/null 2>&1 || return 1
  return 0
}

t_rm_refusals() {
  # --- off and dry ------------------------------------------------------------
  t_rm_fixture off || t_fail "fixture off"
  git config --file "$GIT_CONFIG_GLOBAL" --unset hygiene.syncRemove
  t_rm_expect_kept "hygiene.syncRemove unset (default off)" "would remove"
  t_rm_fixture dry || t_fail "fixture dry"
  RM_ARGS="--dry-run"
  t_rm_expect_kept "sync --dry-run with removal on" "custody: granted"
  RM_ARGS=""
  t_rm_fixture optout || t_fail "fixture optout"
  git -C "$SY_REPO" config hygiene.syncRemove false
  t_rm_expect_kept "repo-local hygiene.syncRemove=false" "would remove"
  # A failed fetch keeps everything (codex review of #107 at dd0452f, P1).
  # Integration is judged from remote-tracking refs, so after a failed fetch
  # they are stale and can miss an upstream that resumed after its merge. The
  # drain then runs as a dry run. Every other refusal starts from the same
  # fixture with a working origin, so this one cannot pass by accident.
  t_rm_fixture fetchfail || t_fail "fixture fetchfail"
  git -C "$SY_REPO" remote set-url origin "$SY_ROOT/no-such-origin.git"
  t_rm_expect_kept "a fetch failed in this run" "removal withheld: fetch failed (origin)"
  # The same hole through a remote sync never fetched: stale branch "old"
  # tracks a second remote, no checkout tracks that remote, and its upstream
  # resumed after the merge. Removal must fetch every remote an upstream lives
  # on, or hyg_remote_moved reads a stale ref equal to the local tip.
  t_rm_fixture remotemoved || t_fail "fixture remotemoved"
  rm_other="$SY_ROOT/../other.git"; rm -rf "$rm_other" "$rm_other.work"
  git init -q --bare "$rm_other"
  git -C "$SY_REPO" remote add other "$rm_other"
  git -C "$SY_REPO" push -q other old 2>/dev/null
  git -C "$SY_REPO" branch -q --set-upstream-to=other/old old
  (
    git clone -q -b old "$rm_other" "$rm_other.work" 2>/dev/null && cd "$rm_other.work" || exit 1
    git config user.email tester@git-guard.local; git config user.name git-guard-tester
    git config commit.gpgsign false; git config core.hooksPath "$GG_T_TMPROOT/no-hooks"
    printf 'resumed\n' > resumed.txt; git add resumed.txt; git commit -q -m "resumed after merge" || exit 1
    git push -q origin old 2>/dev/null
  ) || t_fail "remotemoved: could not resume old on the second remote"
  touch -t 202001010000 "$SY_REPO/.git/logs/refs/heads/old"
  t_sync_run "$sylog"
  git -C "$SY_REPO" rev-parse -q --verify refs/heads/old >/dev/null && t_ok "branch whose unfetched upstream resumed kept" \
    || { t_fail "branch whose unfetched upstream resumed was removed"; grep -F '"lines"' "$report" | head -c 2000 >&2; }
  grep -Fq "keep   branch old  (upstream moved after the merge)" "$report" && t_ok "report names the resumed upstream" \
    || t_fail "report lacks the resumed-upstream reason"
  # The integration ref's own remote must be fetched too (codex review of #107
  # at 9ce7fe3, P1). hygiene.baseRef names lab/integ/main, which integrated sq
  # when last fetched; lab/integ then rolled main back to before the squash.
  # No branch tracks lab/integ, so a sync that fetches only origin judges sq
  # squash-merged from the stale ref and removes it. Drain prints the
  # integration verdict before custody and the cwd check, so the report line
  # discriminates off Linux too. The positive control (baseref-ok, Linux)
  # removes from the same fixture with lab/integ left fresh.
  t_rm_baseref_fixture baseref-rolled || t_fail "fixture baseref-rolled"
  git -C "$SY_REPO" config hygiene.baseRef refs/remotes/lab/integ/main
  git -C "$RM_INTEG" update-ref refs/heads/main "$(git -C "$SY_REPO" rev-parse old)"
  t_sync_run "$sylog"
  [ -d "$RM_SQ" ] && t_ok "worktree the rolled-back integration ref no longer holds kept" \
    || { t_fail "worktree the rolled-back integration ref no longer holds was removed"; grep -F '"lines"' "$report" | head -c 2000 >&2; }
  grep -Fq "repo-sq  (commits not on refs/remotes/lab/integ/main)" "$report" \
    && t_ok "report judges sq against the refreshed integration ref" \
    || { t_fail "report does not judge sq against the refreshed integration ref"; grep -F '"lines"' "$report" | head -c 2000 >&2; }
  # An integration ref that is no remote's cannot be refreshed by a fetch.
  t_rm_baseref_fixture baseref-local || t_fail "fixture baseref-local"
  git -C "$SY_REPO" config hygiene.baseRef refs/heads/main
  t_rm_expect_kept "hygiene.baseRef is a local branch" \
    "removal withheld: integration ref refs/heads/main is not a remote-tracking ref"
  # A fetch that succeeds is not proof (codex review of #107 at 0dca80a4, P1):
  # a narrow or negative refspec leaves the refs drain reads untouched. Sync
  # compares each one with `git ls-remote` and withholds removal on any
  # mismatch. Off Linux the merged stale branch "old" is still deletable
  # (branches need no cwd check), so each case discriminates there too.
  # (1) Narrow refspec: lab/integ fetches only release/*, so its main is never
  # refreshed after the rollback.
  t_rm_baseref_fixture narrow || t_fail "fixture narrow"
  git -C "$SY_REPO" config hygiene.baseRef refs/remotes/lab/integ/main
  git -C "$SY_REPO" config remote.lab/integ.fetch '+refs/heads/release/*:refs/remotes/lab/integ/release/*'
  git -C "$RM_INTEG" update-ref refs/heads/main "$(git -C "$SY_REPO" rev-parse old)"
  t_rm_expect_kept "narrow refspec: integration ref rolled back but never refreshed" \
    "removal withheld: the integration ref refs/remotes/lab/integ/main is stale"
  # Control: the same narrow refspec with lab/integ unchanged proves the ref
  # fresh, so nothing is withheld and the merged stale branch is removed.
  t_rm_baseref_fixture narrow-ok || t_fail "fixture narrow-ok"
  git -C "$SY_REPO" config hygiene.baseRef refs/remotes/lab/integ/main
  git -C "$SY_REPO" config remote.lab/integ.fetch '+refs/heads/release/*:refs/remotes/lab/integ/release/*'
  t_sync_run "$sylog"
  ! grep -Fq "removal withheld" "$report" && ! git -C "$SY_REPO" rev-parse -q --verify refs/heads/old >/dev/null \
    && t_ok "narrow refspec, integration ref unchanged: proven fresh, merged branch removed" \
    || { t_fail "narrow refspec, integration ref unchanged: removal withheld or branch kept"; grep -F '"lines"' "$report" | head -c 2000 >&2; }
  # (2) Negative refspec: origin excludes old, whose upstream resumed after
  # the merge; the tracking ref stays at the merged tip, so hyg_remote_moved
  # sees nothing.
  t_rm_fixture negative || t_fail "fixture negative"
  git -C "$SY_REPO" push -q -u origin old 2>/dev/null
  git -C "$SY_REPO" config --add remote.origin.fetch '^refs/heads/old'
  t_rm_resume_old "$SY_ORIGIN" || t_fail "negative: could not resume old on origin"
  touch -t 202001010000 "$SY_REPO/.git/logs/refs/heads/old"
  t_rm_expect_kept "negative refspec hides an upstream that resumed" "removal withheld: the upstream of old is stale"
  # Control: the same negative refspec with old not resumed is fresh.
  t_rm_fixture negative-ok || t_fail "fixture negative-ok"
  git -C "$SY_REPO" push -q -u origin old 2>/dev/null
  git -C "$SY_REPO" config --add remote.origin.fetch '^refs/heads/old'
  touch -t 202001010000 "$SY_REPO/.git/logs/refs/heads/old"
  t_sync_run "$sylog"
  ! grep -Fq "removal withheld" "$report" && ! git -C "$SY_REPO" rev-parse -q --verify refs/heads/old >/dev/null \
    && t_ok "negative refspec, upstream unchanged: proven fresh, merged branch removed" \
    || { t_fail "negative refspec, upstream unchanged: removal withheld or branch kept"; grep -F '"lines"' "$report" | head -c 2000 >&2; }
  # A branch's upstream remote that has no URL is never fetched (claude review
  # of #107 at 9ce7fe3): removal is withheld, not silently judged stale.
  t_rm_fixture nourl || t_fail "fixture nourl"
  git -C "$SY_REPO" config remote.ghost.fetch '+refs/heads/*:refs/remotes/ghost/*'
  git -C "$SY_REPO" config branch.old.remote ghost
  git -C "$SY_REPO" config branch.old.merge refs/heads/old
  t_rm_expect_kept "an upstream remote has no URL" "removal withheld: fetch failed (ghost: no-url)"
  # Control: a branch tracking a local branch (remote ".") needs no fetch and
  # does not withhold removal.
  t_rm_fixture localup || t_fail "fixture localup"
  git -C "$SY_REPO" branch -q --set-upstream-to=main old
  t_sync_run "$sylog"
  grep -Fq "removal withheld" "$report" && t_fail "a local upstream withheld removal" \
    || t_ok "a local upstream (remote .) does not withhold removal"
  if t_sync_can_ff; then
    [ ! -e "$RM_DONE" ] && t_ok "local-upstream run removes the integrated worktree" \
      || t_fail "local-upstream run kept the integrated worktree"
  fi

  # --- custody refusals ---------------------------------------------------------
  t_rm_fixture nogrants || t_fail "fixture nogrants"
  rm -f "$XDG_CONFIG_HOME/git-guard/custody.grants"
  t_rm_expect_kept "no custody.grants file" "custody: no custody.grants file"
  t_rm_fixture othergrant || t_fail "fixture othergrant"
  printf '%s/elsewhere\t*\n' "$SY_ROOT" > "$XDG_CONFIG_HOME/git-guard/custody.grants"
  t_rm_expect_kept "grants name another repo" "custody: not granted in custody.grants"
  t_rm_fixture claimed || t_fail "fixture claimed"
  printf '{"resource":"repo:x:branch:sq","agent":"other-lane"},{"resource":"repo:x:branch:old"},{"resource":"%s"}' "$RM_DONE" > "$RM_CLAIMS"
  t_rm_expect_kept "an agent-bus claim names the item" "custody: an agent-bus claim names"
  : > "$RM_CLAIMS"
  t_rm_fixture busfail || t_fail "fixture busfail"
  : > "$RM_CLAIMS.fail"
  t_rm_expect_kept "agent-bus claims read fails" "custody: agent-bus claims unreadable"
  rm -f "$RM_CLAIMS.fail"
  # A listing that is not one fails closed (autopilot review of #107, P1).
  t_rm_fixture badclaim || t_fail "fixture badclaim"
  printf 'null' > "$RM_CLAIMS"
  t_rm_expect_kept "claims listing holds a non-object claim" "custody: agent-bus claims unreadable"
  t_rm_fixture errclaim || t_fail "fixture errclaim"
  printf '],"error":"backend unavailable","x":[' > "$RM_CLAIMS"
  t_rm_expect_kept "claims listing carries an error" "custody: agent-bus claims unreadable"
  # Claims are matched decoded: JSON escapes must not hide the names.
  t_rm_fixture escclaim || t_fail "fixture escclaim"
  # The path's slashes as \/ and the branch names as \u escapes: valid JSON
  # that a raw text search of the listing cannot match.
  rm_esc_path="$(printf '%s' "$RM_DONE" | sed 's#/#\\/#g')"
  printf '%s%s%s' '{"resource":"repo:x:branch:\u0073q"},{"resource":"repo:x:branch:\u006fld"},{"resource":"' \
    "$rm_esc_path" '"}' > "$RM_CLAIMS"
  if grep -Fq 'branch:\u0073q' "$RM_CLAIMS" && ! grep -Fq "$RM_DONE" "$RM_CLAIMS"; then
    t_ok "escaped-claims fixture hides the names from a raw text search"
  else t_fail "escaped-claims fixture is not escaped"; fi
  t_rm_expect_kept "JSON-escaped claims name the items" "custody: an agent-bus claim names"
  : > "$RM_CLAIMS"
  t_rm_fixture nobus || t_fail "fixture nobus"
  rm_bus_keep="$GIT_GUARD_AGENT_BUS"; GIT_GUARD_AGENT_BUS="$GG_T_TMPROOT/no-such-agent-bus"
  t_rm_expect_kept "no agent-bus CLI" "custody: agent-bus CLI not found"
  # Control for the line above: the operator may waive the claims check.
  git config --file "$GIT_CONFIG_GLOBAL" hygiene.custodyBus false
  t_sync_run "$sylog"
  if t_sync_can_ff; then
    [ ! -e "$RM_DONE" ] && t_ok "hygiene.custodyBus=false removes without the claims check" \
      || t_fail "custodyBus=false still kept the worktree"
  else
    grep -Fq "cwd-check-unavailable" "$report" && t_ok "off Linux: custodyBus=false passes custody, then the cwd check keeps the tree" \
      || t_fail "off Linux: custodyBus=false did not reach the cwd check"
  fi
  git config --file "$GIT_CONFIG_GLOBAL" --unset hygiene.custodyBus
  GIT_GUARD_AGENT_BUS="$rm_bus_keep"

  # --- drain refusals under --unattended ----------------------------------------
  t_rm_fixture ignored || t_fail "fixture ignored"
  printf 'build/\n' >> "$SY_REPO/.git/info/exclude"
  mkdir -p "$RM_DONE/build" && printf 'x\n' > "$RM_DONE/build/out.o"
  touch -t 202001010000 "$SY_REPO/.git/worktrees/repo-done/logs/HEAD"
  t_sync_run "$sylog"
  [ -d "$RM_DONE/build" ] && t_ok "worktree with ignored data kept (nothing archived)" || t_fail "worktree with ignored data removed"
  grep -Fq "ignored paths" "$report" && t_ok "report names the ignored data" || t_fail "report lacks the ignored-data reason"
  # skip-worktree and assume-unchanged hide modified bytes from `git status`
  # (autopilot review of #107, P1): such a worktree is kept, bytes intact.
  for rm_flag in skip-worktree assume-unchanged; do
    t_rm_fixture "hidden-$rm_flag" || t_fail "fixture hidden-$rm_flag"
    rm_tracked="$(git -C "$RM_DONE" ls-files | head -1)"
    printf 'local edit\n' >> "$RM_DONE/$rm_tracked"
    git -C "$RM_DONE" update-index "--$rm_flag" "$rm_tracked"
    touch -t 202001010000 "$SY_REPO/.git/worktrees/repo-done/logs/HEAD"
    t_sync_run "$sylog"
    if [ -d "$RM_DONE" ] && grep -Fq 'local edit' "$RM_DONE/$rm_tracked"; then
      t_ok "$rm_flag entry: worktree and its hidden edit kept"
    else t_fail "$rm_flag entry: worktree or its hidden edit removed"; fi
    grep -Fq "skip-worktree or assume-unchanged entries" "$report" && t_ok "$rm_flag entry: report names the reason" \
      || t_fail "$rm_flag entry: report lacks the reason"
  done
  # index.lock (claude review of #107 at 9ce7fe3): a git process holding a
  # worktree's index keeps it, in drain's own inspection, not only in sync's
  # checkout pass. The drain-format line distinguishes the two. Off Linux the
  # lock check runs before the cwd check, so the line discriminates there too.
  t_rm_fixture idxlock || t_fail "fixture idxlock"
  : > "$SY_REPO/.git/worktrees/repo-done/index.lock"
  t_sync_run "$sylog"
  [ -d "$RM_DONE" ] && t_ok "worktree with an index.lock kept" || t_fail "worktree with an index.lock removed"
  grep -Fq "repo-done  (locked: index.lock" "$report" && t_ok "drain names the index.lock" \
    || { t_fail "drain does not name the index.lock"; grep -F '"lines"' "$report" | head -c 2000 >&2; }
  rm -f "$SY_REPO/.git/worktrees/repo-done/index.lock"
  t_rm_fixture young || t_fail "fixture young"
  git -C "$SY_REPO" config hygiene.drainMinAgeMinutes 0
  touch "$SY_REPO/.git/worktrees/repo-done/logs/HEAD" "$SY_REPO/.git/logs/refs/heads/old"
  t_sync_run "$sylog"
  [ -d "$RM_DONE" ] && t_ok "repo-local drainMinAgeMinutes=0 cannot lower the one-day floor (fresh worktree kept)" \
    || t_fail "fresh worktree removed with drainMinAgeMinutes=0"
  git -C "$SY_REPO" rev-parse -q --verify refs/heads/old >/dev/null && t_ok "branch whose reflog moved today kept" \
    || t_fail "fresh branch removed"
  grep -Fq "keep   branch old  (moved within 1440 minutes" "$report" && t_ok "report names the branch age" \
    || t_fail "report lacks the branch age reason"
  t_rm_fixture noreflog || t_fail "fixture noreflog"
  rm -f "$SY_REPO/.git/logs/refs/heads/old"
  t_sync_run "$sylog"
  git -C "$SY_REPO" rev-parse -q --verify refs/heads/old >/dev/null && grep -Fq "keep   branch old  (age unknown" "$report" \
    && t_ok "branch with no reflog kept (age unknown)" || t_fail "branch with no reflog removed or not explained"
  t_rm_fixture moved || t_fail "fixture moved"
  ( GIT_GUARD_HYGIENE_TEST_PAUSE_AT=remove GIT_GUARD_HYGIENE_TEST_HOOK="git -C '$RM_DONE' checkout -q --detach" \
      t_sync_run "$sylog" )
  [ -d "$RM_DONE" ] && t_ok "worktree whose HEAD moved after inspection kept" || t_fail "moved worktree removed"
  t_rm_fixture refuse || t_fail "fixture refuse"
  ( cd "$SY_REPO" && sh "$GG_ROOT/bin/git-guard" hygiene drain --apply --unattended --allow-ignored >"$sylog" 2>&1 ); rc=$?
  t_expect_rc 2 "$rc" "drain --unattended refuses --allow-ignored"
  [ -d "$RM_SQ" ] && t_ok "refused drain removed nothing" || t_fail "refused drain removed a worktree"
  git config --file "$GIT_CONFIG_GLOBAL" --unset hygiene.syncRemove
  return 0
}
