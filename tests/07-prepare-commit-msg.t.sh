#!/bin/sh
# Deterministic agent-attribution tests for hooks/prepare-commit-msg.
#
# Behaviour protected: a commit made inside Codex gets exactly one
# `Agent: codex` trailer and one canonical `Co-authored-by: Codex
# <noreply@openai.com>`; a commit inside Claude Code gets exactly one
# `Agent: claude` and no hook-written co-author; a human commit is
# byte-identical. Legacy Codex co-author forms collapse to the canonical one;
# body text, folded trailers and other contributors survive; repeat runs are
# byte-idempotent; a conflicting Agent trailer refuses the commit; GIT_GUARD=0
# bypasses.
#
# What a failure means: every agent on a host commits as the same author, so
# the `Agent:` trailer is the attribution record that tooling parses
# (docs/IDENTITY.md). A missing, duplicated or wrong trailer misattributes
# history, and commit-msg / pre-push identity checks then report the wrong
# principal.

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
  coauthor_count="$(printf '%s\n' "$codex_trailers" | grep -c '^Co-authored-by: Codex <noreply@openai.com>$')"
  legacy_count="$(printf '%s\n' "$codex_message" | grep -c 'codex@users.noreply.github.com')"
  t_expect_rc 1 "$agent_count" "Codex commit has one Agent trailer"
  t_expect_rc 1 "$coauthor_count" "Codex commit has one canonical noreply@openai.com co-author trailer"
  t_expect_rc 0 "$legacy_count" "Codex commit never carries the legacy users.noreply address"

  printf 'dedupe\n' > "$r/dedupe.txt"
  git -C "$r" add dedupe.txt
  (cd "$r" && GIT_GUARD_AGENT=codex git commit -q \
    -m "pre-attributed commit" \
    -m "Agent: codex" \
    -m "Co-authored-by: Codex <noreply@openai.com>")
  dedupe_message="$(git -C "$r" log -1 --format=%B)"
  dedupe_trailers="$(printf '%s\n' "$dedupe_message" | git interpret-trailers --parse)"
  agent_count="$(printf '%s\n' "$dedupe_trailers" | grep -c '^Agent: codex$')"
  coauthor_count="$(printf '%s\n' "$dedupe_trailers" | grep -c '^Co-authored-by: Codex <noreply@openai.com>$')"
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
  coauthor_count="$(printf '%s\n' "$body_trailers" | grep -c '^Co-authored-by: Codex <noreply@openai.com>$')"
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
  t_expect_rc 1 "$(printf '%s\n' "$coauthor_trailers" | grep -c '^Co-authored-by: Codex <noreply@openai.com>$')" \
    "an existing canonical Codex co-author is not duplicated"
  printf '%s\n' "$coauthor_trailers" | grep -qx 'Co-authored-by: Other <other@example.test>'
  t_assert "$?" "another contributor remains attributed"
  printf '%s\n' "$coauthor_trailers" | grep -qx 'Co-authored-by: Codex <noreply@openai.com>'
  t_assert "$?" "existing canonical co-author is preserved"

  printf 'subject\n\nAgent: codex\nAgent: codex\nCo-authored-by: Codex <codex@users.noreply.github.com>\n' > "$r/duplicates-message"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/duplicates-message")
  duplicate_trailers="$(git interpret-trailers --parse "$r/duplicates-message")"
  agent_count="$(printf '%s\n' "$duplicate_trailers" | grep -c '^Agent: codex$')"
  coauthor_count="$(printf '%s\n' "$duplicate_trailers" | grep -c '^Co-authored-by: Codex <noreply@openai.com>$')"
  legacy_count="$(printf '%s\n' "$duplicate_trailers" | grep -c 'codex@users.noreply.github.com')"
  t_expect_rc 2 "$agent_count" "existing duplicate Agent metadata does not multiply"
  t_expect_rc 1 "$coauthor_count" "duplicate Agent input adds no duplicate co-author"
  t_expect_rc 0 "$legacy_count" "legacy generated co-author trailer is removed"

  # Legacy line removal is EXACT and trailer-only. A reworded/amended Codex
  # message drops the generated legacy trailer, while the same text in a body
  # paragraph, another contributor and a near-miss spelling all survive.
  printf 'subject\n\nQuoted in the body:\nCo-authored-by: Codex <codex@users.noreply.github.com>\n\nCo-authored-by: Other <other@example.test>\nCo-authored-by: Codex <codex@users.noreply.github.com>\nCo-authored-by: codex <codex@users.noreply.github.com>\nAgent: codex\n' > "$r/legacy-message"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/legacy-message")
  t_expect_rc 0 "$?" "legacy trailer message hook run succeeds"
  legacy_trailers="$(git interpret-trailers --parse "$r/legacy-message")"
  printf '%s\n' "$legacy_trailers" | grep -qx 'Co-authored-by: Codex <codex@users.noreply.github.com>'
  t_expect_rc 1 "$?" "exact legacy trailer is removed from the trailer block"
  printf '%s\n' "$legacy_trailers" | grep -qx 'Co-authored-by: Codex <noreply@openai.com>'
  t_assert "$?" "canonical co-author replaces the legacy trailer"
  printf '%s\n' "$legacy_trailers" | grep -qx 'Co-authored-by: Other <other@example.test>'
  t_assert "$?" "other contributor survives legacy removal"
  printf '%s\n' "$legacy_trailers" | grep -qx 'Co-authored-by: codex <codex@users.noreply.github.com>'
  t_assert "$?" "near-miss spelling is not a known generated line and survives"
  sed -n 3,4p "$r/legacy-message" > "$r/legacy-body"
  printf 'Quoted in the body:\nCo-authored-by: Codex <codex@users.noreply.github.com>\n' > "$r/legacy-body-expected"
  cmp -s "$r/legacy-body-expected" "$r/legacy-body"
  t_assert "$?" "legacy text in a body paragraph is preserved byte-for-byte"
  cp "$r/legacy-message" "$r/legacy-repeat"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/legacy-message")
  cmp -s "$r/legacy-repeat" "$r/legacy-message"
  t_assert "$?" "legacy removal is byte-idempotent on a second run"

  # A FINAL paragraph that Git does not parse as a trailer block (prose plus
  # the quoted legacy line) is body text: the legacy line must survive.
  printf 'subject\n\nline one of prose\nline two of prose\nline three of prose\nline four of prose\nline five of prose\nCo-authored-by: Codex <codex@users.noreply.github.com>\n' > "$r/prose-legacy-message"
  git interpret-trailers --parse "$r/prose-legacy-message" | grep -q 'users.noreply'
  t_expect_rc 1 "$?" "precondition: Git does not parse the prose paragraph as trailers"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/prose-legacy-message")
  t_expect_rc 0 "$?" "prose-paragraph hook run succeeds"
  sed -n 3,8p "$r/prose-legacy-message" > "$r/prose-legacy-body"
  printf 'line one of prose\nline two of prose\nline three of prose\nline four of prose\nline five of prose\nCo-authored-by: Codex <codex@users.noreply.github.com>\n' > "$r/prose-legacy-expected"
  cmp -s "$r/prose-legacy-expected" "$r/prose-legacy-body"
  t_assert "$?" "legacy text in a non-trailer final paragraph is preserved"

  # core.commentChar: an editor/amend message ends with comment lines in the
  # CONFIGURED character; the trailer block above them is still found.
  git -C "$r" config core.commentChar ';'
  printf 'subject\n\nCo-authored-by: Codex <codex@users.noreply.github.com>\nAgent: codex\n\n; Please enter the commit message for your changes.\n; Lines starting with ; will be ignored.\n' > "$r/commentchar-message"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/commentchar-message")
  t_expect_rc 0 "$?" "commentChar hook run succeeds"
  if grep -q 'users.noreply' "$r/commentchar-message"; then
    t_fail "legacy trailer is removed when core.commentChar is ';'"
  else
    t_ok "legacy trailer is removed when core.commentChar is ';'"
  fi
  grep -qx '; Lines starting with ; will be ignored.' "$r/commentchar-message"
  t_assert "$?" "configured-character comment lines are preserved"
  git -C "$r" config --unset core.commentChar

  # Every earlier generated form COLLAPSES into the one canonical line:
  # legacy users.noreply + unmerged-draft agents.invalid + canonical -> 1 line.
  printf 'subject\n\nCo-authored-by: Codex <codex@users.noreply.github.com>\nCo-authored-by: Codex <codex@agents.invalid>\nCo-authored-by: Codex <noreply@openai.com>\nAgent: codex\n' > "$r/collapse-message"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/collapse-message")
  t_expect_rc 0 "$?" "collapse hook run succeeds"
  collapse_trailers="$(git interpret-trailers --parse "$r/collapse-message")"
  t_expect_rc 1 "$(printf '%s\n' "$collapse_trailers" | grep -c '^Co-authored-by: Codex ')" \
    "legacy, draft and canonical Codex co-authors collapse to one line"
  printf '%s\n' "$collapse_trailers" | grep -qx 'Co-authored-by: Codex <noreply@openai.com>'
  t_assert "$?" "the surviving Codex co-author is the canonical noreply@openai.com"
  printf 'subject\n\nCo-authored-by: Codex <codex@agents.invalid>\n' > "$r/draft-message"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/draft-message")
  if grep -q 'agents.invalid' "$r/draft-message"; then
    t_fail "draft agents.invalid trailer is replaced by the canonical address"
  else
    t_ok "draft agents.invalid trailer is replaced by the canonical address"
  fi

  # A FOLDED trailer (a legacy-looking first line plus an indented
  # continuation) is ONE logical trailer whose parsed value is not an exact
  # generated form. Deleting only its first physical line orphans the
  # continuation, Git then stops recognising the block, and every other
  # contributor in it (here: Other) silently loses parsed co-author identity.
  # Only the complete, unfolded exact legacy trailer may be collapsed.
  printf 'subject\n\nCo-authored-by: Codex <codex@users.noreply.github.com>\n authored implementation only\nCo-authored-by: Codex <codex@users.noreply.github.com>\nCo-authored-by: Other <other@example.test>\nAgent: codex\n' > "$r/folded-message"
  folded_before="$(git interpret-trailers --parse "$r/folded-message")"
  printf '%s\n' "$folded_before" | grep -qx 'Co-authored-by: Other <other@example.test>'
  t_assert "$?" "control: Git parses Other in the folded fixture before the hook"
  printf '%s\n' "$folded_before" |
    grep -qx 'Co-authored-by: Codex <codex@users.noreply.github.com> authored implementation only'
  t_assert "$?" "control: Git parses the folded Codex trailer as one logical value"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/folded-message")
  t_expect_rc 0 "$?" "folded-trailer hook run succeeds"
  folded_after="$(git interpret-trailers --parse "$r/folded-message")"
  printf '%s\n' "$folded_after" | grep -qx 'Co-authored-by: Other <other@example.test>'
  t_assert "$?" "folded trailer: Other keeps parsed co-author identity"
  printf '%s\n' "$folded_after" |
    grep -qx 'Co-authored-by: Codex <codex@users.noreply.github.com> authored implementation only'
  t_assert "$?" "folded trailer: the continuation-bearing trailer is kept as one logical trailer"
  printf '%s\n' "$folded_after" | grep -qx 'Co-authored-by: Codex <codex@users.noreply.github.com>'
  t_expect_rc 1 "$?" "positive control: the complete unfolded legacy trailer is still collapsed"
  t_expect_rc 1 "$(printf '%s\n' "$folded_after" | grep -c '^Co-authored-by: Codex <noreply@openai.com>$')" \
    "folded trailer: exactly one canonical Codex co-author is added"
  printf '%s\n' "$folded_after" | grep -qx 'Agent: codex'
  t_assert "$?" "folded trailer: Agent stays a parsed trailer"
  printf 'Co-authored-by: Codex <codex@users.noreply.github.com>\n authored implementation only\n' > "$r/folded-expected"
  sed -n 3,4p "$r/folded-message" > "$r/folded-kept"
  cmp -s "$r/folded-expected" "$r/folded-kept"
  t_assert "$?" "folded trailer: both physical lines are preserved byte-for-byte"
  cp "$r/folded-message" "$r/folded-repeat"
  (cd "$r" && GIT_GUARD_AGENT=codex "$r/test-hooks/prepare-commit-msg" "$r/folded-message")
  cmp -s "$r/folded-repeat" "$r/folded-message"
  t_assert "$?" "folded trailer: a second invocation is byte-idempotent"
  git interpret-trailers --parse "$r/folded-message" | grep -qx 'Co-authored-by: Other <other@example.test>'
  t_assert "$?" "folded trailer: Other is still parsed after a second invocation"

  # core.commentChar=auto: a REAL `git commit --amend` through an editor whose
  # body has a `#` line makes git pick another comment character (e.g. ';').
  # The legacy trailer above those comments must still collapse.
  printf 'auto\n' > "$r/auto.txt"
  git -C "$r" add auto.txt
  (cd "$r" && GIT_GUARD=0 git commit -q -m "auto subject" -m "# a markdown heading in the body" \
    -m "Co-authored-by: Codex <codex@users.noreply.github.com>
Agent: codex")
  (cd "$r" && GIT_GUARD_AGENT=codex GIT_EDITOR=true git -c core.commentChar=auto commit -q --amend)
  t_expect_rc 0 "$?" "commentChar=auto editor amend succeeds"
  auto_message="$(git -C "$r" log -1 --format=%B)"
  t_expect_rc 0 "$(printf '%s\n' "$auto_message" | grep -c 'codex@users.noreply.github.com')" \
    "commentChar=auto amend drops the legacy trailer"
  t_expect_rc 1 "$(printf '%s\n' "$auto_message" | grep -c '^Co-authored-by: Codex <noreply@openai.com>$')" \
    "commentChar=auto amend carries exactly one canonical co-author"
  printf '%s\n' "$auto_message" | grep -qx '# a markdown heading in the body'
  t_assert "$?" "commentChar=auto amend keeps the '#' body line"

  # Real auto+verbose amends must place attribution above Git's scissors.
  # Inject a literal body marker only after Git selects its comment character;
  # Git 2.55 otherwise consumes seeded scissors while preparing the template.
  for probe_agent in codex claude; do
    for probe_marker in 0 1; do
      probe="$(gg_mktemp_repo)" || { t_fail "create verbose attribution fixture"; return; }
      mkdir "$probe/test-hooks"
      cp "$GG_ROOT/hooks/prepare-commit-msg" "$probe/test-hooks/production"
      cat > "$probe/test-hooks/prepare-commit-msg" <<'GG_VERBOSE_HOOK'
#!/bin/sh
set -eu
if [ "$GG_ATTR_MARKER" = 1 ]; then
  awk '{print; if ($0 == "# a markdown heading in the body") {
    print ""; print "# ------------------------ >8 ------------------------"
  }}' "$1" > "$1.injected"
  cat "$1.injected" > "$1"
  rm "$1.injected"
fi
cp "$1" "$GG_ATTR_ROOT/before"
sh "$GG_ATTR_ROOT/test-hooks/production" "$@"
cp "$1" "$GG_ATTR_ROOT/after"
GG_VERBOSE_HOOK
      chmod +x "$probe/test-hooks/prepare-commit-msg"
      git -C "$probe" config core.hooksPath "$probe/test-hooks"
      printf 'verbose fixture\n' > "$probe/a.txt"
      git -C "$probe" add a.txt
      probe_tree="$(git -C "$probe" write-tree)"
      # Plumbing creates only synthetic private fixture history; no installed
      # hook is invoked or bypassed to plant intentionally legacy attribution.
      if [ "$probe_agent" = codex ]; then
        probe_seed="$(printf 'auto subject\n\n# a markdown heading in the body\n\nCo-authored-by: Codex <codex@users.noreply.github.com>\nAgent: codex\n' |
          git -C "$probe" commit-tree "$probe_tree")"
      else
        probe_seed="$(printf 'auto subject\n\n# a markdown heading in the body\n\nCo-authored-by: Other <other@example.test>\n' |
          git -C "$probe" commit-tree "$probe_tree")"
      fi
      git -C "$probe" update-ref HEAD "$probe_seed"
      (cd "$probe" && GG_ATTR_ROOT="$probe" GG_ATTR_MARKER="$probe_marker" GIT_GUARD_AGENT="$probe_agent" GIT_EDITOR=true \
        git -c core.commentChar=auto -c commit.verbose=true commit -q --amend)
      t_expect_rc 0 "$?" "$probe_agent real auto+verbose amend (literal marker=$probe_marker)"
      git -C "$probe" log -1 --format=%B > "$probe/message"
      git -c 'core.commentChar=;' interpret-trailers --parse "$probe/message" > "$probe/trailers"
      t_expect_rc 1 "$(grep -c "^Agent: $probe_agent$" "$probe/trailers")" "$probe_agent remains exactly one parsed trailer above verbose diff"
      grep -qx '# a markdown heading in the body' "$probe/message"
      t_assert "$?" "$probe_agent verbose amend preserves body heading"
      if [ "$probe_marker" = 1 ]; then
        grep -qx '# ------------------------ >8 ------------------------' "$probe/message"
        t_assert "$?" "$probe_agent preserves earlier literal body scissors"
      fi
      if [ "$probe_agent" = codex ]; then
        t_expect_rc 0 "$(grep -c 'codex@users.noreply.github.com' "$probe/message")" "verbose amend removes the exact legacy Codex trailer"
        t_expect_rc 1 "$(grep -c '^Co-authored-by: Codex <noreply@openai.com>$' "$probe/trailers")" "verbose amend has exactly one parsed canonical co-author"
      else
        grep -qx 'Co-authored-by: Other <other@example.test>' "$probe/trailers"
        t_assert "$?" "Claude verbose amend preserves the other contributor"
      fi
      grep -qx '; ------------------------ >8 ------------------------' "$probe/before"
      t_assert "$?" "actual Git selected semicolon for the verbose boundary"
      sed -n '/^; ------------------------ >8 ------------------------$/,$p' "$probe/before" > "$probe/tail-before"
      sed -n '/^; ------------------------ >8 ------------------------$/,$p' "$probe/after" > "$probe/tail-after"
      cmp -s "$probe/tail-before" "$probe/tail-after"
      t_assert "$?" "$probe_agent scissors and actual verbose diff remain byte-identical"
      gg_rmrepo "$probe"
    done
  done

  # A human (no agent) never has a message rewritten, legacy line included.
  printf 'human amend\n\nCo-authored-by: Codex <codex@users.noreply.github.com>\n' > "$r/human-legacy-message"
  cp "$r/human-legacy-message" "$r/human-legacy-before"
  (cd "$r" && CODEX_THREAD_ID='' GIT_GUARD_AGENT='' "$r/test-hooks/prepare-commit-msg" "$r/human-legacy-message")
  cmp -s "$r/human-legacy-before" "$r/human-legacy-message"
  t_assert "$?" "human message with the legacy line stays byte-identical"

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

# Claude Code attribution. Claude Code exports CLAUDECODE=1 (and
# CLAUDE_CODE_ENTRYPOINT) into every shell it spawns; the hook must add exactly
# one `Agent: claude` trailer and nothing else (the co-author line carries a
# model name, so Claude writes it itself and the hook never duplicates it).
t_case_attribution_claude() {
  t_begin "prepare-commit-msg Claude attribution"

  r="$(gg_mktemp_repo)" || { t_fail "create Claude attribution repo"; return; }
  mkdir -p "$r/test-hooks"
  cp "$GG_ROOT/hooks/prepare-commit-msg" "$r/test-hooks/prepare-commit-msg"
  chmod +x "$r/test-hooks/prepare-commit-msg"
  git -C "$r" config core.hooksPath "$r/test-hooks"

  # Positive control: a real `git commit` under CLAUDECODE=1.
  printf 'claude\n' > "$r/claude.txt"
  git -C "$r" add claude.txt
  (cd "$r" && CLAUDECODE=1 git commit -q -m "claude commit")
  claude_trailers="$(git -C "$r" log -1 --format=%B | git interpret-trailers --parse)"
  agent_count="$(printf '%s\n' "$claude_trailers" | grep -c '^Agent: claude$')"
  t_expect_rc 1 "$agent_count" "CLAUDECODE=1 commit has one Agent: claude trailer"
  coauthor_count="$(printf '%s\n' "$claude_trailers" | grep -c '^Co-authored-by:')"
  t_expect_rc 0 "$coauthor_count" "hook adds no Co-authored-by for Claude"

  # CLAUDE_CODE_ENTRYPOINT alone is also a Claude Code marker.
  printf 'subject\n' > "$r/entrypoint-message"
  (cd "$r" && CLAUDE_CODE_ENTRYPOINT=cli "$r/test-hooks/prepare-commit-msg" "$r/entrypoint-message")
  t_expect_rc 0 "$?" "CLAUDE_CODE_ENTRYPOINT hook run succeeds"
  git interpret-trailers --parse "$r/entrypoint-message" | grep -qx 'Agent: claude'
  t_assert "$?" "CLAUDE_CODE_ENTRYPOINT attributes to claude"

  # An existing Agent: claude trailer (and Claude's own co-author) is kept once.
  printf 'dedupe\n' > "$r/dedupe.txt"
  git -C "$r" add dedupe.txt
  (cd "$r" && CLAUDECODE=1 git commit -q \
    -m "pre-attributed claude commit" \
    -m "Agent: claude
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>")
  dedupe_trailers="$(git -C "$r" log -1 --format=%B | git interpret-trailers --parse)"
  agent_count="$(printf '%s\n' "$dedupe_trailers" | grep -c '^Agent: claude$')"
  t_expect_rc 1 "$agent_count" "existing Agent: claude trailer is not duplicated"
  coauthor_count="$(printf '%s\n' "$dedupe_trailers" | grep -c '^Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>$')"
  t_expect_rc 1 "$coauthor_count" "Claude's own co-author trailer is preserved once"

  # Idempotent: a second run leaves the message byte-identical.
  printf 'subject\n\nbody\n' > "$r/repeat-message"
  (cd "$r" && CLAUDECODE=1 "$r/test-hooks/prepare-commit-msg" "$r/repeat-message")
  cp "$r/repeat-message" "$r/repeat-before"
  (cd "$r" && CLAUDECODE=1 "$r/test-hooks/prepare-commit-msg" "$r/repeat-message")
  cmp -s "$r/repeat-before" "$r/repeat-message"
  t_assert "$?" "repeat Claude hook run is byte-idempotent"

  # A Codex process spawned from inside Claude Code inherits CLAUDECODE=1 but
  # carries its own CODEX_THREAD_ID: the per-process marker wins.
  printf 'nested\n' > "$r/nested.txt"
  git -C "$r" add nested.txt
  (cd "$r" && CLAUDECODE=1 CODEX_THREAD_ID=test-thread git commit -q -m "codex inside claude")
  nested_trailers="$(git -C "$r" log -1 --format=%B | git interpret-trailers --parse)"
  printf '%s\n' "$nested_trailers" | grep -qx 'Agent: codex'
  t_assert "$?" "CODEX_THREAD_ID outranks inherited CLAUDECODE"
  if printf '%s\n' "$nested_trailers" | grep -q '^Agent: claude'; then
    t_fail "nested Codex commit carries no Agent: claude"
  else
    t_ok "nested Codex commit carries no Agent: claude"
  fi

  # Explicit selector outranks every ambient marker.
  printf 'subject\n' > "$r/explicit-message"
  (cd "$r" && CLAUDECODE='' CODEX_THREAD_ID=test-thread GIT_GUARD_AGENT=claude "$r/test-hooks/prepare-commit-msg" "$r/explicit-message")
  git interpret-trailers --parse "$r/explicit-message" | grep -qx 'Agent: claude'
  t_assert "$?" "GIT_GUARD_AGENT=claude attributes to claude"

  # Empty / non-1 markers are not Claude Code.
  printf 'subject\n' > "$r/none-message"
  cp "$r/none-message" "$r/none-before"
  (cd "$r" && CLAUDECODE='' CLAUDE_CODE_ENTRYPOINT='' CODEX_THREAD_ID='' "$r/test-hooks/prepare-commit-msg" "$r/none-message")
  t_expect_rc 0 "$?" "no agent env hook run succeeds"
  cmp -s "$r/none-before" "$r/none-message"
  t_assert "$?" "no agent env leaves message byte-identical"

  # Symmetric conflict: Claude committing over an Agent: codex line blocks.
  printf 'conflict\n' > "$r/conflict.txt"
  git -C "$r" add conflict.txt
  before="$(git -C "$r" rev-parse HEAD)"
  (cd "$r" && CLAUDECODE=1 git commit -q -m "conflicting claude commit" -m "Agent: codex" >/dev/null 2>&1)
  rc=$?
  after="$(git -C "$r" rev-parse HEAD)"
  t_expect_rc 1 "$rc" "Claude commit with Agent: codex trailer blocks"
  if [ "$before" = "$after" ]; then
    t_ok "blocked conflicting Claude commit does not land"
  else
    t_fail "blocked conflicting Claude commit does not land"
  fi

  # GIT_GUARD=0 is a no-op for Claude too.
  printf 'subject\n' > "$r/bypass-message"
  cp "$r/bypass-message" "$r/bypass-before"
  (cd "$r" && GIT_GUARD=0 CLAUDECODE=1 "$r/test-hooks/prepare-commit-msg" "$r/bypass-message")
  t_expect_rc 0 "$?" "GIT_GUARD=0 Claude hook run succeeds"
  cmp -s "$r/bypass-before" "$r/bypass-message"
  t_assert "$?" "GIT_GUARD=0 leaves Claude message byte-identical"

  # Message sources ($2) are not special-cased: merge, squash and amend
  # (commit) are attributed exactly like a plain message.
  for src in merge squash commit; do
    printf 'Merge branch x\n' > "$r/src-$src-message"
    (cd "$r" && CLAUDECODE=1 "$r/test-hooks/prepare-commit-msg" "$r/src-$src-message" "$src" HEAD)
    t_expect_rc 0 "$?" "Claude hook run succeeds for source=$src"
    git interpret-trailers --parse "$r/src-$src-message" | grep -qx 'Agent: claude'
    t_assert "$?" "source=$src is attributed to claude"
  done

  # A squash message indents the squashed commits' trailers; an indented
  # `Agent: codex` is body text, not a conflict.
  printf 'Squashed commit of the following:\n\n    codex work\n\n    Agent: codex\n' > "$r/squash-body-message"
  (cd "$r" && CLAUDECODE=1 "$r/test-hooks/prepare-commit-msg" "$r/squash-body-message" squash)
  t_expect_rc 0 "$?" "indented squashed Agent: codex does not conflict"
  git interpret-trailers --parse "$r/squash-body-message" | grep -qx 'Agent: claude'
  t_assert "$?" "squash message is attributed to claude"

  gg_rmrepo "$r"
}
