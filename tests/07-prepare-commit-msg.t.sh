#!/bin/sh
# Deterministic agent-attribution tests for prepare-commit-msg.

t_case_attribution() {
  t_begin "prepare-commit-msg attribution"

  r="$(gg_mktemp_repo)" || { t_fail "create attribution repo"; return; }
  mkdir -p "$r/test-hooks"
  cp "$GG_ROOT/hooks/prepare-commit-msg" "$r/test-hooks/prepare-commit-msg"
  chmod +x "$r/test-hooks/prepare-commit-msg"
  git -C "$r" config core.hooksPath "$r/test-hooks"

  printf 'human\n' > "$r/human.txt"
  git -C "$r" add human.txt
  (cd "$r" && CODEX_THREAD_ID='' GIT_GUARD_AGENT='' git commit -q -m "human commit")
  human_message="$(git -C "$r" log -1 --format=%B)"
  if printf '%s\n' "$human_message" | grep -q '^Agent:'; then
    t_fail "human commit remains unattributed"
  else
    t_ok "human commit remains unattributed"
  fi

  printf 'codex\n' > "$r/codex.txt"
  git -C "$r" add codex.txt
  (cd "$r" && CODEX_THREAD_ID=test-thread git commit -q -m "codex commit")
  codex_message="$(git -C "$r" log -1 --format=%B)"
  agent_count="$(printf '%s\n' "$codex_message" | grep -c '^Agent: codex$')"
  coauthor_count="$(printf '%s\n' "$codex_message" | grep -c '^Co-authored-by: Codex <codex@users.noreply.github.com>$')"
  t_expect_rc 1 "$agent_count" "Codex commit has one Agent trailer"
  t_expect_rc 1 "$coauthor_count" "Codex commit has one stable co-author trailer"

  printf 'dedupe\n' > "$r/dedupe.txt"
  git -C "$r" add dedupe.txt
  (cd "$r" && GIT_GUARD_AGENT=codex git commit -q \
    -m "pre-attributed commit" \
    -m "Agent: codex" \
    -m "Co-authored-by: Codex <codex@users.noreply.github.com>")
  dedupe_message="$(git -C "$r" log -1 --format=%B)"
  agent_count="$(printf '%s\n' "$dedupe_message" | grep -c '^Agent: codex$')"
  coauthor_count="$(printf '%s\n' "$dedupe_message" | grep -c '^Co-authored-by: Codex <codex@users.noreply.github.com>$')"
  t_expect_rc 1 "$agent_count" "existing Agent trailer is not duplicated"
  t_expect_rc 1 "$coauthor_count" "existing Codex co-author is not duplicated"

  printf 'bypass\n' > "$r/bypass.txt"
  git -C "$r" add bypass.txt
  (cd "$r" && GIT_GUARD=0 CODEX_THREAD_ID=test-thread git commit -q -m "emergency human commit")
  bypass_message="$(git -C "$r" log -1 --format=%B)"
  if printf '%s\n' "$bypass_message" | grep -q '^Agent:'; then
    t_fail "GIT_GUARD=0 bypass suppresses attribution"
  else
    t_ok "GIT_GUARD=0 bypass suppresses attribution"
  fi

  printf 'conflict\n' > "$r/conflict.txt"
  git -C "$r" add conflict.txt
  before="$(git -C "$r" rev-parse HEAD)"
  (cd "$r" && CODEX_THREAD_ID=test-thread git commit -q -m "conflicting commit" -m "Agent: claude" >/dev/null 2>&1)
  rc=$?
  after="$(git -C "$r" rev-parse HEAD)"
  t_expect_rc 1 "$rc" "conflicting Agent trailer blocks commit"
  if [ "$before" = "$after" ]; then
    t_ok "blocked conflicting commit does not land"
  else
    t_fail "blocked conflicting commit does not land"
  fi

  printf 'variant conflict\n\nagent : CLAUDE\n' > "$r/variant-message"
  (cd "$r" && CODEX_THREAD_ID=test-thread "$r/test-hooks/prepare-commit-msg" "$r/variant-message" >/dev/null 2>&1)
  rc=$?
  t_expect_rc 1 "$rc" "case and whitespace variant Agent trailer blocks"

  printf 'mixed conflict\n\nAgent: claude\nAgent: codex\n' > "$r/mixed-message"
  (cd "$r" && CODEX_THREAD_ID=test-thread "$r/test-hooks/prepare-commit-msg" "$r/mixed-message" >/dev/null 2>&1)
  rc=$?
  t_expect_rc 1 "$rc" "any conflicting Agent trailer blocks even when Codex is last"
  if grep -q '^Co-authored-by: Codex ' "$r/mixed-message"; then
    t_fail "blocked mixed attribution is not partially rewritten"
  else
    t_ok "blocked mixed attribution is not partially rewritten"
  fi

  gg_rmrepo "$r"
}
