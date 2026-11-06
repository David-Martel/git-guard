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
