#!/bin/sh
#
# git-guard hygiene — worktree / stale-branch / open-PR backlog limits.
#
# Owner rule (2026-10-09): clear the worktree, branch and PR backlog before
# starting new work, with enforced limits. This file is the local, per-host,
# per-repo half of that rule; vigil-utils `tools/backlog_caps/report.py` is the
# fleet-wide, lane-attributed GitHub report (see docs/QA_TOOLING.md §12).
#
# Subcommands:
#   pre-push REMOTE URL    called by hooks/pre-push with the ref list on stdin.
#                          Exits 77 (HYG_REFUSE) ONLY for a push that creates a NEW branch on
#                          the remote while the repo is over a limit. Commits,
#                          existing-branch pushes, deletes, tags, preserve/* and
#                          the first publish of the default branch never block.
#   post-checkout P N F    called by hooks/post-checkout; warns after
#                          `git worktree add` when over a limit. Always exits 0.
#   report                 print counts vs limits (exit 0).
#   check                  same counts, exit 1 when any limit is exceeded.
#   drain [--dry-run|--apply] [--allow-ignored]
#                          list (default) or remove merged, clean, unlocked
#                          worktrees and stale branches. Unique work is bundled,
#                          never deleted.
#   defaults [--dry-run]   set the recommended GLOBAL git config, only for keys
#                          that are unset (install.sh calls this).
#   sync [--dry-run] [--no-drain]
#                          fetch every repo under hygiene.syncRoots (bounded),
#                          fast-forward each checkout that is provably safe to
#                          move, write the drain dry runs to one report file.
#                          Never deletes. Prints nothing on stdout.
#   sync install-timer | uninstall-timer
#                          a systemd --user timer running sync every 30 minutes.
#
# Configuration (git config; repo-local beats global by git's own precedence):
#   hygiene.mode               enforce (default) | warn | off
#   hygiene.maxWorktrees       linked worktrees per repo, primary excluded (3; 0 = off)
#   hygiene.maxStaleBranches   local branches gone upstream or merged (5; 0 = off)
#   hygiene.maxOpenPRs         open non-bot PRs on the GitHub remote (unset = off)
#   hygiene.exemptLockPrefix   multi-valued; worktrees locked with a reason that
#                              starts with one of these are infrastructure and
#                              are never counted or drained
#   hygiene.baseRef            integration ref when <remote>/HEAD is unknown
#   hygiene.drainMinAgeMinutes drain never removes a worktree whose HEAD moved
#                              within this many minutes (1440; 0 = no guard):
#                              a fresh `worktree add` is clean and "merged"
#                              but may be another agent's live checkout
#   hygiene.preserveDir        where drain writes bundles of unique work
#                              (default ${XDG_STATE_HOME:-~/.local/state}/git-guard/preserve)
#   hygiene.sync               false in a repo (or globally) keeps sync out of it
#   hygiene.syncExclude        multi-valued, global/system only: a path or glob
#                              sync never fetches or moves (also read: one per
#                              line in ~/.config/git-guard/sync.exclude)
#   hygiene.syncRoots          multi-valued directories sync walks, each plus
#                              its direct children (~/dev/repos, ~/.claude/repos)
#   hygiene.syncFetchTimeout   seconds per remote fetch in sync (60)
#   hygiene.syncDrainTimeout   seconds per repo for the drain dry run in sync (300)
# Environment:
#   GIT_GUARD=0                skip all git-guard hooks (existing convention)
#   GIT_GUARD_HYGIENE          off | warn | enforce, beats hygiene.mode
#   GIT_GUARD_HYGIENE_GH       gh executable to use (tests stub it)
#   GIT_GUARD_SYNC_UNIT_DIR, GIT_GUARD_SYNC_SYSTEMCTL
#                              where install-timer writes units and which
#                              systemctl it calls (tests stub both)
#
# POSIX sh, no dependencies beyond git; `gh` is optional and only consulted when
# hygiene.maxOpenPRs is set. Any failure to measure a dimension skips it: this
# gate must never block a push on missing data.

set -u

HYG_DEFAULT_MAX_WORKTREES=3
HYG_DEFAULT_MAX_STALE=5
HYG_DEFAULT_MIN_AGE=1440
# The CLI that ships beside this file (<release>/bin/git-guard). It is not on
# PATH by default, so messages print the full path.
HYG_CLI="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/bin/git-guard"
HYG_TMP=""
# Policy refusal from pre-push. Distinct from 1/2 so that a crash (bash-as-sh
# exits 1 on a `set -u` abort, dash exits 2) can never look like a refusal.
HYG_REFUSE=77

hyg_say() { printf '%s\n' "$*" >&2; }

# hyg_tmpdir — create one private temp dir for this invocation (main shell
# only, so the cleanup trap belongs to the script). Empty on failure; callers
# then skip whatever needed it.
hyg_tmpdir() {
  [ -n "$HYG_TMP" ] && return 0
  HYG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/git-guard-hygiene.XXXXXX" 2>/dev/null)" || HYG_TMP=""
  [ -n "$HYG_TMP" ] || return 0
  # EXIT cleans up. INT/TERM must END the script (exit runs the EXIT trap): a
  # cleanup-only signal trap would let an interrupted `drain --apply` keep
  # removing worktrees and branches.
  trap 'rm -rf "$HYG_TMP"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  return 0
}

# hyg_int KEY DEFAULT — an integer config value, or DEFAULT when unset/invalid.
hyg_int() {
  _raw="$(git config --get "$1" 2>/dev/null || true)"
  if [ -z "$_raw" ]; then printf '%s' "$2"; return 0; fi
  if _v="$(git config --int --get "$1" 2>/dev/null)"; then printf '%s' "$_v"; return 0; fi
  hyg_say "git-guard hygiene: $1='$_raw' is not an integer; using $2"
  printf '%s' "$2"
}

# hyg_mode — off | warn | enforce (env beats config; unknown -> warn, loudly).
hyg_mode() {
  _m="${GIT_GUARD_HYGIENE:-}"
  [ -n "$_m" ] || _m="$(git config --get hygiene.mode 2>/dev/null || true)"
  [ -n "$_m" ] || _m=enforce
  case "$_m" in
    off|warn|enforce) printf '%s' "$_m" ;;
    *) hyg_say "git-guard hygiene: unknown mode '$_m' (want off|warn|enforce); using warn"
       printf 'warn' ;;
  esac
}

# hyg_remote — the remote to measure against: $1 if given, else origin, else
# the first configured remote. Empty when the repo has none.
hyg_remote() {
  if [ -n "${1:-}" ] && git config --get "remote.$1.url" >/dev/null 2>&1; then printf '%s' "$1"; return; fi
  if git config --get remote.origin.url >/dev/null 2>&1; then printf 'origin'; return; fi
  git remote 2>/dev/null | head -n1
}

# hyg_base REMOTE — the integration ref: refs/remotes/<r>/HEAD's target, else
# hygiene.baseRef, else refs/remotes/<r>/main or /master. Empty = unknown (the
# merged test is then skipped, never guessed).
hyg_base() {
  _b=""
  if [ -n "${1:-}" ]; then
    _b="$(git symbolic-ref -q "refs/remotes/$1/HEAD" 2>/dev/null || true)"
  fi
  if [ -z "$_b" ]; then
    _b="$(git config --get hygiene.baseRef 2>/dev/null || true)"
    [ -n "$_b" ] && ! git rev-parse -q --verify "$_b^{commit}" >/dev/null 2>&1 && _b=""
  fi
  if [ -z "$_b" ] && [ -n "${1:-}" ]; then
    for _c in main master; do
      if git rev-parse -q --verify "refs/remotes/$1/$_c" >/dev/null 2>&1; then _b="refs/remotes/$1/$_c"; break; fi
    done
  fi
  printf '%s' "$_b"
}

# hyg_base_name BASE — the short branch name of the base (refs/remotes/o/main
# -> main), used to exempt the default branch itself.
hyg_base_name() {
  case "${1:-}" in
    refs/remotes/*/*) _n="${1#refs/remotes/}"; printf '%s' "${_n#*/}" ;;
    refs/heads/*) printf '%s' "${1#refs/heads/}" ;;
    *) printf '%s' "${1:-}" ;;
  esac
}

# hyg_worktrees — one line per LINKED worktree (primary excluded):
#   <state>\t<path>\t<branch>\t<head>\t<lock-reason>
# Empty fields are written as "-" (a tab is IFS whitespace, so `read` would
# otherwise collapse an empty field and shift the rest; "-" is not a valid
# branch name). state: live | exempt | prunable. Exempt = locked with a reason
# starting with one of hygiene.exemptLockPrefix.
hyg_worktrees() {
  _prefixes="$(git config --get-all hygiene.exemptLockPrefix 2>/dev/null || true)"
  git worktree list --porcelain 2>/dev/null | awk -v prefixes="$_prefixes" '
    function dash(s) { return (s == "" ? "-" : s) }
    function flush() {
      if (path != "" && n > 1) {
        state = "live"
        if (prunable) state = "prunable"
        else if (locked) {
          np = split(prefixes, p, "\n")
          for (i = 1; i <= np; i++) if (p[i] != "" && index(reason, p[i]) == 1) state = "exempt"
        }
        if (locked && reason == "") reason = "locked"
        printf "%s\t%s\t%s\t%s\t%s\n", state, path, dash(branch), dash(head), dash(reason)
      }
      path = ""; branch = ""; head = ""; reason = ""; locked = 0; prunable = 0
    }
    /^worktree / { flush(); n++; path = substr($0, 10); next }
    /^HEAD /     { head = substr($0, 6); next }
    /^branch /   { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch); next }
    /^locked/    { locked = 1; reason = substr($0, 8); next }
    /^prunable/  { prunable = 1; next }
    END { flush() }
  '
}

# hyg_in_use — the local branches git itself refuses to delete because a
# worktree uses them (branch.c branch_checked_out), one short name per line:
#   * the branch checked out in any worktree, primary included, locked or not
#     (from `worktree list` and from each git dir's own HEAD, which still
#     counts when `worktree list` drops an entry it cannot read);
#   * the branch an in-progress rebase returns to (rebase-merge/head-name,
#     rebase-apply/head-name) and every branch a rebase --update-refs will
#     rewrite (rebase-merge/update-refs);
#   * the branch a bisect started from (BISECT_START).
# A rebasing or bisecting worktree is listed as "detached" by
# `git worktree list`, so its `branch` lines alone miss the last two kinds.
# The state files are read from every registered git dir (the common dir and
# <common>/worktrees/*), so an offline worktree still counts. Returns 1, with
# the path on stderr, when <common>/worktrees, a git dir or a rebase state dir
# cannot be listed or searched, or when a HEAD or state file that exists
# cannot be read: callers must then treat every branch as in use. A state
# file that does not exist means that operation is not in progress.
hyg_in_use() {
  _iu_wl="$(git worktree list --porcelain 2>/dev/null)" || { hyg_say "git-guard hygiene: git worktree list failed"; return 1; }
  [ -n "$_iu_wl" ] || { hyg_say "git-guard hygiene: git worktree list printed nothing"; return 1; }
  printf '%s\n' "$_iu_wl" | sed -n 's|^branch refs/heads/||p'
  _iu_cd="$(git rev-parse --git-common-dir 2>/dev/null)" || { hyg_say "git-guard hygiene: cannot find the common git dir"; return 1; }
  _iu_cd="$(cd "$_iu_cd" 2>/dev/null && pwd -P)" || { hyg_say "git-guard hygiene: cannot enter the common git dir $_iu_cd"; return 1; }
  # An unlistable (a-r) or unsearchable (a-x) worktrees dir would hide every
  # linked worktree from the loop below, and from `worktree list` too.
  if [ -e "$_iu_cd/worktrees" ]; then
    hyg_iu_dir "$_iu_cd/worktrees" || return 1
  fi
  for _iu_g in "$_iu_cd" "$_iu_cd"/worktrees/*; do
    if [ ! -d "$_iu_g" ]; then
      # The unexpanded glob (no linked worktrees) or a stray file is not a git
      # dir; a listed name that cannot be stat'ed is.
      [ "$_iu_g" = "$_iu_cd/worktrees/*" ] && [ ! -e "$_iu_g" ] && continue
      [ -e "$_iu_g" ] && [ ! -L "$_iu_g" ] && continue
      hyg_say "git-guard hygiene: cannot inspect worktree git dir $_iu_g"; return 1
    fi
    # An unsearchable git dir would make every state file look absent.
    hyg_iu_dir "$_iu_g" || return 1
    if [ -e "$_iu_g/HEAD" ]; then
      _iu_h="$(cat "$_iu_g/HEAD" 2>/dev/null)" || { hyg_say "git-guard hygiene: cannot read $_iu_g/HEAD"; return 1; }
      case "$_iu_h" in "ref: refs/heads/"*) printf '%s\n' "${_iu_h#ref: refs/heads/}" ;; esac
    fi
    for _iu_d in rebase-merge rebase-apply; do
      if [ -e "$_iu_g/$_iu_d" ]; then hyg_iu_dir "$_iu_g/$_iu_d" || return 1; fi
    done
    for _iu_f in rebase-merge/head-name rebase-apply/head-name rebase-merge/update-refs; do
      [ -e "$_iu_g/$_iu_f" ] || continue
      # update-refs holds <ref>, <old oid>, <new oid> per entry; only the ref
      # lines start with refs/heads/.
      sed -n 's|^refs/heads/||p' "$_iu_g/$_iu_f" 2>/dev/null || { hyg_say "git-guard hygiene: cannot read $_iu_g/$_iu_f"; return 1; }
    done
    if [ -e "$_iu_g/BISECT_START" ]; then
      # The short branch name, or an object id when bisect began detached.
      # git strips a refs/heads/ prefix (read_and_strip_branch); so does this.
      _iu_n="$(cat "$_iu_g/BISECT_START" 2>/dev/null)" || { hyg_say "git-guard hygiene: cannot read $_iu_g/BISECT_START"; return 1; }
      _iu_n="${_iu_n#refs/heads/}"
      [ -z "$_iu_n" ] || printf '%s\n' "$_iu_n"
    fi
  done
  return 0
}

# hyg_iu_dir DIR — true when DIR is a directory this process can list and
# search; otherwise names it on stderr.
hyg_iu_dir() {
  [ -d "$1" ] && [ -r "$1" ] && [ -x "$1" ] && return 0
  hyg_say "git-guard hygiene: cannot list or search $1"
  return 1
}

# hyg_stale BASE — local branches whose upstream is gone or whose tip is
# merged into BASE, excluding main, master, the base's own branch name,
# preserve/*, and any branch a worktree uses (hyg_in_use: checked-out ones
# are drained as worktrees; rebasing/bisecting ones belong to their owner).
# One line each: <reason>\t<branch>. One awk pass: a fork per
# branch made this minutes long on a repo with hundreds of branches.
hyg_stale() {
  _base="${1:-}"
  [ -n "$HYG_TMP" ] || return 0
  # A failed scan only affects the count here; hyg_delete_branch re-reads it.
  hyg_in_use > "$HYG_TMP/checked-out" 2>/dev/null || :
  : > "$HYG_TMP/merged"
  if [ -n "$_base" ]; then
    git for-each-ref --merged "$_base" --format='%(refname:short)' refs/heads/ > "$HYG_TMP/merged" 2>/dev/null || :
  fi
  git for-each-ref --format='%(refname:short)	%(upstream:track)' refs/heads/ 2>/dev/null |
    awk -F '\t' -v co="$HYG_TMP/checked-out" -v mf="$HYG_TMP/merged" -v bname="$(hyg_base_name "$_base")" '
      BEGIN {
        while ((getline l < co) > 0) skip[l] = 1
        while ((getline l < mf) > 0) merged[l] = 1
      }
      {
        b = $1
        if (b == "main" || b == "master" || b == bname || index(b, "preserve/") == 1 || (b in skip)) next
        if (b in merged) printf "merged\t%s\n", b
        else if ($2 == "[gone]") printf "gone\t%s\n", b
      }'
}

# hyg_gh_slug URL — owner/repo for a github.com URL, else empty.
hyg_gh_slug() {
  case "${1:-}" in
    *github.com[:/]*) _s="${1#*github.com[:/]}"; _s="${_s%.git}"; _s="${_s%/}"; printf '%s' "$_s" ;;
    *) : ;;
  esac
}

# hyg_open_prs URL — count of open non-bot PRs, or empty when unmeasurable
# (no gh, not GitHub, offline, auth failure, timeout). REST, not GraphQL: the
# account's GraphQL budget is shared by every agent.
hyg_open_prs() {
  _slug="$(hyg_gh_slug "${1:-}")"
  [ -n "$_slug" ] || return 0
  _gh="${GIT_GUARD_HYGIENE_GH:-gh}"
  command -v "$_gh" >/dev/null 2>&1 || return 0
  _to=""
  if command -v timeout >/dev/null 2>&1; then _to="timeout 15"
  elif command -v gtimeout >/dev/null 2>&1; then _to="gtimeout 15"
  fi
  # shellcheck disable=SC2086  # _to is intentionally word-split (empty or 2 words)
  _n="$($_to "$_gh" api "repos/$_slug/pulls?state=open&per_page=100" \
        --jq '[.[] | select(.user.type != "Bot")] | length' 2>/dev/null)" || return 0
  case "$_n" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$_n"
}

# hyg_measure REMOTE URL WITH_PRS — sets HYG_WT_N HYG_WT_LIST HYG_ST_N
# HYG_ST_LIST HYG_PR_N HYG_BASE HYG_OVER (space-separated exceeded keys).
hyg_measure() {
  hyg_tmpdir
  _remote="$(hyg_remote "${1:-}")"
  _url="${2:-}"
  [ -n "$_url" ] || { [ -n "$_remote" ] && _url="$(git config --get "remote.$_remote.url" 2>/dev/null || true)"; }
  HYG_MAX_WT="$(hyg_int hygiene.maxWorktrees "$HYG_DEFAULT_MAX_WORKTREES")"
  HYG_MAX_ST="$(hyg_int hygiene.maxStaleBranches "$HYG_DEFAULT_MAX_STALE")"
  HYG_MAX_PR="$(hyg_int hygiene.maxOpenPRs 0)"
  HYG_BASE="$(hyg_base "$_remote")"
  HYG_WT_LIST="$(hyg_worktrees | awk -F '\t' '$1 == "live"')"
  HYG_WT_N="$(printf '%s' "$HYG_WT_LIST" | grep -c . || true)"
  HYG_ST_LIST="$(hyg_stale "$HYG_BASE")"
  HYG_ST_N="$(printf '%s' "$HYG_ST_LIST" | grep -c . || true)"
  HYG_PR_N=""
  if [ "${3:-0}" = "1" ] && [ "$HYG_MAX_PR" -gt 0 ]; then HYG_PR_N="$(hyg_open_prs "$_url")"; fi
  HYG_OVER=""
  [ "$HYG_MAX_WT" -gt 0 ] && [ "$HYG_WT_N" -gt "$HYG_MAX_WT" ] && HYG_OVER="$HYG_OVER hygiene.maxWorktrees"
  [ "$HYG_MAX_ST" -gt 0 ] && [ "$HYG_ST_N" -gt "$HYG_MAX_ST" ] && HYG_OVER="$HYG_OVER hygiene.maxStaleBranches"
  [ -n "$HYG_PR_N" ] && [ "$HYG_PR_N" -gt "$HYG_MAX_PR" ] && HYG_OVER="$HYG_OVER hygiene.maxOpenPRs"
  return 0
}

# hyg_explain LEVEL — the human message for an over-limit state.
hyg_explain() {
  _lvl="$1"
  for _k in $HYG_OVER; do
    case "$_k" in
      hygiene.maxWorktrees)
        hyg_say "git-guard hygiene $_lvl: $HYG_WT_N linked worktrees > hygiene.maxWorktrees=$HYG_MAX_WT"
        printf '%s\n' "$HYG_WT_LIST" | awk -F '\t' 'NF { printf "    worktree %s  (%s%s)\n", $2, ($3 == "-" ? "detached" : $3), ($5 == "-" ? "" : ", locked: " $5) }' >&2 ;;
      hygiene.maxStaleBranches)
        hyg_say "git-guard hygiene $_lvl: $HYG_ST_N stale local branches > hygiene.maxStaleBranches=$HYG_MAX_ST"
        printf '%s\n' "$HYG_ST_LIST" | awk -F '\t' 'NF { printf "    branch %s  (%s)\n", $2, $1 }' >&2 ;;
      hygiene.maxOpenPRs)
        hyg_say "git-guard hygiene $_lvl: $HYG_PR_N open PRs > hygiene.maxOpenPRs=$HYG_MAX_PR (review and merge or close them)" ;;
    esac
  done
  hyg_say "  Drain first:  git fetch --prune && sh $HYG_CLI hygiene drain --dry-run   (then --apply)"
  hyg_say "  drain removes only clean, unlocked, merged work and bundles any unique tip first."
  hyg_say "  What it keeps (locked, dirty, unique commits) needs its owner: finish, merge or hand it off,"
  hyg_say "  or raise this repo's limit deliberately: git config hygiene.<key> <n>."
}

hyg_pre_push() {
  [ "${GIT_GUARD:-1}" = "0" ] && return 0
  _mode="$(hyg_mode)"
  [ "$_mode" = "off" ] && return 0
  _remote="${1:-}"; _url="${2:-}"
  _new=""
  while read -r _lref _lsha _rref _rsha; do
    [ -n "${_rref:-}" ] || continue
    case "$_rref" in
      refs/heads/preserve/*|refs/heads/main|refs/heads/master) continue ;;
      refs/heads/*) : ;;
      *) continue ;;
    esac
    case "$_lsha" in *[!0]*) : ;; *) continue ;; esac     # delete
    case "$_rsha" in *[!0]*) continue ;; esac              # existing branch
    _new="$_new ${_rref#refs/heads/}"
  done
  [ -n "$_new" ] || return 0
  hyg_measure "$_remote" "$_url" 1
  # The first publish of the default branch itself is not new work.
  _bn="$(hyg_base_name "$HYG_BASE")"
  if [ -n "$_bn" ]; then
    _kept=""
    for _b in $_new; do [ "$_b" = "$_bn" ] || _kept="$_kept $_b"; done
    _new="$_kept"
    [ -n "$_new" ] || return 0
  fi
  [ -n "$HYG_OVER" ] || return 0
  if [ "$_mode" = "warn" ]; then
    hyg_explain WARN
    hyg_say "  (hygiene mode warn: pushing new branch(es)$_new anyway)"
    return 0
  fi
  hyg_explain BLOCK
  hyg_say "  Refused: new branch(es)$_new. Existing branches, deletes and commits are never blocked."
  hyg_say "  One push only: GIT_GUARD_HYGIENE=warn git push ...   Do NOT use --no-verify."
  return "$HYG_REFUSE"
}

hyg_post_checkout() {
  [ "${GIT_GUARD:-1}" = "0" ] && return 0
  # Only `git worktree add` (and clone): previous HEAD is the null ref, a
  # branch checkout, and we are in a linked worktree. Ordinary checkouts stay
  # silent and cost nothing.
  case "${1:-x}" in *[!0]*) return 0 ;; esac
  [ "${3:-}" = "1" ] || return 0
  _gd="$(git rev-parse --git-dir 2>/dev/null)" || return 0
  _cd="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
  [ "$_gd" != "$_cd" ] || return 0
  _mode="$(hyg_mode)"
  [ "$_mode" = "off" ] && return 0
  hyg_measure "" "" 0
  [ -n "$HYG_OVER" ] || return 0
  hyg_explain WARN
  if [ "$_mode" = "enforce" ]; then
    hyg_say "  Pushing a NEW branch from this repo is refused until the backlog is under the limit."
  fi
  return 0
}

hyg_report() {
  hyg_measure "" "" 1
  _pr_limit="$HYG_MAX_PR"; [ "$_pr_limit" -gt 0 ] || _pr_limit="off"
  echo "git-guard hygiene report: $(git rev-parse --show-toplevel 2>/dev/null)"
  echo "  mode:              $(hyg_mode)"
  echo "  base ref:          ${HYG_BASE:-<unknown: merged test skipped>} (as of the last fetch)"
  echo "  linked worktrees:  $HYG_WT_N (limit hygiene.maxWorktrees=$HYG_MAX_WT)"
  printf '%s\n' "$HYG_WT_LIST" | awk -F '\t' 'NF { printf "    %s  (%s%s)\n", $2, ($3 == "-" ? "detached" : $3), ($5 == "-" ? "" : ", locked: " $5) }'
  hyg_worktrees | awk -F '\t' '$1 == "exempt" { printf "    [exempt] %s  (locked: %s)\n", $2, $5 }
                                $1 == "prunable" { printf "    [prunable] %s  (registration only; confirm the path is really gone, then: git worktree prune)\n", $2 }'
  echo "  stale branches:    $HYG_ST_N (limit hygiene.maxStaleBranches=$HYG_MAX_ST)"
  printf '%s\n' "$HYG_ST_LIST" | awk -F '\t' 'NF { printf "    %s  (%s)\n", $2, $1 }'
  echo "  open PRs:          ${HYG_PR_N:-<not measured>} (limit hygiene.maxOpenPRs=$_pr_limit)"
  if [ -n "$HYG_OVER" ]; then echo "  OVER LIMIT:       $HYG_OVER"; echo "  next: git fetch --prune && sh $HYG_CLI hygiene drain --dry-run"
  else echo "  within limits"; fi
}

# --- drain -------------------------------------------------------------------

# hyg_op_in_progress GITDIR — true when a merge/rebase/cherry-pick/revert/bisect
# is in progress in that worktree's git dir.
hyg_op_in_progress() {
  for _f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    [ -e "$1/$_f" ] && return 0
  done
  return 1
}

# hyg_integrated TIP BASE — prints how TIP is integrated into BASE
# (ancestor | patch-equivalent | content-equivalent), or nothing.
hyg_integrated() {
  _tip="$1"; _base="$2"
  [ -n "$_base" ] || return 0
  if git merge-base --is-ancestor "$_tip" "$_base" 2>/dev/null; then printf 'ancestor'; return 0; fi
  _cherry="$(git cherry "$_base" "$_tip" 2>/dev/null)" || return 0
  if [ -n "$_cherry" ] && ! printf '%s\n' "$_cherry" | grep -q '^+'; then printf 'patch-equivalent'; return 0; fi
  # Squash merge: every path the branch touched has the same blob on BASE as
  # on TIP (both absent = deleted on both). Compared per path by object id, so
  # globs and spaces are inert; a C-quoted name (control characters, quotes,
  # backslashes) cannot be compared safely and means "not integrated".
  [ -n "$HYG_TMP" ] || return 0
  _mb="$(git merge-base "$_tip" "$_base" 2>/dev/null)" || return 0
  git -c core.quotePath=false diff --name-only "$_mb" "$_tip" > "$HYG_TMP/touched" 2>/dev/null || return 0
  [ -s "$HYG_TMP/touched" ] || return 0
  _eq=1
  while IFS= read -r _f; do
    case "$_f" in \"*) _eq=0; break ;; esac
    _a="$(git rev-parse -q --verify "$_tip:$_f" 2>/dev/null || true)"
    _c="$(git rev-parse -q --verify "$_base:$_f" 2>/dev/null || true)"
    [ "$_a" = "$_c" ] || { _eq=0; break; }
  done < "$HYG_TMP/touched"
  [ "$_eq" = "1" ] && printf 'content-equivalent'
  return 0
}

# hyg_remote_moved BRANCH BASE — true when BRANCH's upstream still exists and
# its tip is neither the local tip nor integrated into BASE (someone, often a
# bot, pushed after the merge: LEARNED_RULES 48). Only as fresh as the last
# fetch.
hyg_remote_moved() {
  _up="$(git rev-parse -q --verify "$1@{upstream}" 2>/dev/null)" || return 1
  [ "$_up" = "$(git rev-parse -q --verify "refs/heads/$1")" ] && return 1
  [ -n "$(hyg_integrated "$_up" "$2")" ] && return 1
  return 0
}

# hyg_stashed BRANCH — true when a stash entry was made on BRANCH (fixed-string
# match: branch names may contain regex metacharacters).
hyg_stashed() {
  git stash list --format='%gs' 2>/dev/null |
    awk -v a="WIP on $1:" -v b="On $1:" 'index($0, a) == 1 || index($0, b) == 1 { f = 1 } END { exit !f }'
}

# hyg_test_pause POINT — TEST-ONLY seams (default off), at POINT = start |
# remove | delete (default start). GIT_GUARD_HYGIENE_TEST_HOOK is a command run
# there (a test moves a ref between inspection and action, deterministically);
# GIT_GUARD_HYGIENE_TEST_PAUSE sleeps that many seconds (a test signals the
# run). Never set either in real use.
hyg_test_pause() {
  [ "${GIT_GUARD_HYGIENE_TEST_PAUSE_AT:-start}" = "$1" ] || return 0
  if [ -n "${GIT_GUARD_HYGIENE_TEST_HOOK:-}" ]; then sh -c "$GIT_GUARD_HYGIENE_TEST_HOOK" >/dev/null 2>&1 || :; fi
  if [ -n "${GIT_GUARD_HYGIENE_TEST_PAUSE:-}" ]; then sleep "$GIT_GUARD_HYGIENE_TEST_PAUSE"; fi
  return 0
}

# hyg_sha256 FILE — hex sha256 of FILE, or failure when no tool is present.
hyg_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1
  fi
}

# hyg_preserve NAME TIP — preserve TIP as a verified bundle and print its path.
# `git bundle create <file> <raw-sha>` refuses ("empty bundle"), so TIP is
# pinned to a temporary ref, the ref is bundled (minus BASE when that leaves
# something to bundle), the bundle is verified, its sha256 is written beside it
# as <bundle>.sha256, and only then is the temporary ref deleted. ANY failure
# removes the partial files and returns 1: callers must then remove nothing.
# Date-free, sha-qualified file name.
hyg_preserve() {
  _dir="$(git config --get hygiene.preserveDir 2>/dev/null || true)"
  [ -n "$_dir" ] || _dir="${XDG_STATE_HOME:-$HOME/.local/state}/git-guard/preserve"
  _repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")"
  _slug="$(printf '%s' "$1" | tr '/' '-')"
  _short="$(git rev-parse --short "$2" 2>/dev/null)" || return 1
  _out="$_dir/$_repo/$_slug-$_short.bundle"
  if [ -f "$_out" ] && [ -f "$_out.sha256" ] && git bundle verify -q "$_out" >/dev/null 2>&1 &&
     [ "$(hyg_sha256 "$_out")" = "$(awk '{print $1}' "$_out.sha256")" ]; then
    printf '%s' "$_out"; return 0
  fi
  mkdir -p "$_dir/$_repo" 2>/dev/null || return 1
  _tmpref="refs/git-guard-preserve/$_slug"
  git update-ref "$_tmpref" "$2" 2>/dev/null || return 1
  _ok=0
  if { [ -n "$HYG_BASE" ] && git bundle create -q "$_out" "$_tmpref" "^$HYG_BASE" >/dev/null 2>&1; } ||
     git bundle create -q "$_out" "$_tmpref" >/dev/null 2>&1; then
    if git bundle verify -q "$_out" >/dev/null 2>&1 && _sum="$(hyg_sha256 "$_out")" && [ -n "$_sum" ] &&
       printf '%s  %s\n' "$_sum" "$(basename "$_out")" > "$_out.sha256"; then
      _ok=1
    fi
  fi
  git update-ref -d "$_tmpref" "$2" >/dev/null 2>&1 || _ok=0
  if [ "$_ok" != "1" ]; then rm -f "$_out" "$_out.sha256"; return 1; fi
  printf '%s' "$_out"
}

# hyg_delete_branch BRANCH TIP HOW [BUNDLE] — delete BRANCH only if it still
# points at TIP, atomically (`update-ref -d <ref> <old>` is a compare-and-
# delete). `git branch -d` is never used: it deletes whatever the branch points
# at NOW whenever that is merged, so a branch that moved after inspection would
# go. An ancestor of BASE is reachable from BASE and needs no bundle; a
# non-ancestor (squash/patch-equivalent) is deleted only after a successful
# preservation (BUNDLE, or one made here). Its config section is removed after
# a successful delete, as `branch -d` would.
hyg_delete_branch() {
  _b=""
  if [ "$3" != "ancestor" ]; then
    _b="${4:-}"
    if [ -z "$_b" ]; then _b="$(hyg_preserve "$1" "$2")" || return 1; fi
  fi
  hyg_test_pause delete
  # A same-tip checkout, rebase or bisect does not move the ref, so the
  # compare-and-delete below would not notice it: re-read every worktree's
  # use of the branch right before deleting (hyg_in_use, which also covers
  # the primary and locked or offline worktrees). Failed inspection retains it.
  [ -n "$HYG_TMP" ] || return 1
  hyg_in_use > "$HYG_TMP/in-use" 2>/dev/null || return 1
  if grep -Fqx -- "$1" "$HYG_TMP/in-use"; then
    hyg_say "git-guard hygiene: branch $1 kept (checked out, rebasing or bisecting in a worktree)"
    return 1
  else
    _delete_scan_status=$?
    [ "$_delete_scan_status" = "1" ] || return 1
  fi
  git update-ref -d "refs/heads/$1" "$2" >/dev/null 2>&1 || return 1
  git config --remove-section "branch.$1" >/dev/null 2>&1 || :
  [ -z "$_b" ] || echo "      (bundle kept: $_b)"
  return 0
}

hyg_drain() {
  _apply=0; _allow_ignored=0
  for _a in "$@"; do
    case "$_a" in
      --apply) _apply=1 ;;
      --dry-run) _apply=0 ;;
      --allow-ignored) _allow_ignored=1 ;;
      *) hyg_say "git-guard hygiene drain: unknown argument '$_a'"; return 2 ;;
    esac
  done
  hyg_measure "" "" 0
  [ -n "$HYG_TMP" ] || { hyg_say "git-guard hygiene drain: cannot create a temp dir; nothing done"; return 1; }
  # A scan that cannot see every worktree's HEAD and rebase/bisect state
  # cannot say which branches are in use, so every branch is: refuse the whole
  # drain, dry run included, and name what could not be read.
  if ! hyg_in_use > "$HYG_TMP/in-use" 2> "$HYG_TMP/in-use-err"; then
    cat "$HYG_TMP/in-use-err" >&2
    hyg_say "git-guard hygiene drain: refused: cannot tell which branches worktrees are using, so every branch is treated as in use; nothing removed."
    hyg_say "  Restore read and search permission on the path above (or finish that worktree's operation), then rerun."
    return 1
  fi
  _min_age="$(hyg_int hygiene.drainMinAgeMinutes "$HYG_DEFAULT_MIN_AGE")"
  hyg_test_pause start
  echo "git-guard hygiene drain ($([ "$_apply" = "1" ] && echo apply || echo dry-run)): $(git rev-parse --show-toplevel 2>/dev/null)"
  echo "  (merge state is judged from refs as of the last fetch; run git fetch --prune first)"
  [ -n "$HYG_BASE" ] || echo "  base ref unknown (no <remote>/HEAD, no hygiene.baseRef): nothing is provably merged; skipping."

  hyg_worktrees > "$HYG_TMP/worktrees" 2>/dev/null || :
  while IFS='	' read -r _st _path _br _head _reason; do
    [ "$_br" = "-" ] && _br=""
    [ "$_head" = "-" ] && _head=""
    [ "$_reason" = "-" ] && _reason=""
    case "$_st" in
      exempt)   echo "  keep   $_path  (infrastructure lock: $_reason)"; continue ;;
      prunable) echo "  keep   $_path  (registration only; confirm the path is gone, then: git worktree prune)"; continue ;;
    esac
    if [ -n "$_reason" ]; then echo "  keep   $_path  (locked: $_reason)"; continue; fi
    [ -n "$HYG_BASE" ] && [ -n "$_head" ] || { echo "  keep   $_path  (base or HEAD unknown)"; continue; }
    _gd="$(git -C "$_path" rev-parse --absolute-git-dir 2>/dev/null)" || { echo "  keep   $_path  (cannot inspect)"; continue; }
    # Recent HEAD movement (worktree add, checkout, commit) means it may be a
    # live checkout: never pull it out from under its agent. logs/HEAD is used
    # because `git status` (below) can rewrite the index but not the reflog.
    # This check runs before anything here touches the worktree.
    if [ "$_min_age" -gt 0 ]; then
      _hf="$_gd/logs/HEAD"; [ -f "$_hf" ] || _hf="$_gd/HEAD"
      _recent="$(find "$_hf" -mmin -"$_min_age" 2>/dev/null)" || _recent="unknown"
      if [ -n "$_recent" ]; then
        echo "  keep   $_path  (HEAD moved within hygiene.drainMinAgeMinutes=$_min_age; may be in use)"; continue
      fi
    fi
    if hyg_op_in_progress "$_gd"; then echo "  keep   $_path  (merge/rebase/cherry-pick in progress)"; continue; fi
    if [ -n "$(git -C "$_path" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
      echo "  keep   $_path  (uncommitted or untracked changes)"; continue
    fi
    _ign="$(git -C "$_path" status --porcelain --ignored --untracked-files=all 2>/dev/null | grep -c '^!!' || true)"
    if [ "$_ign" -gt 0 ] && [ "$_allow_ignored" = "0" ]; then
      echo "  keep   $_path  ($_ign ignored paths, e.g. build output; review, then rerun with --allow-ignored)"; continue
    fi
    _how="$(hyg_integrated "$_head" "$HYG_BASE")"
    if [ -z "$_how" ]; then echo "  keep   $_path  (commits not on $HYG_BASE)"; continue; fi
    if [ -n "$_br" ]; then
      if hyg_stashed "$_br"; then echo "  keep   $_path  (a stash was made on $_br)"; continue; fi
      if hyg_remote_moved "$_br" "$HYG_BASE"; then echo "  keep   $_path  (upstream of $_br moved after the merge)"; continue; fi
    fi
    if [ "$_apply" != "1" ]; then echo "  would remove $_path  (${_br:-detached}, $_how)"; continue; fi
    # Not an ancestor of BASE: preserve BEFORE removing anything, and stop
    # this item entirely if preservation fails.
    _bundle=""
    if [ "$_how" != "ancestor" ]; then
      if ! _bundle="$(hyg_preserve "${_br:-detached-$(basename "$_path")}" "$_head")"; then
        echo "  keep   $_path  (PRESERVE FAILED: bundle not written; nothing removed)"; continue
      fi
    fi
    # Recheck right before removal: keep it if its HEAD or branch changed
    # since inspection (someone is using it).
    hyg_test_pause remove
    _now_head="$(git -C "$_path" rev-parse -q --verify HEAD 2>/dev/null || true)"
    _now_br="$(git -C "$_path" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    _now_status="$(git -C "$_path" status --porcelain --ignored --untracked-files=all 2>/dev/null)" || {
      echo "  keep   $_path  (cannot refresh worktree custody)"; continue
    }
    if [ "$_allow_ignored" = "1" ]; then
      _now_status="$(printf '%s\n' "$_now_status" | sed '/^!!/d')"
    fi
    if [ "$_now_head" != "$_head" ] || [ "$_now_br" != "$_br" ] ||
       [ -n "$_now_status" ] || hyg_op_in_progress "$_gd"; then
      echo "  keep   $_path  (changed since inspection; may be in use)"; continue
    fi
    if ! git worktree remove "$_path" >/dev/null 2>&1; then
      echo "  keep   $_path  (git worktree remove refused)"; continue
    fi
    echo "  removed $_path  (${_br:-detached}, $_how)${_bundle:+; bundle: $_bundle}"
    if [ -n "$_br" ]; then
      hyg_delete_branch "$_br" "$_head" "$_how" "$_bundle" || echo "      branch $_br kept (delete refused)"
    fi
  done < "$HYG_TMP/worktrees"

  # Stale branches (re-measured: worktree removal above may have freed some).
  hyg_stale "$HYG_BASE" > "$HYG_TMP/stale" 2>/dev/null || :
  while IFS='	' read -r _why _br; do
    [ -n "$_br" ] || continue
    _tip="$(git rev-parse -q --verify "refs/heads/$_br")" || continue
    _how="$(hyg_integrated "$_tip" "$HYG_BASE")"
    if [ -z "$_how" ]; then
      # Upstream gone, commits unique: preserve, never delete.
      if [ "$_apply" = "1" ]; then
        if _b="$(hyg_preserve "$_br" "$_tip")"; then echo "  keep   branch $_br  (unique commits, upstream $_why; bundle: $_b; owner decides)"
        else echo "  keep   branch $_br  (unique commits, upstream $_why; PRESERVE FAILED)"; fi
      else
        echo "  keep   branch $_br  (unique commits, upstream $_why; --apply writes a bundle, never deletes)"
      fi
      continue
    fi
    if hyg_stashed "$_br"; then echo "  keep   branch $_br  (a stash was made on it)"; continue; fi
    if hyg_remote_moved "$_br" "$HYG_BASE"; then echo "  keep   branch $_br  (upstream moved after the merge)"; continue; fi
    if [ "$_apply" = "1" ]; then
      if hyg_delete_branch "$_br" "$_tip" "$_how"; then echo "  removed branch $_br  ($_how)"
      else echo "  keep   branch $_br  (PRESERVE FAILED or branch moved; nothing deleted)"; fi
    else
      echo "  would remove branch $_br  ($_how)"
    fi
  done < "$HYG_TMP/stale"
  [ "$_apply" = "1" ] || echo "  (dry run: nothing changed; rerun with --apply)"
  echo "  Remote branches are left to GitHub's delete_branch_on_merge; open PRs need review, merge or close."
  return 0
}

# --- sync: fleet auto fast-forward + drain report ----------------------------
#
# Owner direction (2026-10-30): more repositories should fast-forward on their
# own, so the branch, worktree and PR backlog drains with less effort. `sync`
# walks hygiene.syncRoots, fetches each repository once per upstream remote
# with a bound, and fast-forwards a checkout only when nothing local can be
# lost or disturbed. Every other checkout is a logged skip. The read-only
# `drain --dry-run` of each repository then goes into one report file. sync
# never deletes anything. Tests: tests/36-sync.t.sh.

HYG_SYNC_DEFAULT_FETCH_TIMEOUT=60
HYG_SYNC_DEFAULT_DRAIN_TIMEOUT=300
HYG_SYNC_UNIT=git-guard-sync

hyg_sync_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# hyg_sync_note RESULT PATH BRANCH REASON [BEFORE AFTER] — one log line on
# stderr (the journal, under the timer) and one report record.
hyg_sync_note() {
  hyg_say "git-guard sync: $1 $2 (${3:--}): $4"
  printf 'C\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$HYG_SYNC_REPO" "$2" "${3:--}" "$1" "$4" "${5:--}" "${6:--}" >> "$HYG_SYNC_REC"
}

# hyg_sync_bounded SECONDS CMD... — run CMD, killed after SECONDS. Exit 124
# means it timed out. Uses timeout(1) when present, else a watchdog.
hyg_sync_bounded() {
  _bs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$_bs" "$@"; _brc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 5 "$_bs" "$@"; _brc=$?
  else
    "$@" & _bp=$!
    ( sleep "$_bs"; kill -9 "$_bp" 2>/dev/null ) & _bw=$!
    wait "$_bp"; _brc=$?
    kill "$_bw" 2>/dev/null; wait "$_bw" 2>/dev/null
    [ "$_brc" = "137" ] && _brc=124
  fi
  [ "$_brc" = "137" ] && _brc=124
  return "$_brc"
}

# hyg_sync_excluded PATH — runner work dirs and /opt deployment slots are
# never touched, wherever a root points (HYG_SYNC_WHY=excluded-path). Nor is
# a path the host excludes without writing into the repository: a
# hygiene.syncExclude value in the global or system config, or a line of
# ${XDG_CONFIG_HOME:-~/.config}/git-guard/sync.exclude. Each is a path or a
# glob and also covers everything below it (HYG_SYNC_WHY names the entry).
hyg_sync_excluded() {
  case "$1/" in /opt/*|*/_work/*|*/actions-runner/*) HYG_SYNC_WHY=excluded-path; return 0 ;; esac
  [ -s "$HYG_TMP/excludes" ] || return 1
  while IFS='	' read -r _xs _xp; do
    # shellcheck disable=SC2254  # the entry is a glob on purpose
    case "$1" in $_xp|$_xp/*) HYG_SYNC_WHY="excluded ($_xs: $_xp)"; return 0 ;; esac
  done < "$HYG_TMP/excludes"
  return 1
}

# hyg_sync_excludes — <source>\t<pattern> lines for hyg_sync_excluded. Run
# from / so that no repository's own config is read; ~ is expanded, blank
# lines and # comments are dropped, and an existing directory is also listed
# under its physical path (the paths sync compares are physical).
hyg_sync_excludes() {
  _xf="${XDG_CONFIG_HOME:-$HOME/.config}/git-guard/sync.exclude"
  { git config --get-all hygiene.syncExclude 2>/dev/null | sed 's/^/hygiene.syncExclude	/'
    [ -r "$_xf" ] && sed 's/^/sync.exclude	/' "$_xf"
  } | while IFS='	' read -r _xs _xp; do
    _xp="$(printf '%s' "$_xp" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$_xp" in ''|\#*) continue ;; \~) _xp="$HOME" ;; \~/*) _xp="$HOME/${_xp#??}" ;; esac
    _xp="${_xp%/}"; [ -n "$_xp" ] || continue
    printf '%s\t%s\n' "$_xs" "$_xp"
    if [ -d "$_xp" ]; then
      _xr="$(cd "$_xp" 2>/dev/null && pwd -P)"
      [ -n "$_xr" ] && [ "$_xr" != "$_xp" ] && printf '%s\t%s\n' "$_xs" "$_xr"
    fi
  done
}

# hyg_sync_ancestors — this process and its ancestors (Linux /proc), space
# separated: the shell that ran `sync` from inside a checkout is not a user of
# that checkout.
hyg_sync_ancestors() {
  _ap=$$; _an=0; _al=""
  while [ -n "$_ap" ] && [ "$_ap" != "0" ] && [ "$_an" -lt 64 ]; do
    _al="$_al $_ap"; _an=$((_an + 1))
    [ -r "/proc/$_ap/stat" ] || break
    # The command name may hold spaces or parens: ppid follows the LAST ") ".
    _ap="$(sed -n 's/.*) [^ ]* \([0-9][0-9]*\) .*/\1/p' "/proc/$_ap/stat" 2>/dev/null)"
  done
  printf '%s' "$_al"
}

# hyg_sync_cwd_user DIR — prints the pid of one process (not an ancestor)
# whose cwd is DIR or below it, "unavailable" when this host has no Linux
# /proc to ask, or nothing. Processes of other users whose cwd cannot be read
# are not visible; the log says how many.
hyg_sync_cwd_user() {
  if [ "$(uname -s 2>/dev/null)" != "Linux" ] || [ ! -r /proc/self/cwd ]; then printf 'unavailable'; return 0; fi
  # shellcheck disable=SC2012  # ls -l is the one-process way to read every cwd link
  ls -l /proc/[0-9]*/cwd 2>/dev/null | awk -v t="$1" -v anc="$HYG_SYNC_ANC" '
    BEGIN { n = split(anc, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
    {
      i = index($0, " -> "); if (!i) next
      target = substr($0, i + 4); link = substr($0, 1, i - 1)
      sub(/.* \/proc\//, "", link); sub(/\/cwd$/, "", link)
      if (link in skip) next
      if (target == t || index(target, t "/") == 1) { print link; exit }
    }'
}

# hyg_sync_fetched REMOTE — the recorded fetch result for REMOTE in this repo.
hyg_sync_fetched() {
  awk -F '\t' -v r="$1" '$1 == r { print $2; exit }' "$HYG_TMP/fetched" 2>/dev/null
}

# hyg_sync_checkout PATH PRIMARY DEFAULT_BRANCH LOCK — decide one checkout.
# Fast-forward only when every check passes; each failed check is one skip.
hyg_sync_checkout() {
  _wt="$1"; _prim="$2"; _defb="$3"; _lock="$4"
  _br="$(git -C "$_wt" symbolic-ref -q --short HEAD 2>/dev/null)" || _br=""
  if hyg_sync_excluded "$_wt"; then hyg_sync_note skip "$_wt" "$_br" "$HYG_SYNC_WHY"; return 0; fi
  if [ "$_lock" != "-" ]; then hyg_sync_note skip "$_wt" "$_br" "worktree-locked: $_lock"; return 0; fi
  [ -n "$_br" ] || { hyg_sync_note skip "$_wt" "" detached; return 0; }
  case "$_br" in preserve/*) hyg_sync_note skip "$_wt" "$_br" preserve-branch; return 0 ;; esac
  if [ "$_prim" = "1" ]; then
    [ -n "$_defb" ] || { hyg_sync_note skip "$_wt" "$_br" default-branch-unknown; return 0; }
    [ "$_br" = "$_defb" ] || { hyg_sync_note skip "$_wt" "$_br" "not-default-branch (default $_defb)"; return 0; }
  fi
  _rem="$(git -C "$_wt" config --get "branch.$_br.remote" 2>/dev/null || true)"
  _up="$(git -C "$_wt" for-each-ref --format='%(upstream)' "refs/heads/$_br" 2>/dev/null)"
  if [ -z "$_rem" ] || [ -z "$_up" ] || ! git -C "$_wt" config --get "remote.$_rem.url" >/dev/null 2>&1; then
    hyg_sync_note skip "$_wt" "$_br" no-upstream; return 0
  fi
  _fr="$(hyg_sync_fetched "$_rem")"
  [ "$_fr" = "ok" ] || { hyg_sync_note skip "$_wt" "$_br" "fetch-${_fr:-failed} ($_rem)"; return 0; }
  git -C "$_wt" rev-parse -q --verify "$_up^{commit}" >/dev/null 2>&1 || { hyg_sync_note skip "$_wt" "$_br" upstream-gone; return 0; }
  _gd="$(git -C "$_wt" rev-parse --absolute-git-dir 2>/dev/null)" || { hyg_sync_note skip "$_wt" "$_br" cannot-inspect; return 0; }
  if hyg_op_in_progress "$_gd"; then hyg_sync_note skip "$_wt" "$_br" "in-progress (merge/rebase/cherry-pick/revert/bisect)"; return 0; fi
  [ ! -e "$_gd/index.lock" ] || { hyg_sync_note skip "$_wt" "$_br" "locked: index.lock"; return 0; }
  if git -C "$_wt" ls-files -v 2>/dev/null | grep -q '^[a-zS] '; then
    hyg_sync_note skip "$_wt" "$_br" "hidden-local-changes (skip-worktree/assume-unchanged)"; return 0
  fi
  _st="$(git -C "$_wt" status --porcelain --untracked-files=normal 2>/dev/null)" || { hyg_sync_note skip "$_wt" "$_br" status-failed; return 0; }
  if [ -n "$_st" ]; then
    if printf '%s\n' "$_st" | grep -qv '^??'; then hyg_sync_note skip "$_wt" "$_br" dirty
    else hyg_sync_note skip "$_wt" "$_br" untracked; fi
    return 0
  fi
  _lr="$(git -C "$_wt" rev-list --left-right --count "HEAD...$_up" 2>/dev/null)" || { hyg_sync_note skip "$_wt" "$_br" count-failed; return 0; }
  _ahead="$(printf '%s' "$_lr" | awk '{print $1}')"; _behind="$(printf '%s' "$_lr" | awk '{print $2}')"
  if [ "${_ahead:-1}" != "0" ]; then hyg_sync_note skip "$_wt" "$_br" "ahead ($_ahead ahead, $_behind behind)"; return 0; fi
  if [ "${_behind:-0}" = "0" ]; then hyg_sync_note current "$_wt" "$_br" up-to-date; return 0; fi
  _phys="$(cd "$_wt" 2>/dev/null && pwd -P)" || { hyg_sync_note skip "$_wt" "$_br" cannot-inspect; return 0; }
  _user="$(hyg_sync_cwd_user "$_phys")"
  case "$_user" in
    unavailable) hyg_sync_note skip "$_wt" "$_br" "cwd-check-unavailable (no Linux /proc)"; return 0 ;;
    ?*) hyg_sync_note skip "$_wt" "$_br" "in-use (pid $_user has its cwd in the tree)"; return 0 ;;
  esac
  _before="$(git -C "$_wt" rev-parse HEAD 2>/dev/null)"
  if [ "$HYG_SYNC_DRY" = "1" ]; then
    hyg_sync_note would-ff "$_wt" "$_br" "$_behind commit(s) from ${_up#refs/remotes/} (dry run)" "$_before" "$(git -C "$_wt" rev-parse "$_up" 2>/dev/null)"
    return 0
  fi
  git -C "$_wt" merge --ff-only --quiet "$_up" </dev/null >/dev/null 2>&1
  _after="$(git -C "$_wt" rev-parse HEAD 2>/dev/null)"
  if [ "$_after" = "$_before" ]; then hyg_sync_note skip "$_wt" "$_br" merge-refused "$_before" "$_after"; return 0; fi
  hyg_sync_note ff "$_wt" "$_br" "$_behind commit(s) from ${_up#refs/remotes/}" "$_before" "$_after"
  return 0
}

# hyg_sync_repo REPO — fetch, then decide the primary and each linked worktree,
# then record the drain dry run.
hyg_sync_repo() {
  HYG_SYNC_REPO="$1"
  if hyg_sync_excluded "$1"; then hyg_sync_note skip "$1" "" "$HYG_SYNC_WHY"; return 0; fi
  if [ "$(git -C "$1" config --bool --get hygiene.sync 2>/dev/null)" = "false" ]; then
    hyg_sync_note skip "$1" "" "opted-out (hygiene.sync=false)"; return 0
  fi
  # <path>\t<primary 1|0>\t<lock reason or ->, prunable and bare entries dropped.
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '
    function flush() { if (path != "" && !bare && !prunable) printf "%s\t%d\t%s\n", path, (n == 1), (locked ? (reason == "" ? "locked" : reason) : "-"); path = ""; bare = 0; prunable = 0; locked = 0; reason = "" }
    /^worktree / { flush(); n++; path = substr($0, 10); next }
    /^bare$/     { bare = 1; next }
    /^prunable/  { prunable = 1; next }
    /^locked/    { locked = 1; reason = substr($0, 8); next }
    END { flush() }' > "$HYG_TMP/checkouts"
  # Fetch once per remote that origin or any checked-out branch tracks.
  : > "$HYG_TMP/fetched"
  { git -C "$1" config --get remote.origin.url >/dev/null 2>&1 && echo origin
    while IFS='	' read -r _p _x _y; do
      _b="$(git -C "$_p" symbolic-ref -q --short HEAD 2>/dev/null)" || continue
      git -C "$1" config --get "branch.$_b.remote" 2>/dev/null
    done < "$HYG_TMP/checkouts"
  } | awk 'NF && !seen[$0]++' > "$HYG_TMP/remotes"
  _to="$(cd "$1" && hyg_int hygiene.syncFetchTimeout "$HYG_SYNC_DEFAULT_FETCH_TIMEOUT")"
  while IFS= read -r _r; do
    git -C "$1" config --get "remote.$_r.url" >/dev/null 2>&1 || continue
    hyg_sync_bounded "$_to" git -C "$1" -c gc.auto=0 fetch --prune --quiet "$_r" </dev/null >/dev/null 2>&1
    case $? in 0) _res=ok ;; 124) _res=timeout ;; *) _res=failed ;; esac
    printf '%s\t%s\n' "$_r" "$_res" >> "$HYG_TMP/fetched"
    printf 'F\t%s\t%s\t%s\n' "$1" "$_r" "$_res" >> "$HYG_SYNC_REC"
    [ "$_res" = "ok" ] || hyg_say "git-guard sync: fetch $_res $1 ($_r)"
  done < "$HYG_TMP/remotes"
  _defb="$(cd "$1" && hyg_base_name "$(hyg_base "$(hyg_remote "")")")"
  while IFS='	' read -r _p _prim _lk; do
    hyg_sync_checkout "$_p" "$_prim" "$_defb" "$_lk"
  done < "$HYG_TMP/checkouts"
  if [ "$HYG_SYNC_DRAIN" = "1" ]; then
    _dto="$(cd "$1" && hyg_int hygiene.syncDrainTimeout "$HYG_SYNC_DEFAULT_DRAIN_TIMEOUT")"
    ( cd "$1" && hyg_sync_bounded "$_dto" sh "$HYG_SELF" drain --dry-run ) </dev/null > "$HYG_TMP/drain" 2>&1
    _drc=$?
    [ "$_drc" = "124" ] && echo "  (drain dry run timed out after ${_dto}s: hygiene.syncDrainTimeout)" >> "$HYG_TMP/drain"
    awk -v r="$1" -v rc="$_drc" '{ printf "D\t%s\t%s\t%s\n", r, rc, $0 } END { if (NR == 0) printf "D\t%s\t%s\t\n", r, rc }' "$HYG_TMP/drain" >> "$HYG_SYNC_REC"
  fi
  return 0
}

# hyg_sync_roots — configured roots (hygiene.syncRoots, multi-valued, ~
# expanded), else ~/dev/repos and ~/.claude/repos. One per line.
hyg_sync_roots() {
  _rs="$(git config --get-all hygiene.syncRoots 2>/dev/null || true)"
  [ -n "$_rs" ] || _rs="$HOME/dev/repos
$HOME/.claude/repos"
  printf '%s\n' "$_rs" | while IFS= read -r _r; do
    case "$_r" in \~) _r="$HOME" ;; \~/*) _r="$HOME/${_r#??}" ;; esac
    [ -n "$_r" ] && printf '%s\n' "$_r"
  done
}

# hyg_sync_report OUT — render the records as JSON (written to a temp file and
# moved into place, so a reader never sees half a report).
hyg_sync_report() {
  awk -F '\t' -v host="$(hostname 2>/dev/null || uname -n)" -v started="$HYG_SYNC_STARTED" -v finished="$(hyg_sync_now)" -v roots="$HYG_SYNC_ROOTS" '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/\r/, "\\r", s); gsub(/[[:cntrl:]]/, " ", s); return "\"" s "\"" }
    function opt(s) { return (s == "-" ? "null" : esc(s)) }
    $1 == "C" { c[++nc] = sprintf("{\"repo\":%s,\"path\":%s,\"branch\":%s,\"result\":%s,\"reason\":%s,\"before\":%s,\"after\":%s}", esc($2), esc($3), opt($4), esc($5), esc($6), opt($7), opt($8)) }
    $1 == "F" { f[++nf] = sprintf("{\"repo\":%s,\"remote\":%s,\"result\":%s}", esc($2), esc($3), esc($4)) }
    $1 == "D" {
      if (!($2 in di)) { di[$2] = ++nd; dr[nd] = $2; dx[nd] = $3; dl[nd] = "" }
      k = di[$2]; line = $0; sub(/^D\t[^\t]*\t[^\t]*\t/, "", line)
      if (line != "") dl[k] = dl[k] (dl[k] == "" ? "" : ",") esc(line)
    }
    END {
      printf "{\"schema\":1,\"host\":%s,\"started\":%s,\"finished\":%s,\"roots\":[", esc(host), esc(started), esc(finished)
      n = split(roots, rr, "\n"); s = ""; for (i = 1; i <= n; i++) if (rr[i] != "") { printf "%s%s", s, esc(rr[i]); s = "," }
      printf "],\"checkouts\":["; for (i = 1; i <= nc; i++) printf "%s%s", (i > 1 ? "," : ""), c[i]
      printf "],\"fetches\":["; for (i = 1; i <= nf; i++) printf "%s%s", (i > 1 ? "," : ""), f[i]
      printf "],\"drain\":["; for (i = 1; i <= nd; i++) printf "%s{\"repo\":%s,\"exit\":%d,\"lines\":[%s]}", (i > 1 ? "," : ""), esc(dr[i]), dx[i], dl[i]
      printf "]}\n"
    }' "$HYG_SYNC_REC" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

hyg_sync_run() {
  HYG_SYNC_DRAIN=1; HYG_SYNC_DRY=0
  for _a in "$@"; do
    case "$_a" in
      --no-drain) HYG_SYNC_DRAIN=0 ;;
      --dry-run) HYG_SYNC_DRY=1 ;;
      *) hyg_say "git-guard hygiene sync: unknown argument '$_a'"; return 2 ;;
    esac
  done
  [ "${GIT_GUARD:-1}" = "0" ] && return 0
  HYG_SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
  _state="${XDG_STATE_HOME:-$HOME/.local/state}/git-guard"
  mkdir -p "$_state" 2>/dev/null || { hyg_say "git-guard sync: cannot create $_state; nothing done"; return 1; }
  hyg_tmpdir
  [ -n "$HYG_TMP" ] || { hyg_say "git-guard sync: cannot create a temp dir; nothing done"; return 1; }
  # One pass at a time per user; a lock older than two hours is a crashed run.
  HYG_SYNC_LOCK="$_state/sync.lock"
  if ! mkdir "$HYG_SYNC_LOCK" 2>/dev/null; then
    if [ -n "$(find "$HYG_SYNC_LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
      rmdir "$HYG_SYNC_LOCK" 2>/dev/null; mkdir "$HYG_SYNC_LOCK" 2>/dev/null || { hyg_say "git-guard sync: another pass holds $HYG_SYNC_LOCK"; return 0; }
    else
      hyg_say "git-guard sync: another pass holds $HYG_SYNC_LOCK; nothing done"; return 0
    fi
  fi
  trap 'rm -rf "$HYG_TMP"; rmdir "$HYG_SYNC_LOCK" 2>/dev/null' EXIT
  # Never prompt (the timer has no terminal), and do not inherit another
  # repository's GIT_DIR or index from a caller that runs inside a hook.
  GIT_TERMINAL_PROMPT=0; GCM_INTERACTIVE=never
  [ -n "${GIT_SSH_COMMAND:-}" ] || GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10'
  export GIT_TERMINAL_PROMPT GCM_INTERACTIVE GIT_SSH_COMMAND
  for _v in $(git rev-parse --local-env-vars 2>/dev/null); do unset "$_v"; done
  cd / || return 1
  HYG_SYNC_ANC="$(hyg_sync_ancestors)"
  HYG_SYNC_STARTED="$(hyg_sync_now)"
  HYG_SYNC_REC="$HYG_TMP/records"; : > "$HYG_SYNC_REC"
  HYG_SYNC_ROOTS="$(hyg_sync_roots)"
  hyg_sync_excludes > "$HYG_TMP/excludes"
  printf '%s\n' "$HYG_SYNC_ROOTS" | while IFS= read -r _root; do
    [ -d "$_root" ] || continue
    for _d in "$_root" "$_root"/*; do
      [ -d "$_d/.git" ] || continue
      (cd "$_d" && pwd -P)
    done
  done | awk 'NF && !seen[$0]++' > "$HYG_TMP/repos"
  while IFS= read -r _repo; do hyg_sync_repo "$_repo"; done < "$HYG_TMP/repos"
  hyg_sync_report "$_state/sync-report.json" || hyg_say "git-guard sync: could not write $_state/sync-report.json"
  hyg_say "git-guard sync: $(awk -F '\t' '$1 == "C" { n[$5]++ } END { printf "%d ff, %d would-ff, %d current, %d skip", n["ff"], n["would-ff"], n["current"], n["skip"] }' "$HYG_SYNC_REC") across $(grep -c . "$HYG_TMP/repos" || true) repos; report $_state/sync-report.json"
  return 0
}

# hyg_sync_cli — the git-guard CLI the timer should start: the store's
# `current` link when this release is the one it points at, so an upgrade
# moves the timer with it; otherwise this checkout's own bin/git-guard.
hyg_sync_cli() {
  _root="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd -P)"
  _store="$(dirname "$_root")"
  if [ -L "$_store/current" ] && [ "$(cd "$_store/current" 2>/dev/null && pwd -P)" = "$_root" ]; then
    printf '%s' "$_store/current/bin/git-guard"
  else
    printf '%s' "$_root/bin/git-guard"
  fi
}

# hyg_sync_timer install|uninstall — a systemd --user oneshot service and a
# 30-minute timer. GIT_GUARD_SYNC_UNIT_DIR and GIT_GUARD_SYNC_SYSTEMCTL exist
# for tests.
hyg_sync_timer() {
  _ud="${GIT_GUARD_SYNC_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
  _sc="${GIT_GUARD_SYNC_SYSTEMCTL:-systemctl}"
  if [ "$1" = "uninstall" ]; then
    "$_sc" --user disable --now "$HYG_SYNC_UNIT.timer" >/dev/null 2>&1 || :
    rm -f "$_ud/$HYG_SYNC_UNIT.service" "$_ud/$HYG_SYNC_UNIT.timer"
    "$_sc" --user daemon-reload >/dev/null 2>&1 || :
    echo "git-guard sync: removed $_ud/$HYG_SYNC_UNIT.{service,timer}"
    return 0
  fi
  command -v "$_sc" >/dev/null 2>&1 || { hyg_say "git-guard sync: $_sc not found; this installer needs systemd --user (Windows: see docs/QA_TOOLING.md §12)"; return 1; }
  mkdir -p "$_ud" || return 1
  _cli="$(hyg_sync_cli)"
  cat > "$_ud/$HYG_SYNC_UNIT.service" <<EOF || return 1
[Unit]
Description=git-guard hygiene sync: fast-forward clean checkouts, write the drain report

[Service]
Type=oneshot
ExecStart=/bin/sh "$_cli" hygiene sync
Nice=19
IOSchedulingClass=idle
TimeoutStartSec=1800
EOF
  cat > "$_ud/$HYG_SYNC_UNIT.timer" <<EOF || return 1
[Unit]
Description=Run git-guard hygiene sync every 30 minutes

[Timer]
OnCalendar=*:0/30
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF
  "$_sc" --user daemon-reload || { hyg_say "git-guard sync: systemctl --user daemon-reload failed"; return 1; }
  "$_sc" --user enable --now "$HYG_SYNC_UNIT.timer" || { hyg_say "git-guard sync: could not enable $HYG_SYNC_UNIT.timer"; return 1; }
  echo "git-guard sync: installed $_ud/$HYG_SYNC_UNIT.{service,timer} (ExecStart $_cli); logs: journalctl --user -u $HYG_SYNC_UNIT"
  return 0
}

hyg_sync() {
  case "${1:-run}" in
    run)             [ "$#" -gt 0 ] && shift; hyg_sync_run "$@" ;;
    --*)             hyg_sync_run "$@" ;;
    install-timer)   hyg_sync_timer install ;;
    uninstall-timer) hyg_sync_timer uninstall ;;
    *) hyg_say "usage: git-guard hygiene sync [run] [--dry-run] [--no-drain] | install-timer | uninstall-timer"; return 2 ;;
  esac
}

# --- global defaults ---------------------------------------------------------

hyg_defaults() {
  _dry=0; [ "${1:-}" = "--dry-run" ] && _dry=1
  # Deliberately NOT set:
  #  * gc.worktreePruneExpire: shortening it prunes the registration of a
  #    worktree whose drive is merely offline (T:), which WORKTREE_LIFECYCLE.md
  #    forbids.
  #  * fetch.pruneTags: with fetch.prune it deletes local-only tags (release or
  #    backup tags never pushed) on every fetch.
  for _kv in \
    "fetch.prune=true" \
    "worktree.guessRemote=true" \
    "rerere.enabled=true" \
    "hygiene.maxWorktrees=$HYG_DEFAULT_MAX_WORKTREES" \
    "hygiene.maxStaleBranches=$HYG_DEFAULT_MAX_STALE"; do
    _k="${_kv%%=*}"; _v="${_kv#*=}"
    _cur="$(git config --global --get "$_k" 2>/dev/null || true)"
    if [ -n "$_cur" ]; then
      echo "  ok (kept): $_k=$_cur"
    elif [ "$_dry" = "1" ]; then
      echo "  DRY: git config --global $_k $_v"
    elif git config --global "$_k" "$_v"; then
      echo "  set: $_k=$_v"
    else
      echo "  FAILED to set $_k (continuing)" >&2
    fi
  done
  # Fleet infrastructure lock namespaces (release trees, fleet-build pins),
  # the same ones vigil-utils policy/backlog-caps.toml treats as infrastructure.
  if [ -n "$(git config --global --get-all hygiene.exemptLockPrefix 2>/dev/null || true)" ]; then
    echo "  ok (kept): hygiene.exemptLockPrefix (already set)"
  else
    for _p in "vigil.operator-release/" "vigil.fleet-build/"; do
      if [ "$_dry" = "1" ]; then echo "  DRY: git config --global --add hygiene.exemptLockPrefix $_p"
      elif git config --global --add hygiene.exemptLockPrefix "$_p"; then echo "  set: hygiene.exemptLockPrefix += $_p"
      else echo "  FAILED to add hygiene.exemptLockPrefix $_p (continuing)" >&2
      fi
    done
  fi
  return 0
}

case "${1:-report}" in
  pre-push)      shift; hyg_pre_push "$@" ;;
  post-checkout) shift; hyg_post_checkout "$@" ;;
  report)        hyg_report ;;
  check)         hyg_measure "" "" 1; [ -z "$HYG_OVER" ] || { hyg_explain OVER; exit 1; } ;;
  drain)         shift; hyg_drain "$@" ;;
  defaults)      shift; hyg_defaults "$@" ;;
  sync)          shift; hyg_sync "$@" ;;
  *) hyg_say "usage: hygiene.sh pre-push|post-checkout|report|check|drain|defaults|sync"; exit 2 ;;
esac
