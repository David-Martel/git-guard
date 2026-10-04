#!/bin/sh
#
# git-guard preserve/* exemption — structural checks only, trailer-gated.
#
# A preservation commit snapshots WIP that the hooks did not author, so a repo's
# language/lint gates (lefthook ast-grep/pyright/rust-no-panic, astgrep_panics=
# strict, ...) refuse it, and preservation was forced out of commits into
# fragile stash-create objects. This lets such a commit through with ONLY the
# structural checks, and only when BOTH hold:
#   * the branch is preserve/* (at pre-push: EVERY updated remote ref is
#     refs/heads/preserve/* or refs/preserve/*), and
#   * the commit message carries `Preserve-Of: <ref-or-sha>` and that value
#     resolves to a commit. A trailer naming nothing unlocks nothing.
#
# Still runs (structural):
#   secret scan      hook-native: hooks/pre-commit step 1 (common/secret_scan.sh),
#                    which runs BEFORE this file is consulted; at pre-push this
#                    file scans every new commit (they may never have been
#                    scanned: update-ref writes to refs/preserve/* run no hooks).
#   NUL / reserved   hook-native: hooks/pre-commit step 2 (common/nul-cleanup.sh,
#   paths            which also carries the reserved-path safety), likewise
#                    BEFORE this file is consulted.
#   large-file guard inside qa_gate.sh, so it is listed in
#                    GG_PRESERVE_QA_STRUCTURAL below and run via QA_ONLY_CHECKS.
# Skipped: the rest of qa_gate.sh (language/lint checks) and the repo's
# downstream chain (GIT_GUARD_DOWNSTREAM_HOOK / .git-guard/*.local / lefthook).
#
# The message is not available at pre-commit, so the work is split:
#   pre-commit  structural checks, then record a deferral marker keyed to the
#               index tree and branch; the caller skips the rest of the hook.
#   commit-msg  consume the marker. Valid trailer -> log and pass. Otherwise
#               re-run hooks/pre-commit in full (GIT_GUARD_PRESERVE_FULL_RUN=1),
#               so no QA is ever skipped without a valid trailer.
#   pre-push    preserve-only push whose new commits all carry a valid trailer
#               -> secret-scan those commits, log, and skip the downstream gate.
#
# Opt-out: `preserve_exemption=off` in the repo's .qa-gate.conf, or
# GIT_GUARD_PRESERVE_EXEMPTION=0 in the environment (the env can only disable).
# Log: stderr plus <git-common-dir>/git-guard/preserve-exemptions.log.
# Reference: docs/QA_TOOLING.md "preserve/* exemption".
#
# Usage (from the hooks; exit 3 = "not exempt, run the normal hook"):
#   preserve.sh pre-commit             0 deferred | 1 blocked | 3 not exempt
#   preserve.sh commit-msg <msgfile>   0 exempt   | 1 blocked | 3 not exempt
#                                      (3 also when the deferred QA ran and
#                                      passed: the commit was not exempted)
#   preserve.sh pre-push <remote> <url> < ref-list
#                                      0 exempt   | 1 blocked | 3 not exempt

set -u

GG_PRESERVE_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# qa_gate.sh-resident structural checks that still run on an exempted commit
# (space-separated QA_ONLY_CHECKS names). Hook-native structural checks run
# ahead of the pre-commit call site and need no entry here.
GG_PRESERVE_QA_STRUCTURAL="largefile"

gg_preserve_say() { printf 'git-guard: %s\n' "$*" >&2; }

# Echo the current branch if it is preserve/<something>; fail otherwise
# (detached HEAD included).
gg_preserve_branch() {
  _b="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  case "$_b" in preserve/?*) printf '%s' "$_b" ;; *) return 1 ;; esac
}

# Exemption enabled? Env can only disable. The repo conf is read through
# qa_gate.sh so precedence and validation match the gate; a malformed conf
# fails closed (no exemption), and the normal gate then reports it.
gg_preserve_enabled() {
  case "${GIT_GUARD_PRESERVE_EXEMPTION:-}" in 0|off|no|false) return 1 ;; esac
  _v="$(sh "$GG_PRESERVE_DIR/qa_gate.sh" --get preserve_exemption on 2>/dev/null)" || return 1
  [ "$_v" = "on" ]
}

gg_preserve_marker() { git rev-parse --git-path git-guard/preserve-deferred 2>/dev/null; }

# Append one line to the per-repo log (shared by all worktrees). A log that
# cannot be written is reported, not fatal: stderr already carries the record.
gg_preserve_log() {
  _dir="$(git rev-parse --git-common-dir 2>/dev/null)/git-guard"
  _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown-time)"
  _line="$_ts $* skipped=qa_gate-non-structural,downstream-chain"
  if mkdir -p "$_dir" 2>/dev/null && printf '%s\n' "$_line" >> "$_dir/preserve-exemptions.log" 2>/dev/null; then
    gg_preserve_say "preserve exemption USED ($*); logged to $_dir/preserve-exemptions.log"
  else
    gg_preserve_say "preserve exemption USED ($*); WARNING: could not write $_dir/preserve-exemptions.log"
  fi
}

# Read a commit message on stdin; echo each Preserve-Of value, one per line.
gg_preserve_trailers() {
  git interpret-trailers --parse 2>/dev/null | sed -n 's/^[Pp]reserve-[Oo]f: *//p'
}

# Succeed iff there is at least one Preserve-Of value and EVERY value resolves
# to a commit. The charset excludes revision syntax (`:/text`, `@{...}`, `^`,
# `~`) so a search or reflog expression cannot stand in for a real ref or sha.
# Echoes "value=sha" pairs for the log.
gg_preserve_valid() {
  _vals="$1"; _out=""
  [ -n "$_vals" ] || return 1
  for _v in $_vals; do
    case "$_v" in -*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
    _sha="$(git rev-parse --verify --quiet "${_v}^{commit}" 2>/dev/null)" || return 1
    _out="${_out:+$_out,}${_v}=${_sha}"
  done
  printf '%s' "$_out"
}

gg_preserve_pre_commit() {
  _marker="$(gg_preserve_marker)" || return 3
  # Only a marker written by THIS pre-commit may ever be consumed.
  rm -f "$_marker"
  [ "${GIT_GUARD_PRESERVE_FULL_RUN:-0}" = "1" ] && return 3
  _branch="$(gg_preserve_branch)" || return 3
  if ! gg_preserve_enabled; then
    gg_preserve_say "preserve exemption is disabled here (preserve_exemption / GIT_GUARD_PRESERVE_EXEMPTION); running the normal gates."
    return 3
  fi
  QA_SKIP_NUL=1 QA_ONLY_CHECKS="$GG_PRESERVE_QA_STRUCTURAL" sh "$GG_PRESERVE_DIR/qa_gate.sh" || return 1
  # Never defer without a marker: any failure here falls back to the full gate.
  _tree="$(git write-tree 2>/dev/null)" || return 3
  mkdir -p "$(dirname "$_marker")" 2>/dev/null || return 3
  printf '%s %s\n' "$_tree" "$_branch" > "$_marker" 2>/dev/null || return 3
  gg_preserve_say "branch '$_branch': structural checks passed; language/lint QA and downstream hooks DEFERRED to commit-msg (a valid 'Preserve-Of: <ref-or-sha>' trailer skips them)."
  return 0
}

gg_preserve_commit_msg() {
  _msg="${1:-}"
  _marker="$(gg_preserve_marker)" || return 3
  [ -f "$_marker" ] || return 3
  _m_tree=""; _m_branch=""
  read -r _m_tree _m_branch < "$_marker" || :
  rm -f "$_marker"
  _why=""
  _tree="$(git write-tree 2>/dev/null)" || _tree=""
  _branch="$(gg_preserve_branch)" || _branch=""
  if [ -z "$_tree" ] || [ "$_tree" != "$_m_tree" ] || [ "$_branch" != "$_m_branch" ]; then
    _why="the deferral marker does not match this commit (index tree or branch changed)"
  elif ! gg_preserve_enabled; then
    _why="the exemption is disabled"
  else
    _vals="$(gg_preserve_trailers < "$_msg")"
    if [ -z "$_vals" ]; then
      _why="no 'Preserve-Of:' trailer"
    elif _resolved="$(gg_preserve_valid "$_vals")"; then
      gg_preserve_log "hook=commit-msg branch=$_branch tree=$_tree preserve-of=$_resolved"
      return 0
    else
      _why="'Preserve-Of:' does not name an existing commit (refs and shas only)"
    fi
  fi
  gg_preserve_say "preserve exemption NOT applied: $_why; running the deferred QA now."
  # Any failure is 1: a downstream gate's own exit code must not read as 3.
  GIT_GUARD_PRESERVE_FULL_RUN=1 "$GG_PRESERVE_DIR/../pre-commit" || return 1
  return 3
}

gg_preserve_all_zero() { case "$1" in *[!0]*) return 1 ;; *) return 0 ;; esac; }

gg_preserve_pre_push() {
  _remote="${1:-}"
  gg_preserve_enabled || return 3
  _commits=""; _refs=""; _n=0
  while read -r _lref _lsha _rref _rsha; do
    [ -n "${_lref:-}" ] || continue
    case "$_rref" in refs/heads/preserve/?*|refs/preserve/?*) : ;; *) return 3 ;; esac
    _refs="${_refs:+$_refs,}$_rref"
    gg_preserve_all_zero "$_lsha" && continue   # deletion: no new commits
    if [ -n "$_rsha" ] && ! gg_preserve_all_zero "$_rsha" &&
       git cat-file -e "${_rsha}^{commit}" 2>/dev/null; then
      _new="$(git rev-list "$_lsha" --not "$_rsha" --remotes="$_remote" 2>/dev/null)" || return 3
    else
      _new="$(git rev-list "$_lsha" --not --remotes="$_remote" 2>/dev/null)" || return 3
    fi
    for _c in $_new; do
      _vals="$(git show -s --format=%B "$_c" 2>/dev/null | gg_preserve_trailers)"
      gg_preserve_valid "$_vals" >/dev/null || return 3
      _commits="$_commits $_c"; _n=$((_n + 1))
    done
  done
  [ -n "$_refs" ] || return 3
  if [ -n "$_commits" ]; then
    GIT_GUARD_SECRET_SCAN_COMMITS="$_commits" sh "$GG_PRESERVE_DIR/secret_scan.sh" || return 1
  fi
  gg_preserve_log "hook=pre-push remote=$_remote refs=$_refs commits=$_n"
  return 0
}

case "${1:-}" in
  pre-commit) gg_preserve_pre_commit ;;
  commit-msg) shift; gg_preserve_commit_msg "$@" ;;
  pre-push)   shift; gg_preserve_pre_push "$@" ;;
  *) printf 'usage: preserve.sh pre-commit | commit-msg <msgfile> | pre-push <remote> <url>\n' >&2; exit 2 ;;
esac
