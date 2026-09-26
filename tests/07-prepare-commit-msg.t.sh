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
  codex_trailers="$(printf '%s\n' "$codex_message" | git interpret-trailers --parse)"
  agent_count="$(printf '%s\n' "$codex_trailers" | grep -c '^Agent: codex$')"
  coauthor_count="$(printf '%s\n' "$codex_trailers" | grep -c '^Co-authored-by: Codex <codex@users.noreply.github.com>$')"
  t_expect_rc 1 "$agent_count" "Codex commit has one Agent trailer"
  t_expect_rc 1 "$coauthor_count" "Codex commit has one stable co-author trailer"

  printf 'dedupe\n' > "$r/dedupe.txt"
  git -C "$r" add dedupe.txt
  (cd "$r" && GIT_GUARD_AGENT=codex git commit -q \
    -m "pre-attributed commit" \
    -m "Agent: codex" \
    -m "Co-authored-by: Codex <codex@users.noreply.github.com>")
  dedupe_message="$(git -C "$r" log -1 --format=%B)"
  dedupe_trailers="$(printf '%s\n' "$dedupe_message" | git interpret-trailers --parse)"
  agent_count="$(printf '%s\n' "$dedupe_trailers" | grep -c '^Agent: codex$')"
  coauthor_count="$(printf '%s\n' "$dedupe_trailers" | grep -c '^Co-authored-by: Codex <codex@users.noreply.github.com>$')"
  t_expect_rc 1 "$agent_count" "existing Agent trailer is not duplicated"
  t_expect_rc 1 "$coauthor_count" "existing Codex co-author is not duplicated"

  # Existing body paragraphs must neither suppress final attribution nor be
  # deleted to make a grep-based count look correct.
  printf 'subject\n\nAgent: codex\n\nPreserve this body.\n\nCodex <codex@users.noreply.github.com>\n' > "$r/body-message"
  cp "$r/body-message" "$r/body-before"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/body-message")
  t_expect_rc 0 "$?" "body Agent does not prevent final attribution"
  body_trailers="$(git interpret-trailers --parse "$r/body-message")"
  agent_count="$(printf '%s\n' "$body_trailers" | grep -c '^Agent: codex$')"
  coauthor_count="$(printf '%s\n' "$body_trailers" | grep -c '^Co-authored-by: Codex <codex@users.noreply.github.com>$')"
  t_expect_rc 1 "$agent_count" "body case has one parsed Agent trailer"
  t_expect_rc 1 "$coauthor_count" "body case has one parsed canonical co-author"
  body_lines="$(wc -l < "$r/body-before" | tr -d ' ')"
  head -n "$body_lines" "$r/body-message" > "$r/body-prefix"
  cmp -s "$r/body-before" "$r/body-prefix"
  t_assert "$?" "original body is preserved byte-for-byte"

  printf 'subject\n\nagent : CODEX\nCo-authored-by: Other <other@example.test>\nCo-authored-by: Codex <noreply@openai.com>\n' > "$r/coauthors-message"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/coauthors-message")
  t_expect_rc 0 "$?" "canonical Agent and co-author added alongside other authors"
  coauthor_trailers="$(git interpret-trailers --parse "$r/coauthors-message")"
  printf '%s\n' "$coauthor_trailers" | grep -qx 'Agent: codex'
  t_assert "$?" "case/spacing variant becomes canonical parsed Agent"
  printf '%s\n' "$coauthor_trailers" | grep -qx 'Co-authored-by: Codex <codex@users.noreply.github.com>'
  t_assert "$?" "legacy co-author does not suppress canonical co-author"
  printf '%s\n' "$coauthor_trailers" | grep -qx 'Co-authored-by: Other <other@example.test>'
  t_assert "$?" "another contributor remains attributed"
  printf '%s\n' "$coauthor_trailers" | grep -qx 'Co-authored-by: Codex <noreply@openai.com>'
  t_assert "$?" "existing co-author metadata is preserved"

  printf 'subject\n\nAgent: codex\nAgent: codex\nCo-authored-by: Codex <codex@users.noreply.github.com>\n' > "$r/duplicates-message"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/duplicates-message")
  duplicate_trailers="$(git interpret-trailers --parse "$r/duplicates-message")"
  agent_count="$(printf '%s\n' "$duplicate_trailers" | grep -c '^Agent: codex$')"
  coauthor_count="$(printf '%s\n' "$duplicate_trailers" | grep -c '^Co-authored-by: Codex <codex@users.noreply.github.com>$')"
  t_expect_rc 2 "$agent_count" "existing duplicate Agent metadata does not multiply"
  t_expect_rc 1 "$coauthor_count" "duplicate Agent input adds no duplicate co-author"

  for message in body-message coauthors-message duplicates-message; do
    cp "$r/$message" "$r/repeat-before"
    (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/$message")
    t_expect_rc 0 "$?" "repeat hook succeeds for $message"
    cmp -s "$r/repeat-before" "$r/$message"
    t_assert "$?" "repeat hook is byte-idempotent for $message"
  done

  printf 'explicit other agent\n\nAgent: claude\n' > "$r/other-agent-message"
  cp "$r/other-agent-message" "$r/other-agent-before"
  (cd "$r" && CODEX_THREAD_ID=test-thread GIT_GUARD_AGENT=claude "$r/test-hooks/prepare-commit-msg" "$r/other-agent-message")
  t_expect_rc 0 "$?" "explicit non-Codex agent overrides ambient Codex detection"
  cmp -s "$r/other-agent-before" "$r/other-agent-message"
  t_assert "$?" "non-Codex message remains byte-identical"

  printf 'bypass\n' > "$r/bypass.txt"
  git -C "$r" add bypass.txt
  (cd "$r" && GIT_GUARD=0 CODEX_THREAD_ID=test-thread git commit -q -m "emergency human commit")
  bypass_message="$(git -C "$r" log -1 --format=%B)"
  if printf '%s\n' "$bypass_message" | grep -q '^Agent:'; then
    t_fail "GIT_GUARD=0 bypass suppresses attribution"
  else
    t_ok "GIT_GUARD=0 bypass suppresses attribution"
  fi

  printf 'bypass preserves conflict\n\nAgent: claude\n' > "$r/bypass-message"
  cp "$r/bypass-message" "$r/bypass-before"
  (cd "$r" && GIT_GUARD=0 GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/bypass-message")
  t_expect_rc 0 "$?" "explicit bypass precedes conflict detection"
  cmp -s "$r/bypass-before" "$r/bypass-message"
  t_assert "$?" "bypass message remains byte-identical"

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
