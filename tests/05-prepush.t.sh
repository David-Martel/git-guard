#!/bin/sh
# Category 5 — pre-push blocking. git-guard's HARD enforcement lives at
# pre-commit (the gate is staged-file oriented; nothing is staged at push time).
# The shipped pre-push is a thin OPTIONAL downstream-chaining hook: it runs a
# configured downstream gate (e.g. a heavy tests/clippy pusher) and refuses the
# push when that gate fails. This case proves that block-wiring: a planted
# failing `.git-guard/pre-push.local` refuses the push, and GIT_GUARD=0 bypasses.
# A pre-push hook already exists, so we assert its refusal path (per the prompt).
# shellcheck shell=sh

t_case_prepush() {
  t_begin "05 pre-push blocking (downstream chain refusal)"
  [ -f "$GG_ROOT/hooks/pre-push" ] || { t_fail "hooks/pre-push missing"; return 0; }

  r="$(gg_mktemp_repo)"
  mkdir -p "$r/.git-guard"
  printf '#!/bin/sh\necho "downstream pre-push gate FAILED" >&2\nexit 7\n' > "$r/.git-guard/pre-push.local"
  chmod +x "$r/.git-guard/pre-push.local"

  # 1. A failing downstream gate must make pre-push refuse (non-zero).
  logf="$(gg_tmp_log)"
  ( cd "$r" && sh "$GG_ROOT/hooks/pre-push" origin git@example >/dev/null 2>"$logf" </dev/null ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "pre-push refuses when downstream gate fails (rc=$rc)"; else t_fail "pre-push did NOT refuse a failing downstream gate"; fi
  grep -q "downstream pre-push gate FAILED" "$logf" 2>/dev/null \
    && t_ok "downstream pre-push gate output surfaced" \
    || t_fail "downstream pre-push gate output missing"
  rm -f "$logf"

  # 2. GIT_GUARD=0 is the documented conscious bypass (push proceeds).
  ( cd "$r" && GIT_GUARD=0 sh "$GG_ROOT/hooks/pre-push" origin git@example >/dev/null 2>&1 </dev/null ); rc=$?
  t_expect_rc 0 "$rc" "GIT_GUARD=0 bypasses pre-push (conscious escape hatch)"

  # 3. With NO downstream gate, pre-push is a clean no-op (never blocks a push).
  rm -rf "$r/.git-guard"
  ( cd "$r" && sh "$GG_ROOT/hooks/pre-push" origin git@example >/dev/null 2>&1 </dev/null ); rc=$?
  t_expect_rc 0 "$rc" "pre-push is a clean no-op with no downstream gate"

  gg_rmrepo "$r"
}
