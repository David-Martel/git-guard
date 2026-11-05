#!/bin/sh
# Category 36 — hygiene sync: fleet auto fast-forward plus a drain report
# (hooks/common/hygiene.sh `sync`).
#
# Owner direction (2026-10-30): more repositories should fast-forward on their
# own, so that the branch, worktree and PR backlog can be drained with less
# effort. `git-guard hygiene sync` walks hygiene.syncRoots, fetches each repo
# with a bound, and fast-forwards a checkout only when nothing local can be
# lost or disturbed. Everything else is a logged skip. Each pass then records
# the read-only `drain --dry-run` of every repo in one report file.
#
# Load-bearing assertions:
#   * POSITIVE CONTROL: a clean primary checkout on the default branch, behind
#     its upstream, is fast-forwarded to the upstream tip; nothing is written
#     to stdout; the report records "ff". Every skip below starts from this
#     same fixture, so a skip that never fires cannot pass by accident.
#   * Each refusal leaves HEAD where it was and names its reason: modified,
#     untracked, ahead, off the default branch (primary), detached, a merge in
#     progress, index.lock, skip-worktree, a foreign process cwd in the tree
#     (Linux /proc), hygiene.sync=false, a runner work dir path (_work), a
#     preserve/* worktree branch, and a hanging fetch (bounded by
#     hygiene.syncFetchTimeout).
#   * A clean linked worktree on its own branch fast-forwards to its upstream.
#   * The report is valid JSON and carries each repo's drain dry run; the dry
#     run deletes nothing.
#   * --dry-run reaches the same decision, logs would-ff and moves nothing.
#   * install-timer writes a oneshot service and a 30-minute timer that run at
#     Nice=19 / IOSchedulingClass=idle, start the release through the store's
#     `current` link (so an upgrade does not pin the timer to an old release),
#     and enable the timer through systemctl --user (stubbed here).
# shellcheck shell=sh

# t_sync_fixture NAME — a bare origin, a seed clone that pushes to it, and a
# clone of it at $GG_T_TMPROOT/sync-NAME/root/repo, with origin/HEAD set and
# hooks disabled. Sets SY_ROOT SY_REPO SY_SEED SY_ORIGIN. Returns 1 on failure.
t_sync_fixture() {
  _base="$GG_T_TMPROOT/sync-$1"
  rm -rf "$_base"
  mkdir -p "$_base/root" "$GG_T_TMPROOT/no-hooks" || return 1
  SY_ROOT="$_base/root"; SY_REPO="$SY_ROOT/repo"; SY_SEED="$_base/seed"; SY_ORIGIN="$_base/origin.git"
  (
    git init -q --bare -b main "$SY_ORIGIN" || exit 1
    git init -q -b main "$SY_SEED" || exit 1
    cd "$SY_SEED" || exit 1
    git config user.email tester@git-guard.local; git config user.name git-guard-tester
    git config commit.gpgsign false; git config core.hooksPath "$GG_T_TMPROOT/no-hooks"
    printf 'one\n' > one.txt; git add one.txt; git commit -q -m one || exit 1
    git remote add origin "$SY_ORIGIN"; git push -q origin main 2>/dev/null || exit 1
    git clone -q "$SY_ORIGIN" "$SY_REPO" 2>/dev/null || exit 1
    cd "$SY_REPO" || exit 1
    git config user.email tester@git-guard.local; git config user.name git-guard-tester
    git config commit.gpgsign false; git config core.hooksPath "$GG_T_TMPROOT/no-hooks"
    git remote set-head origin main >/dev/null 2>&1 || exit 1
  ) || return 1
  git config --file "$GIT_CONFIG_GLOBAL" --unset-all hygiene.syncRoots >/dev/null 2>&1
  git config --file "$GIT_CONFIG_GLOBAL" --add hygiene.syncRoots "$SY_ROOT"
  return 0
}

# t_sync_advance [BRANCH] — push one new commit on BRANCH (main) from the seed;
# prints the new tip.
t_sync_advance() {
  _sb="${1:-main}"
  (
    cd "$SY_SEED" || exit 1
    git checkout -q "$_sb" 2>/dev/null || git checkout -q -b "$_sb" || exit 1
    _n="$(git rev-list --count HEAD)"
    printf 'n%s\n' "$_n" > "adv-$_sb-$_n.txt"; git add -A; git commit -q -m "advance $_sb $_n" || exit 1
    git push -q origin "$_sb" 2>/dev/null || exit 1
    git rev-parse HEAD
  )
}

# t_sync_run LOG [ARGS...] — run `git-guard hygiene sync` from outside every
# fixture. stderr goes to LOG, stdout to LOG.out. Returns the exit code.
t_sync_run() {
  _sl="$1"; shift
  ( cd "$GG_T_TMPROOT" && sh "$GG_ROOT/bin/git-guard" hygiene sync "$@" >"$_sl.out" 2>"$_sl" )
}

# t_sync_expect_skip NAME REASON — run sync on the prepared fixture and assert
# HEAD did not move and the log names REASON for the repo.
t_sync_expect_skip() {
  _before="$(git -C "$SY_REPO" rev-parse HEAD)"
  t_sync_run "$sylog"
  if [ "$(git -C "$SY_REPO" rev-parse HEAD)" = "$_before" ]; then t_ok "$1: HEAD not moved"
  else t_fail "$1: HEAD moved"; fi
  if t_sync_logged skip "$SY_REPO" | grep -Fq "$2"; then t_ok "$1: logged as skip ($2)"
  else t_fail "$1: no skip line naming '$2'"; sed 's/^/      /' "$sylog" >&2; fi
}

# t_sync_forms PATH — PATH in every spelling a sync log or report can use on
# this host, one per line. Why: sync names a checkout by the path Git reports
# (C:/... under Git for Windows) while fixtures hold MSYS /tmp/... paths, so a
# one-spelling grep fails on Windows even though sync did the right thing.
t_sync_forms() {
  printf '%s\n' "$1"
  if gg_is_windows; then
    cygpath -m "$1" 2>/dev/null
    gg_git_path "$1" 2>/dev/null
  fi
}

# t_sync_logged KIND PATH — the lines of $sylog that say "KIND PATH", for any
# spelling of PATH.
t_sync_logged() {
  t_sync_forms "$2" | sort -u | while IFS= read -r _sf; do grep -F "$1 $_sf" "$sylog"; done
}

# t_sync_report_has RESULT PATH — the JSON report records RESULT for PATH.
t_sync_report_has() {
  t_sync_forms "$2" | "$(gg_python)" -c 'import json,sys; d=json.load(open(sys.argv[1])); forms={l.strip() for l in sys.stdin if l.strip()}; sys.exit(0 if any(c["result"]==sys.argv[2] and c["path"] in forms for c in d["checkouts"]) else 1)' "$report" "$1"
}

# t_sync_can_ff — this host can prove no process has its cwd in a checkout,
# the last check before a fast-forward (hooks/common/hygiene.sh
# hyg_sync_cwd_user). docs/QA_TOOLING.md (hygiene sync, step 3): off Linux
# every otherwise-eligible candidate is skipped with cwd-check-unavailable.
t_sync_can_ff() { [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ -r /proc/self/cwd ]; }

t_case_sync() {
  t_begin "36 hygiene sync (bounded fetch, fast-forward only when safe, drain report, timer)"
  sy_had_gcg="${GIT_CONFIG_GLOBAL+x}"
  sy_old_gcg="${GIT_CONFIG_GLOBAL-}"
  sy_had_xdg="${XDG_STATE_HOME+x}"
  sy_old_xdg="${XDG_STATE_HOME-}"
  GIT_CONFIG_GLOBAL="$GG_T_TMPROOT/sync-empty-global"
  : > "$GIT_CONFIG_GLOBAL"
  XDG_STATE_HOME="$GG_T_TMPROOT/sync-state"
  export GIT_CONFIG_GLOBAL XDG_STATE_HOME
  t_sync_body
  if [ -n "$sy_had_gcg" ]; then GIT_CONFIG_GLOBAL="$sy_old_gcg"; export GIT_CONFIG_GLOBAL
  else unset GIT_CONFIG_GLOBAL; fi
  if [ -n "$sy_had_xdg" ]; then XDG_STATE_HOME="$sy_old_xdg"; export XDG_STATE_HOME
  else unset XDG_STATE_HOME; fi
}

t_sync_body() {
  sylog="$(gg_tmp_log)"
  report="$XDG_STATE_HOME/git-guard/sync-report.json"

  # --- positive control ----------------------------------------------------
  t_sync_fixture ff || { t_fail "could not build the sync fixture"; return 0; }
  before="$(git -C "$SY_REPO" rev-parse HEAD)"
  tip="$(t_sync_advance)"
  t_sync_run "$sylog"; rc=$?
  t_expect_rc 0 "$rc" "sync exits 0"
  if t_sync_can_ff; then
    want=ff
    [ "$(git -C "$SY_REPO" rev-parse HEAD)" = "$tip" ] && t_ok "clean, behind primary on main is fast-forwarded" \
      || { t_fail "clean, behind primary was NOT fast-forwarded"; sed 's/^/      /' "$sylog" >&2; }
    t_sync_logged ff "$SY_REPO" | grep -q . && t_ok "fast-forward is logged" || t_fail "no ff line in the log"
  else
    want=skip
    [ "$(git -C "$SY_REPO" rev-parse HEAD)" = "$before" ] && t_ok "off Linux: the eligible checkout is not moved" \
      || t_fail "off Linux: HEAD moved without a cwd check"
    t_sync_logged skip "$SY_REPO" | grep -Fq cwd-check-unavailable \
      && t_ok "off Linux: the skip names cwd-check-unavailable" \
      || { t_fail "off Linux: no cwd-check-unavailable skip"; sed 's/^/      /' "$sylog" >&2; }
  fi
  [ -s "$sylog.out" ] && t_fail "sync wrote to stdout" || t_ok "sync writes nothing to stdout"
  if [ -f "$report" ]; then
    t_ok "report written to \$XDG_STATE_HOME/git-guard/sync-report.json"
    if gg_has_python; then
      t_sync_report_has "$want" "$SY_REPO" && t_ok "report is valid JSON and records the $want" \
        || t_fail "report is not valid JSON or lacks the $want record"
    else t_skip "python absent: report JSON not parsed"; fi
  else t_fail "no report written"; fi
  # Off Linux nothing fast-forwarded above; bring the checkout up to date so the
  # up-to-date decision, which precedes the cwd check, is still exercised.
  t_sync_can_ff || git -C "$SY_REPO" merge -q --ff-only "$tip" >/dev/null 2>&1
  t_sync_run "$sylog"
  t_sync_logged current "$SY_REPO" | grep -q . && t_ok "an up-to-date checkout is logged as current" \
    || t_fail "up-to-date checkout not logged as current"

  # --dry-run decides the same way but moves nothing.
  t_sync_fixture dry || t_fail "fixture dry"
  dtip="$(t_sync_advance)"; dbefore="$(git -C "$SY_REPO" rev-parse HEAD)"
  t_sync_run "$sylog" --dry-run
  [ "$(git -C "$SY_REPO" rev-parse HEAD)" = "$dbefore" ] && t_ok "--dry-run moves nothing" || t_fail "--dry-run moved HEAD"
  if t_sync_can_ff; then
    t_sync_logged would-ff "$SY_REPO" | grep -q . && t_ok "--dry-run logs would-ff" || t_fail "--dry-run did not log would-ff"
    t_sync_run "$sylog"
    [ "$(git -C "$SY_REPO" rev-parse HEAD)" = "$dtip" ] && t_ok "the same checkout fast-forwards without --dry-run" \
      || t_fail "checkout did not fast-forward after the dry run"
  else
    t_skip "off Linux: no cwd check, so neither would-ff nor the follow-up fast-forward can happen"
  fi

  # --- refusals (each on a fresh fixture that is behind) --------------------
  t_sync_fixture dirty && t_sync_advance >/dev/null && printf 'edit\n' >> "$SY_REPO/one.txt" &&
    t_sync_expect_skip "modified file" "dirty"
  t_sync_fixture untracked && t_sync_advance >/dev/null && printf 'x\n' > "$SY_REPO/new.txt" &&
    t_sync_expect_skip "untracked file" "untracked"
  t_sync_fixture ahead && t_sync_advance >/dev/null &&
    ( cd "$SY_REPO" && printf 'mine\n' > mine.txt && git add mine.txt && git commit -q -m mine ) &&
    t_sync_expect_skip "local commit ahead" "ahead"
  t_sync_fixture offmain && t_sync_advance topic >/dev/null && t_sync_advance >/dev/null &&
    ( cd "$SY_REPO" && git fetch -q origin && git checkout -q -b topic origin/topic ) &&
    t_sync_expect_skip "primary off the default branch" "not-default-branch"
  t_sync_fixture detached && t_sync_advance >/dev/null && git -C "$SY_REPO" checkout -q --detach &&
    t_sync_expect_skip "detached HEAD" "detached"
  t_sync_fixture merging && t_sync_advance >/dev/null &&
    git -C "$SY_REPO" rev-parse HEAD > "$SY_REPO/.git/MERGE_HEAD" &&
    t_sync_expect_skip "merge in progress" "in-progress"
  t_sync_fixture locked && t_sync_advance >/dev/null && : > "$SY_REPO/.git/index.lock" &&
    t_sync_expect_skip "index.lock present" "index.lock"
  t_sync_fixture hidden && t_sync_advance >/dev/null && git -C "$SY_REPO" update-index --skip-worktree one.txt &&
    t_sync_expect_skip "skip-worktree entry" "hidden-local-changes"
  t_sync_fixture optout && t_sync_advance >/dev/null && git -C "$SY_REPO" config hygiene.sync false &&
    t_sync_expect_skip "hygiene.sync=false" "opted-out"

  # A process (not this sync) working inside the tree: services run from
  # checkouts. Linux only: the check reads /proc/<pid>/cwd.
  if [ -r /proc/self/cwd ] && [ "$(uname -s)" = "Linux" ]; then
    t_sync_fixture cwd && t_sync_advance >/dev/null
    ( cd "$SY_REPO" && exec sleep 60 ) &
    sy_pid=$!
    t_sync_expect_skip "foreign process cwd in the tree" "in-use"
    kill "$sy_pid" 2>/dev/null; wait "$sy_pid" 2>/dev/null
  else
    t_skip "no /proc: foreign-cwd refusal not exercised"
  fi

  # Runner work dirs are never touched, wherever they sit.
  t_sync_fixture runner || t_fail "fixture runner"
  mkdir -p "$SY_ROOT/_work" && mv "$SY_REPO" "$SY_ROOT/_work/repo" && SY_REPO="$SY_ROOT/_work/repo"
  git config --file "$GIT_CONFIG_GLOBAL" --add hygiene.syncRoots "$SY_ROOT/_work"
  t_sync_advance >/dev/null
  t_sync_expect_skip "runner work dir (_work)" "excluded-path"

  # A hanging fetch is bounded and ends in a skip. GIT_SSH_COMMAND is only
  # defaulted when unset, so this stub replaces ssh.
  t_sync_fixture hang || t_fail "fixture hang"
  t_sync_advance >/dev/null
  git -C "$SY_REPO" remote set-url origin "ssh://sync.invalid/never.git"
  git -C "$SY_REPO" config hygiene.syncFetchTimeout 2
  sy_t0="$(date +%s)"
  sy_had_ssh="${GIT_SSH_COMMAND+x}"; sy_old_ssh="${GIT_SSH_COMMAND-}"
  GIT_SSH_COMMAND='sleep 60; :'; export GIT_SSH_COMMAND
  t_sync_expect_skip "hanging fetch" "fetch-timeout"
  if [ -n "$sy_had_ssh" ]; then GIT_SSH_COMMAND="$sy_old_ssh"; export GIT_SSH_COMMAND; else unset GIT_SSH_COMMAND; fi
  sy_dt=$(( $(date +%s) - sy_t0 ))
  [ "$sy_dt" -lt 30 ] && t_ok "hanging fetch bounded (${sy_dt}s)" || t_fail "hanging fetch took ${sy_dt}s"

  # --- linked worktrees ---------------------------------------------------
  t_sync_fixture linked || t_fail "fixture linked"
  t_sync_advance topic >/dev/null
  git -C "$SY_REPO" fetch -q origin
  git -C "$SY_REPO" worktree add -q --track -b topic "$SY_ROOT/repo-topic" origin/topic >/dev/null 2>&1 \
    || t_fail "worktree add topic"
  git -C "$SY_REPO" worktree add -q -b preserve/keep "$SY_ROOT/repo-keep" origin/topic >/dev/null 2>&1 \
    || t_fail "worktree add preserve/keep"
  git -C "$SY_REPO" branch -q --set-upstream-to=origin/topic preserve/keep
  wtip="$(t_sync_advance topic)"
  keep_before="$(git -C "$SY_ROOT/repo-keep" rev-parse HEAD)"
  t_sync_run "$sylog"
  if t_sync_can_ff; then
    [ "$(git -C "$SY_ROOT/repo-topic" rev-parse HEAD)" = "$wtip" ] \
      && t_ok "clean linked worktree fast-forwards on its own branch" \
      || { t_fail "linked worktree was not fast-forwarded"; sed 's/^/      /' "$sylog" >&2; }
  else
    t_sync_logged skip "$SY_ROOT/repo-topic" | grep -Fq cwd-check-unavailable \
      && t_ok "off Linux: the eligible linked worktree reaches the cwd check and is skipped" \
      || { t_fail "off Linux: linked worktree not skipped with cwd-check-unavailable"; sed 's/^/      /' "$sylog" >&2; }
  fi
  [ "$(git -C "$SY_ROOT/repo-keep" rev-parse HEAD)" = "$keep_before" ] \
    && t_ok "preserve/* worktree is not moved" || t_fail "preserve/* worktree moved"
  t_sync_logged skip "$SY_ROOT/repo-keep" | grep -Fq "preserve" \
    && t_ok "preserve/* skip is logged" || t_fail "preserve/* skip not logged"

  # --- drain report ---------------------------------------------------------
  t_sync_fixture drain || t_fail "fixture drain"
  git -C "$SY_REPO" branch merged-gone
  git -C "$SY_REPO" push -q origin merged-gone 2>/dev/null
  git -C "$SY_REPO" branch -q --set-upstream-to=origin/merged-gone merged-gone
  git -C "$SY_REPO" push -q origin --delete merged-gone 2>/dev/null
  t_sync_run "$sylog"
  git -C "$SY_REPO" rev-parse -q --verify refs/heads/merged-gone >/dev/null \
    && t_ok "drain dry run in sync deletes nothing" || t_fail "sync deleted a branch"
  if gg_has_python; then
    t_sync_forms "$SY_REPO" | "$(gg_python)" -c 'import json,sys; d=json.load(open(sys.argv[1])); forms={l.strip() for l in sys.stdin if l.strip()}; sys.exit(0 if any(r["repo"] in forms and any("would remove branch merged-gone" in l for l in r["lines"]) for r in d["drain"]) else 1)' \
      "$report" && t_ok "report carries the repo's drain dry run" \
      || t_fail "report lacks the drain dry run for the repo"
  else
    grep -q 'would remove branch merged-gone' "$report" && t_ok "report carries the drain dry run" \
      || t_fail "report lacks the drain dry run"
  fi

  # --- timer installer ------------------------------------------------------
  units="$GG_T_TMPROOT/sync-units"; stub="$GG_T_TMPROOT/sync-systemctl"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s.calls"\n' "$stub" > "$stub"; chmod +x "$stub"
  store="$GG_T_TMPROOT/sync-store"; mkdir -p "$store/v9"
  cp -R "$GG_ROOT/bin" "$GG_ROOT/hooks" "$GG_ROOT/VERSION" "$store/v9/"
  ln -s "$store/v9" "$store/current"
  ( GIT_GUARD_SYNC_UNIT_DIR="$units" GIT_GUARD_SYNC_SYSTEMCTL="$stub" \
      sh "$store/v9/bin/git-guard" hygiene sync install-timer >"$sylog" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "install-timer succeeds"
  svc="$units/git-guard-sync.service"; tmr="$units/git-guard-sync.timer"
  [ -f "$svc" ] && [ -f "$tmr" ] && t_ok "service and timer units written" || t_fail "units not written"
  # MSYS ln -s copies the directory unless native symlinks are enabled; the
  # installer then correctly has no link to start through (systemd is Linux-only).
  if [ -L "$store/current" ]; then
    grep -Fq "\"$store/current/bin/git-guard\" hygiene sync" "$svc" 2>/dev/null \
      && t_ok "service starts the release through the store's current link" \
      || t_fail "service does not start through current/ ($(grep ExecStart "$svc" 2>/dev/null))"
  else
    t_skip "ln -s made no symlink on this host: the current/ link is not exercised"
  fi
  grep -q '^Nice=19$' "$svc" 2>/dev/null && grep -q '^IOSchedulingClass=idle$' "$svc" 2>/dev/null \
    && t_ok "service runs at Nice=19 and idle IO" || t_fail "service lacks Nice=19 / idle IO"
  grep -q '^Type=oneshot$' "$svc" 2>/dev/null && t_ok "service is oneshot" || t_fail "service is not oneshot"
  grep -q '^OnCalendar=\*:0/30$' "$tmr" 2>/dev/null && grep -q '^RandomizedDelaySec=' "$tmr" 2>/dev/null \
    && t_ok "timer fires every 30 minutes with a randomized delay" || t_fail "timer schedule wrong"
  grep -Fxq -- "--user daemon-reload" "$stub.calls" 2>/dev/null && grep -Fxq -- "--user enable --now git-guard-sync.timer" "$stub.calls" 2>/dev/null \
    && t_ok "timer enabled through systemctl --user" || t_fail "systemctl --user calls missing ($(cat "$stub.calls" 2>/dev/null))"
  : > "$stub.calls"
  ( GIT_GUARD_SYNC_UNIT_DIR="$units" GIT_GUARD_SYNC_SYSTEMCTL="$stub" \
      sh "$store/v9/bin/git-guard" hygiene sync uninstall-timer >"$sylog" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "uninstall-timer succeeds"
  [ ! -e "$svc" ] && [ ! -e "$tmr" ] && t_ok "uninstall-timer removes both units" || t_fail "units left behind"
  grep -Fxq -- "--user disable --now git-guard-sync.timer" "$stub.calls" 2>/dev/null \
    && t_ok "uninstall-timer disables the timer" || t_fail "timer not disabled"
  return 0
}
