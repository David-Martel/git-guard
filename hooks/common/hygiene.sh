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
# Environment:
#   GIT_GUARD=0                skip all git-guard hooks (existing convention)
#   GIT_GUARD_HYGIENE          off | warn | enforce, beats hygiene.mode
#   GIT_GUARD_HYGIENE_GH       gh executable to use (tests stub it)
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
  *) hyg_say "usage: hygiene.sh pre-push|post-checkout|report|check|drain|defaults"; exit 2 ;;
esac
