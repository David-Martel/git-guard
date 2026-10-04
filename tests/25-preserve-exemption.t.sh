#!/bin/sh
# Category 25 — the preserve/* exemption: structural checks only, trailer-gated.
#
# A preservation commit snapshots WIP the hooks did not author, so a repo's
# language/lint gates (clarius lefthook: ast-grep, pyright, rust-no-panic;
# intublade astgrep_panics=strict) used to refuse it, which pushed preservation
# out of commits into fragile stash-create objects. The exemption lets such a
# commit through with ONLY the structural checks, and only when:
#   * the branch is preserve/* (or, at pre-push, every updated ref is
#     refs/heads/preserve/* or refs/preserve/*), AND
#   * the message carries a `Preserve-Of: <ref-or-sha>` trailer that resolves.
#
# The load-bearing assertions are the POSITIVE CONTROLS: a secret still blocks,
# the large-file guard still runs, a missing or unresolvable trailer still runs
# (and fails on) the deferred QA, a non-preserve branch gets nothing, and the
# per-repo opt-out turns it all off. The failing gate is a downstream hook
# ($GIT_GUARD_DOWNSTREAM_HOOK), the same chain lefthook is reached through, so
# the case needs no ast-grep/ruff and proves the downstream chain is skipped.
# shellcheck shell=sh

# t_pres_repo — a repo with git-guard hooks, one clean commit on main and a
# checked-out preserve/wip branch. Echoes its path.
t_pres_repo() {
  _r="$(gg_mktemp_repo)" || return 1
  (
    cd "$_r" || exit 1
    git config core.hooksPath "$GG_ROOT/hooks"
    git checkout -q -b main
    printf '# fixture\n' > README.md
    git add README.md
    GIT_GUARD_RULES_DIR="$GG_BUNDLED" git commit -q -m "initial" >/dev/null 2>&1 || exit 1
    git checkout -q -b preserve/wip
  ) || return 1
  printf '%s' "$_r"
}

# t_pres_commit REPO MSGFILE LOG [ENV...] — commit with the failing downstream
# witness hook wired in. Returns git commit's exit code.
t_pres_commit() {
  _r="$1"; _m="$2"; _l="$3"; shift 3
  ( cd "$_r" && env GIT_GUARD_DOWNSTREAM_HOOK="$GG_T_PRES_HOOK" \
      GIT_GUARD_RULES_DIR="$GG_BUNDLED" "$@" git commit -F "$_m" >"$_l" 2>&1 )
}

# t_pres_check MSG TEST... — run a test command, record ok/FAIL under MSG.
t_pres_check() {
  _msg="$1"; shift
  if "$@"; then t_ok "$_msg"; else t_fail "$_msg"; fi
}

# t_pres_head REPO — the subject of HEAD.
t_pres_head() { ( cd "$1" && git log -1 --format=%s 2>/dev/null ); }

t_case_preserve_exemption() {
  t_begin "25 preserve/* exemption (structural checks only, trailer-gated)"

  # The witness: a downstream gate that always fails and records that it ran.
  GG_T_PRES_DIR="$GG_T_TMPROOT/preserve"
  mkdir -p "$GG_T_PRES_DIR"
  GG_T_PRES_RAN="$GG_T_PRES_DIR/downstream-ran"
  GG_T_PRES_HOOK="$GG_T_PRES_DIR/failing-gate"
  printf '#!/bin/sh\nprintf ran >> "%s"\nexit 1\n' "$GG_T_PRES_RAN" > "$GG_T_PRES_HOOK"
  chmod +x "$GG_T_PRES_HOOK"

  msg_ok="$GG_T_PRES_DIR/msg-ok"
  printf 'preserve: snapshot WIP\n\nPreserve-Of: main\n' > "$msg_ok"
  msg_none="$GG_T_PRES_DIR/msg-none"
  printf 'preserve: snapshot WIP, no trailer\n' > "$msg_none"
  msg_bogus="$GG_T_PRES_DIR/msg-bogus"
  printf 'preserve: trailer names nothing\n\nPreserve-Of: refs/heads/no-such-branch\n' > "$msg_bogus"
  msg_revsyntax="$GG_T_PRES_DIR/msg-revsyntax"
  printf 'preserve: trailer uses revision syntax\n\nPreserve-Of: :/initial\n' > "$msg_revsyntax"
  log="$(gg_tmp_log)"

  # --- 1. NEGATIVE CONTROL: the trailer alone unlocks nothing off preserve/* --
  r="$(t_pres_repo)" || { t_fail "fixture repo could not be created"; return 1; }
  ( cd "$r" && git checkout -q -b feature/x && printf 'x\n' > a.txt && git add a.txt )
  rm -f "$GG_T_PRES_RAN"
  t_pres_commit "$r" "$msg_ok" "$log"; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "non-preserve branch + trailer: the failing gate still blocks (rc=$rc)"
  else t_fail "non-preserve branch + trailer: commit landed (exemption leaked off preserve/*)"; fi
  t_pres_check "non-preserve branch: the downstream gate ran" [ -f "$GG_T_PRES_RAN" ]
  gg_rmrepo "$r"

  # --- 2. The exemption: preserve/* + valid trailer skips QA + downstream -----
  r="$(t_pres_repo)" || { t_fail "fixture repo could not be created"; return 1; }
  ( cd "$r" && printf 'wip\n' > a.txt && git add a.txt )
  if gg_has_python; then
    gg_fixture_bad_json "$r"; ( cd "$r" && git add broken.json )
  fi
  rm -f "$GG_T_PRES_RAN"
  t_pres_commit "$r" "$msg_ok" "$log"; rc=$?
  t_expect_rc 0 "$rc" "preserve/* + valid Preserve-Of: the commit lands"
  t_pres_check "the preservation commit is HEAD" [ "$(t_pres_head "$r")" = "preserve: snapshot WIP" ]
  t_pres_check "the downstream gate was SKIPPED" [ ! -f "$GG_T_PRES_RAN" ]
  if gg_has_python; then
    if grep -q 'invalid JSON' "$log"; then t_fail "qa_gate's language checks ran on an exempted commit"
    else t_ok "qa_gate's language checks (validate.json=block) were skipped"; fi
  else
    t_skip "python absent: cannot plant the invalid-JSON gate"
  fi
  grep -q 'preserve exemption USED' "$log"; t_assert $? "stderr announces the exemption"
  plog="$(cd "$r" && git rev-parse --git-common-dir)/git-guard/preserve-exemptions.log"
  case "$plog" in /*) : ;; *) plog="$r/$plog" ;; esac
  if [ -f "$plog" ] && grep -q 'hook=commit-msg' "$plog" && grep -q 'preserve-of=main' "$plog" \
     && grep -q 'branch=preserve/wip' "$plog"; then
    t_ok "the exemption is logged to <git-common-dir>/git-guard/preserve-exemptions.log"
  else
    t_fail "no exemption log line in $plog"
  fi
  marker="$(cd "$r" && git rev-parse --git-path git-guard/preserve-deferred)"
  case "$marker" in /*) : ;; *) marker="$r/$marker" ;; esac
  t_pres_check "the deferral marker is consumed by commit-msg" [ ! -e "$marker" ]

  # --- 2b. The commit-msg downstream chain is skipped too --------------------
  ( cd "$r" && printf 'msg-chain\n' >> a.txt && git add a.txt )
  rm -f "$GG_T_PRES_RAN"
  t_pres_commit "$r" "$msg_ok" "$log" GIT_GUARD_DOWNSTREAM_COMMIT_MSG="$GG_T_PRES_HOOK"; rc=$?
  t_expect_rc 0 "$rc" "exempted commit + failing downstream commit-msg gate: lands"
  t_pres_check "the downstream commit-msg gate was skipped" [ ! -f "$GG_T_PRES_RAN" ]

  # --- 3. No trailer: the deferred QA runs in commit-msg and blocks ----------
  ( cd "$r" && printf 'more\n' >> a.txt && git add a.txt )
  head_before="$(cd "$r" && git rev-parse HEAD)"
  rm -f "$GG_T_PRES_RAN"
  t_pres_commit "$r" "$msg_none" "$log"; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "preserve/* without a trailer: the deferred gate blocks (rc=$rc)"
  else t_fail "preserve/* without a trailer: commit landed with QA skipped"; fi
  t_pres_check "without a trailer the downstream gate ran" [ -f "$GG_T_PRES_RAN" ]
  grep -q 'running the deferred QA' "$log"; t_assert $? "stderr says the deferred QA is running"
  t_pres_check "no commit landed" [ "$(cd "$r" && git rev-parse HEAD)" = "$head_before" ]

  # --- 4. A trailer naming nothing must not unlock ---------------------------
  rm -f "$GG_T_PRES_RAN"
  t_pres_commit "$r" "$msg_bogus" "$log"; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "unresolvable Preserve-Of: blocked (rc=$rc)"
  else t_fail "unresolvable Preserve-Of: unlocked the exemption"; fi
  t_pres_check "unresolvable trailer: the downstream gate ran" [ -f "$GG_T_PRES_RAN" ]

  # --- 5. Revision syntax (:/text, @{..}) is refused, not resolved -----------
  rm -f "$GG_T_PRES_RAN"
  t_pres_commit "$r" "$msg_revsyntax" "$log"; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "Preserve-Of: :/text is refused (rc=$rc)"
  else t_fail "Preserve-Of: :/text unlocked the exemption"; fi

  # --- 6. POSITIVE CONTROL: a planted secret still BLOCKS --------------------
  gg_fixture_fake_secret "$r"; ( cd "$r" && git add leak.js )
  rm -f "$GG_T_PRES_RAN"
  t_pres_commit "$r" "$msg_ok" "$log"; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "preserve/* + trailer + secret: BLOCKED (rc=$rc)"
  else t_fail "preserve/* + trailer + secret: the secret was committed"; fi
  grep -q 'possible secret' "$log"; t_assert $? "the secret scan named the leak"
  ( cd "$r" && git rm -q --cached leak.js && rm -f leak.js )

  # --- 7. POSITIVE CONTROL: the large-file guard still runs ------------------
  # largefile is WARN-only by design (qa_gate.sh offers no block mode), so the
  # control is that its warning still fires and honours the repo conf. The same
  # conf carries preserve_exemption=on, proving the new key is a KNOWN key.
  printf 'largefile_kb=1\npreserve_exemption=on\n' > "$r/.qa-gate.conf"
  awk 'BEGIN { for (i = 0; i < 64; i++) print "0123456789012345678901234567890123456789012345678901234567890123" }' \
    > "$r/big.txt"
  ( cd "$r" && git add big.txt )
  rm -f "$GG_T_PRES_RAN"
  t_pres_commit "$r" "$msg_ok" "$log"; rc=$?
  t_expect_rc 0 "$rc" "preserve/* + trailer + large file: lands (largefile is warn-only)"
  grep -q 'large staged file big.txt' "$log"; t_assert $? "the large-file guard still ran on the exempted commit"
  t_pres_check "the downstream gate stayed skipped" [ ! -f "$GG_T_PRES_RAN" ]

  # --- 8. Opt-out: .qa-gate.conf preserve_exemption=off ----------------------
  printf 'preserve_exemption=off\n' > "$r/.qa-gate.conf"
  ( cd "$r" && printf 'opt-out\n' >> a.txt && git add a.txt )
  rm -f "$GG_T_PRES_RAN"
  t_pres_commit "$r" "$msg_ok" "$log"; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "preserve_exemption=off: the failing gate blocks (rc=$rc)"
  else t_fail "preserve_exemption=off: the exemption still applied"; fi
  t_pres_check "preserve_exemption=off: the downstream gate ran" [ -f "$GG_T_PRES_RAN" ]
  rm -f "$r/.qa-gate.conf"

  # --- 9. Opt-out: GIT_GUARD_PRESERVE_EXEMPTION=0 ----------------------------
  rm -f "$GG_T_PRES_RAN"
  t_pres_commit "$r" "$msg_ok" "$log" GIT_GUARD_PRESERVE_EXEMPTION=0; rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "GIT_GUARD_PRESERVE_EXEMPTION=0: the failing gate blocks (rc=$rc)"
  else t_fail "GIT_GUARD_PRESERVE_EXEMPTION=0: the exemption still applied"; fi

  # --- 10. A stale marker for a different index cannot unlock ----------------
  marker="$(cd "$r" && git rev-parse --git-path git-guard/preserve-deferred)"
  case "$marker" in /*) : ;; *) marker="$r/$marker" ;; esac
  mkdir -p "$(dirname "$marker")"
  printf '%s preserve/wip\n' 0123456789abcdef0123456789abcdef01234567 > "$marker"
  rm -f "$GG_T_PRES_RAN"
  ( cd "$r" && env GIT_GUARD_DOWNSTREAM_HOOK="$GG_T_PRES_HOOK" GIT_GUARD_RULES_DIR="$GG_BUNDLED" \
      sh "$GG_ROOT/hooks/commit-msg" "$msg_ok" >"$log" 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "stale marker (tree mismatch): commit-msg runs the full QA (rc=$rc)"
  else t_fail "stale marker (tree mismatch): commit-msg passed without QA"; fi
  t_pres_check "the stale marker is removed" [ ! -e "$marker" ]
  gg_rmrepo "$r"

  # --- 11. pre-push: preserve-only pushes skip the downstream pre-push gate --
  r="$(t_pres_repo)" || { t_fail "fixture repo could not be created"; return 1; }
  remote="$(mktemp -d "${GG_T_TMPROOT:-/tmp}/gg.remote.XXXXXX")"
  git init -q --bare "$remote"
  ( cd "$r" && git remote add origin "$remote" && git push -q origin main >/dev/null 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "pre-push fixture: main pushed"
  ( cd "$r" && printf 'wip\n' > a.txt && git add a.txt )
  t_pres_commit "$r" "$msg_ok" "$log"; rc=$?
  t_expect_rc 0 "$rc" "pre-push fixture: an exempted preserve commit"

  rm -f "$GG_T_PRES_RAN"
  ( cd "$r" && env GIT_GUARD_DOWNSTREAM_PRE_PUSH="$GG_T_PRES_HOOK" \
      git push origin preserve/wip >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "push of refs/heads/preserve/* with trailered commits: exempt"
  t_pres_check "the downstream pre-push gate was skipped" [ ! -f "$GG_T_PRES_RAN" ]
  plog="$(cd "$r" && git rev-parse --git-common-dir)/git-guard/preserve-exemptions.log"
  case "$plog" in /*) : ;; *) plog="$r/$plog" ;; esac
  grep -q 'hook=pre-push' "$plog" 2>/dev/null; t_assert $? "the pre-push exemption is logged"

  # Mixed push: a preserve ref alongside an ordinary ref gets the normal pre-push.
  rm -f "$GG_T_PRES_RAN"
  ( cd "$r" && env GIT_GUARD_DOWNSTREAM_PRE_PUSH="$GG_T_PRES_HOOK" \
      git push origin preserve/wip:refs/heads/preserve/wip2 main:refs/heads/other >"$log" 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "mixed push (preserve + ordinary ref): normal pre-push blocks (rc=$rc)"
  else t_fail "mixed push: the exemption covered a non-preserve ref"; fi
  t_pres_check "mixed push: the downstream pre-push gate ran" [ -f "$GG_T_PRES_RAN" ]

  # A preserve ref carrying a commit WITHOUT the trailer gets the normal pre-push.
  notrailer="$(cd "$r" && git commit-tree -p HEAD -m 'no trailer' "HEAD^{tree}")"
  rm -f "$GG_T_PRES_RAN"
  ( cd "$r" && env GIT_GUARD_DOWNSTREAM_PRE_PUSH="$GG_T_PRES_HOOK" \
      git push origin "$notrailer:refs/heads/preserve/notrailer" >"$log" 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "preserve ref with a trailerless commit: normal pre-push blocks (rc=$rc)"
  else t_fail "preserve ref with a trailerless commit: exempted"; fi

  # refs/preserve/* (written by update-ref, so no commit hook ever ran) is covered.
  snap="$(cd "$r" && printf 'snapshot\n\nPreserve-Of: main\n' | git commit-tree -p HEAD "HEAD^{tree}")"
  ( cd "$r" && git update-ref refs/preserve/snap "$snap" )
  rm -f "$GG_T_PRES_RAN"
  ( cd "$r" && env GIT_GUARD_DOWNSTREAM_PRE_PUSH="$GG_T_PRES_HOOK" \
      git push origin refs/preserve/snap:refs/preserve/snap >"$log" 2>&1 ); rc=$?
  t_expect_rc 0 "$rc" "push of refs/preserve/* with a trailered commit: exempt"
  t_pres_check "refs/preserve/*: the downstream pre-push gate was skipped" [ ! -f "$GG_T_PRES_RAN" ]

  # POSITIVE CONTROL: a never-scanned refs/preserve/* commit carrying a secret.
  mkdir -p "$GG_T_PRES_DIR/leak"; gg_fixture_fake_secret "$GG_T_PRES_DIR/leak"
  leaktree="$( cd "$r" && blob="$(git hash-object -w "$GG_T_PRES_DIR/leak/leak.js")" &&
    printf '100644 blob %s\tleak.js\n' "$blob" | git mktree )"
  leak="$(cd "$r" && printf 'leak\n\nPreserve-Of: main\n' | git commit-tree -p HEAD "$leaktree")"
  ( cd "$r" && git update-ref refs/preserve/leak "$leak" )
  ( cd "$r" && git push origin refs/preserve/leak:refs/preserve/leak >"$log" 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "refs/preserve/* commit with a secret: push BLOCKED (rc=$rc)"
  else t_fail "refs/preserve/* commit with a secret: pushed"; fi
  grep -q 'possible secret' "$log"; t_assert $? "the pushed-commit secret scan named the leak"

  rm -f "$log"; rm -rf "$remote"; gg_rmrepo "$r"
}
