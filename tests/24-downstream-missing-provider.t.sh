#!/bin/sh
# Category 24 — a CONFIGURED-BUT-MISSING downstream provider fails loudly in
# pre-commit and pre-push, as it already does in commit-msg (category 13 §7).
#
# The defect this pins: pre-commit and pre-push tested the downstream variable
# with `[ -n "$VAR" ] && [ -x "$VAR" ]`, so a variable naming a missing or
# non-executable file was treated exactly like an UNSET one. The hook then fell
# through to the next provider (repo .git-guard/<hook>.local, then lefthook) or,
# with none present, exited 0 -- the configured gate was skipped with output
# identical to a pass.
#
# Each hook is invoked directly so only the chaining step is under test. The
# substitution sub-case plants a `.local` provider that writes a marker: with
# the variable set but broken, that provider must NOT run in its place. The
# empty-variable sub-case is the negative control: "" still means not configured
# and must reach the `.local` provider. No case depends on whether lefthook is
# installed, because a set variable is decided before lefthook is consulted.
# shellcheck shell=sh

# $1 hook name, $2 repo, $3 log; the rest are env assignments for the hook.
# pre-push gets a remote name + URL and an empty stdin (no ref list).
gg_t24_run() {
  _h="$1"; _r="$2"; _log="$3"; shift 3
  if [ "$_h" = "pre-push" ]; then
    ( cd "$_r" && env "$@" sh "$GG_ROOT/hooks/pre-push" origin git@example ) \
      >"$_log" 2>&1 </dev/null
  else
    ( cd "$_r" && env "$@" sh "$GG_ROOT/hooks/pre-commit" ) >"$_log" 2>&1 </dev/null
  fi
}

t_case_downstream_missing_provider() {
  t_begin "24 downstream missing provider (pre-commit + pre-push fail loudly)"

  for hook in pre-commit pre-push; do
    case "$hook" in
      pre-commit) var=GIT_GUARD_DOWNSTREAM_HOOK ;;
      pre-push)   var=GIT_GUARD_DOWNSTREAM_PRE_PUSH ;;
    esac
    r="$(gg_mktemp_repo)"
    [ -n "$r" ] || { t_fail "$hook: could not create a fixture repo"; return 1; }
    printf 'hi\n' > "$r/a.txt"
    ( cd "$r" && git add a.txt )
    log="$(gg_tmp_log)"

    # Positive control: a configured executable downstream runs and its exit
    # code propagates (so the refusals below are not just "always rc 1").
    printf '#!/bin/sh\necho downstream-ran >&2\nexit 7\n' > "$r/downstream-ok"
    chmod +x "$r/downstream-ok"
    gg_t24_run "$hook" "$r" "$log" "$var=$r/downstream-ok"; rc=$?
    t_expect_rc 7 "$rc" "$hook: a configured executable downstream's exit code propagates"
    grep -q downstream-ran "$log"; t_assert $? "$hook: the configured downstream actually ran"

    # Configured but MISSING, no other provider: must refuse, loudly.
    gg_t24_run "$hook" "$r" "$log" "$var=$r/no-such-hook"; rc=$?
    t_expect_rc 1 "$rc" "$hook: a configured but MISSING downstream refuses"
    grep -q 'git-guard BLOCK' "$log"; t_assert $? "$hook: the missing-downstream refusal is LOUD"
    grep -q "$var" "$log"; t_assert $? "$hook: the refusal names the variable"
    grep -q 'no-such-hook' "$log"; t_assert $? "$hook: the refusal names the configured path"

    # Configured but NOT EXECUTABLE: same refusal.
    printf '#!/bin/sh\nexit 0\n' > "$r/downstream-noexec"; chmod -x "$r/downstream-noexec"
    gg_t24_run "$hook" "$r" "$log" "$var=$r/downstream-noexec"; rc=$?
    t_expect_rc 1 "$rc" "$hook: a configured but NON-EXECUTABLE downstream refuses"
    grep -q 'git-guard BLOCK' "$log"; t_assert $? "$hook: the non-executable refusal is LOUD"

    # Configured but MISSING while a repo .local provider exists: refuse, and do
    # NOT silently substitute the .local provider for the configured one.
    mkdir -p "$r/.git-guard"
    printf '#!/bin/sh\necho local-provider-ran >&2\nexit 0\n' > "$r/.git-guard/$hook.local"
    chmod +x "$r/.git-guard/$hook.local"
    gg_t24_run "$hook" "$r" "$log" "$var=$r/no-such-hook"; rc=$?
    t_expect_rc 1 "$rc" "$hook: a MISSING downstream refuses even when a .local provider exists"
    if grep -q local-provider-ran "$log"; then
      t_fail "$hook: the .local provider was silently substituted for the missing one"
    else
      t_ok "$hook: the .local provider is NOT substituted for the missing one"
    fi

    # Negative control: an EMPTY variable means not configured -> the .local
    # provider is the one that runs, and the hook passes.
    gg_t24_run "$hook" "$r" "$log" "$var="; rc=$?
    t_expect_rc 0 "$rc" "$hook: an EMPTY downstream variable means not configured"
    grep -q local-provider-ran "$log"; t_assert $? "$hook: with the variable empty, the .local provider runs"

    # The documented bypass still wins over a broken configuration.
    gg_t24_run "$hook" "$r" "$log" GIT_GUARD=0 "$var=$r/no-such-hook"; rc=$?
    t_expect_rc 0 "$rc" "$hook: GIT_GUARD=0 bypasses even a broken downstream configuration"

    rm -f "$log"; gg_rmrepo "$r"
  done
}
